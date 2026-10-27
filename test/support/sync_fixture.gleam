//// Scripted sync runs for `sync_test` (PHASE-05 T5).
////
//// A `Spec` is everything one run varies: the JMAP script after the session,
//// the `Bounds`, the session's limits, the byte budget and the clock. `run`
//// serves the session GET, binds a real `Client` over `fixture_send`, runs
//// `sync.run` against a store that stays open, and dumps the store before and
//// after — on the path, with the writer still open, because closing a
//// connection rolls back a transaction it leaked (memory
//// `mem.fact.sqlite.esqlite-readonly-uri`).
////
//// The step builders answer with `jmap_fixture` documents, so a script names
//// only the fields a case cares about: `mailboxes` and `opening` answer the
//// three calls of the opening request, the rest one call under `call_id`.

import gleam/dynamic/decode
import gleam/http
import gleam/http/response.{Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import gleeunit/should
import screwtape/config
import screwtape/error.{type Error}
import screwtape/jmap/client
import screwtape/jmap/request
import screwtape/model
import screwtape/store
import screwtape/store/query
import screwtape/sync
import support/cli_fixture
import support/fixture_send.{type RecordedCall, type Step, Expect}
import support/jmap_fixture
import support/snapshot_fixture
import support/store_dump
import support/temp

pub const session_url = "https://api.example.test/session"

pub const api_url = "https://api.example.test/jmap/"

/// The account `jmap_fixture` documents belong to.
pub const account_id = "acct-1"

/// The account of the snapshot a store is seeded with before an `inject` case.
pub const seed_account = "acct-old"

/// `now` without its fraction, as `synced_at` must render it.
pub const now_text = "2026-10-26T09:00:00Z"

// ---------------------------------------------------------------- specs

pub type Spec {
  Spec(
    script: List(Step),
    bounds: sync.Bounds,
    max_objects_in_get: Int,
    is_read_only: Bool,
    max_total_bytes: Int,
    now: Timestamp,
    prior: Option(model.Prior),
  )
}

/// `script` under roomy limits: `bounds(Some(100))`, 1000 objects per get, a
/// read-only account, a megabyte of budget, and no Prior.
pub fn spec(script: List(Step)) -> Spec {
  Spec(
    script: script,
    bounds: bounds(Some(100)),
    max_objects_in_get: 1000,
    is_read_only: True,
    max_total_bytes: 1_000_000,
    now: now(),
    prior: None,
  )
}

/// The `inbox` window capped at `max_messages`, with no age bound, ten pages
/// and 1000 body bytes.
pub fn bounds(max_messages: Option(Int)) -> sync.Bounds {
  sync.Bounds(
    window: config.Window(
      mailboxes: ["inbox"],
      max_age_days: None,
      max_messages: max_messages,
      retain_messages: None,
    ),
    max_pages: 10,
    max_body_bytes: 1000,
  )
}

/// `now_text` plus half a second, so a run that forgets to truncate shows it.
pub fn now() -> Timestamp {
  let assert Ok(whole) = timestamp.parse_rfc3339(now_text)
  timestamp.add(whole, duration.milliseconds(500))
}

/// The session document `run` serves for `spec`.
pub fn session_body(spec: Spec) -> String {
  jmap_fixture.session_with(api_url, spec.max_objects_in_get, spec.is_read_only)
}

// ---------------------------------------------------------------- steps

fn ok(body: String) -> fixture_send.Reply {
  Ok(Response(status: 200, headers: [], body: body))
}

/// The `inbox` mailbox `jmap_fixture.email` files every message in.
pub fn inbox() -> jmap_fixture.Mailbox {
  jmap_fixture.mailbox("mb-1", "Inbox", Some("inbox"))
}

/// The opening request's answer: `list` and its `state`, with the Email and
/// Thread states `es-0` and `ts-0`.
pub fn mailboxes(list: List(jmap_fixture.Mailbox), state: String) -> Step {
  opening(list, state, "es-0", "ts-0")
}

/// The opening request's answer, with all three states.
pub fn opening(
  list: List(jmap_fixture.Mailbox),
  mailbox_state: String,
  email_state: String,
  thread_state: String,
) -> Step {
  opening_with(jmap_fixture.opening_entries(
    list,
    mailbox_state,
    email_state,
    thread_state,
  ))
}

/// The opening request answered with `entries`, in order: for a case that
/// drops, reorders or replaces one.
pub fn opening_with(entries: List(jmap_fixture.Entry)) -> Step {
  Expect(request.MailboxGet, ok(jmap_fixture.responses(entries)))
}

/// One `Email/query` page with `total`, the server's `limit` when it sent one,
/// and `canCalculateChanges: true`.
pub fn page(
  ids: List(String),
  query_state: String,
  position: Int,
  total: Int,
  limit: Option(Int),
) -> Step {
  page_with(ids, query_state, position, total, limit, True)
}

pub fn page_with(
  ids: List(String),
  query_state: String,
  position: Int,
  total: Int,
  limit: Option(Int),
  can_calculate_changes: Bool,
) -> Step {
  Expect(
    request.EmailQuery,
    ok(jmap_fixture.email_query_response(
      ids,
      query_state,
      position,
      Some(total),
      limit,
      can_calculate_changes,
    )),
  )
}

pub fn emails(
  list: List(jmap_fixture.Email),
  state: String,
  not_found: List(String),
) -> Step {
  Expect(
    request.EmailGet,
    ok(jmap_fixture.email_get_response(list, state, not_found)),
  )
}

/// One light `Email/get` (DEC-026): the mutable fields of `emails_` under
/// `state`, and the ids in `not_found`.
pub fn lights(
  emails_: List(jmap_fixture.Email),
  state: String,
  not_found: List(String),
) -> Step {
  let lights =
    list.map(emails_, fn(email) {
      #(email.id, email.mailbox_ids, email.keywords)
    })
  Expect(
    request.EmailGet,
    ok(jmap_fixture.light_email_get_response(lights, state, not_found)),
  )
}

pub fn threads(list: List(#(String, List(String))), state: String) -> Step {
  Expect(request.ThreadGet, ok(jmap_fixture.thread_get_response(list, state)))
}

/// The threads of `emails`, each with its members, in first-seen order.
pub fn threads_of(
  emails: List(jmap_fixture.Email),
) -> List(#(String, List(String))) {
  list.fold(emails, [], fn(threads, email) {
    case list.key_find(threads, email.thread_id) {
      Ok(ids) ->
        list.key_set(threads, email.thread_id, list.append(ids, [email.id]))
      Error(Nil) -> list.append(threads, [#(email.thread_id, [email.id])])
    }
  })
}

/// One `Email/get` and one `Thread/get` that deliver `emails` whole.
pub fn fetch(emails_: List(jmap_fixture.Email)) -> List(Step) {
  fetch_chunked(emails_, 1000)
}

/// The `Email/get` steps that deliver `emails` in chunks of `size`, states
/// `es-1`, `es-2`, …, then the `Thread/get` steps over their threads, sorted
/// by id as the run asks for them, in chunks of `size`, states `ts-1`, ….
/// No emails is no step (PHASE-11 EX-2).
pub fn fetch_chunked(
  emails_: List(jmap_fixture.Email),
  size: Int,
) -> List(Step) {
  let email_steps =
    list.sized_chunk(emails_, size)
    |> list.index_map(fn(chunk, i) { emails(chunk, numbered("es-", i), []) })
  let thread_steps =
    threads_of(emails_)
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.sized_chunk(size)
    |> list.index_map(fn(chunk, i) { threads(chunk, numbered("ts-", i)) })
  list.append(email_steps, thread_steps)
}

fn numbered(prefix: String, index: Int) -> String {
  prefix <> int.to_string(index + 1)
}

/// `prefix<from>` .. `prefix<to>`: message ids.
pub fn ids(prefix: String, from: Int, to: Int) -> List(String) {
  int.range(from: from, to: to + 1, with: [], run: fn(acc, i) {
    [prefix <> int.to_string(i), ..acc]
  })
  |> list.reverse
}

pub fn emails_of(ids: List(String)) -> List(jmap_fixture.Email) {
  list.map(ids, jmap_fixture.email)
}

/// A 500 with no body where `method` was expected.
pub fn failure(method: request.Method) -> Step {
  Expect(method, Ok(Response(status: 500, headers: [], body: "")))
}

/// `script` up to `index`, with the step at `index` replaced by a 500 for the
/// same method: the run must fail there and send nothing after it.
pub fn fail_at(script: List(Step), index: Int) -> List(Step) {
  let #(head, tail) = list.split(script, index)
  let assert [step, ..] = tail
  list.append(head, [failure(method_of(step))])
}

/// The JMAP methods `script` expects, in order.
pub fn methods(script: List(Step)) -> List(request.Method) {
  list.map(script, method_of)
}

fn method_of(step: Step) -> request.Method {
  let assert Expect(call:, ..) = step
  call
}

/// The response bytes of `steps`, for budget arithmetic.
pub fn bytes(steps: List(Step)) -> Int {
  steps
  |> list.map(fn(step) {
    case step {
      Expect(reply: Ok(response), ..)
      | fixture_send.Step(reply: Ok(response), ..) ->
        string.byte_size(response.body)
      _ -> 0
    }
  })
  |> int.sum
}

// ---------------------------------------------------------------- runs

/// A store under a fresh temporary directory, its writer open.
pub type Store {
  Store(dir: String, path: String, writer: store.Writer)
}

/// What one run returned and sent, and the store around it. `calls` holds the
/// first call of each JMAP request; `requests` every call of each.
pub type Run {
  Run(
    result: Result(sync.Summary, Error),
    calls: List(RecordedCall),
    requests: List(List(RecordedCall)),
    unmatched: Int,
    before: String,
    after: String,
  )
}

/// A fresh store, seeded with `seed` when given; closed and removed after
/// `body`.
pub fn with_store(seed: Option(model.Snapshot), body: fn(Store) -> a) -> a {
  let dir = temp.dir("screwtape-sync")
  let path = dir <> "/screwtape.db"
  let assert Ok(writer) = store.open_writer(path)
  case seed {
    Some(snapshot) -> {
      let assert Ok(Nil) = store.write_snapshot(writer, snapshot)
      Nil
    }
    None -> Nil
  }
  let outcome = body(Store(dir, path, writer))
  store.close_writer(writer)
  temp.remove_dir(dir)
  outcome
}

/// The snapshot an `inject` case seeds its store with.
pub fn seeded() -> Option(model.Snapshot) {
  Some(snapshot_fixture.full(seed_account))
}

/// Run `spec` against `store`, dumping it on either side of the run.
pub fn run(store: Store, spec: Spec) -> Run {
  let fixture =
    fixture_send.start([
      fixture_send.Step(http.Get, ok(session_body(spec))),
      ..spec.script
    ])
  let assert Ok(client_) =
    client.session(
      fixture_send.send(fixture),
      cli_fixture.token("sync-secret"),
      session_url,
      client.budget(spec.max_total_bytes),
    )
  let before = store_dump.dump(store.path)
  let result =
    sync.run(client_, store.writer, spec.bounds, spec.prior, spec.now)
  let after = store_dump.dump(store.path)
  Run(
    result: result,
    calls: fixture_send.recorded_calls(fixture),
    requests: fixture_send.recorded(fixture)
      |> list.filter(fn(request) { request.method == http.Post })
      |> list.map(fixture_send.calls_of),
    unmatched: fixture_send.unmatched_count(fixture),
    before: before,
    after: after,
  )
}

/// The committed store as `cli` reads it before a run: its Prior, or `None`
/// when it holds no snapshot.
pub fn prior_of(store: Store) -> Option(model.Prior) {
  let assert Ok(reader) = store.open_reader(store.path)
  let result = store.read(reader, query.prior)
  store.close_reader(reader)
  case result {
    Ok(prior) -> Some(prior)
    Error(error.Store("no_snapshot")) -> None
    Error(other) -> panic as { "prior_of: " <> string.inspect(other) }
  }
}

/// Run `spec` with the Prior read from `store`, as `cli` does.
pub fn run_with_prior(store: Store, spec: Spec) -> Run {
  run(store, Spec(..spec, prior: prior_of(store)))
}

/// One run of `spec` on a fresh store seeded with `seed`.
pub fn run_sync(
  spec: Spec,
  seed: Option(model.Snapshot),
  body: fn(Store, Run) -> a,
) -> a {
  use store <- with_store(seed)
  body(store, run(store, spec))
}

// ---------------------------------------------------------------- assertions

/// The run sent exactly `expected`, in order, and every request matched.
pub fn expect_calls(run: Run, expected: List(request.Method)) -> Nil {
  run.calls
  |> list.map(fn(call) { call.name })
  |> should.equal(list.map(expected, request.method_name))
  run.unmatched |> should.equal(0)
}

/// The run failed with `expected`, the seeded store — any snapshot — is
/// byte-for-byte as it was (`user_version` included), and the writer holds no
/// open transaction: it can still commit.
pub fn expect_unchanged(store: Store, run: Run, expected: Error) -> Nil {
  run.result |> should.equal(Error(expected))
  count(store, "sync") |> should.equal(1)
  run.after |> should.equal(run.before)
  user_version(run.after) |> should.equal(user_version(run.before))
  store.write_snapshot(store.writer, snapshot_fixture.full("acct-probe"))
  |> should.equal(Ok(Nil))
}

/// The `user_version=` line every dump starts with.
pub fn user_version(dump: String) -> String {
  let assert [line, ..] = string.split(dump, "\n")
  line
}

/// A committed run's summary.
pub fn summary(run: Run) -> sync.Summary {
  let assert Ok(summary) = run.result
  summary
}

// ---------------------------------------------------------------- recorded calls

/// Every call of the run's first JMAP request: the opening request.
pub fn opening_calls(run: Run) -> List(RecordedCall) {
  let assert [first, ..] = run.requests
  first
}

/// The calls of `method`, in order.
pub fn calls_of(run: Run, method: request.Method) -> List(RecordedCall) {
  let name = request.method_name(method)
  list.filter(run.calls, fn(call) { call.name == name })
}

/// An integer argument of a call; `None` when absent or null.
pub fn int_argument(call: RecordedCall, name: String) -> Option(Int) {
  let decoder =
    decode.optional_field(
      name,
      None,
      decode.optional(decode.int),
      decode.success,
    )
  let assert Ok(value) = decode.run(call.arguments, decoder)
  value
}

/// The `position` of every `Email/query`.
pub fn positions(run: Run) -> List(Int) {
  calls_of(run, request.EmailQuery)
  |> list.map(fn(call) {
    let assert Some(position) = int_argument(call, "position")
    position
  })
}

/// The `limit` of every `Email/query`; `None` where none was sent.
pub fn limits(run: Run) -> List(Option(Int)) {
  calls_of(run, request.EmailQuery)
  |> list.map(int_argument(_, "limit"))
}

/// The `ids` of every call of `method`.
pub fn id_lists(run: Run, method: request.Method) -> List(List(String)) {
  calls_of(run, method) |> list.map(fixture_send.ids_of)
}

/// The `inMailbox` ids of a call's `OR` filter (a window with no age bound).
pub fn filter_mailboxes(call: RecordedCall) -> List(String) {
  let decoder =
    decode.at(
      ["filter", "conditions"],
      decode.list(decode.at(["inMailbox"], decode.string)),
    )
  let assert Ok(ids) = decode.run(call.arguments, decoder)
  ids
}

// ---------------------------------------------------------------- store rows

/// The rows `sql` selects from the committed store at `store.path`.
pub fn rows(store: Store, sql: String, decoder: decode.Decoder(a)) -> List(a) {
  let assert Ok(reader) = store.open_reader(store.path)
  let result =
    store.read(reader, fn(tx) {
      store.select(tx, sql, with: [], expecting: decoder)
    })
  store.close_reader(reader)
  let assert Ok(rows) = result
  rows
}

/// `count(*)` of `table`.
pub fn count(store: Store, table: String) -> Int {
  let assert [n] =
    rows(
      store,
      "SELECT count(*) FROM " <> table,
      decode.field(0, decode.int, decode.success),
    )
  n
}

pub fn pair_decoder() -> decode.Decoder(#(String, String)) {
  use a <- decode.field(0, decode.string)
  use b <- decode.field(1, decode.string)
  decode.success(#(a, b))
}
