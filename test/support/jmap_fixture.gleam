//// JMAP documents the tests hand to a decoder or serve from a scripted
//// `local_jmap` (PHASE-10, EX-2).
////
//// `session_with` and `session` are generated rather than read: they have to
//// name the URL of the server a test just started, and vary the core limits.
//// `mailbox_get_response`, `email_query_response`, `email_get_response` and
//// `thread_get_response` build method-response documents from records, so a
//// test names only the fields it cares about; `opening_response` answers the
//// three calls of `request.opening`, and `responses` builds any document from
//// its `Entry` list. The rest are fixtures under
//// `test/fixtures/jmap/`, read through `screwtape/file`; a missing fixture
//// crashes the test that asked for it.
////
//// Builders return strings only: `local_jmap` serves them too, and nothing here
//// depends on `support/fixture_send`.

import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import screwtape/file
import screwtape/jmap/request

/// The account every generated document belongs to.
const account_id = "acct-1"

/// A session document naming `api_url`, with the limits a full run assumes.
pub fn session(api_url: String) -> String {
  session_with(api_url, 1000, False)
}

/// A session document naming `api_url`, with the given core limits and read-only
/// flag, in the shape `decode.session` accepts.
pub fn session_with(
  api_url: String,
  max_objects_in_get: Int,
  is_read_only: Bool,
) -> String {
  json.object([
    #("apiUrl", json.string(api_url)),
    #("username", json.string("operator@example.test")),
    #(
      "primaryAccounts",
      json.object([#(request.mail_capability, json.string(account_id))]),
    ),
    #(
      "accounts",
      json.object([
        #(
          account_id,
          json.object([
            #("name", json.string("operator@example.test")),
            #("isReadOnly", json.bool(is_read_only)),
            #("isPersonal", json.bool(True)),
          ]),
        ),
      ]),
    ),
    #(
      "capabilities",
      json.object([
        #(
          request.core_capability,
          json.object([
            #("maxSizeUpload", json.int(50_000_000)),
            #("maxObjectsInGet", json.int(max_objects_in_get)),
            #("maxCallsInRequest", json.int(32)),
          ]),
        ),
        #(request.mail_capability, json.object([])),
      ]),
    ),
  ])
  |> json.to_string
}

/// The UTF-8 text of `test/fixtures/jmap/<name>`.
pub fn text(name: String) -> String {
  let assert Ok(text) = file.read_text("test/fixtures/jmap/" <> name)
  text
}

/// A mailbox as `Mailbox/get` reports it.
pub type Mailbox {
  Mailbox(
    id: String,
    name: String,
    role: Option(String),
    parent_id: Option(String),
    sort_order: Int,
    total_emails: Int,
    unread_emails: Int,
  )
}

/// A top-level mailbox with no messages.
pub fn mailbox(id: String, name: String, role: Option(String)) -> Mailbox {
  Mailbox(
    id: id,
    name: name,
    role: role,
    parent_id: None,
    sort_order: 0,
    total_emails: 0,
    unread_emails: 0,
  )
}

/// A `Mailbox/get` response with `state` and an empty `notFound`.
pub fn mailbox_get_response(mailboxes: List(Mailbox), state: String) -> String {
  method_response(
    request.method_name(request.MailboxGet),
    mailbox_get_arguments(mailboxes, state),
  )
}

fn mailbox_get_arguments(mailboxes: List(Mailbox), state: String) -> json.Json {
  json.object([
    #("accountId", json.string(account_id)),
    #("state", json.string(state)),
    #("list", json.array(mailboxes, mailbox_json)),
    #("notFound", json.preprocessed_array([])),
  ])
}

/// An `Email/query` response page. `total` and `limit` are omitted when `None`.
pub fn email_query_response(
  ids: List(String),
  query_state: String,
  position: Int,
  total: Option(Int),
  limit: Option(Int),
  can_calculate_changes: Bool,
) -> String {
  let arguments = [
    #("accountId", json.string(account_id)),
    #("queryState", json.string(query_state)),
    #("canCalculateChanges", json.bool(can_calculate_changes)),
    #("position", json.int(position)),
    #("ids", json.array(ids, json.string)),
  ]
  let arguments = case total {
    None -> arguments
    Some(total) -> list.append(arguments, [#("total", json.int(total))])
  }
  let arguments = case limit {
    None -> arguments
    Some(limit) -> list.append(arguments, [#("limit", json.int(limit))])
  }
  method_response(
    request.method_name(request.EmailQuery),
    json.object(arguments),
  )
}

/// A text body part. `plain` and `html` supply the usual flags.
pub type Part {
  Part(
    part_id: String,
    type_: String,
    value: String,
    is_truncated: Bool,
    is_encoding_problem: Bool,
  )
}

/// A `text/plain` body part that is neither truncated nor mis-encoded.
pub fn plain(part_id: String, value: String) -> Part {
  Part(
    part_id: part_id,
    type_: "text/plain",
    value: value,
    is_truncated: False,
    is_encoding_problem: False,
  )
}

/// A `text/html` body part that is neither truncated nor mis-encoded.
pub fn html(part_id: String, value: String) -> Part {
  Part(
    part_id: part_id,
    type_: "text/html",
    value: value,
    is_truncated: False,
    is_encoding_problem: False,
  )
}

/// An attachment as `Email/get` reports it.
pub type Attachment {
  Attachment(
    part_id: String,
    blob_id: String,
    name: Option(String),
    type_: String,
    size: Int,
  )
}

/// An email with the properties the run fetches. `email` supplies defaults.
pub type Email {
  Email(
    id: String,
    thread_id: String,
    mailbox_ids: List(String),
    keywords: List(String),
    received_at: String,
    subject: Option(String),
    from: List(#(Option(String), String)),
    text_body: List(Part),
    attachments: List(Attachment),
  )
}

/// An email in `mb-1` with one plain part, default subject, sender and dates.
pub fn email(id: String) -> Email {
  Email(
    id: id,
    thread_id: "t-" <> id,
    mailbox_ids: ["mb-1"],
    keywords: [],
    received_at: "2026-10-25T21:04:11Z",
    subject: Some("Subject " <> id),
    from: [#(Some("Acme"), "billing@acme.test")],
    text_body: [plain("1", "Body of " <> id)],
    attachments: [],
  )
}

/// The RFC 8621 properties the run fetches, as an `Email/get` list entry.
pub fn email_json(email: Email) -> json.Json {
  json.object([
    #("id", json.string(email.id)),
    #("blobId", json.string("b-" <> email.id)),
    #("threadId", json.string(email.thread_id)),
    #("mailboxIds", flags(email.mailbox_ids)),
    #("keywords", flags(email.keywords)),
    #("size", json.int(1000)),
    #("receivedAt", json.string(email.received_at)),
    #(
      "messageId",
      json.array(["<" <> email.id <> "@example.test>"], json.string),
    ),
    #("inReplyTo", json.null()),
    #("references", json.null()),
    #("sender", json.null()),
    #("from", json.array(email.from, address_json)),
    #("to", json.preprocessed_array([])),
    #("cc", json.null()),
    #("bcc", json.null()),
    #("replyTo", json.null()),
    #("subject", json.nullable(email.subject, json.string)),
    #("sentAt", json.string("2026-10-25T21:04:00+01:00")),
    #("hasAttachment", json.bool(!list.is_empty(email.attachments))),
    #("preview", json.string("Preview " <> email.id)),
    #("textBody", json.array(email.text_body, part_json)),
    #("attachments", json.array(email.attachments, attachment_json)),
    #("bodyValues", body_values(email.text_body)),
  ])
}

/// An `Email/get` response with `state` and the ids in `not_found`.
pub fn email_get_response(
  emails: List(Email),
  state: String,
  not_found: List(String),
) -> String {
  method_response(
    request.method_name(request.EmailGet),
    email_get_arguments(emails, state, not_found),
  )
}

fn email_get_arguments(
  emails: List(Email),
  state: String,
  not_found: List(String),
) -> json.Json {
  get_arguments(json.array(emails, email_json), state, not_found)
}

/// The envelope every `Email/get` response shares: `accountId`, `state`, the
/// `list` of items and `notFound`.
fn get_arguments(
  list: json.Json,
  state: String,
  not_found: List(String),
) -> json.Json {
  json.object([
    #("accountId", json.string(account_id)),
    #("state", json.string(state)),
    #("list", list),
    #("notFound", json.array(not_found, json.string)),
  ])
}

/// A light `Email/get` response: the mutable fields of `lights` (id,
/// `mailboxIds`, `keywords`), plus `state` and the ids in `not_found`.
pub fn light_email_get_response(
  lights: List(#(String, List(String), List(String))),
  state: String,
  not_found: List(String),
) -> String {
  method_response(
    request.method_name(request.EmailGet),
    get_arguments(json.array(lights, light_email_json), state, not_found),
  )
}

fn light_email_json(light: #(String, List(String), List(String))) -> json.Json {
  let #(id, mailbox_ids, keywords) = light
  json.object([
    #("id", json.string(id)),
    #("mailboxIds", flags(mailbox_ids)),
    #("keywords", flags(keywords)),
  ])
}

/// An `Email/changes` response from `old_state` to `new_state`.
pub fn changes_response(
  old_state: String,
  new_state: String,
  has_more: Bool,
  created: List(String),
  updated: List(String),
  destroyed: List(String),
) -> String {
  method_response(
    request.method_name(request.EmailChanges),
    json.object([
      #("accountId", json.string(account_id)),
      #("oldState", json.string(old_state)),
      #("newState", json.string(new_state)),
      #("hasMoreChanges", json.bool(has_more)),
      #("created", json.array(created, json.string)),
      #("updated", json.array(updated, json.string)),
      #("destroyed", json.array(destroyed, json.string)),
    ]),
  )
}

/// A `Thread/get` response with `state` and an empty `notFound`.
pub fn thread_get_response(
  threads: List(#(String, List(String))),
  state: String,
) -> String {
  method_response(
    request.method_name(request.ThreadGet),
    thread_get_arguments(threads, state),
  )
}

fn thread_get_arguments(
  threads: List(#(String, List(String))),
  state: String,
) -> json.Json {
  json.object([
    #("accountId", json.string(account_id)),
    #("state", json.string(state)),
    #(
      "list",
      json.array(threads, fn(thread) {
        let #(id, email_ids) = thread
        json.object([
          #("id", json.string(id)),
          #("emailIds", json.array(email_ids, json.string)),
        ])
      }),
    ),
    #("notFound", json.preprocessed_array([])),
  ])
}

/// One entry of `methodResponses`: `[name, arguments, callId]`.
pub type Entry {
  Entry(name: String, arguments: json.Json, call_id: String)
}

/// Pairs each opening call with its argument set. Fails rather than
/// truncating when the request's call count and the argument count differ, so a
/// call can never be answered with another call's arguments.
pub fn opening_pairs(
  calls: List(#(String, String)),
  arguments: List(json.Json),
) -> Result(List(Entry), Nil) {
  list.strict_zip(calls, arguments)
  |> result.map(fn(pairs) {
    list.map(pairs, fn(pair) {
      let #(#(call_id, name), arguments) = pair
      Entry(name:, arguments:, call_id:)
    })
  })
}

/// The entries that answer `request.opening`, under its call ids: the
/// mailboxes and `mailbox_state`, then an empty `Email/get` and `Thread/get`
/// with `email_state` and `thread_state`.
pub fn opening_entries(
  mailboxes: List(Mailbox),
  mailbox_state: String,
  email_state: String,
  thread_state: String,
) -> List(Entry) {
  let arguments = [
    mailbox_get_arguments(mailboxes, mailbox_state),
    email_get_arguments([], email_state, []),
    thread_get_arguments([], thread_state),
  ]
  let assert Ok(entries) =
    opening_pairs(request.call_names(request.opening(account_id, 0)), arguments)
    as "opening calls and argument sets differ in length"
  entries
}

/// The response document `opening_entries` describes.
pub fn opening_response(
  mailboxes: List(Mailbox),
  mailbox_state: String,
  email_state: String,
  thread_state: String,
) -> String {
  responses(opening_entries(mailboxes, mailbox_state, email_state, thread_state))
}

/// A method error entry of `type_` answering `call_id`.
pub fn error_entry(type_: String, call_id: String) -> Entry {
  Entry("error", json.object([#("type", json.string(type_))]), call_id)
}

/// The method error an `Email/changes` call that cannot page its state answers:
/// a method-problem type, not a request-level URN.
pub fn cannot_calculate_changes_entry(call_id: String) -> Entry {
  error_entry("cannotCalculateChanges", call_id)
}

/// A response document of `entries`, in order.
pub fn responses(entries: List(Entry)) -> String {
  json.object([
    #(
      "methodResponses",
      json.array(entries, fn(entry) {
        json.preprocessed_array([
          json.string(entry.name),
          entry.arguments,
          json.string(entry.call_id),
        ])
      }),
    ),
  ])
  |> json.to_string
}

fn method_response(name: String, arguments: json.Json) -> String {
  responses([Entry(name, arguments, request.call_id)])
}

fn mailbox_json(mailbox: Mailbox) -> json.Json {
  json.object([
    #("id", json.string(mailbox.id)),
    #("name", json.string(mailbox.name)),
    #("role", json.nullable(mailbox.role, json.string)),
    #("parentId", json.nullable(mailbox.parent_id, json.string)),
    #("sortOrder", json.int(mailbox.sort_order)),
    #("totalEmails", json.int(mailbox.total_emails)),
    #("unreadEmails", json.int(mailbox.unread_emails)),
  ])
}

fn flags(keys: List(String)) -> json.Json {
  json.object(list.map(keys, fn(key) { #(key, json.bool(True)) }))
}

fn address_json(address: #(Option(String), String)) -> json.Json {
  let #(name, email) = address
  json.object([
    #("name", json.nullable(name, json.string)),
    #("email", json.string(email)),
  ])
}

fn part_json(part: Part) -> json.Json {
  json.object([
    #("partId", json.string(part.part_id)),
    #("blobId", json.string("pb-" <> part.part_id)),
    #("size", json.int(string.byte_size(part.value))),
    #("name", json.null()),
    #("type", json.string(part.type_)),
    #("disposition", json.null()),
    #("cid", json.null()),
  ])
}

fn attachment_json(attachment: Attachment) -> json.Json {
  json.object([
    #("partId", json.string(attachment.part_id)),
    #("blobId", json.string(attachment.blob_id)),
    #("size", json.int(attachment.size)),
    #("name", json.nullable(attachment.name, json.string)),
    #("type", json.string(attachment.type_)),
    #("disposition", json.string("attachment")),
    #("cid", json.null()),
  ])
}

fn body_values(parts: List(Part)) -> json.Json {
  json.object(
    list.map(parts, fn(part) {
      #(
        part.part_id,
        json.object([
          #("value", json.string(part.value)),
          #("isEncodingProblem", json.bool(part.is_encoding_problem)),
          #("isTruncated", json.bool(part.is_truncated)),
        ]),
      )
    }),
  )
}
