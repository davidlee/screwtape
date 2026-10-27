//// Contract tests for `screwtape/sync` (PHASE-05 T5; EX-2..EX-6; VT-1..VT-4).
////
//// Every case runs the real `sync.run` over a real `Client` bound to a
//// scripted `fixture_send` (session, the three-call opening request, then one
//// JMAP call per request), against a
//// temporary store whose writer stays open (`support/sync_fixture`). Every case
//// asserts the exact sequence of JMAP calls sent and that no request went
//// unmatched, so a run that sends an extra page, a repeated get or a call out
//// of order fails even when its result looks right.
////
//// "Unchanged" means a byte-for-byte equal logical dump, `user_version`
//// included, taken on the path while the writer is open; the writer must then
//// still commit, so a transaction left open by a failed run shows.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleeunit
import gleeunit/should
import screwtape/config
import screwtape/error
import screwtape/jmap/request.{EmailGet, EmailQuery, MailboxGet, ThreadGet}
import screwtape/model
import screwtape/normalise
import screwtape/sync
import support/fixture_send.{type Step}
import support/jmap_fixture
import support/sync_fixture.{
  type Run, type Store, Spec, bounds, count, emails, emails_of, expect_calls,
  expect_unchanged, fail_at, fetch, fetch_chunked, id_lists, ids, mailboxes,
  methods, page, page_with, positions, rows, run, run_sync, seeded, spec,
  summary, threads, threads_of, type_states, with_store,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------- helpers

/// The one-mailbox `Mailbox/get` most cases start with.
fn inbox_step() -> Step {
  mailboxes([sync_fixture.inbox()], "ms-1")
}

/// Mailboxes, `pages`, then the gets that deliver `delivered` whole.
fn script_of(pages: List(Step), delivered: List(String)) -> List(Step) {
  list.flatten([[inbox_step()], pages, fetch(emails_of(delivered))])
}

/// A phase 1 that finds nothing: one empty page.
fn empty_page() -> Step {
  page([], "qs-1", 0, 0, None)
}

fn with_pages(bounds: sync.Bounds, max_pages: Int) -> sync.Bounds {
  sync.Bounds(..bounds, max_pages: max_pages)
}

fn window(mailboxes: List(String)) -> sync.Bounds {
  sync.Bounds(
    ..bounds(Some(100)),
    window: config.Window(
      mailboxes: mailboxes,
      max_age_days: None,
      max_messages: Some(100),
      retain_messages: None,
    ),
  )
}

/// Two pages of three under the server's clamp of 3, both from position 0 of
/// one attempt: the first with `first_state`, the second with `second_state`.
fn attempt(
  prefix: String,
  first_state: String,
  second_state: String,
  can_calculate_changes: Bool,
) -> List(Step) {
  [
    page_with(
      ids(prefix, 1, 3),
      first_state,
      0,
      20,
      Some(3),
      can_calculate_changes,
    ),
    page(ids(prefix, 4, 6), second_state, 3, 20, Some(3)),
  ]
}

/// Bounds for the restart cases: six messages, and two pages per attempt, so
/// a restart only fits if `max_pages` counts one attempt (A4).
fn restart_bounds() -> sync.Bounds {
  with_pages(bounds(Some(6)), 2)
}

fn first_query(run: Run) -> fixture_send.RecordedCall {
  let assert [call, ..] = sync_fixture.calls_of(run, EmailQuery)
  call
}

fn synced_at() -> model.UtcDate {
  let assert Ok(date) = normalise.utc_date(sync_fixture.now_text)
  date
}

/// A call's `ids`: `None` when it is JSON null, `Some([])` when it is empty.
/// Panics when the call carries no `ids` at all.
fn ids_argument(call: fixture_send.RecordedCall) -> Option(List(String)) {
  let assert Ok(ids) =
    decode.run(
      call.arguments,
      decode.at(["ids"], decode.optional(decode.list(decode.string))),
    )
  ids
}

// Rows of the committed store.

fn message_states(store: Store) -> List(#(String, String)) {
  rows(
    store,
    "SELECT id, email_state FROM message ORDER BY id",
    sync_fixture.pair_decoder(),
  )
}

fn message_ids(store: Store) -> List(String) {
  message_states(store) |> list.map(fn(row) { row.0 })
}

fn query_state_row(store: Store) -> #(String, String, Int, String, Int) {
  let decoder = {
    use filter_json <- decode.field(0, decode.string)
    use sort_json <- decode.field(1, decode.string)
    use collapse <- decode.field(2, decode.int)
    use query_state <- decode.field(3, decode.string)
    use can_calculate <- decode.field(4, decode.int)
    decode.success(#(
      filter_json,
      sort_json,
      collapse,
      query_state,
      can_calculate,
    ))
  }
  let assert [row] =
    rows(
      store,
      "SELECT filter_json, sort_json, collapse_threads, query_state,"
        <> " can_calculate_changes FROM query_state",
      decoder,
    )
  row
}

fn sync_row(store: Store) -> #(String, String, String, String, Int, Int, Int) {
  let decoder = {
    use account_id <- decode.field(0, decode.string)
    use synced_at <- decode.field(1, decode.string)
    use api_url <- decode.field(2, decode.string)
    use window_json <- decode.field(3, decode.string)
    use max_objects <- decode.field(4, decode.int)
    use max_calls <- decode.field(5, decode.int)
    use is_read_only <- decode.field(6, decode.int)
    decode.success(#(
      account_id,
      synced_at,
      api_url,
      window_json,
      max_objects,
      max_calls,
      is_read_only,
    ))
  }
  let assert [row] =
    rows(
      store,
      "SELECT account_id, synced_at, api_url, window_json, max_objects_in_get,"
        <> " max_calls_in_request, is_read_only FROM sync",
      decoder,
    )
  row
}

// ---------------------------------------------------------------- VT-1 paging

/// The server clamps to 3 and the window holds 9: three full pages, then the
/// window is full. Catches a run that stops at the first page shorter than its
/// request, or keeps paging once `max_messages` is reached.
pub fn paging_three_full_pages_until_max_messages_test() {
  let all = ids("e", 1, 9)
  let script =
    script_of(
      [
        page(ids("e", 1, 3), "qs-1", 0, 20, Some(3)),
        page(ids("e", 4, 6), "qs-1", 3, 20, Some(3)),
        page(ids("e", 7, 9), "qs-1", 6, 20, Some(3)),
      ],
      all,
    )
  let spec = Spec(..spec(script), bounds: bounds(Some(9)))
  use _store, run <- run_sync(spec, None)

  expect_calls(run, methods(script))
  positions(run) |> should.equal([0, 3, 6])
  sync_fixture.limits(run) |> should.equal([Some(9), Some(3), Some(3)])
  id_lists(run, EmailGet) |> should.equal([all])
  summary(run).messages |> should.equal(9)
}

/// A page shorter than its effective size ends phase 1, though `total` and
/// `max_messages` say there is more. Catches a run that pages until `total`
/// or until an empty page.
pub fn paging_short_page_stops_test() {
  let all = ids("e", 1, 5)
  let script =
    script_of(
      [
        page(ids("e", 1, 3), "qs-1", 0, 20, Some(3)),
        page(ids("e", 4, 5), "qs-1", 3, 20, Some(3)),
      ],
      all,
    )
  let spec = Spec(..spec(script), bounds: bounds(Some(10)))
  use _store, run <- run_sync(spec, None)

  expect_calls(run, methods(script))
  positions(run) |> should.equal([0, 3])
  sync_fixture.limits(run) |> should.equal([Some(10), Some(3)])
  summary(run).messages |> should.equal(5)
}

/// `position + page length = total` ends phase 1 after three full pages: no
/// fourth request. Catches a run that needs an empty page to stop.
pub fn paging_position_reaching_total_stops_test() {
  let all = ids("e", 1, 9)
  let script =
    script_of(
      [
        page(ids("e", 1, 3), "qs-1", 0, 9, Some(3)),
        page(ids("e", 4, 6), "qs-1", 3, 9, Some(3)),
        page(ids("e", 7, 9), "qs-1", 6, 9, Some(3)),
      ],
      all,
    )
  use _store, run <- run_sync(spec(script), None)

  expect_calls(run, methods(script))
  positions(run) |> should.equal([0, 3, 6])
  summary(run).messages |> should.equal(9)
}

/// The server clamps a limit of 10 to 3: the next requests ask for the clamp,
/// the last for the one message still to fetch, and a page of 3 is not short.
/// Catches a run that ignores the response `limit` (it would ask for 7 and
/// stop after a "short" first page).
pub fn paging_clamped_limit_test() {
  let all = ids("e", 1, 10)
  let script =
    script_of(
      [
        page(ids("e", 1, 3), "qs-1", 0, 50, Some(3)),
        page(ids("e", 4, 6), "qs-1", 3, 50, Some(3)),
        page(ids("e", 7, 9), "qs-1", 6, 50, Some(3)),
        page(["e10"], "qs-1", 9, 50, Some(1)),
      ],
      all,
    )
  let spec = Spec(..spec(script), bounds: bounds(Some(10)))
  use _store, run <- run_sync(spec, None)

  expect_calls(run, methods(script))
  sync_fixture.limits(run)
  |> should.equal([Some(10), Some(3), Some(3), Some(1)])
  positions(run) |> should.equal([0, 3, 6, 9])
  summary(run).messages |> should.equal(10)
}

/// A clamp holds for the rest of the attempt: once asked for exactly the clamp,
/// the server need not echo `limit` (RFC 8620 § 5.5 returns it only when it
/// differs), and the next request must still ask for at most 3. Catches a run
/// that forgets the clamp when a page omits `limit` (it would ask for 4).
pub fn paging_clamp_persists_when_limit_is_not_echoed_test() {
  let all = ids("e", 1, 10)
  let script =
    script_of(
      [
        page(ids("e", 1, 3), "qs-1", 0, 50, Some(3)),
        page(ids("e", 4, 6), "qs-1", 3, 50, None),
        page(ids("e", 7, 9), "qs-1", 6, 50, None),
        page(["e10"], "qs-1", 9, 50, None),
      ],
      all,
    )
  let spec = Spec(..spec(script), bounds: bounds(Some(10)))
  use _store, run <- run_sync(spec, None)

  expect_calls(run, methods(script))
  sync_fixture.limits(run)
  |> should.equal([Some(10), Some(3), Some(3), Some(1)])
  summary(run).messages |> should.equal(10)
}

/// With no `max_messages` the first request sends no limit; once the server
/// has clamped, every later request sends the clamp. Catches a run that never
/// sends a limit, or invents one.
pub fn paging_clamped_without_max_messages_test() {
  let all = ids("e", 1, 7)
  let script =
    script_of(
      [
        page(ids("e", 1, 3), "qs-1", 0, 7, Some(3)),
        page(ids("e", 4, 6), "qs-1", 3, 7, Some(3)),
        page(["e7"], "qs-1", 6, 7, Some(3)),
      ],
      all,
    )
  let bounds =
    sync.Bounds(
      ..bounds(None),
      window: config.Window(
        mailboxes: ["inbox"],
        max_age_days: Some(30),
        max_messages: None,
        retain_messages: None,
      ),
    )
  let spec = Spec(..spec(script), bounds: bounds)
  use _store, run <- run_sync(spec, None)

  expect_calls(run, methods(script))
  sync_fixture.limits(run) |> should.equal([None, Some(3), Some(3)])
  summary(run).messages |> should.equal(7)
}

/// A third page is needed but `max_pages` is 2: `LimitExceeded("max_pages")`,
/// no third request, and the store as it was. Catches a run that ignores
/// `max_pages`, or stores what it had.
pub fn paging_max_pages_exceeded_test() {
  let script = [
    inbox_step(),
    page(ids("e", 1, 3), "qs-1", 0, 50, Some(3)),
    page(ids("e", 4, 6), "qs-1", 3, 50, Some(3)),
  ]
  let spec = Spec(..spec(script), bounds: with_pages(bounds(Some(10)), 2))
  use store, run <- run_sync(spec, seeded())

  expect_calls(run, methods(script))
  expect_unchanged(store, run, error.LimitExceeded("max_pages"))
}

/// Six messages fit one page as requested, but the server clamps to 2, so a
/// third page is needed past `max_pages` 2. Catches a run that checks
/// `max_pages` against the pages its own limit would need.
pub fn paging_clamped_past_max_pages_test() {
  let script = [
    inbox_step(),
    page(["e1", "e2"], "qs-1", 0, 50, Some(2)),
    page(["e3", "e4"], "qs-1", 2, 50, Some(2)),
  ]
  let spec = Spec(..spec(script), bounds: with_pages(bounds(Some(6)), 2))
  use store, run <- run_sync(spec, seeded())

  expect_calls(run, methods(script))
  sync_fixture.limits(run) |> should.equal([Some(6), Some(2)])
  expect_unchanged(store, run, error.LimitExceeded("max_pages"))
}

/// A server that repeats an id: it is fetched once, at its first position
/// (A7). Catches a run that passes phase-1 ids to `Email/get` undeduped.
pub fn paging_duplicate_ids_fetched_once_test() {
  let script =
    script_of([page(["e1", "e2", "e1", "e3"], "qs-1", 0, 4, None)], [
      "e1", "e2", "e3",
    ])
  use _store, run <- run_sync(
    Spec(..spec(script), bounds: bounds(Some(10))),
    None,
  )

  expect_calls(run, methods(script))
  id_lists(run, EmailGet) |> should.equal([["e1", "e2", "e3"]])
}

// ---------------------------------------------------------------- VT-2 restart

/// One queryState change restarts phase 1 at position 0; only the settled
/// attempt's ids are fetched, and its queryState and first-page
/// canCalculateChanges are stored. Two pages per attempt under `max_pages` 2
/// also proves the page count resets per attempt. Catches a run with no
/// queryState comparison, one that keeps ids across attempts, or one that
/// records the first attempt's values.
pub fn query_unstable_one_change_restarts_test() {
  let settled = ids("b", 1, 6)
  let script =
    script_of(
      list.append(
        attempt("a", "qs-1", "qs-2", True),
        attempt("b", "qs-2", "qs-2", False),
      ),
      settled,
    )
  let spec = Spec(..spec(script), bounds: restart_bounds())
  use store, run <- run_sync(spec, None)

  expect_calls(run, methods(script))
  positions(run) |> should.equal([0, 3, 0, 3])
  id_lists(run, EmailGet) |> should.equal([settled])
  message_ids(store) |> should.equal(settled)
  let #(_, _, _, query_state, can_calculate) = query_state_row(store)
  query_state |> should.equal("qs-2")
  can_calculate |> should.equal(0)
}

/// Exactly two changes is the most a run tolerates, and it still commits.
/// Catches a restart budget off by one.
pub fn query_unstable_two_changes_succeed_test() {
  let settled = ids("c", 1, 6)
  let script =
    script_of(
      list.flatten([
        attempt("a", "qs-1", "qs-2", True),
        attempt("b", "qs-2", "qs-3", True),
        attempt("c", "qs-3", "qs-3", True),
      ]),
      settled,
    )
  let spec = Spec(..spec(script), bounds: restart_bounds())
  use store, run <- run_sync(spec, None)

  expect_calls(run, methods(script))
  positions(run) |> should.equal([0, 3, 0, 3, 0, 3])
  message_ids(store) |> should.equal(settled)
  query_state_row(store).3 |> should.equal("qs-3")
}

/// A third change is `QueryUnstable`, sent after exactly three attempts, and
/// the store, `user_version` included, is as it was. Catches unbounded
/// restarts, or a run that stores the last attempt anyway.
pub fn query_unstable_third_change_fails_test() {
  let script =
    list.flatten([
      [inbox_step()],
      attempt("a", "qs-1", "qs-2", True),
      attempt("b", "qs-2", "qs-3", True),
      attempt("c", "qs-3", "qs-4", True),
    ])
  let spec = Spec(..spec(script), bounds: restart_bounds())
  use store, run <- run_sync(spec, seeded())

  expect_calls(run, methods(script))
  expect_unchanged(store, run, error.QueryUnstable)
}

// ---------------------------------------------------------------- VT-2 phase 2

/// `maxObjectsInGet` 2 over five ids: three `Email/get`s of at most two ids,
/// in phase-1 order, whose union is the five with no repeats, each under
/// `maxBodyValueBytes = max_body_bytes`; `Thread/get` likewise in twos. Catches
/// overlapping or oversized chunks, and a fixed body cap.
pub fn exactly_once_chunks_test() {
  let all = ids("e", 1, 5)
  let script =
    list.flatten([
      [inbox_step(), page(all, "qs-1", 0, 5, None)],
      fetch_chunked(emails_of(all), 2),
    ])
  let spec =
    Spec(
      ..spec(script),
      bounds: sync.Bounds(..bounds(Some(5)), max_body_bytes: 777),
      max_objects_in_get: 2,
    )
  use store, run <- run_sync(spec, None)

  expect_calls(run, methods(script))
  let email_ids = id_lists(run, EmailGet)
  email_ids |> should.equal([["e1", "e2"], ["e3", "e4"], ["e5"]])
  list.flatten(email_ids) |> should.equal(all)
  sync_fixture.calls_of(run, EmailGet)
  |> list.map(sync_fixture.int_argument(_, "maxBodyValueBytes"))
  |> should.equal([Some(777), Some(777), Some(777)])
  id_lists(run, ThreadGet)
  |> should.equal([["t-e1", "t-e2"], ["t-e3", "t-e4"], ["t-e5"]])
  message_ids(store) |> should.equal(all)
}

/// An id `Email/get` reports `notFound` is left out of `message` and counted;
/// its thread is not asked for. Catches a run that drops the count, or builds
/// thread ids from phase 1 instead of the fetched emails.
pub fn not_found_ids_are_absent_and_counted_test() {
  let script = [
    inbox_step(),
    page(["e1", "e2", "e3"], "qs-1", 0, 3, None),
    emails(emails_of(["e1", "e3"]), "es-1", ["e2"]),
    threads(threads_of(emails_of(["e1", "e3"])), "ts-1"),
  ]
  use store, run <- run_sync(spec(script), None)

  expect_calls(run, methods(script))
  id_lists(run, ThreadGet) |> should.equal([["t-e1", "t-e3"]])
  message_ids(store) |> should.equal(["e1", "e3"])
  summary(run).not_found |> should.equal(1)
  summary(run).messages |> should.equal(2)
}

// ---------------------------------------------------------------- VT-3 inject

/// Mailboxes, three pages of two, three `Email/get`s and three `Thread/get`s
/// of two (indices 0, 1–3, 4–6, 7–9).
fn inject_script() -> List(Step) {
  list.flatten([
    [
      inbox_step(),
      page(["e1", "e2"], "qs-1", 0, 50, Some(2)),
      page(["e3", "e4"], "qs-1", 2, 50, Some(2)),
      page(["e5", "e6"], "qs-1", 4, 50, Some(2)),
    ],
    fetch_chunked(emails_of(ids("e", 1, 6)), 2),
  ])
}

/// A 500 at step `index` of `inject_script` on a seeded store: the run sends
/// nothing after it and leaves the store as it was.
fn inject_500_at(index: Int) -> Nil {
  let script = fail_at(inject_script(), index)
  let spec =
    Spec(..spec(script), bounds: bounds(Some(6)), max_objects_in_get: 2)
  use store, run <- run_sync(spec, seeded())

  expect_calls(run, methods(script))
  expect_unchanged(store, run, error.Http("status_500"))
}

/// Catches a run that writes the mailboxes before phase 1.
pub fn inject_500_at_mailbox_get_test() {
  inject_500_at(0)
}

/// At page 1, 2 and 3 of three. Catches a run that writes per page, or one
/// that treats a failed page as the end of phase 1.
pub fn inject_500_at_each_query_page_test() {
  inject_500_at(1)
  inject_500_at(2)
  inject_500_at(3)
}

/// At the first and the second `Email/get`. Catches a run that writes per
/// chunk, or skips a failed chunk.
pub fn inject_500_at_email_get_test() {
  inject_500_at(4)
  inject_500_at(5)
}

/// At the first and the last `Thread/get`. Catches a run that writes the
/// messages before fetching threads.
pub fn inject_500_at_thread_get_test() {
  inject_500_at(7)
  inject_500_at(9)
}

fn opening_entries() -> List(jmap_fixture.Entry) {
  jmap_fixture.opening_entries([sync_fixture.inbox()], "ms-1", "es-0", "ts-0")
}

/// A script holding only the opening request, answered with `entries`: the run
/// must send nothing after it and leave the seeded store untouched.
fn first_request_case(
  entries: List(jmap_fixture.Entry),
  expected: error.Error,
) -> Nil {
  use store, run <- run_sync(
    spec([sync_fixture.opening_with(entries)]),
    seeded(),
  )

  expect_calls(run, [MailboxGet])
  expect_unchanged(store, run, expected)
  // The run must still have sent the three calls of the opening request.
  sync_fixture.opening_calls(run)
  |> list.map(fn(call) { call.name })
  |> should.equal([
    request.method_name(request.MailboxGet),
    request.method_name(request.EmailGet),
    request.method_name(request.ThreadGet),
  ])
}

/// ISS-001: a method error answering the opening `Email/get` (c1) names
/// `Email/get`. Catches a run that attributes errors to `Mailbox/get` or to
/// the wrong call id.
pub fn inject_first_request_email_error_test() {
  let entries =
    list.map(opening_entries(), fn(entry) {
      case entry.call_id {
        "c1" -> jmap_fixture.error_entry("serverFail", "c1")
        _ -> entry
      }
    })
  first_request_case(entries, error.JmapMethod("Email/get", "serverFail"))
}

/// ISS-001: a method error answering the opening `Thread/get` (c2) names
/// `Thread/get`. Catches a run that assumes only the mailbox call can fail.
pub fn inject_first_request_thread_error_test() {
  let entries =
    list.map(opening_entries(), fn(entry) {
      case entry.call_id {
        "c2" -> jmap_fixture.error_entry("serverFail", "c2")
        _ -> entry
      }
    })
  first_request_case(entries, error.JmapMethod("Thread/get", "serverFail"))
}

/// ISS-001: the opening request makes three calls, so two answers are a
/// `methodResponses` decode error. Catches a run that accepts a short reply.
pub fn inject_first_request_missing_thread_get_test() {
  let entries =
    list.filter(opening_entries(), fn(entry) { entry.call_id != "c2" })
  first_request_case(entries, error.Decode("methodResponses"))
}

/// ISS-001: answers out of call order are a `methodResponses` decode error,
/// even though every name and call id is still present. Catches positional
/// decoding that ignores call ids.
pub fn inject_first_request_reordered_responses_test() {
  let assert [c0, c1, c2] = opening_entries()
  first_request_case([c0, c2, c1], error.Decode("methodResponses"))
}

/// Two attachments with one `partId` on one email break the attachment
/// primary key at insert: `Store("write_failed")`, rolled back. Catches a
/// write outside one transaction, or a leaked transaction (the writer must
/// still commit).
pub fn inject_insert_failure_test() {
  let attachment = fn(blob) {
    jmap_fixture.Attachment(
      part_id: "2",
      blob_id: blob,
      name: Some("a.pdf"),
      type_: "application/pdf",
      size: 10,
    )
  }
  let email =
    jmap_fixture.Email(..jmap_fixture.email("e1"), attachments: [
      attachment("blob-a"),
      attachment("blob-b"),
    ])
  let script = [
    inbox_step(),
    page(["e1"], "qs-1", 0, 1, None),
    ..fetch([email])
  ]
  use store, run <- run_sync(spec(script), seeded())

  expect_calls(run, methods(script))
  expect_unchanged(store, run, error.Store("write_failed"))
}

/// A budget that holds the session, `Mailbox/get` and the page, but not the
/// `Email/get` body: `LimitExceeded("max_total_bytes")`, store unchanged.
/// Catches a run that builds a fresh client (and budget) per call, or writes
/// what it fetched before the breach.
pub fn inject_budget_breach_test() {
  let prefix = [inbox_step(), page(["e1"], "qs-1", 0, 1, None)]
  let script = list.append(prefix, fetch(emails_of(["e1"])))
  let base = spec(script)
  let budget =
    string.byte_size(sync_fixture.session_body(base))
    + sync_fixture.bytes(prefix)
    + 1
  use store, run <- run_sync(Spec(..base, max_total_bytes: budget), seeded())

  expect_calls(run, [MailboxGet, EmailQuery, EmailGet])
  expect_unchanged(store, run, error.LimitExceeded("max_total_bytes"))
}

// ---------------------------------------------------------------- VT-4 states

/// ISS-001: the opening request fetches the Email and Thread states with two
/// empty gets, so `type_state` holds `es-0` and `ts-0`, not the first phase-2
/// chunk's states. Catches the PHASE-05 behaviour, where the first phase-2
/// state won.
pub fn type_state_earliest_first_request_test() {
  let all = ids("e", 1, 3)
  let opening =
    sync_fixture.opening([sync_fixture.inbox()], "ms-1", "es-0", "ts-0")
  let script =
    list.flatten([
      [opening, page(all, "qs-1", 0, 3, None)],
      fetch_chunked(emails_of(all), 2),
    ])
  use store, run <- run_sync(Spec(..spec(script), max_objects_in_get: 2), None)

  expect_calls(run, methods(script))
  type_states(store)
  |> should.equal([
    #("Email", "es-0"),
    #("Mailbox", "ms-1"),
    #("Thread", "ts-0"),
  ])
  message_states(store)
  |> should.equal([#("e1", "es-1"), #("e2", "es-1"), #("e3", "es-2")])
  summary(run).states
  |> should.equal([
    model.TypeState("Email", "es-0"),
    model.TypeState("Mailbox", "ms-1"),
    model.TypeState("Thread", "ts-0"),
  ])

  let calls = sync_fixture.opening_calls(run)
  calls
  |> list.map(fn(call) { call.name })
  |> should.equal([
    request.method_name(request.MailboxGet),
    request.method_name(request.EmailGet),
    request.method_name(request.ThreadGet),
  ])
  calls |> list.map(ids_argument) |> should.equal([None, Some([]), Some([])])
  calls
  |> list.map(fn(call) { call.call_id })
  |> should.equal(["c0", "c1", "c2"])
}

/// The `query_state` row holds the filter as sent (with `after` = `now`
/// truncated to the second, less 30 days), the sort, no thread collapse, the
/// settled queryState and its canCalculateChanges. Catches a filter rebuilt
/// differently from the one sent, an untruncated or wrong `after`, and a
/// hard-coded canCalculateChanges.
pub fn query_state_row_test() {
  let script =
    script_of([page_with(["e1", "e2"], "qs-9", 0, 2, None, False)], ["e1", "e2"])
  let bounds =
    sync.Bounds(
      ..bounds(Some(5)),
      window: config.Window(
        mailboxes: ["inbox"],
        max_age_days: Some(30),
        max_messages: Some(5),
        retain_messages: None,
      ),
    )
  use store, run <- run_sync(Spec(..spec(script), bounds: bounds), None)

  expect_calls(run, methods(script))
  let after = "2026-09-26T09:00:00Z"
  decode.run(
    first_query(run).arguments,
    decode.at(
      ["filter", "conditions"],
      decode.at([1], decode.at(["after"], decode.string)),
    ),
  )
  |> should.equal(Ok(after))
  query_state_row(store)
  |> should.equal(#(
    json.to_string(request.email_query_filter(["mb-1"], Some(after))),
    json.to_string(request.email_query_sort()),
    0,
    "qs-9",
    0,
  ))
}

// ---------------------------------------------------------------- VT-4 runs

/// The same script and `now` twice on one store: the second commit leaves the
/// dump the first left. Catches appended (duplicated) rows, and any
/// wall-clock read inside the run.
pub fn repeated_run_identical_dump_test() {
  let script = script_of([page(["e1", "e2"], "qs-1", 0, 2, None)], ["e1", "e2"])
  use store <- with_store(None)
  let first = run(store, spec(script))
  let second = run(store, spec(script))

  expect_calls(first, methods(script))
  expect_calls(second, methods(script))
  first.result |> should.be_ok
  second.after |> should.equal(first.after)
}

/// A message no longer in the window is gone after the next run, with every
/// row that named it. Catches an upsert that never deletes.
pub fn window_leaver_rows_removed_test() {
  let both =
    script_of([page(["kept", "gone"], "qs-1", 0, 2, None)], ["kept", "gone"])
  let kept = script_of([page(["kept"], "qs-2", 0, 1, None)], ["kept"])
  use store <- with_store(None)
  let first = run(store, spec(both))
  let second = run(store, spec(kept))

  expect_calls(first, methods(both))
  expect_calls(second, methods(kept))
  first.after |> string.contains("gone") |> should.be_true
  second.after |> string.contains("gone") |> should.be_false
  message_ids(store) |> should.equal(["kept"])
}

// ---------------------------------------------------------------- VT-4 window

/// A window entry matching no role and no name is `Config("unknown_mailbox")`
/// before any `Email/query`, though another entry resolves. Catches a run that
/// drops unmatched entries.
pub fn unknown_mailbox_test() {
  let script = [inbox_step()]
  let spec = Spec(..spec(script), bounds: window(["inbox", "Nope"]))
  use store, run <- run_sync(spec, seeded())

  expect_calls(run, [MailboxGet])
  expect_unchanged(store, run, error.Config("unknown_mailbox"))
}

/// `inbox` matches the mailbox whose role is inbox, not the one named
/// "inbox". Every mailbox is still stored. Catches name-first or
/// match-either resolution.
pub fn window_role_beats_name_test() {
  let script = [
    mailboxes(
      [
        jmap_fixture.mailbox("mb-a", "Inbox", Some("inbox")),
        jmap_fixture.mailbox("mb-b", "inbox", None),
      ],
      "ms-1",
    ),
    empty_page(),
  ]
  use _store, run <- run_sync(
    Spec(..spec(script), bounds: window(["inbox"])),
    None,
  )

  expect_calls(run, methods(script))
  sync_fixture.filter_mailboxes(first_query(run)) |> should.equal(["mb-a"])
  summary(run).mailboxes |> should.equal(2)
}

/// With no role match, an entry matches by exact, case-sensitive name; the
/// resolved ids follow config order and are deduped. Catches a
/// case-insensitive match, mailbox-list order, and repeated ids.
pub fn window_name_fallback_in_config_order_test() {
  let script = [
    mailboxes(
      [
        jmap_fixture.mailbox("mb-a", "Inbox", Some("inbox")),
        jmap_fixture.mailbox("mb-r", "Receipts", None),
        jmap_fixture.mailbox("mb-l", "receipts", None),
      ],
      "ms-1",
    ),
    empty_page(),
  ]
  let spec =
    Spec(..spec(script), bounds: window(["Receipts", "inbox", "Inbox"]))
  use _store, run <- run_sync(spec, None)

  expect_calls(run, methods(script))
  sync_fixture.filter_mailboxes(first_query(run))
  |> should.equal(["mb-r", "mb-a"])
}

/// ISS-001: an empty window sends only the opening request and the phase-1
/// page: no `Email/get` or `Thread/get` follows. The opening states are stored
/// and the snapshot commits with no messages. Catches a run that skips the
/// empty gets, or commits nothing.
pub fn empty_window_first_request_test() {
  let script = [inbox_step(), empty_page()]
  use store, run <- run_sync(spec(script), None)

  expect_calls(run, [MailboxGet, EmailQuery])
  run.after |> should.not_equal(run.before)
  count(store, "message") |> should.equal(0)
  type_states(store)
  |> should.equal([
    #("Email", "es-0"),
    #("Mailbox", "ms-1"),
    #("Thread", "ts-0"),
  ])
  summary(run).messages |> should.equal(0)
  summary(run).threads |> should.equal(0)
}

// ---------------------------------------------------------------- VT-4 session

/// The `sync` row and the summary carry the session's `isReadOnly`, limits
/// and `apiUrl`, the window as JSON and `now` truncated to the second.
fn read_only_case(is_read_only: Bool) -> Nil {
  let script = script_of([page(["e1"], "qs-1", 0, 1, None)], ["e1"])
  let bounds = bounds(Some(100))
  let spec =
    Spec(
      ..spec(script),
      bounds: bounds,
      is_read_only: is_read_only,
      max_objects_in_get: 7,
    )
  use store, run <- run_sync(spec, None)

  expect_calls(run, methods(script))
  summary(run).is_read_only |> should.equal(is_read_only)
  sync_row(store)
  |> should.equal(
    #(
      sync_fixture.account_id,
      sync_fixture.now_text,
      sync_fixture.api_url,
      config.window_json(bounds.window),
      7,
      32,
      case is_read_only {
        True -> 1
        False -> 0
      },
    ),
  )
}

/// Both values. Catches a hard-coded `is_read_only`, and session limits not
/// carried into the row.
pub fn is_read_only_test() {
  read_only_case(True)
  read_only_case(False)
}

// ---------------------------------------------------------------- summary

/// A server-truncated plain body, two plain parts whose 30 bytes exceed
/// `max_body_bytes` 20, unparseable HTML, a shared thread and a notFound id:
/// the whole summary is exact. Catches counting truncation by one cause only,
/// counting parts instead of failures, threads per message, or messages
/// requested instead of stored.
pub fn summary_values_test() {
  let server_cut =
    jmap_fixture.Email(..jmap_fixture.email("e1"), thread_id: "t-x", text_body: [
      jmap_fixture.Part(
        ..jmap_fixture.plain("1", "server cut"),
        is_truncated: True,
      ),
    ])
  let over_bound =
    jmap_fixture.Email(..jmap_fixture.email("e2"), thread_id: "t-x", text_body: [
      jmap_fixture.plain("1", "fifteen bytes!!"),
      jmap_fixture.plain("2", "fifteen bytes!!"),
    ])
  let bad_html =
    jmap_fixture.Email(..jmap_fixture.email("e3"), text_body: [
      jmap_fixture.html("1", "</</"),
    ])
  let delivered = [server_cut, over_bound, bad_html]
  let script = [
    mailboxes(
      [
        sync_fixture.inbox(),
        jmap_fixture.mailbox("mb-2", "Archive", Some("archive")),
      ],
      "ms-1",
    ),
    page(["e1", "e2", "e3", "e4"], "qs-1", 0, 4, None),
    emails(delivered, "es-1", ["e4"]),
    threads(threads_of(delivered), "ts-1"),
  ]
  let spec =
    Spec(
      ..spec(script),
      bounds: sync.Bounds(..bounds(Some(10)), max_body_bytes: 20),
    )
  use _store, run <- run_sync(spec, None)

  expect_calls(run, methods(script))
  id_lists(run, ThreadGet) |> should.equal([["t-e3", "t-x"]])
  summary(run)
  |> should.equal(sync.Summary(
    account_id: sync_fixture.account_id,
    synced_at: synced_at(),
    mailboxes: 2,
    messages: 3,
    threads: 2,
    truncated_bodies: 2,
    not_found: 1,
    conversion_failures: 1,
    states: [
      model.TypeState("Email", "es-0"),
      model.TypeState("Mailbox", "ms-1"),
      model.TypeState("Thread", "ts-0"),
    ],
    is_read_only: True,
    // No Prior: a full run, for want of state (VT-1).
    mode: sync.Full,
    fallback_reason: Some("no_state"),
  ))
}

// ---------------------------------------------------------------- PHASE-05 review

/// Review F2: every requested id comes back in `list` or `notFound` (RFC 8620
/// § 5.1). A chunk answered without one of its ids would drop that message
/// silently; the run fails instead, and the store stands. Catches a run that
/// trusts `list`.
pub fn email_get_missing_id_fails_test() {
  let script = [
    inbox_step(),
    page(["e1", "e2"], "qs-1", 0, 2, None),
    emails(emails_of(["e1"]), "es-1", []),
  ]
  use store, run <- run_sync(spec(script), seeded())

  expect_calls(run, methods(script))
  expect_unchanged(store, run, error.Decode("notFound"))
}

/// Review F2: an id the chunk did not ask for is outside the window; storing it
/// would break I3. Catches a run that stores whatever `list` holds.
pub fn email_get_unrequested_id_fails_test() {
  let script = [
    inbox_step(),
    page(["e1"], "qs-1", 0, 1, None),
    emails(emails_of(["e1", "e9"]), "es-1", []),
  ]
  use store, run <- run_sync(spec(script), seeded())

  expect_calls(run, methods(script))
  expect_unchanged(store, run, error.Decode("list"))
}

/// Review F3: a server that ignores `limit` and answers more ids than the
/// window still wants does not grow the window past `max_messages`: the run
/// keeps the first ids and stops (I4). Catches a run that collects whole pages.
pub fn paging_oversized_page_is_cut_to_the_window_test() {
  let script = [
    inbox_step(),
    page(ids("e", 1, 5), "qs-1", 0, 50, None),
    emails(emails_of(ids("e", 1, 3)), "es-1", []),
    threads(threads_of(emails_of(ids("e", 1, 3))), "ts-1"),
  ]
  let spec = Spec(..spec(script), bounds: bounds(Some(3)))
  use _store, run <- run_sync(spec, None)

  expect_calls(run, methods(script))
  id_lists(run, EmailGet) |> should.equal([ids("e", 1, 3)])
  summary(run).messages |> should.equal(3)
}

/// Review F7: an empty page ends phase 1 even when `total` says more remain,
/// and the empty window commits without any phase-2 gets (ISS-001). Catches a
/// run that relies on `total` alone (it would page until `max_pages`).
pub fn paging_empty_page_stops_test() {
  let script = [inbox_step(), page([], "qs-1", 0, 50, None)]
  use _store, run <- run_sync(spec(script), None)

  expect_calls(run, methods(script))
  summary(run).messages |> should.equal(0)
}

/// Review F7: a server whose pages never advance (the same ids at position 0)
/// cannot hold the run: `max_pages` ends it. Catches a paging loop bounded only
/// by `total` or by new ids.
pub fn paging_non_advancing_position_hits_max_pages_test() {
  let stuck = page(["e1", "e2"], "qs-1", 0, 50, Some(2))
  let script = [inbox_step(), stuck, stuck, stuck]
  let spec =
    Spec(..spec(script), bounds: sync.Bounds(..bounds(Some(10)), max_pages: 3))
  use store, run <- run_sync(spec, seeded())

  expect_calls(run, methods(script))
  expect_unchanged(store, run, error.LimitExceeded("max_pages"))
}

// ---------------------------------------------------------------- the Prior (SL-002 PHASE-08)

/// A first sync of `delivered` from `mailboxes_step` under `bounds`, with no
/// Prior: the committed store the next run reads its Prior from.
fn seed(
  store: Store,
  mailboxes_step: Step,
  bounds: sync.Bounds,
  delivered: List(jmap_fixture.Email),
) -> Nil {
  let ids = list.map(delivered, fn(email) { email.id })
  let script =
    list.flatten([
      [mailboxes_step, page(ids, "qs-0", 0, list.length(ids), None)],
      fetch(delivered),
    ])
  let first = run(store, Spec(..spec(script), bounds: bounds))
  summary(first).messages |> should.equal(list.length(ids))
}

/// The inbox window: `max_messages`, `max_age_days` and `retain_messages`.
fn inbox_window(
  max_messages: Option(Int),
  max_age_days: Option(Int),
  retain_messages: Option(Int),
) -> sync.Bounds {
  sync.Bounds(
    ..bounds(max_messages),
    window: config.Window(
      mailboxes: ["inbox"],
      max_age_days:,
      max_messages:,
      retain_messages:,
    ),
  )
}

/// A store seeded with e1 and e2, then a run whose Prior is `bent` and whose
/// bounds are `second`: the Prior is unusable, so nothing stored is refreshed
/// or kept, and every query id is fetched again in full (`no_state`). Without
/// the check under test the Prior is usable and the run sends a light get the
/// script does not expect.
fn expect_refetched(bent: fn(model.Prior) -> model.Prior, second: sync.Bounds) {
  use store <- with_store(None)
  seed(store, inbox_step(), bounds(Some(10)), emails_of(["e1", "e2"]))
  let assert Some(prior) = sync_fixture.prior_of(store)
  let script = script_of([page(["e1", "e2"], "qs-1", 0, 2, None)], ["e1", "e2"])
  let run =
    run(store, Spec(..spec(script), bounds: second, prior: Some(bent(prior))))

  expect_calls(run, methods(script))
  id_lists(run, EmailGet) |> should.equal([["e1", "e2"]])
  summary(run).mode |> should.equal(sync.Full)
  summary(run).fallback_reason |> should.equal(Some("no_state"))
}

/// Another server under the same account id: its ids are not this server's.
pub fn prior_from_another_server_is_no_state_test() {
  expect_refetched(
    fn(prior) { model.Prior(..prior, api_url: "https://other.example.test/") },
    bounds(Some(10)),
  )
}

pub fn prior_of_another_account_is_no_state_test() {
  expect_refetched(
    fn(prior) { model.Prior(..prior, account_id: "acct-2") },
    bounds(Some(10)),
  )
}

/// The stored bodies were cut at `max_body_value_bytes` 1000; a run under
/// another `max_body_bytes` cannot reuse them.
pub fn body_limit_change_is_no_state_test() {
  expect_refetched(fn(prior) { prior }, {
    sync.Bounds(..bounds(Some(10)), max_body_bytes: 2000)
  })
}

/// Another `window_json` (`max_messages` 10 → 5) with the same mailboxes: a
/// full run with the Prior. The stored ids get one light `Email/get` — light
/// properties, no body values — and its answer decides what is kept: e1 is
/// marked seen under a new state, e2 is gone, and e3 moved out of the window.
/// Only e1 is fetched by nobody and kept, refreshed.
pub fn window_json_change_is_window_changed_test() {
  use store <- with_store(None)
  seed(store, inbox_step(), bounds(Some(10)), emails_of(["e1", "e2", "e3"]))
  let seen = jmap_fixture.Email(..jmap_fixture.email("e1"), keywords: ["$seen"])
  let moved =
    jmap_fixture.Email(..jmap_fixture.email("e3"), mailbox_ids: ["mb-9"])
  let script = [
    inbox_step(),
    page(["e1"], "qs-1", 0, 1, None),
    sync_fixture.lights([seen, moved], "es-9", ["e2"]),
    threads(threads_of([seen]), "ts-1"),
  ]
  let run =
    sync_fixture.run_with_prior(
      store,
      Spec(..spec(script), bounds: bounds(Some(5))),
    )

  expect_calls(run, methods(script))
  let assert [light] = sync_fixture.calls_of(run, EmailGet)
  fixture_send.ids_of(light) |> should.equal(["e1", "e2", "e3"])
  decode.run(
    light.arguments,
    decode.at(["properties"], decode.list(decode.string)),
  )
  |> should.equal(Ok(["id", "mailboxIds", "keywords"]))
  sync_fixture.int_argument(light, "maxBodyValueBytes") |> should.equal(None)
  summary(run).fallback_reason |> should.equal(Some("window_changed"))
  summary(run).not_found |> should.equal(1)
  message_states(store) |> should.equal([#("e1", "es-9")])
  rows(
    store,
    "SELECT is_seen FROM message",
    decode.field(0, decode.int, decode.success),
  )
  |> should.equal([1])
}

/// A `notFound` id the chunk never asked for: the run fails before the write,
/// since `notFound` now removes messages from the store.
pub fn not_found_outside_the_chunk_fails_test() {
  let script = [
    inbox_step(),
    page(["e1"], "qs-1", 0, 1, None),
    emails(emails_of(["e1"]), "es-1", ["e9"]),
  ]
  use store, run <- run_sync(spec(script), seeded())

  expect_calls(run, methods(script))
  expect_unchanged(store, run, error.Decode("notFound"))
}

/// The window names "Work"; the mailbox once called "Work" is renamed and
/// another takes the name, so the same `window_json` resolves to another id.
/// The stored messages refresh into a mailbox outside the window and drop out.
pub fn mailbox_rename_is_window_changed_test() {
  let work =
    sync.Bounds(
      ..bounds(Some(10)),
      window: config.Window(..bounds(Some(10)).window, mailboxes: ["Work"]),
    )
  let in_old = fn(id) {
    jmap_fixture.Email(..jmap_fixture.email(id), mailbox_ids: ["mb-2"])
  }
  let fresh =
    jmap_fixture.Email(..jmap_fixture.email("e3"), mailbox_ids: ["mb-3"])
  use store <- with_store(None)
  seed(
    store,
    mailboxes([jmap_fixture.mailbox("mb-2", "Work", None)], "ms-1"),
    work,
    [in_old("e1"), in_old("e2")],
  )
  let script = [
    mailboxes(
      [
        jmap_fixture.mailbox("mb-2", "Old Work", None),
        jmap_fixture.mailbox("mb-3", "Work", None),
      ],
      "ms-2",
    ),
    page(["e3"], "qs-1", 0, 1, None),
    emails([fresh], "es-1", []),
    sync_fixture.lights([in_old("e1"), in_old("e2")], "es-1", []),
    threads(threads_of([fresh]), "ts-1"),
  ]
  let run =
    sync_fixture.run_with_prior(store, Spec(..spec(script), bounds: work))

  expect_calls(run, methods(script))
  sync_fixture.filter_mailboxes(first_query(run)) |> should.equal(["mb-3"])
  summary(run).fallback_reason |> should.equal(Some("window_changed"))
  message_ids(store) |> should.equal(["e3"])
}

/// `retain_messages` 3 over a window of 2 (a `window_json` change): the query
/// now finds e3 and e1, so only e3 is fetched in full; e2 has left the fetch
/// window but is retained from the store — refreshed light, no body refetch —
/// and keeps its thread rows, because `Thread/get` runs over the merged set.
pub fn retained_message_keeps_its_thread_test() {
  use store <- with_store(None)
  seed(store, inbox_step(), bounds(Some(2)), emails_of(["e1", "e2"]))
  let script = [
    inbox_step(),
    page(["e3", "e1"], "qs-1", 0, 3, None),
    emails(emails_of(["e3"]), "es-1", []),
    sync_fixture.lights(emails_of(["e1", "e2"]), "es-1", []),
    threads(threads_of(emails_of(["e1", "e2", "e3"])), "ts-1"),
  ]
  let run =
    sync_fixture.run_with_prior(
      store,
      Spec(..spec(script), bounds: inbox_window(Some(2), None, Some(3))),
    )

  expect_calls(run, methods(script))
  id_lists(run, EmailGet) |> should.equal([["e3"], ["e1", "e2"]])
  id_lists(run, ThreadGet) |> should.equal([["t-e1", "t-e2", "t-e3"]])
  summary(run).fallback_reason |> should.equal(Some("window_changed"))
  message_ids(store) |> should.equal(["e1", "e2", "e3"])
  rows(
    store,
    "SELECT thread_id FROM thread_email WHERE message_id = 'e2'",
    decode.field(0, decode.string, decode.success),
  )
  |> should.equal(["t-e2"])
}

/// Forty days on, e1 (received the day before the seed run) is past the
/// 30-day window, and the query no longer finds it. With `retain_messages`
/// set the age bound does not apply and e1 is kept; without it, e1 is dropped.
/// Both second runs change `window_json`, so both are full runs with the Prior.
pub fn retention_ignores_the_age_bound_test() {
  let later = timestamp.add(sync_fixture.now(), duration.hours(24 * 40))
  let aged = fn(second: sync.Bounds, script: List(Step)) {
    use store <- with_store(None)
    seed(
      store,
      inbox_step(),
      inbox_window(Some(10), Some(30), None),
      emails_of(["e1"]),
    )
    let run =
      sync_fixture.run_with_prior(
        store,
        Spec(..spec(script), bounds: second, now: later),
      )
    expect_calls(run, methods(script))
    message_ids(store)
  }
  let refresh = [
    inbox_step(),
    empty_page(),
    sync_fixture.lights(emails_of(["e1"]), "es-1", []),
  ]

  aged(
    inbox_window(Some(10), Some(30), Some(10)),
    list.append(refresh, [threads(threads_of(emails_of(["e1"])), "ts-1")]),
  )
  |> should.equal(["e1"])
  aged(inbox_window(Some(9), Some(30), None), refresh)
  |> should.equal([])
}

// ---------------------------------------------------------------- incremental (SL-002 PHASE-06)

/// e1 and e2 committed by a first, full run (Email state `es-0`): the store
/// every incremental case starts from.
fn seed_two(store: Store) -> Nil {
  seed(store, inbox_step(), spec([]).bounds, emails_of(["e1", "e2"]))
}

/// The next run of `script`, under `spec`'s bounds, from the Prior.
fn again(store: Store, script: List(Step)) -> Run {
  sync_fixture.run_with_prior(store, spec(script))
}

fn since_states(run: Run) -> List(Option(String)) {
  sync_fixture.calls_of(run, request.EmailChanges)
  |> list.map(sync_fixture.string_argument(_, "sinceState"))
}

/// I-M2: nothing changed, so the run sends the opening request,
/// `Email/changes` from the stored state and `Thread/get` over what it keeps —
/// no `Email/query`, and no `Email/get` with ids (the opening's is the empty
/// state probe). The Prior's query record is carried.
pub fn unchanged_account_fetches_no_email_test() {
  use store <- with_store(None)
  seed_two(store)
  let query_before = query_state_row(store)
  let script = [
    inbox_step(),
    sync_fixture.no_changes("es-0", "es-1"),
    threads(threads_of(emails_of(["e1", "e2"])), "ts-1"),
  ]
  let run = again(store, script)

  expect_calls(run, methods(script))
  since_states(run) |> should.equal([Some("es-0")])
  let assert [_, opening_get, _] = sync_fixture.opening_calls(run)
  ids_argument(opening_get) |> should.equal(Some([]))
  sync_fixture.calls_of(run, EmailGet) |> should.equal([])
  summary(run).mode |> should.equal(sync.Incremental)
  summary(run).fallback_reason |> should.equal(None)
  message_ids(store) |> should.equal(["e1", "e2"])
  query_state_row(store) |> should.equal(query_before)
}

/// I-M2: an updated id neither stored nor in the query (an Archive message
/// marked seen) is ignored: the query runs, and no `Email/get` is sent.
pub fn outside_window_change_ignored_test() {
  use store <- with_store(None)
  seed_two(store)
  let script = [
    inbox_step(),
    sync_fixture.changes("es-0", "es-1", False, [], ["x9"], []),
    page(["e1", "e2"], "qs-1", 0, 2, None),
    threads(threads_of(emails_of(["e1", "e2"])), "ts-1"),
  ]
  let run = again(store, script)

  expect_calls(run, methods(script))
  sync_fixture.calls_of(run, EmailGet) |> should.equal([])
  message_ids(store) |> should.equal(["e1", "e2"])
}

/// I-M1: store [e1, e2], server [e1, e2, e3], `max_messages` 2, e1 destroyed:
/// the change runs the query, and the next-oldest message comes in.
pub fn deletion_backfills_test() {
  use store <- with_store(None)
  seed(store, inbox_step(), bounds(Some(2)), emails_of(["e1", "e2"]))
  let script = [
    inbox_step(),
    sync_fixture.changes("es-0", "es-1", False, [], [], ["e1"]),
    page(["e2", "e3"], "qs-1", 0, 2, None),
    emails(emails_of(["e3"]), "es-1", []),
    threads(threads_of(emails_of(["e2", "e3"])), "ts-1"),
  ]
  let run =
    sync_fixture.run_with_prior(
      store,
      Spec(..spec(script), bounds: bounds(Some(2))),
    )

  expect_calls(run, methods(script))
  id_lists(run, EmailGet) |> should.equal([["e3"]])
  message_ids(store) |> should.equal(["e2", "e3"])
}

/// I-M1: no Email changes and a clock forty days on, past the 30-day window:
/// only the age bound removes the message, and with nothing kept there is no
/// `Thread/get`.
pub fn age_out_without_changes_test() {
  let window = inbox_window(Some(10), Some(30), None)
  use store <- with_store(None)
  seed(store, inbox_step(), window, emails_of(["e1"]))
  let script = [inbox_step(), sync_fixture.no_changes("es-0", "es-1")]
  let later = timestamp.add(sync_fixture.now(), duration.hours(24 * 40))
  let run =
    sync_fixture.run_with_prior(
      store,
      Spec(..spec(script), bounds: window, now: later),
    )

  expect_calls(run, methods(script))
  summary(run).mode |> should.equal(sync.Incremental)
  message_ids(store) |> should.equal([])
}

/// I-M3: the full path stores the opening request's Email state; the
/// incremental path the last `Email/changes` `newState`, here of two pages.
pub fn stored_email_state_test() {
  use store <- with_store(None)
  seed_two(store)
  type_states(store) |> list.key_find("Email") |> should.equal(Ok("es-0"))

  let script = [
    inbox_step(),
    sync_fixture.changes("es-0", "es-1", True, [], [], []),
    sync_fixture.no_changes("es-1", "es-2"),
    threads(threads_of(emails_of(["e1", "e2"])), "ts-1"),
  ]
  let run = again(store, script)

  expect_calls(run, methods(script))
  type_states(store) |> list.key_find("Email") |> should.equal(Ok("es-2"))
}

/// Paging: while `hasMoreChanges`, the next page asks from the last
/// `newState`; ids accumulate across pages and `destroyed` wins — e1, updated
/// on the first page and destroyed on the second, is not refreshed but gone.
pub fn changes_pages_accumulate_and_destroyed_wins_test() {
  use store <- with_store(None)
  seed_two(store)
  let script = [
    inbox_step(),
    sync_fixture.changes("es-0", "es-1", True, ["e3"], ["e1"], []),
    sync_fixture.changes("es-1", "es-2", False, [], ["e2"], ["e1"]),
    page(["e3", "e2"], "qs-1", 0, 2, None),
    emails(emails_of(["e3"]), "es-2", []),
    sync_fixture.lights(emails_of(["e2"]), "es-2", []),
    threads(threads_of(emails_of(["e2", "e3"])), "ts-1"),
  ]
  let run = again(store, script)

  expect_calls(run, methods(script))
  since_states(run) |> should.equal([Some("es-0"), Some("es-1")])
  id_lists(run, EmailGet) |> should.equal([["e3"], ["e2"]])
  message_ids(store) |> should.equal(["e2", "e3"])
}

/// Paging: changes on an earlier page count though the last page reports
/// none — e1, updated, is refreshed under the new state; e2, destroyed, is
/// gone.
pub fn changes_on_an_earlier_page_count_test() {
  use store <- with_store(None)
  seed_two(store)
  let script = [
    inbox_step(),
    sync_fixture.changes("es-0", "es-1", True, [], ["e1"], ["e2"]),
    sync_fixture.no_changes("es-1", "es-2"),
    page(["e1"], "qs-1", 0, 1, None),
    sync_fixture.lights(emails_of(["e1"]), "es-2", []),
    threads(threads_of(emails_of(["e1"])), "ts-1"),
  ]
  let run = again(store, script)

  expect_calls(run, methods(script))
  message_states(store) |> should.equal([#("e1", "es-2")])
}

/// A created id alone is a change: the query runs and the arrival is fetched.
pub fn created_only_runs_the_query_test() {
  use store <- with_store(None)
  seed_two(store)
  let script = [
    inbox_step(),
    sync_fixture.changes("es-0", "es-1", False, ["e3"], [], []),
    page(["e3", "e2", "e1"], "qs-1", 0, 3, None),
    emails(emails_of(["e3"]), "es-1", []),
    threads(threads_of(emails_of(["e1", "e2", "e3"])), "ts-1"),
  ]
  let run = again(store, script)

  expect_calls(run, methods(script))
  id_lists(run, EmailGet) |> should.equal([["e3"]])
  message_ids(store) |> should.equal(["e1", "e2", "e3"])
}

/// I-M4: a get fails after `Email/changes`, so nothing is written and the
/// stored Email state stays `es-0`; the next run asks for changes from it
/// again.
pub fn failure_then_retry_test() {
  use store <- with_store(None)
  seed_two(store)
  let script = [
    inbox_step(),
    sync_fixture.changes("es-0", "es-1", False, [], ["e1"], []),
    page(["e1", "e2"], "qs-1", 0, 2, None),
    sync_fixture.failure(EmailGet),
  ]
  let failed = again(store, script)

  expect_calls(failed, methods(script))
  // Not `expect_unchanged`: its commit probe would replace the store the retry
  // reads its Prior from.
  failed.result |> should.equal(Error(error.Http("status_500")))
  failed.after |> should.equal(failed.before)

  let retry = [
    inbox_step(),
    sync_fixture.no_changes("es-0", "es-1"),
    threads(threads_of(emails_of(["e1", "e2"])), "ts-1"),
  ]
  let run = again(store, retry)
  expect_calls(run, methods(retry))
  since_states(run) |> should.equal([Some("es-0")])
}

/// I-M1 under concurrent change: e2 moves out of the window after the run's
/// `Email/changes` and before its `Email/query`. This run misses the move and
/// keeps e2, but stores the pre-move `newState`, so the next run reports the
/// move and converges on the ids a full sync would hold.
pub fn concurrent_move_converges_test() {
  use store <- with_store(None)
  seed_two(store)
  let moved =
    jmap_fixture.Email(..jmap_fixture.email("e2"), mailbox_ids: ["mb-9"])
  let first = [
    inbox_step(),
    sync_fixture.changes("es-0", "es-1", False, [], ["e1"], []),
    page(["e1"], "qs-1", 0, 1, None),
    sync_fixture.lights(emails_of(["e1"]), "es-2", []),
    threads(threads_of(emails_of(["e1", "e2"])), "ts-1"),
  ]
  let run = again(store, first)

  expect_calls(run, methods(first))
  message_ids(store) |> should.equal(["e1", "e2"])
  type_states(store) |> list.key_find("Email") |> should.equal(Ok("es-1"))

  let second = [
    inbox_step(),
    sync_fixture.changes("es-1", "es-2", False, [], ["e2"], []),
    page(["e1"], "qs-2", 0, 1, None),
    sync_fixture.lights([moved], "es-2", []),
    threads(threads_of(emails_of(["e1"])), "ts-2"),
  ]
  let run = again(store, second)

  expect_calls(run, methods(second))
  message_ids(store) |> should.equal(["e1"])
}

/// I-M1: one scripted server history — e1 marked seen, e2 destroyed, e4
/// created — reached incrementally from [e1, e2, e3] holds the same ids and
/// mutable fields as a fresh full sync of the final server.
pub fn incremental_equals_full_test() {
  let seen = jmap_fixture.Email(..jmap_fixture.email("e1"), keywords: ["$seen"])
  let final = [jmap_fixture.email("e4"), seen, jmap_fixture.email("e3")]
  let mutable = fn(store: Store) {
    let assert Some(prior) = sync_fixture.prior_of(store)
    prior.messages
    |> list.map(fn(m) { #(m.id, m.mailbox_ids, m.keywords, m.is_seen) })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  }

  let incremental = {
    use store <- with_store(None)
    seed(store, inbox_step(), bounds(Some(3)), emails_of(["e1", "e2", "e3"]))
    let script = [
      inbox_step(),
      sync_fixture.changes("es-0", "es-1", False, ["e4"], ["e1"], ["e2"]),
      page(["e4", "e1", "e3"], "qs-1", 0, 3, None),
      emails(emails_of(["e4"]), "es-1", []),
      sync_fixture.lights([seen], "es-1", []),
      threads(threads_of(final), "ts-1"),
    ]
    let run =
      sync_fixture.run_with_prior(
        store,
        Spec(..spec(script), bounds: bounds(Some(3))),
      )
    expect_calls(run, methods(script))
    mutable(store)
  }
  let full = {
    use store <- with_store(None)
    seed(store, inbox_step(), bounds(Some(3)), final)
    mutable(store)
  }

  list.map(incremental, fn(m) { m.0 }) |> should.equal(["e1", "e3", "e4"])
  incremental |> should.equal(full)
}

// ---------------------------------------------------------------- fallbacks (SL-002 PHASE-09)

/// The full path with the Prior over e1 and e2, as a fallback runs it: the
/// query, one light refresh of every stored id, and the threads.
fn full_with_prior() -> List(Step) {
  [
    page(["e1", "e2"], "qs-1", 0, 2, None),
    sync_fixture.lights(emails_of(["e1", "e2"]), "es-1", []),
    threads(threads_of(emails_of(["e1", "e2"])), "ts-1"),
  ]
}

/// `cannotCalculateChanges` falls back to the full path with the Prior, and
/// says why.
pub fn cannot_calculate_changes_falls_back_test() {
  use store <- with_store(None)
  seed_two(store)
  let script = [
    inbox_step(),
    sync_fixture.changes_error("cannotCalculateChanges"),
    ..full_with_prior()
  ]
  let run = again(store, script)

  expect_calls(run, methods(script))
  summary(run).mode |> should.equal(sync.Full)
  summary(run).fallback_reason
  |> should.equal(Some("cannot_calculate_changes"))
  message_states(store) |> should.equal([#("e1", "es-1"), #("e2", "es-1")])
}

/// `hasMoreChanges` still true after `max_pages` pages falls back to the full
/// path with the Prior: no further page is asked for, and e1's reported
/// update does not narrow the refresh.
pub fn too_many_changes_falls_back_test() {
  use store <- with_store(None)
  seed_two(store)
  let script = [
    inbox_step(),
    sync_fixture.changes("es-0", "es-1", True, [], ["e1"], []),
    sync_fixture.changes("es-1", "es-2", True, [], [], []),
    ..full_with_prior()
  ]
  let base = spec(script)
  let run =
    sync_fixture.run_with_prior(
      store,
      Spec(..base, bounds: sync.Bounds(..base.bounds, max_pages: 2)),
    )

  expect_calls(run, methods(script))
  summary(run).mode |> should.equal(sync.Full)
  summary(run).fallback_reason |> should.equal(Some("too_many_changes"))
  message_states(store) |> should.equal([#("e1", "es-1"), #("e2", "es-1")])
}

/// DEC-026: the `cannotCalculateChanges` response is not charged, so a
/// `max_total_bytes` one byte over the fallback's full path — below that plus
/// the error response — still completes; one byte under it does not.
pub fn cannot_calculate_changes_within_max_total_bytes_test() {
  let error_step = sync_fixture.changes_error("cannotCalculateChanges")
  let script = [inbox_step(), error_step, ..full_with_prior()]
  let full_cost =
    string.byte_size(sync_fixture.session_body(spec(script)))
    + sync_fixture.bytes([inbox_step(), ..full_with_prior()])
  let with_budget = fn(budget) {
    use store <- with_store(None)
    seed_two(store)
    sync_fixture.run_with_prior(
      store,
      Spec(..spec(script), max_total_bytes: budget),
    )
  }

  { full_cost + 1 < full_cost + sync_fixture.bytes([error_step]) }
  |> should.be_true
  summary(with_budget(full_cost + 1)).fallback_reason
  |> should.equal(Some("cannot_calculate_changes"))
  with_budget(full_cost - 1).result
  |> should.equal(Error(error.LimitExceeded("max_total_bytes")))
}

/// Any other `Email/changes` error fails the run before the write.
pub fn other_changes_error_fails_the_run_test() {
  use store <- with_store(None)
  seed_two(store)
  let script = [inbox_step(), sync_fixture.changes_error("serverFail")]
  let run = again(store, script)

  expect_calls(run, methods(script))
  expect_unchanged(store, run, error.JmapMethod("Email/changes", "serverFail"))
}
