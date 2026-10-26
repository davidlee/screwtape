//// Contract tests for `screwtape/sync` (PHASE-05 T5; EX-2..EX-6; VT-1..VT-4).
////
//// Every case runs the real `sync.run` over a real `Client` bound to a
//// scripted `fixture_send` (session, then one JMAP call per request), against a
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
import gleam/option.{None, Some}
import gleam/string
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
  summary, threads, threads_of, with_store,
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

fn type_states(store: Store) -> List(#(String, String)) {
  rows(
    store,
    "SELECT type, state FROM type_state ORDER BY type",
    sync_fixture.pair_decoder(),
  )
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

/// Two chunks of each get: `type_state` keeps the earliest state per type
/// (Email from the first `Email/get`, Thread from the first `Thread/get`,
/// Mailbox from `Mailbox/get`), and each message keeps the state of the chunk
/// that delivered it. Catches latest-state-wins, and one state for all
/// messages.
pub fn type_state_earliest_test() {
  let all = ids("e", 1, 3)
  let script =
    list.flatten([
      [inbox_step(), page(all, "qs-1", 0, 3, None)],
      fetch_chunked(emails_of(all), 2),
    ])
  use store, run <- run_sync(Spec(..spec(script), max_objects_in_get: 2), None)

  expect_calls(run, methods(script))
  type_states(store)
  |> should.equal([
    #("Email", "es-1"),
    #("Mailbox", "ms-1"),
    #("Thread", "ts-1"),
  ])
  message_states(store)
  |> should.equal([#("e1", "es-1"), #("e2", "es-1"), #("e3", "es-2")])
  summary(run).states
  |> should.equal([
    model.TypeState("Email", "es-1"),
    model.TypeState("Mailbox", "ms-1"),
    model.TypeState("Thread", "ts-1"),
  ])
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
    ..fetch([])
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
    ..fetch([])
  ]
  let spec =
    Spec(..spec(script), bounds: window(["Receipts", "inbox", "Inbox"]))
  use _store, run <- run_sync(spec, None)

  expect_calls(run, methods(script))
  sync_fixture.filter_mailboxes(first_query(run))
  |> should.equal(["mb-r", "mb-a"])
}

/// An empty window still sends one `Email/get` and one `Thread/get` with
/// `ids: []`, records all three states and commits a snapshot with no
/// messages (A9). Catches a run that skips the empty gets, or commits nothing.
pub fn empty_window_commits_test() {
  let script = [inbox_step(), empty_page(), ..fetch([])]
  use store, run <- run_sync(spec(script), None)

  expect_calls(run, [MailboxGet, EmailQuery, EmailGet, ThreadGet])
  id_lists(run, EmailGet) |> should.equal([[]])
  id_lists(run, ThreadGet) |> should.equal([[]])
  run.after |> should.not_equal(run.before)
  count(store, "message") |> should.equal(0)
  type_states(store)
  |> should.equal([
    #("Email", "es-1"),
    #("Mailbox", "ms-1"),
    #("Thread", "ts-1"),
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
  id_lists(run, ThreadGet) |> should.equal([["t-x", "t-e3"]])
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
      model.TypeState("Email", "es-1"),
      model.TypeState("Mailbox", "ms-1"),
      model.TypeState("Thread", "ts-1"),
    ],
    is_read_only: True,
  ))
}
