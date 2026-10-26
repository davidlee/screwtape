//// Tests for `support/jmap_fixture` and the method-name matching added to
//// `support/fixture_send` (PHASE-10, EX-2).
////
//// Each response document is parsed by the production decoder with the call id
//// and method name a run would send, so a builder that names a different method
//// fails here rather than in a contract test.

import gleam/bit_array
import gleam/http
import gleam/http/response.{Response}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/credential.{type Token}
import screwtape/error
import screwtape/jmap/client
import screwtape/jmap/decode
import screwtape/jmap/request
import support/fixture_send
import support/jmap_fixture
import support/temp

pub fn main() {
  gleeunit.main()
}

const session_url = "https://api.example.test/session"

const account_id = "acct-1"

const sentinel = "SENTINEL-jmap-fixture-0123456789abcdef"

const roomy = 1_000_000

fn token() -> Token {
  let dir = temp.dir("jmap-fixture-token")
  temp.write(dir <> "/fastmail", bit_array.from_string(sentinel <> "\n"))
  let result = credential.read(dir, "fastmail")
  temp.remove_dir(dir)
  let assert Ok(token) = result
  token
}

fn ok(status: Int, body: String) -> fixture_send.Reply {
  Ok(Response(status: status, headers: [], body: body))
}

fn get(body: String) -> fixture_send.Step {
  fixture_send.Step(http.Get, ok(200, body))
}

fn expect(method: request.Method, body: String) -> fixture_send.Step {
  fixture_send.Expect(method, ok(200, body))
}

fn open_session(
  fixture: fixture_send.Fixture,
) -> Result(client.Client, error.Error) {
  client.session(
    fixture_send.send(fixture),
    token(),
    session_url,
    client.budget(roomy),
  )
}

fn assert_response(text: String, method: request.Method) -> Nil {
  let expected = request.method_name(method)
  let assert Ok([decode.MethodResponse(name:, ..)]) =
    decode.method_responses(text, [#(request.call_id, expected)])
  name |> should.equal(expected)
}

pub fn session_with_test() {
  let text =
    jmap_fixture.session_with("https://api.example.test/jmap/", 42, True)
  let assert Ok(session) = decode.session(text)
  session.max_objects_in_get |> should.equal(42)
  session.is_read_only |> should.be_true
}

pub fn mailbox_get_response_test() {
  assert_response(
    jmap_fixture.mailbox_get_response(
      [
        jmap_fixture.mailbox("mb-1", "Inbox", Some("inbox")),
        jmap_fixture.mailbox("mb-2", "Archive", None),
      ],
      "state-1",
    ),
    request.MailboxGet,
  )
}

pub fn email_query_response_test() {
  assert_response(
    jmap_fixture.email_query_response(
      ["e-1", "e-2"],
      "q-1",
      0,
      Some(2),
      None,
      True,
    ),
    request.EmailQuery,
  )
}

pub fn email_query_response_without_total_test() {
  let text =
    jmap_fixture.email_query_response(["e-1"], "q-1", 0, None, None, False)
  string.contains(text, "\"total\"") |> should.be_false
  string.contains(text, "\"limit\"") |> should.be_false
}

pub fn email_get_response_test() {
  assert_response(
    jmap_fixture.email_get_response([jmap_fixture.email("e-1")], "state-1", []),
    request.EmailGet,
  )
}

pub fn thread_get_response_test() {
  assert_response(
    jmap_fixture.thread_get_response([#("t-1", ["e-1", "e-2"])], "state-1"),
    request.ThreadGet,
  )
}

pub fn expect_mismatch_is_unmatched_test() {
  let fixture =
    fixture_send.start([
      get(jmap_fixture.session("https://api.example.test/jmap/")),
      expect(
        request.EmailGet,
        jmap_fixture.email_get_response(
          [jmap_fixture.email("e-1")],
          "state-1",
          [],
        ),
      ),
    ])

  let assert Ok(client_) = open_session(fixture)
  let assert Error(error.Http("status_500")) =
    client.call(client_, [request.mailbox_get(account_id, request.call_id)])

  fixture_send.unmatched_count(fixture) |> should.equal(1)
}

pub fn recorded_calls_test() {
  let fixture =
    fixture_send.start([
      get(jmap_fixture.session("https://api.example.test/jmap/")),
      expect(
        request.EmailGet,
        jmap_fixture.email_get_response(
          [jmap_fixture.email("e-1")],
          "state-1",
          [],
        ),
      ),
      expect(
        request.EmailGet,
        jmap_fixture.email_get_response(
          [jmap_fixture.email("e-2")],
          "state-1",
          [],
        ),
      ),
    ])

  let assert Ok(client_) = open_session(fixture)
  let assert Ok(#(client_, _)) =
    client.call(client_, [
      request.email_get(account_id, ["e-1"], 1024, request.call_id),
    ])
  let assert Ok(#(_, _)) =
    client.call(client_, [
      request.email_get(account_id, ["e-2"], 1024, request.call_id),
    ])

  let calls = fixture_send.recorded_calls(fixture)
  calls
  |> list.map(fn(call) { call.name })
  |> should.equal([
    request.method_name(request.EmailGet),
    request.method_name(request.EmailGet),
  ])
  calls
  |> list.map(fixture_send.ids_of)
  |> should.equal([["e-1"], ["e-2"]])
}
