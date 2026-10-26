//// The token-leak suite: invariant I1 on every failure path and on a crash
//// (PHASE-10, T5a; EX-5, VT-2, DEC-019).
////
//// I1: the bearer token never appears on stdout, on stderr, or in any returned
//// `Error`. Each case writes the fixed sentinel below into the credentials file,
//// runs the shipment's own `entrypoint.sh run --config C sync` over a fresh
//// scripted `local_jmap` (so the run is the production path end to end), and
//// asserts three things at once: the expected exit code, the error kind decoded
//// from the one stderr JSON line, and the sentinel's absence from stdout bytes
//// and stderr. Each failing case that fails at or before `Mailbox/get` is then
//// repeated in process through `client.session`/`client.call` with the same
//// `Send` the CLI binds, and the returned `Error` is inspected: neither its JSON
//// line nor `string.inspect` may hold the sentinel. A happy-path control proves
//// the same setup runs end to end, so "absent" does not pass because nothing
//// ran; VA-1 (below) shows the sentinel would be seen if it leaked.
////
//// PHASE-05 extended `sync` to the whole orchestration (`Mailbox/get`,
//// `Email/query`, `Email/get`, `Thread/get`, one store write), so the suite runs
//// the full sync and inspects the store dump as well: the control's dump must
//// hold the scripted message ids (so "no sentinel" is not passing because
//// nothing was written) and no sentinel, and a failure past phase 1 must leave
//// a seeded store's dump exactly as it was (I2). Two cases fail too late for the
//// in-process repeat — its driver issues the session and one `Mailbox/get` — so
//// they run only as the shipment subprocess.
////
//// Three cases put the sentinel in the server's own text. A 500 whose problem
//// document's `type` is the sentinel: the type is not one of RFC 8620 § 3.6.1's
//// four, so the status stands (`http`, `status_500`). A method-level error whose
//// `type` is the sentinel: it is not in RFC 8620 § 3.6.2 / § 5's set, so it
//// becomes the fixed `"unknown"`. A 200 session whose `primaryAccounts` is keyed
//// by the sentinel: the `Decode` path names the map, not the key.
////
//// The crash cases are DEC-019's reading of EX-5's "a crash forced inside the
//// client": spike T0 found no HTTP- or token-shaped crash reachable in the built
//// client on OTP 28.5 (httpc validates neither headers nor responses, and
//// httpc_handler swallows every exception), so no production hook was added for
//// a test's benefit (plan Risk). Instead `subprocess.erl_eval` drives the real
//// edge — `screwtape_ffi:silence_logger/0` and `screwtape_ffi:guard/1` — with a
//// body that reads the token through the compiled `screwtape@credential` module,
//// reveals it through `bearer`, and crashes with the header in the term: once as
//// an `erlang:error/1` raise, once as a linked process's `exit/1`. Either way the
//// guard answers one fixed internal-error line and exit 1.
////
//// VA-1 — the same crash without `guard/1` and with the logger at its default,
//// which prints the sentinel — is a manual control recorded in the phase sheet,
//// not committed here: a test that asserts a leak would have to print it.
////
//// The sentinel is UTF-8 ASCII on purpose: the local TLS server rejects
//// non-UTF-8 request header bytes (phase Findings), so a non-ASCII sentinel would
//// fail a run before any case reached its own edge.

import gleam/bit_array
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/cli
import screwtape/credential
import screwtape/error.{type Error}
import screwtape/jmap/client
import screwtape/jmap/request as jmap_request
import screwtape/store
import support/cli_fixture
import support/jmap_fixture
import support/local_jmap
import support/snapshot_fixture
import support/store_dump
import support/subprocess
import support/temp

pub fn main() -> Nil {
  gleeunit.main()
}

/// I1's marker: every credential file here holds this, so one byte of it in
/// stdout, stderr or an inspected `Error` is the leak the case exists to catch.
const sentinel = "SENTINEL-i1-9f3c1d7a4b2e5068"

/// Short enough that a withheld session reply times out well inside the test's
/// own patience (the subprocess helper waits seconds), long enough that the
/// zero-cost replies are never mistaken for it.
const short_timeout_ms = 300

/// Smaller than any session document the fixtures serve, so the first request's
/// cap is breached before a body arrives: `LimitExceeded` with no token in it.
const tiny_max_total_bytes = 64

/// One failing scenario: what the server answers, the error kind the run must
/// report, the field that proves the case reached its own edge, and the two
/// config bounds a case may tighten. The field is a substring of the error line
/// rather than the whole line, so the case does not pin the line's layout — but
/// two cases that share a kind (`http` above all) cannot pass on each other's
/// evidence.
type Scenario {
  Scenario(
    label: String,
    script: fn(String) -> List(local_jmap.Reply),
    kind: String,
    field: String,
    max_total_bytes: Int,
    request_timeout_ms: Int,
  )
}

// ---------------------------------------------------------------- cases 1-8

/// 401: the server refused the credential.
pub fn session_401_test() {
  scenario("session-401", fixed_reply(401, ""), "auth", "\"status\":401")
  |> run_failing_scenario
}

/// 403: the same refusal, the other status.
pub fn session_403_test() {
  scenario("session-403", fixed_reply(403, ""), "auth", "\"status\":403")
  |> run_failing_scenario
}

/// 429: slow down; the run ends, it does not retry.
pub fn session_429_test() {
  scenario("session-429", fixed_reply(429, ""), "rate_limited", "rate_limited")
  |> run_failing_scenario
}

/// A 500 whose body is not a JMAP problem document: the status, not its text.
pub fn session_500_test() {
  scenario(
    "session-500",
    fixed_reply(500, "not a problem document"),
    "http",
    "\"reason\":\"status_500\"",
  )
  |> run_failing_scenario
}

/// A 500 whose problem document carries the sentinel as its `type`: not one of
/// RFC 8620 § 3.6.1's types, so the status stands and no server text is kept.
pub fn session_500_sentinel_type_test() {
  scenario(
    "session-500-sentinel-type",
    fixed_reply(500, "{\"type\":\"" <> sentinel <> "\"}"),
    "http",
    "\"reason\":\"status_500\"",
  )
  |> run_failing_scenario
}

/// The reply's last byte is withheld and the config's timeout is short: the
/// transport gives up, which is `Http("timeout")` and no request data.
pub fn session_timeout_test() {
  let script = fn(base_url: String) { [withheld(session_document(base_url))] }
  Scenario(
    label: "session-timeout",
    script: script,
    kind: "http",
    field: "\"reason\":\"timeout\"",
    max_total_bytes: cli_fixture.default_max_total_bytes,
    request_timeout_ms: short_timeout_ms,
  )
  |> run_failing_scenario
}

/// A 200 whose body does not parse: the decoder's path, never the body.
pub fn session_malformed_json_test() {
  scenario(
    "session-malformed",
    fixed_reply(200, "{not json"),
    "decode",
    "\"path\":\"$\"",
  )
  |> run_failing_scenario
}

/// A 200 session whose `primaryAccounts` map is keyed by the sentinel: the
/// path names the map, never the key.
pub fn session_sentinel_key_test() {
  let script = fn(base_url: String) {
    let body =
      jmap_fixture.session(base_url <> "/api")
      |> string.replace(
        "{\"urn:ietf:params:jmap:mail\":\"acct-1\"}",
        "{\"" <> sentinel <> "\":5}",
      )
    [local_jmap.reply(200, body)]
  }
  scenario(
    "session-sentinel-key",
    script,
    "decode",
    "\"path\":\"primaryAccounts\"",
  )
  |> run_failing_scenario
}

/// Session fine, then a method-level `["error", ...]`: the method it is
/// attributed to and its problem type, not the arguments the server sent.
pub fn method_error_test() {
  let script = fn(base_url: String) {
    [
      session_document(base_url),
      local_jmap.reply(200, jmap_fixture.text("method_error.json")),
    ]
  }
  scenario("method-error", script, "jmap_method", "\"method\":\"Mailbox/get\"")
  |> run_failing_scenario
}

/// A method-level error whose `type` is the sentinel: not in RFC 8620
/// § 3.6.2 / § 5's set, so the fixed `"unknown"` stands in for it.
pub fn method_error_sentinel_type_test() {
  let script = fn(base_url: String) {
    [
      session_document(base_url),
      local_jmap.reply(
        200,
        "{\"methodResponses\":[[\"error\",{\"type\":\""
          <> sentinel
          <> "\"},\"c0\"]]}",
      ),
    ]
  }
  scenario(
    "method-error-sentinel-type",
    script,
    "jmap_method",
    "\"type\":\"unknown\"",
  )
  |> run_failing_scenario
}

/// A budget smaller than the session body: the ceiling fires before the body
/// is received, and the bound's name is all the `Error` carries.
pub fn session_oversized_test() {
  Scenario(
    label: "session-oversized",
    script: fn(base_url: String) { [session_document(base_url)] },
    kind: "limit_exceeded",
    field: "\"bound\":\"max_total_bytes\"",
    max_total_bytes: tiny_max_total_bytes,
    request_timeout_ms: cli_fixture.default_request_timeout_ms,
  )
  |> run_failing_scenario
}

// ---------------------------------------------------------------- case 9

/// DEC-019 (9a): a crash raised with the revealed header in the term, inside the
/// real `guard/1` after the real `silence_logger/0`. One fixed line, exit 1.
pub fn forced_crash_raise_test() {
  let credentials = cli_fixture.credential_dir(sentinel)
  let record =
    unwrap(subprocess.erl_eval(
      "screwtape_ffi:silence_logger(), "
      <> "screwtape_ffi:guard(fun() -> "
      <> revealed_header(credentials)
      <> "erlang:error({crash, Header})"
      <> " end), "
      <> "screwtape_ffi:halt(0)",
    ))
  temp.remove_dir(credentials)

  assert_internal_error(record)
}

/// DEC-019 (9b): the same reveal, but the crash arrives as an exit signal from a
/// process the guarded body linked to — the class a `try`/`catch` in the caller
/// could not contain.
pub fn forced_crash_linked_exit_test() {
  let credentials = cli_fixture.credential_dir(sentinel)
  let record =
    unwrap(subprocess.erl_eval(
      "screwtape_ffi:silence_logger(), "
      <> "screwtape_ffi:guard(fun() -> "
      <> revealed_header(credentials)
      <> "spawn_link(fun() -> exit({crash, Header}) end), "
      <> "receive after 5000 -> ok end"
      <> " end), "
      <> "screwtape_ffi:halt(0)",
    ))
  temp.remove_dir(credentials)

  assert_internal_error(record)
}

// ---------------------------------------------------------------- case 10

/// The positive control: the same config, credential and process edge, a server
/// that answers the whole sync, exit 0 and the document on stdout — whose one
/// stderr line is the writable account's warning, not a leak. Without this a
/// suite of "sentinel absent" cases could pass because nothing ran. Its own
/// store is kept until it is dumped, so the store's rows show the run reached
/// the write and hold no sentinel.
pub fn happy_path_control_test() {
  let store = temp.dir("i1-store-happy")
  let store_path = store <> "/mail.sqlite3"
  let record =
    run_sync_at(
      "happy",
      cli_fixture.full_sync_script,
      cli_fixture.default_max_total_bytes,
      cli_fixture.default_request_timeout_ms,
      store_path,
    )
  let dump = store_dump.dump(store_path)
  temp.remove_dir(store)

  record.exit_code |> should.equal(0)
  record.stderr
  |> should.equal(
    "{\"level\":\"warning\",\"warning\":\"account_not_read_only\"}\n",
  )
  record.stderr |> string.contains(sentinel) |> should.be_false
  let stdout = bit_array.to_string(record.stdout) |> should.be_ok
  stdout |> string.contains("\"kind\":\"sync\"") |> should.be_true
  stdout |> string.contains(sentinel) |> should.be_false

  // The dump is non-vacuous: the scripted messages are stored rows, so the
  // sentinel's absence below is not the absence of a write that never happened.
  dump |> string.contains("\"m1\"") |> should.be_true
  dump |> string.contains("\"m2\"") |> should.be_true
  dump |> string.contains(sentinel) |> should.be_false
}

// ---------------------------------------------------------------- cases 11-12

/// PHASE-05: the run is past phase 1 — the session, `Mailbox/get` and
/// `Email/query` all succeed — and `Email/get` answers a method-level error.
/// The store is seeded first, so the dump after the run proves nothing was
/// committed (I2), and the line names the method and the problem type, never
/// the arguments the server sent.
pub fn email_get_method_error_test() {
  let store = temp.dir("i1-store-email-get-error")
  let store_path = store <> "/mail.sqlite3"
  seed_store(store_path, "acct-old")
  let before = store_dump.dump(store_path)

  let record =
    run_sync_at(
      "email-get-error",
      email_get_error_script,
      cli_fixture.default_max_total_bytes,
      cli_fixture.default_request_timeout_ms,
      store_path,
    )
  let after = store_dump.dump(store_path)
  temp.remove_dir(store)

  should_fail_late(record, "jmap_method", Some("\"method\":\"Email/get\""))
  before |> string.contains("acct-old") |> should.be_true
  after |> should.equal(before)
}

/// An `Email/query` whose `queryState` is the sentinel on each attempt's first
/// page and another value on the page after it: every attempt is abandoned, and
/// the third one is `QueryUnstable` — an `Error` with no payload at all.
pub fn query_state_keeps_moving_test() {
  let record =
    run_sync(
      "query-unstable",
      unstable_query_script,
      cli_fixture.default_max_total_bytes,
      cli_fixture.default_request_timeout_ms,
    )

  should_fail_late(record, "query_unstable", None)
}

// ---------------------------------------------------------------- driver

/// Run one scenario both ways: the shipment subprocess (cases 1-8's assertions)
/// and, for the same script, the client in process (case 11: the returned
/// `Error` holds no sentinel).
fn run_failing_scenario(scenario: Scenario) -> Nil {
  let record =
    run_sync(
      scenario.label,
      scenario.script,
      scenario.max_total_bytes,
      scenario.request_timeout_ms,
    )

  record.exit_code |> should.equal(1)
  let stderr = string.trim(record.stderr)
  // Exactly one line, and it is the error line: no report, no traceback, no
  // blank line that a leaked crash could hide in.
  record.stderr |> should.equal(stderr <> "\n")
  cli_fixture.error_kind(stderr) |> should.equal(Ok(scenario.kind))
  stderr |> string.contains(scenario.field) |> should.be_true

  let stdout = bit_array.to_string(record.stdout) |> should.be_ok
  stdout |> string.contains(sentinel) |> should.be_false
  record.stderr |> string.contains(sentinel) |> should.be_false

  let in_process = in_process_failure(scenario)
  let line = error.to_json_line(in_process)
  cli_fixture.error_kind(line) |> should.equal(Ok(scenario.kind))
  line |> string.contains(scenario.field) |> should.be_true
  string.inspect(in_process) |> string.contains(sentinel) |> should.be_false
}

/// The scenario's script served by a fresh server, with a config file naming
/// that server and a credentials directory holding the sentinel, run through
/// the shipment's own entry point. The server and both directories are torn
/// down whatever the run did; a withheld reply is released so `stop` never
/// leaves a blocked worker behind.
fn run_sync(
  label: String,
  script: fn(String) -> List(local_jmap.Reply),
  max_total_bytes: Int,
  request_timeout_ms: Int,
) -> subprocess.Record {
  let store = temp.dir("i1-store-" <> label)
  let record =
    run_sync_at(
      label,
      script,
      max_total_bytes,
      request_timeout_ms,
      store <> "/mail.sqlite3",
    )
  temp.remove_dir(store)
  record
}

/// `run_sync` against a store path the caller owns, so a case can seed the
/// store before the run and dump it after.
fn run_sync_at(
  label: String,
  script: fn(String) -> List(local_jmap.Reply),
  max_total_bytes: Int,
  request_timeout_ms: Int,
  store_path: String,
) -> subprocess.Record {
  let server = local_jmap.start_with(script)
  let credentials = cli_fixture.credential_dir(sentinel)
  let #(dir, path) =
    cli_fixture.config_dir(
      "i1-" <> label,
      cli_fixture.config_text_with(
        local_jmap.url(server, "/session"),
        store_path,
        ca_file: Some(server.ca_path),
        max_total_bytes:,
        request_timeout_ms:,
      ),
    )
  let shipment = unwrap(subprocess.shipment_dir())
  let record =
    unwrap(
      subprocess.run_env(
        subprocess.entrypoint(shipment),
        ["run", "--config", path, "sync"],
        [#("CREDENTIALS_DIRECTORY", Some(credentials))],
      ),
    )
  local_jmap.release(server)
  local_jmap.stop(server)
  temp.remove_dir(dir)
  temp.remove_dir(credentials)
  record
}

/// The assertions a failure past the first call shares with
/// `run_failing_scenario`, minus the in-process repeat: that driver's one call
/// is `Mailbox/get`, so it cannot reach a later failure, and a second mechanism
/// would only duplicate it. `field` is a substring of the error line, as in
/// `Scenario`.
fn should_fail_late(
  record: subprocess.Record,
  kind: String,
  field: Option(String),
) -> Nil {
  record.exit_code |> should.equal(1)
  let stderr = string.trim(record.stderr)
  record.stderr |> should.equal(stderr <> "\n")
  cli_fixture.error_kind(stderr) |> should.equal(Ok(kind))
  case field {
    Some(field) -> stderr |> string.contains(field) |> should.be_true
    None -> Nil
  }

  let stdout = bit_array.to_string(record.stdout) |> should.be_ok
  stdout |> string.contains(sentinel) |> should.be_false
  stderr |> string.contains(sentinel) |> should.be_false
}

/// The whole passing script with its `Email/get` replaced by a method-level
/// error, built like the `method-error-sentinel-type` case's.
fn email_get_error_script(base_url: String) -> List(local_jmap.Reply) {
  let assert [session, mailboxes, query, _, _] =
    cli_fixture.full_sync_script(base_url)
  [
    session,
    mailboxes,
    query,
    local_jmap.reply(
      200,
      "{\"methodResponses\":[[\"error\",{\"type\":\"serverFail\"},\"c0\"]]}",
    ),
  ]
}

/// The session and `Mailbox/get`, then three attempts of two `Email/query`
/// pages each: the sentinel's `queryState` first (a one-id page whose `limit`
/// forces a second page), a different one after it, so no attempt settles.
fn unstable_query_script(base_url: String) -> List(local_jmap.Reply) {
  let assert [session, mailboxes, ..] = cli_fixture.full_sync_script(base_url)
  let page = fn(state: String, ids: List(String), position: Int) {
    local_jmap.reply(
      200,
      jmap_fixture.email_query_response(
        ids,
        state,
        position,
        Some(2),
        Some(1),
        True,
      ),
    )
  }
  [
    session,
    mailboxes,
    page(sentinel, ["m1"], 0),
    page("qs-moved", ["m2"], 1),
    page(sentinel, ["m1"], 0),
    page("qs-moved", ["m2"], 1),
    page(sentinel, ["m1"], 0),
    page("qs-moved", ["m2"], 1),
  ]
}

/// Write `snapshot_fixture.full(account_id)` into the store at `path`, so a run
/// that fails has a previous snapshot whose dump it must leave untouched.
fn seed_store(path: String, account_id: String) -> Nil {
  let assert Ok(writer) = store.open_writer(path)
  let assert Ok(Nil) =
    store.write_snapshot(writer, snapshot_fixture.full(account_id))
  store.close_writer(writer)
}

/// The same failing script in process: the token read from a credentials file,
/// the `Send` the CLI itself binds, and the `Error` the client answers — no
/// printing, no exit, so the value can be inspected.
fn in_process_failure(scenario: Scenario) -> Error {
  let server = local_jmap.start_with(scenario.script)
  let credentials = cli_fixture.credential_dir(sentinel)
  let failure = case credential.read(credentials, "fastmail") {
    Error(error) -> error
    Ok(token) -> client_failure(scenario, server, token)
  }
  local_jmap.release(server)
  local_jmap.stop(server)
  temp.remove_dir(credentials)
  failure
}

fn client_failure(
  scenario: Scenario,
  server: local_jmap.Server,
  token: credential.Token,
) -> Error {
  let send =
    cli.production_send(scenario.request_timeout_ms, Some(server.ca_path))
  let budget = client.budget(scenario.max_total_bytes)
  let url = local_jmap.url(server, "/session")
  case client.session(send, token, url, budget) {
    Error(error) -> error
    Ok(bound) ->
      case
        client.call(bound, [
          jmap_request.mailbox_get(client.session_of(bound).account_id, "c0"),
        ])
      {
        Error(error) -> error
        Ok(_) -> {
          let message =
            scenario.label
            <> ": the in-process run succeeded; the case must fail"
          panic as message
        }
      }
  }
}

// ---------------------------------------------------------------- helpers

fn scenario(
  label: String,
  script: fn(String) -> List(local_jmap.Reply),
  kind: String,
  field: String,
) -> Scenario {
  Scenario(
    label: label,
    script: script,
    kind: kind,
    field: field,
    max_total_bytes: cli_fixture.default_max_total_bytes,
    request_timeout_ms: cli_fixture.default_request_timeout_ms,
  )
}

/// A one-reply script that ignores the server's own URL (the apiUrl matters only
/// to a case that reaches a `Mailbox/get`).
fn fixed_reply(
  status: Int,
  body: String,
) -> fn(String) -> List(local_jmap.Reply) {
  fn(_base_url) { [local_jmap.reply(status, body)] }
}

/// A session document naming this server's `/api`, the reply a case starts from.
fn session_document(base_url: String) -> local_jmap.Reply {
  local_jmap.reply(200, jmap_fixture.session(base_url <> "/api"))
}

/// The same reply with its last body byte held back until `release`.
fn withheld(reply: local_jmap.Reply) -> local_jmap.Reply {
  local_jmap.Reply(..reply, withhold_end: True)
}

/// Erlang expressions that read the sentinel through the shipped credential
/// module and reveal it: `Header` is `<<"authorization">>`'s value,
/// `<<"Bearer SENTINEL-i1-...">>`, in the crashing frame.
fn revealed_header(credentials: String) -> String {
  "{ok, T} = 'screwtape@credential':read(<<\""
  <> credentials
  <> "\">>, <<\"fastmail\">>), "
  <> "{_, Header} = 'screwtape@credential':bearer(T), "
}

/// The guard's one answer for any crash: exit 1, nothing on stdout, exactly the
/// fixed line on stderr, and no sentinel anywhere.
fn assert_internal_error(record: subprocess.Record) -> Nil {
  record.exit_code |> should.equal(1)
  record.stdout |> should.equal(<<>>)
  record.stderr
  |> should.equal("{\"level\":\"error\",\"error\":\"internal\"}\n")
  record.stderr |> string.contains(sentinel) |> should.be_false
}

fn unwrap(result: Result(a, subprocess.Failure)) -> a {
  case result {
    Ok(value) -> value
    Error(failure) -> {
      let message = subprocess.failure_message(failure)
      panic as message
    }
  }
}
