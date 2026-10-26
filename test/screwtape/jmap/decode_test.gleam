//// Contract tests for `screwtape/jmap/decode` (PHASE-10, D6; VT-6).
////
//// The fixtures are synthetic JMAP documents under `test/fixtures/jmap/`, read
//// through the same `file:read_file/1` external the unit uses (A4). A fixture
//// is bent one field at a time so each failing case differs from a passing
//// decode in exactly the check it exercises.
////
//// `Decode(path)` paths name a fixed location and never quote the input: the
//// assertions here are on the exact path strings.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/error
import screwtape/jmap/decode

pub fn main() -> Nil {
  gleeunit.main()
}

const mail_urn = "urn:ietf:params:jmap:mail"

const not_request = "urn:ietf:params:jmap:error:notRequest"

fn fixture(name: String) -> String {
  let assert Ok(bytes) = read_file("test/fixtures/jmap/" <> name)
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

fn bent(name: String, from: String, into: String) -> String {
  string.replace(fixture(name), from, into)
}

/// The fixture with one mailbox's `id` removed, so `list[2].id` is the first
/// error in the list.
fn mailbox_without_id() -> String {
  bent("mailbox_get.json", "\"id\":\"mb-3\",", "")
}

pub fn session_full_test() {
  let assert Ok(session) = decode.session(fixture("session.json"))
  session.api_url |> should.equal("https://api.example.test/jmap/")
  session.account_id |> should.equal("acct-1")
  session.is_read_only |> should.be_false
  session.max_objects_in_get |> should.equal(1000)
  session.max_calls_in_request |> should.equal(32)
}

pub fn session_read_only_test() {
  let text = bent("session.json", "\"isReadOnly\":false", "\"isReadOnly\":true")

  let assert Ok(session) = decode.session(text)
  session.is_read_only |> should.be_true
}

pub fn session_without_mail_test() {
  decode.session(fixture("session_no_mail.json"))
  |> should.equal(Error(error.JmapRequest("no_mail_capability")))
}

pub fn session_capabilities_without_mail_test() {
  let text = bent("session.json", "," <> json_pair(mail_urn, "{}"), "")

  let assert Error(error.JmapRequest("no_mail_capability")) =
    decode.session(text)
}

pub fn session_non_https_api_url_test() {
  decode.session(fixture("session_http_api.json"))
  |> should.equal(Error(error.JmapRequest("api_url_not_https")))
}

pub fn session_missing_field_test() {
  let text =
    bent("session.json", "\"apiUrl\":\"https://api.example.test/jmap/\",", "")

  decode.session(text) |> should.equal(Error(error.Decode("apiUrl")))
}

pub fn session_malformed_json_test() {
  decode.session("{\"apiUrl\":") |> should.equal(Error(error.Decode("$")))
}

pub fn problem_document_test() {
  decode.problem(fixture("problem_not_request.json"))
  |> should.equal(Ok(not_request))
}

pub fn problem_without_type_test() {
  decode.problem("{\"status\":400}") |> should.equal(Error(Nil))
  decode.problem("not json") |> should.equal(Error(Nil))
}

pub fn method_error_carries_the_request_method_test() {
  let result =
    decode.method_responses(fixture("method_error.json"), [
      #("c0", "Mailbox/get"),
    ])

  result
  |> should.equal(Error(error.JmapMethod("Mailbox/get", not_request)))
}

pub fn method_error_with_unknown_call_test() {
  let result = decode.method_responses(fixture("method_error.json"), [])

  result
  |> should.equal(Error(error.Decode("methodResponses[0][2]")))
}

pub fn method_responses_carry_calls_test() {
  let assert Ok([response]) =
    decode.method_responses(fixture("mailbox_get.json"), [
      #("c0", "Mailbox/get"),
    ])

  response.name |> should.equal("Mailbox/get")
  response.call_id |> should.equal("c0")
}

pub fn method_responses_missing_field_test() {
  decode.method_responses("{\"methodResponses\":[]}", [])
  |> should.equal(Ok([]))
  decode.method_responses("{}", [])
  |> should.equal(Error(error.Decode("methodResponses")))
  decode.method_responses("{\"methodResponses\":[42]}", [])
  |> should.equal(Error(error.Decode("methodResponses[0]")))
}

pub fn mailboxes_list_and_state_test() {
  let assert Ok([response]) =
    decode.method_responses(fixture("mailbox_get.json"), [
      #("c0", "Mailbox/get"),
    ])
  let assert Ok(#(mailboxes, state)) = decode.mailboxes(response)

  state |> should.equal("state-1")
  mailboxes
  |> should.equal([
    decode.MailboxSummary(id: "mb-1", name: "Inbox", role: Some("inbox")),
    decode.MailboxSummary(id: "mb-2", name: "Archive", role: None),
    decode.MailboxSummary(id: "mb-3", name: "Work", role: None),
  ])
}

pub fn mailboxes_missing_field_test() {
  let assert Ok([response]) =
    decode.method_responses(mailbox_without_id(), [#("c0", "Mailbox/get")])

  decode.mailboxes(response)
  |> should.equal(Error(error.Decode("list[2].id")))
}

pub fn mailboxes_mistyped_field_test() {
  let text = bent("mailbox_get.json", "\"state\":\"state-1\"", "\"state\":1")
  let assert Ok([response]) =
    decode.method_responses(text, [#("c0", "Mailbox/get")])

  decode.mailboxes(response) |> should.equal(Error(error.Decode("state")))
}

fn json_pair(name: String, value: String) -> String {
  "\"" <> name <> "\":" <> value
}

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)
