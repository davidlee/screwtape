//// Contract tests for `screwtape/jmap/client` (SL-001 PHASE-10, VT-1; EX-2).
////
//// The token comes from a real file under a temporary directory, because
//// `Token` has no test-only constructor; its secret is `sentinel`. Every `Error`
//// asserted here is also inspected for that secret: an `Error` is printed to
//// stderr, so a leak would show up exactly there.
////
//// Most requests go through `support/fixture_send`; the exhaustion case also
//// runs once over the production `Send` against `support/local_jmap`.

import gleam/bit_array
import gleam/http
import gleam/http/response.{Response}
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/cli
import screwtape/credential.{type Token}
import screwtape/error
import screwtape/jmap/client
import screwtape/jmap/decode
import screwtape/jmap/request as jmap_request
import support/fixture_send
import support/jmap_fixture
import support/local_jmap
import support/temp

pub fn main() -> Nil {
  gleeunit.main()
}

/// A namespaced secret: no `Error` a client call returns may render it.
const sentinel = "SENTINEL-client-0123456789abcdef"

/// The `type` of `method_error.json` and `problem_not_request.json`.
const not_request = "urn:ietf:params:jmap:error:notRequest"

/// The URL the session is fetched from; the session document's own `apiUrl` is
/// what `call` posts to.
const session_url = "https://api.example.test/session"

const account_id = "acct-1"

const request_call_id = "c0"

/// Far above any scripted body, for the cases that only care about routing.
const roomy = 1_000_000

/// The per-request timeout the production `Send` is bound with.
const timeout_ms = 5000

// ---------------------------------------------------------------- helpers

/// The only way to a `Token`: a real file, read by `credential.read`.
fn token() -> Token {
  let dir = temp.dir("client-token")
  temp.write(dir <> "/fastmail", bit_array.from_string(sentinel <> "\n"))
  let result = credential.read(dir, "fastmail")
  temp.remove_dir(dir)
  let assert Ok(token) = result
  token
}

fn ok(status: Int, body: String) -> fixture_send.Reply {
  Ok(Response(status: status, headers: [], body: body))
}

fn get(status: Int, body: String) -> fixture_send.Step {
  fixture_send.Step(http.Get, ok(status, body))
}

fn post(status: Int, body: String) -> fixture_send.Step {
  fixture_send.Step(http.Post, ok(status, body))
}

fn get_failure(failure: client.HttpFailure) -> fixture_send.Step {
  fixture_send.Step(http.Get, Error(failure))
}

fn post_failure(failure: client.HttpFailure) -> fixture_send.Step {
  fixture_send.Step(http.Post, Error(failure))
}

fn invocation() -> jmap_request.Invocation {
  jmap_request.mailbox_get(account_id, request_call_id)
}

fn open_session(
  fixture: fixture_send.Fixture,
  max_total_bytes: Int,
) -> Result(client.Client, error.Error) {
  client.session(
    fixture_send.send(fixture),
    token(),
    session_url,
    client.budget(max_total_bytes),
  )
}

/// A fixture that has already answered the session fetch with `session.json`,
/// plus the client bound to it; `script` follows, one entry per `call`.
fn with_session(
  script: List(fixture_send.Step),
) -> #(fixture_send.Fixture, client.Client) {
  let fixture =
    fixture_send.start([get(200, jmap_fixture.text("session.json")), ..script])
  let assert Ok(client_) = open_session(fixture, roomy)
  #(fixture, client_)
}

/// The failure is the expected one, and its printed form holds no token.
fn expect_error(result: Result(a, error.Error), expected: error.Error) -> Nil {
  let assert Error(actual) = result
  actual |> should.equal(expected)
  string.inspect(actual) |> string.contains(sentinel) |> should.be_false
}

// ---------------------------------------------------------------- budget

pub fn budget_remaining_test() {
  client.budget(4096) |> client.remaining |> should.equal(4096)
}

/// VT-1 "exhausted", "max_total_bytes": the two 2xx bodies take the budget to
/// exactly 0, and the next `call` makes no request at all.
pub fn exhausted_budget_refuses_the_next_call_test() {
  let session_body = jmap_fixture.text("session.json")
  let call_body = jmap_fixture.text("mailbox_get.json")
  let max_total_bytes =
    string.byte_size(session_body) + string.byte_size(call_body)
  let fixture =
    fixture_send.start([get(200, session_body), post(200, call_body)])

  let assert Ok(client_) = open_session(fixture, max_total_bytes)
  let assert Ok(#(client_, responses)) = client.call(client_, [invocation()])
  responses |> list.length |> should.equal(1)
  client.remaining(client.budget_of(client_)) |> should.equal(0)

  client.call(client_, [invocation()])
  |> expect_error(error.LimitExceeded("max_total_bytes"))

  fixture_send.request_count(fixture) |> should.equal(2)
}

/// VT-1 "request_count": the same exhaustion over the production `Send`. After
/// the 2xx session and the 2xx call spend the budget to 0, the refused call
/// opens no connection, so the server's count does not move.
pub fn exhausted_budget_real_transport_sends_nothing_test() {
  let call_body = jmap_fixture.text("mailbox_get.json")
  let server =
    local_jmap.start_with(fn(base_url) {
      [
        local_jmap.reply(200, jmap_fixture.session(base_url <> "/api")),
        local_jmap.reply(200, call_body),
      ]
    })
  let session_body = jmap_fixture.session(local_jmap.url(server, "/api"))
  // The production `Send`, owned by `screwtape/cli` (D8); this case binds it
  // with the real server's per-run CA.
  let send = cli.production_send(timeout_ms, Some(server.ca_path))
  let max_total_bytes =
    string.byte_size(session_body) + string.byte_size(call_body)

  let fetched =
    client.session(
      send,
      token(),
      local_jmap.url(server, "/session"),
      client.budget(max_total_bytes),
    )
  let assert Ok(client_) = fetched
  let assert Ok(#(client_, _)) = client.call(client_, [invocation()])

  let before = local_jmap.request_count(server)
  let exhausted = client.call(client_, [invocation()])
  let after = local_jmap.request_count(server)
  local_jmap.stop(server)

  before |> should.equal(2)
  exhausted |> expect_error(error.LimitExceeded("max_total_bytes"))
  after |> should.equal(before)
}

/// A budget of 0 is already spent: the session fetch is refused before it
/// exists, so the helper records nothing.
pub fn zero_budget_sends_no_request_test() {
  let fixture =
    fixture_send.start([get(200, jmap_fixture.text("session.json"))])

  open_session(fixture, 0)
  |> expect_error(error.LimitExceeded("max_total_bytes"))

  fixture_send.request_count(fixture) |> should.equal(0)
}

/// `Send`'s `TooLarge` is a budget outcome, not an HTTP one, and the fixture
/// honours its cap: the session body is one byte over the whole budget.
pub fn oversized_session_body_over_the_budget_test() {
  let session_body = jmap_fixture.text("session.json")
  let fixture = fixture_send.start([get(200, session_body)])

  open_session(fixture, string.byte_size(session_body) - 1)
  |> expect_error(error.LimitExceeded("max_total_bytes"))

  fixture_send.request_count(fixture) |> should.equal(1)
}

/// The cap handed to `Send` is the bytes left: the whole budget first, then the
/// budget with the session body taken off.
pub fn cap_passed_is_the_budget_left_test() {
  let session_body = jmap_fixture.text("session.json")
  let call_body = jmap_fixture.text("mailbox_get.json")
  let max_total_bytes =
    string.byte_size(session_body) + string.byte_size(call_body) + 500
  let fixture =
    fixture_send.start([get(200, session_body), post(200, call_body)])

  let assert Ok(client_) = open_session(fixture, max_total_bytes)
  let assert Ok(#(client_, _)) = client.call(client_, [invocation()])

  fixture_send.caps(fixture)
  |> should.equal([
    max_total_bytes,
    max_total_bytes - string.byte_size(session_body),
  ])
  client.remaining(client.budget_of(client_)) |> should.equal(500)
}

/// VT-1 "503": a non-2xx answer from `call` is an error, which ends the run
/// (EX-2). It is not retried, and the cap it was received under is the budget
/// left after the session (A2).
pub fn call_503_is_an_error_test() {
  let session_body = jmap_fixture.text("session.json")
  let fixture =
    fixture_send.start([
      get(200, session_body),
      post(503, "{\"title\":\"upstream unavailable\"}"),
    ])

  let assert Ok(client_) = open_session(fixture, roomy)
  client.call(client_, [invocation()])
  |> expect_error(error.Http("status_503"))

  fixture_send.caps(fixture)
  |> should.equal([roomy, roomy - string.byte_size(session_body)])
}

// ---------------------------------------------------------------- decoding

/// A 2xx session and a 2xx call: the session fields decode, the method
/// responses come back in order, and `budget_of` carries what is left.
pub fn session_and_call_decode_test() {
  let #(fixture, client_) =
    with_session([post(200, jmap_fixture.text("mailbox_get.json"))])

  let session = client.session_of(client_)
  session.api_url |> should.equal("https://api.example.test/jmap/")
  session.account_id |> should.equal(account_id)
  session.is_read_only |> should.be_false
  session.max_objects_in_get |> should.equal(1000)
  session.max_calls_in_request |> should.equal(32)

  let assert Ok(#(client_, responses)) = client.call(client_, [invocation()])
  let assert [decode.MethodResponse(name:, call_id:, ..)] = responses
  name |> should.equal("Mailbox/get")
  call_id |> should.equal(request_call_id)

  let spent =
    string.byte_size(jmap_fixture.text("session.json"))
    + string.byte_size(jmap_fixture.text("mailbox_get.json"))
  fixture_send.request_count(fixture) |> should.equal(2)
  client.remaining(client.budget_of(client_)) |> should.equal(roomy - spent)

  // The GET is the session URL; the POST is the session's own `apiUrl` and the
  // request document, not the session URL again.
  let assert [#(http.Get, _, _), #(http.Post, url, body)] =
    fixture_send.recorded(fixture)
    |> list.map(fn(request) { #(request.method, request.url, request.body) })
  url |> should.equal("https://api.example.test/jmap/")
  body |> should.equal(json.to_string(jmap_request.body([invocation()])))
}

/// The budget is bytes, not characters: a body whose UTF-8 text is longer in
/// bytes than in characters spends its byte size, so `remaining` is the budget
/// less `string.byte_size`, which a character count could not produce.
pub fn budget_is_charged_in_bytes_test() {
  let session_body = jmap_fixture.text("session.json")
  let call_body =
    string.replace(
      jmap_fixture.text("mailbox_get.json"),
      "\"Inbox\"",
      "\"Ä–日本\"",
    )
  call_body
  |> string.byte_size
  |> should.not_equal(string.length(call_body))
  let max_total_bytes =
    string.byte_size(session_body) + string.byte_size(call_body) + 500
  let fixture =
    fixture_send.start([get(200, session_body), post(200, call_body)])

  let assert Ok(client_) = open_session(fixture, max_total_bytes)
  let assert Ok(#(client_, _)) = client.call(client_, [invocation()])

  client.remaining(client.budget_of(client_))
  |> should.equal(
    max_total_bytes
    - string.byte_size(session_body)
    - string.byte_size(call_body),
  )
}

/// A method-level error names the method that was sent, not the call id. The
/// fixture's type is not in RFC 8620 § 3.6.2's set, so it is `"unknown"`.
pub fn method_error_is_jmap_method_test() {
  let #(_, client_) =
    with_session([post(200, jmap_fixture.text("method_error.json"))])

  client.call(client_, [invocation()])
  |> expect_error(error.JmapMethod("Mailbox/get", "unknown"))
}

// ---------------------------------------------------------------- call_one

fn mailbox_method() -> String {
  jmap_request.method_name(jmap_request.MailboxGet)
}

/// One call in, one call out: `call_one` hands back the single entry the server
/// answered, and charges the response to the budget like `call` does.
pub fn call_one_answers_the_single_entry_test() {
  let #(fixture, client_) =
    with_session([post(200, jmap_fixture.text("mailbox_get.json"))])
  let assert Ok([expected]) =
    decode.method_responses(jmap_fixture.text("mailbox_get.json"), [
      #(request_call_id, mailbox_method()),
    ])

  let assert Ok(#(client_, response)) = client.call_one(client_, invocation())
  response |> should.equal(expected)
  fixture_send.request_count(fixture) |> should.equal(2)
  client.remaining(client.budget_of(client_))
  |> should.equal(
    roomy
    - string.byte_size(jmap_fixture.text("session.json"))
    - string.byte_size(jmap_fixture.text("mailbox_get.json")),
  )
}

/// A response document with no entries answers no call: `call_one` must report
/// that at `methodResponses` rather than crash or invent a response.
pub fn call_one_without_an_entry_is_a_decode_error_test() {
  let #(_, client_) = with_session([post(200, "{\"methodResponses\":[]}")])

  client.call_one(client_, invocation())
  |> expect_error(error.Decode("methodResponses"))
}

/// Two entries cannot both answer one call: like zero, the count is a decode
/// error at the map, not a silent pick of the first.
pub fn call_one_with_two_entries_is_a_decode_error_test() {
  let #(_, client_) = with_session([post(200, two_entries())])

  client.call_one(client_, invocation())
  |> expect_error(error.Decode("methodResponses"))
}

fn two_entries() -> String {
  let entry =
    json.preprocessed_array([
      json.string(mailbox_method()),
      json.object([
        #("accountId", json.string(account_id)),
        #("state", json.string("state-1")),
        #("list", json.preprocessed_array([])),
        #("notFound", json.preprocessed_array([])),
      ]),
      json.string(request_call_id),
    ])
  json.object([#("methodResponses", json.preprocessed_array([entry, entry]))])
  |> json.to_string
}

// ---------------------------------------------------------------- statuses

/// D2, status by status: 401/403 with no body, 429, a 500 whose body is a JMAP
/// problem document, and a 500 whose body is not. Each is one request.
pub fn session_status_table_test() {
  let cases = [
    #(401, "unauthorized", error.Auth(401)),
    #(403, "forbidden", error.Auth(403)),
    #(429, "slow down", error.RateLimited),
    #(
      500,
      jmap_fixture.text("problem_not_request.json"),
      error.JmapRequest(not_request),
    ),
    #(500, "boom", error.Http("status_500")),
  ]

  cases
  |> list.each(fn(c) {
    let fixture = fixture_send.start([get(c.0, c.1)])
    open_session(fixture, roomy) |> expect_error(c.2)
    fixture_send.request_count(fixture) |> should.equal(1)
  })
}

/// The same table on the POST path, where the session has already decoded.
pub fn call_status_table_test() {
  let cases = [
    #(401, "unauthorized", error.Auth(401)),
    #(403, "forbidden", error.Auth(403)),
    #(429, "slow down", error.RateLimited),
    #(
      500,
      jmap_fixture.text("problem_not_request.json"),
      error.JmapRequest(not_request),
    ),
    #(503, "boom", error.Http("status_503")),
  ]

  cases
  |> list.each(fn(c) {
    let #(_, client_) = with_session([post(c.0, c.1)])
    client.call(client_, [invocation()]) |> expect_error(c.2)
  })
}

/// Every `HttpFailure` has its own fixed reason, and `TooLarge` is the budget's.
pub fn send_failure_table_test() {
  let cases = [
    #(client.Timeout, error.Http("timeout")),
    #(client.ConnectFailed, error.Http("connect_failed")),
    #(client.TlsFailed, error.Http("tls_failed")),
    #(client.BadUtf8, error.Http("bad_utf8")),
    #(client.TooLarge, error.LimitExceeded("max_total_bytes")),
  ]

  cases
  |> list.each(fn(c) {
    let fixture = fixture_send.start([get_failure(c.0)])
    open_session(fixture, roomy) |> expect_error(c.1)
    fixture_send.request_count(fixture) |> should.equal(1)
  })
}

/// A transport failure on the POST maps the same way as one on the session.
pub fn call_send_failure_test() {
  let #(_, client_) = with_session([post_failure(client.Timeout)])

  client.call(client_, [invocation()]) |> expect_error(error.Http("timeout"))
}

// ---------------------------------------------------------------- the token

/// The header the client sends is exactly `credential.bearer`, on the session
/// GET and on the POST that follows it.
pub fn authorization_header_test() {
  let #(fixture, client_) =
    with_session([post(200, jmap_fixture.text("mailbox_get.json"))])

  let assert Ok(#(_, _)) = client.call(client_, [invocation()])

  let expected = Ok("Bearer " <> sentinel)
  fixture_send.recorded(fixture)
  |> list.map(fn(request) { list.key_find(request.headers, "authorization") })
  |> should.equal([expected, expected])
}
