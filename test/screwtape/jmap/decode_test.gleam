//// Contract tests for `screwtape/jmap/decode` (PHASE-10, D6; VT-6).
////
//// The fixtures are synthetic JMAP documents under `test/fixtures/jmap/`, read
//// through `support/jmap_fixture` and so through the same `file:read_file/1`
//// external the unit uses (A4). A fixture
//// is bent one field at a time so each failing case differs from a passing
//// decode in exactly the check it exercises.
////
//// `Decode(path)` paths name a fixed location and never quote the input: the
//// assertions here are on the exact path strings.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/error
import screwtape/jmap/decode
import support/jmap_fixture

pub fn main() -> Nil {
  gleeunit.main()
}

const mail_urn = "urn:ietf:params:jmap:mail"

const not_request = "urn:ietf:params:jmap:error:notRequest"

fn bent(name: String, from: String, into: String) -> String {
  string.replace(jmap_fixture.text(name), from, into)
}

/// The fixture with one mailbox's `id` removed, so `list[2].id` is the first
/// error in the list.
fn mailbox_without_id() -> String {
  bent("mailbox_get.json", "\"id\":\"mb-3\",", "")
}

pub fn session_full_test() {
  let assert Ok(session) = decode.session(jmap_fixture.text("session.json"))
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
  decode.session(jmap_fixture.text("session_no_mail.json"))
  |> should.equal(Error(error.JmapRequest("no_mail_capability")))
}

pub fn session_capabilities_without_mail_test() {
  let text = bent("session.json", "," <> json_pair(mail_urn, "{}"), "")

  let assert Error(error.JmapRequest("no_mail_capability")) =
    decode.session(text)
}

pub fn session_non_https_api_url_test() {
  decode.session(jmap_fixture.text("session_http_api.json"))
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

/// A map keyed by server data is not a path segment: the path names the map.
pub fn session_path_names_the_map_not_a_server_key_test() {
  let text =
    bent(
      "session.json",
      "\"urn:ietf:params:jmap:mail\":\"acct-1\"",
      "\"SENTINEL-KEY\":5",
    )

  decode.session(text) |> should.equal(Error(error.Decode("primaryAccounts")))
}

/// The core limits constrain what a request may ask for, so a non-positive
/// value is a document we cannot use.
pub fn session_nonpositive_core_limits_test() {
  [
    #("maxObjectsInGet", "\"maxObjectsInGet\":1000", "0"),
    #("maxObjectsInGet", "\"maxObjectsInGet\":1000", "-1"),
    #("maxCallsInRequest", "\"maxCallsInRequest\":32", "0"),
    #("maxCallsInRequest", "\"maxCallsInRequest\":32", "-5"),
  ]
  |> list.each(fn(c) {
    let replacement = "\"" <> c.0 <> "\":" <> c.2
    decode.session(bent("session.json", c.1, replacement))
    |> should.equal(Error(error.Decode("capabilities." <> c.0)))
  })
}

pub fn problem_document_test() {
  decode.problem(jmap_fixture.text("problem_not_request.json"))
  |> should.equal(Ok(not_request))
}

pub fn problem_without_type_test() {
  decode.problem("{\"status\":400}") |> should.equal(Error(Nil))
  decode.problem("not json") |> should.equal(Error(Nil))
}

/// Only the four request-level types of RFC 8620 § 3.6.1 are carried; a
/// server's own `type` string never becomes an `Error`.
pub fn problem_carries_each_request_level_type_test() {
  [
    "urn:ietf:params:jmap:error:unknownCapability",
    "urn:ietf:params:jmap:error:notJSON",
    not_request,
    "urn:ietf:params:jmap:error:limit",
  ]
  |> list.each(fn(type_) {
    decode.problem("{\"type\":\"" <> type_ <> "\"}")
    |> should.equal(Ok(type_))
  })
}

pub fn problem_rejects_a_type_outside_the_rfc_set_test() {
  decode.problem("{\"type\":\"SENTINEL-TYPE\"}")
  |> should.equal(Error(Nil))
}

/// A method-level `type` in the RFC 8620 § 3.6.2 / § 5 set is the server's
/// value.
pub fn method_error_keeps_a_known_type_test() {
  let text =
    "{\"methodResponses\":[[\"error\",{\"type\":\"serverUnavailable\"},\"c0\"]]}"

  decode.method_responses(text, [#("c0", "Mailbox/get")])
  |> should.equal(Error(error.JmapMethod("Mailbox/get", "serverUnavailable")))
}

/// A method-level `type` outside that set is the fixed `"unknown"`, never the
/// server's text.
pub fn method_error_maps_an_unknown_type_test() {
  let text =
    "{\"methodResponses\":[[\"error\",{\"type\":\"SENTINEL-TYPE\"},\"c0\"]]}"

  decode.method_responses(text, [#("c0", "Mailbox/get")])
  |> should.equal(Error(error.JmapMethod("Mailbox/get", "unknown")))
}

pub fn method_error_carries_the_request_method_test() {
  let result =
    decode.method_responses(jmap_fixture.text("method_error.json"), [
      #("c0", "Mailbox/get"),
    ])

  // The fixture's `type` is a request-level URN, not a method-level one, so the
  // fixed `"unknown"` stands in for it.
  result
  |> should.equal(Error(error.JmapMethod("Mailbox/get", "unknown")))
}

pub fn method_error_with_unknown_call_test() {
  let result =
    decode.method_responses(jmap_fixture.text("method_error.json"), [])

  result
  |> should.equal(Error(error.Decode("methodResponses[0][2]")))
}

pub fn method_responses_carry_calls_test() {
  let assert Ok([response]) =
    decode.method_responses(jmap_fixture.text("mailbox_get.json"), [
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
    decode.method_responses(jmap_fixture.text("mailbox_get.json"), [
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
