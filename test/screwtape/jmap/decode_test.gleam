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

import gleam/dynamic/decode as gleam_decode
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/error
import screwtape/jmap/decode
import screwtape/jmap/request
import screwtape/model
import screwtape/normalise
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

  decode.method_responses(text, [
    #(request.call_id, request.method_name(request.MailboxGet)),
  ])
  |> should.equal(
    Error(error.JmapMethod(
      request.method_name(request.MailboxGet),
      "serverUnavailable",
    )),
  )
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

/// Each mailbox carries every RFC 8621 field the model stores, in the fixture's
/// order: a decoder that defaulted `sortOrder`, `totalEmails` or `unreadEmails`
/// would silently lose the server's ordering and counts.
pub fn mailboxes_list_and_state_test() {
  let response = mailbox_response(jmap_fixture.text("mailbox_get.json"))
  let assert Ok(#(mailboxes, state)) = decode.mailboxes(response)

  state |> should.equal("state-1")
  mailboxes
  |> should.equal([
    model.Mailbox(
      id: "mb-1",
      name: "Inbox",
      parent_id: None,
      role: Some("inbox"),
      sort_order: 1,
      total_emails: 12,
      unread_emails: 3,
    ),
    model.Mailbox(
      id: "mb-2",
      name: "Archive",
      parent_id: None,
      role: None,
      sort_order: 2,
      total_emails: 0,
      unread_emails: 0,
    ),
    model.Mailbox(
      id: "mb-3",
      name: "Work",
      parent_id: Some("mb-2"),
      role: None,
      sort_order: 3,
      total_emails: 5,
      unread_emails: 1,
    ),
  ])
}

pub fn mailboxes_missing_field_test() {
  let response = mailbox_response(mailbox_without_id())

  decode.mailboxes(response)
  |> should.equal(Error(error.Decode("list[2].id")))
}

/// `sortOrder` has no RFC 8621 default we may invent: a mailbox without it is
/// a document we cannot order, so the path names the missing field.
pub fn mailboxes_missing_sort_order_test() {
  let text = bent("mailbox_get.json", "\"sortOrder\":1,", "")
  let response = mailbox_response(text)

  decode.mailboxes(response)
  |> should.equal(Error(error.Decode("list[0].sortOrder")))
}

pub fn mailboxes_mistyped_field_test() {
  let text = bent("mailbox_get.json", "\"state\":\"state-1\"", "\"state\":1")
  let response = mailbox_response(text)

  decode.mailboxes(response) |> should.equal(Error(error.Decode("state")))
}

/// One `Email/query` page: ids, state, position and the `total` the run asked
/// for, with no `limit` when the server did not clamp.
pub fn email_query_page_test() {
  let text =
    jmap_fixture.email_query_response(
      ["m1", "m2"],
      "qs-1",
      10,
      Some(42),
      None,
      True,
    )

  decode.email_query(response_of(text, request.EmailQuery))
  |> should.equal(
    Ok(decode.QueryPage(
      ids: ["m1", "m2"],
      query_state: "qs-1",
      can_calculate_changes: True,
      position: 10,
      total: 42,
      limit: None,
    )),
  )
}

/// A server that clamped the page reports its own `limit`; dropping it would
/// make the run ask for the unclamped size again.
pub fn email_query_page_carries_a_server_limit_test() {
  let text =
    jmap_fixture.email_query_response(
      ["m1"],
      "qs-2",
      0,
      Some(7),
      Some(3),
      False,
    )

  decode.email_query(response_of(text, request.EmailQuery))
  |> should.equal(
    Ok(decode.QueryPage(
      ids: ["m1"],
      query_state: "qs-2",
      can_calculate_changes: False,
      position: 0,
      total: 7,
      limit: Some(3),
    )),
  )
}

/// The run asks for `total` and pages until it, so a page without one is a
/// document that cannot end the run: the path names `total`.
pub fn email_query_page_without_total_test() {
  let text =
    jmap_fixture.email_query_response(["m1"], "qs-1", 0, None, None, True)

  decode.email_query(response_of(text, request.EmailQuery))
  |> should.equal(Error(error.Decode("total")))
}

/// One `Email/get` page normalises its email: the true keys of `mailboxIds`
/// become the mailbox list, the date is parsed, and `bodyValues` is keyed by
/// part id. A decoder that passed the raw flags map on would not answer
/// `mailbox_ids`.
pub fn emails_page_test() {
  let text =
    jmap_fixture.email_get_response([jmap_fixture.email("m1")], "state-e1", [
      "gone",
    ])
  let assert Ok(page) = decode.emails(response_of(text, request.EmailGet))

  page.state |> should.equal("state-e1")
  page.not_found |> should.equal(["gone"])
  let assert [email] = page.emails
  email.mailbox_ids |> should.equal(["mb-1"])
  email.keywords |> should.equal([])
  let assert Ok(received_at) = normalise.utc_date("2026-10-25T21:04:11Z")
  email.received_at |> should.equal(received_at)
  email.body_values
  |> list.any(fn(entry) { entry.0 == "1" })
  |> should.be_true
}

/// RFC 8621 § 4.1.1 / § 4.1.4: `mailboxIds` and `keywords` are sets, so only
/// `true` keys are members; a decoder that kept `false` keys would list
/// mailboxes and keywords the email does not have.
pub fn emails_exclude_false_flags_test() {
  let text =
    jmap_fixture.email_get_response([jmap_fixture.email("m1")], "state-e1", [])
  let text =
    string.replace(
      text,
      "\"mailboxIds\":{\"mb-1\":true}",
      "\"mailboxIds\":{\"mb-1\":true,\"mb-x\":false}",
    )
  let text =
    string.replace(
      text,
      "\"keywords\":{}",
      "\"keywords\":{\"$seen\":true,\"$flagged\":false}",
    )
  let assert Ok(page) = decode.emails(response_of(text, request.EmailGet))
  let assert [email] = page.emails

  email.mailbox_ids |> should.equal(["mb-1"])
  email.keywords |> should.equal(["$seen"])
}

/// `receivedAt` is a `UTCDate`, not free text: text that does not parse is a
/// decode failure naming the field, not a message with a bogus date.
pub fn emails_invalid_received_at_test() {
  let text =
    jmap_fixture.email_get_response([jmap_fixture.email("m1")], "state-e1", [])
  let text =
    string.replace(
      text,
      "\"receivedAt\":\"2026-10-25T21:04:11Z\"",
      "\"receivedAt\":\"not a date\"",
    )

  decode.emails(response_of(text, request.EmailGet))
  |> should.equal(Error(error.Decode("list[0].receivedAt")))
}

/// A thread page keeps its member ids in order; a decoder that reordered or
/// re-keyed them would break thread order.
pub fn threads_page_test() {
  let text = jmap_fixture.thread_get_response([#("t1", ["m1", "m2"])], "ts-1")

  decode.threads(response_of(text, request.ThreadGet))
  |> should.equal(Ok([model.Thread("t1", ["m1", "m2"])]))
}

/// A `Thread/get` that asked for no objects still answers the Thread state: the
/// opening call needs exactly this string. Catches a decoder that looked for the
/// state through `threads`, whose empty `list` would make it fail.
pub fn state_reads_the_thread_get_state_test() {
  let text = jmap_fixture.thread_get_response([], "ts-9")

  decode.state(response_of(text, request.ThreadGet))
  |> should.equal(Ok("ts-9"))
}

/// The same for an `Email/get` with no ids: its `state` is the Email state the
/// run starts from, reported on the arguments themselves rather than inside a
/// list entry. Catches a decoder that read `list[0].state`.
pub fn state_reads_the_email_get_state_test() {
  let text = jmap_fixture.email_get_response([], "es-9", [])

  decode.state(response_of(text, request.EmailGet))
  |> should.equal(Ok("es-9"))
}

/// RFC 8620 § 5.1 makes `state` mandatory in a `/get` response, so its absence
/// is a decode failure at the field, not `Ok("")`. Catches a decoder that
/// defaulted the state, which would let the next call ask for changes since a
/// state that was never served.
pub fn state_missing_is_a_decode_error_test() {
  let text =
    jmap_fixture.email_get_response([], "es-9", [])
    |> string.replace("\"state\":\"es-9\",", "")
  string.contains(text, "\"state\"") |> should.be_false

  decode.state(response_of(text, request.EmailGet))
  |> should.equal(Error(error.Decode("state")))
}

/// A non-string `state` is the same failure at the same path: server text that
/// is not a string must not be coerced into one, or the run would carry a
/// state no server issued.
pub fn state_non_string_is_a_decode_error_test() {
  let text =
    jmap_fixture.thread_get_response([], "ts-9")
    |> string.replace("\"state\":\"ts-9\"", "\"state\":7")

  decode.state(response_of(text, request.ThreadGet))
  |> should.equal(Error(error.Decode("state")))
}

/// I1: `mailboxIds` is keyed by server data, so the path must end at the map.
/// A decoder that appended the key would put document text in the path.
pub fn emails_mailbox_ids_key_ends_the_path_test() {
  let text = "\"mailboxIds\":{\"SENTINEL-KEY\":\"not a bool\"}"
  let text =
    string.replace(
      jmap_fixture.email_get_response(
        [jmap_fixture.email("m1")],
        "state-e1",
        [],
      ),
      "\"mailboxIds\":{\"mb-1\":true}",
      text,
    )

  decode.emails(response_of(text, request.EmailGet))
  |> should.equal(Error(error.Decode("list[0].mailboxIds")))
}

/// The same rule for a key that happens to be a fixed field name: `id` must
/// not extend the path past `mailboxIds`, so the error reads
/// `list[0].mailboxIds` and not `list[0].mailboxIds.id`.
pub fn emails_fixed_name_key_still_ends_the_path_test() {
  let text =
    jmap_fixture.email_get_response([jmap_fixture.email("m1")], "state-e1", [])
  let text =
    string.replace(
      text,
      "\"mailboxIds\":{\"mb-1\":true}",
      "\"mailboxIds\":{\"id\":\"not a bool\"}",
    )

  decode.emails(response_of(text, request.EmailGet))
  |> should.equal(Error(error.Decode("list[0].mailboxIds")))
}

/// A numeric-looking `bodyValues` key must not become a list index in the
/// path: `7` is a part id the server chose, so the path ends at the map.
pub fn emails_body_values_numeric_key_ends_the_path_test() {
  let text =
    jmap_fixture.email_get_response([jmap_fixture.email("m1")], "state-e1", [])
  let text =
    string.replace(
      text,
      "\"bodyValues\":{\"1\":",
      "\"bodyValues\":{\"7\":true,\"1\":",
    )

  decode.emails(response_of(text, request.EmailGet))
  |> should.equal(Error(error.Decode("list[0].bodyValues")))
}

/// F8: a response entry must name the method that was sent under its call id;
/// otherwise an `Email/get` reply could be read as `Mailbox/get` and the run
/// would decode the wrong arguments. The path names the entry's name slot.
pub fn method_response_name_must_match_the_call_test() {
  let text =
    jmap_fixture.mailbox_get_response(
      [jmap_fixture.mailbox("mb-1", "Inbox", Some("inbox"))],
      "state-1",
    )

  decode.method_responses(text, [
    #(request.call_id, request.method_name(request.EmailGet)),
  ])
  |> should.equal(Error(error.Decode("methodResponses[0][0]")))
}

fn mailbox_response(text: String) -> decode.MethodResponse {
  response_of(text, request.MailboxGet)
}

/// The one response of a document the test built for `method`.
fn response_of(text: String, method: request.Method) -> decode.MethodResponse {
  let assert Ok([response]) =
    decode.method_responses(text, [
      #(request.call_id, request.method_name(method)),
    ])
  response
}

fn json_pair(name: String, value: String) -> String {
  "\"" <> name <> "\":" <> value
}

// `normalise.utc_date` through `decode.document`: TEXT is not a date, the
// field path is the error, and a fractional UTCDate keeps its raw text with
// sub-millisecond digits dropped.

fn received_at_decoder() -> gleam_decode.Decoder(model.UtcDate) {
  use date <- gleam_decode.field("receivedAt", decode.utc_date())
  gleam_decode.success(date)
}

pub fn received_at_valid_fractional_utc_date_test() {
  let assert Ok(date) =
    decode.document(
      "{\"receivedAt\":\"2024-02-29T23:59:59.1234Z\"}",
      received_at_decoder(),
    )

  date.raw |> should.equal("2024-02-29T23:59:59.1234Z")
  date.ms |> should.equal(1_709_251_199_123)
}

pub fn received_at_invalid_utc_date_is_a_decode_error_test() {
  decode.document("{\"receivedAt\":\"not a date\"}", received_at_decoder())
  |> should.equal(Error(error.Decode("receivedAt")))
}

/// Review F4: a digits-only server key in `primaryAccounts` must not become a
/// list index in the path (`primaryAccounts[98765]`): the path names the map.
pub fn session_numeric_primary_account_key_ends_the_path_test() {
  let text =
    bent(
      "session.json",
      "\"urn:ietf:params:jmap:mail\":\"acct-1\"",
      "\"98765432101234\":5",
    )

  decode.session(text) |> should.equal(Error(error.Decode("primaryAccounts")))
}

/// Review F6: RFC 8621 § 4.1.4 defaults `isEncodingProblem` and `isTruncated`
/// to false; a server that omits them is answering correctly. Catches a
/// decoder that requires them.
pub fn emails_body_value_flags_default_to_false_test() {
  let text =
    jmap_fixture.email_get_response([jmap_fixture.email("m1")], "state-e1", [])
    |> string.replace(",\"isEncodingProblem\":false", "")
    |> string.replace(",\"isTruncated\":false", "")
  string.contains(text, "isTruncated") |> should.be_false
  let assert Ok(page) = decode.emails(response_of(text, request.EmailGet))
  let assert [email] = page.emails
  let assert [#("1", value)] = email.body_values
  value.is_truncated |> should.be_false
  value.is_encoding_problem |> should.be_false
}
