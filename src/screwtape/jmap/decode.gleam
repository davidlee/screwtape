//// Decoding the JMAP session, method responses and problem documents
//// (PHASE-10, D6; design § 5.2).
////
//// A failure is either `JmapRequest` — a session without the mail capability,
//// an `apiUrl` that is not `https`, or an RFC 8620 § 3.6.1 problem document —
//// or `JmapMethod(method, type)` for a method-level error, or `Decode(path)`.
//// `path` names a location built only from fixed field names and list indices:
//// never a document key, never a field value, never any of the input text.
//// Where a location passes through a map keyed by server data (`accounts`,
//// `capabilities`), the path names the map only.
////
//// `path` and its `render` are the one choke point for that rule: a segment
//// that is neither a list index nor one of the fixed field names this module
//// decodes ends the path there, so a server-chosen key can never be appended.
//// Later decoders extend the fixed set with the fields they decode; until they
//// do, a path deeper than this module's own field names stops at the last one
//// it knows.
////
//// Paths are relative to the value the decoder was handed: `session` and
//// `method_responses` start at the document root (`"apiUrl"`), while
//// `mailboxes` starts at the response's arguments, so a missing id in the third
//// mailbox is `"list[2].id"` there. `method_responses` names an entry's
//// position (`"methodResponses[0]"`, `"methodResponses[0][2]"`) because it
//// does not decode an entry's arguments; `mailboxes` decodes those.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import screwtape/error.{type Error, Decode, JmapMethod, JmapRequest}
import screwtape/jmap/request.{core_capability, mail_capability}
import screwtape/model.{type UtcDate}
import screwtape/normalise

/// The location of a whole document, for JSON that does not parse at all.
const root = "$"

/// The method name that marks an error entry in `methodResponses`.
const error_method = "error"

/// The request-level problem types of RFC 8620 § 3.6.1: the only `type` values
/// a problem document may contribute to an `Error`.
const request_problem_types = [
  "urn:ietf:params:jmap:error:unknownCapability",
  "urn:ietf:params:jmap:error:notJSON",
  "urn:ietf:params:jmap:error:notRequest",
  "urn:ietf:params:jmap:error:limit",
]

/// The method-level problem types of RFC 8620 § 3.6.2 and § 5: the only `type`
/// values a method error may contribute to an `Error`.
const method_problem_types = [
  "serverUnavailable",
  "serverFail",
  "serverPartialFail",
  "unknownMethod",
  "invalidArguments",
  "invalidResultReference",
  "forbidden",
  "accountNotFound",
  "accountNotSupportedByMethod",
  "accountReadOnly",
  "requestTooLarge",
  "cannotCalculateChanges",
  "stateMismatch",
  "anchorNotFound",
  "unsupportedSort",
  "unsupportedFilter",
  "tooManyChanges",
]

/// The field names this module's decoders can place in a path. A segment that
/// is neither one of them nor a list index comes from the document — a map key
/// the server chose — and ends the path. A decoder added later extends this set
/// with the fields it decodes.
const path_fields = [
  "apiUrl",
  "primaryAccounts",
  "capabilities",
  "accounts",
  "maxObjectsInGet",
  "maxCallsInRequest",
  "isReadOnly",
  "methodResponses",
  "state",
  "list",
  "id",
  "name",
  "role",
  "type",
  "receivedAt",
  "parentId",
  "sortOrder",
  "totalEmails",
  "unreadEmails",
  "ids",
  "queryState",
  "canCalculateChanges",
  "position",
  "total",
  "limit",
  "notFound",
  "blobId",
  "threadId",
  "mailboxIds",
  "keywords",
  "size",
  "messageId",
  "inReplyTo",
  "references",
  "sender",
  "from",
  "to",
  "cc",
  "bcc",
  "replyTo",
  "subject",
  "sentAt",
  "hasAttachment",
  "preview",
  "textBody",
  "attachments",
  "bodyValues",
  "partId",
  "disposition",
  "cid",
  "value",
  "isEncodingProblem",
  "isTruncated",
  "email",
  "emailIds",
]

/// The field names whose value is a map keyed by server data (the session's
/// `primaryAccounts`, `capabilities` and `accounts`; an email's `mailboxIds`,
/// `keywords` and `bodyValues`). A path that enters one of them ends there: the
/// keys are document text and may never be appended, not even when a key
/// happens to read as a list index or as one of `path_fields` (I1).
const server_keyed_fields = [
  "primaryAccounts",
  "capabilities",
  "accounts",
  "mailboxIds",
  "keywords",
  "bodyValues",
]

/// The parts of the JMAP session the scope uses.
pub type Session {
  Session(
    api_url: String,
    account_id: String,
    is_read_only: Bool,
    max_objects_in_get: Int,
    max_calls_in_request: Int,
  )
}

/// One entry of `methodResponses`: `[name, arguments, callId]`. `arguments`
/// stays dynamic; `mailboxes` decodes the response it expects.
pub type MethodResponse {
  MethodResponse(name: String, arguments: Dynamic, call_id: String)
}

/// One `Email/query` page (RFC 8620 § 5.5). `limit` is present only when the
/// server enforced a limit other than the one asked for (a clamp, F9); `total`
/// is required, because the run asks for it (`calculateTotal`).
pub type QueryPage {
  QueryPage(
    ids: List(String),
    query_state: String,
    can_calculate_changes: Bool,
    position: Int,
    total: Int,
    limit: Option(Int),
  )
}

/// One `Email/get` response: the emails, the Email `state` it was served
/// under, and the ids the server no longer has.
pub type EmailPage {
  EmailPage(
    emails: List(normalise.Email),
    state: String,
    not_found: List(String),
  )
}

/// The page of an `Email/query` response.
pub fn email_query(response: MethodResponse) -> Result(QueryPage, Error) {
  decode_at(response.arguments, query_page_decoder(), "")
}

/// The emails, state and `notFound` of an `Email/get` response.
pub fn emails(response: MethodResponse) -> Result(EmailPage, Error) {
  decode_at(response.arguments, email_page_decoder(), "")
}

/// The threads of a `Thread/get` response; `notFound` is ignored (PHASE-05
/// A8), and the run takes the Thread state from the opening request (`state`).
pub fn threads(response: MethodResponse) -> Result(List(model.Thread), Error) {
  decode_at(response.arguments, thread_page_decoder(), "")
}

/// The `state` of a `/get` response, for a get that asked for no objects.
pub fn state(response: MethodResponse) -> Result(String, Error) {
  decode_at(
    response.arguments,
    decode.field("state", decode.string, decode.success),
    "",
  )
}

/// A JMAP `UTCDate` field. Text that does not parse fails here, so it surfaces
/// as `Decode(path)` naming the field (DEC-021).
pub fn utc_date() -> decode.Decoder(UtcDate) {
  use raw <- decode.then(decode.string)
  case normalise.utc_date(raw) {
    Ok(date) -> decode.success(date)
    Error(Nil) -> decode.failure(model.UtcDate(raw: "", ms: 0), "UTCDate")
  }
}

/// Decode a JMAP session document.
pub fn session(text: String) -> Result(Session, Error) {
  use raw <- result.try(document(text, raw_session_decoder()))
  use _ <- result.try(check_https(raw.api_url))
  use account_id <- result.try(mail_account(raw))
  use limits <- result.try(core_limits(raw.capabilities))
  use is_read_only <- result.try(read_only(raw.accounts, account_id))
  Ok(Session(
    api_url: raw.api_url,
    account_id: account_id,
    is_read_only: is_read_only,
    max_objects_in_get: limits.0,
    max_calls_in_request: limits.1,
  ))
}

/// An RFC 8620 § 3.6.1 problem document's `type`, or `Error(Nil)` for anything
/// else: a document that does not parse, one with no `type`, or a `type`
/// outside that fixed set. A server's own text never becomes an `Error` (I1).
pub fn problem(text: String) -> Result(String, Nil) {
  use dynamic <- result.try(
    json.parse(text, using: decode.dynamic) |> result.replace_error(Nil),
  )
  use type_ <- result.try(
    decode.run(dynamic, decode.at(["type"], decode.string))
    |> result.replace_error(Nil),
  )
  case list.contains(request_problem_types, type_) {
    True -> Ok(type_)
    False -> Error(Nil)
  }
}

/// Decode `methodResponses`. `calls` maps each request call id to the method
/// name that was sent for it, so a `["error", {type}, id]` entry becomes
/// `JmapMethod(method, type)` for the call it answers. An error entry whose id
/// is not in `calls` cannot be attributed, and is `Decode` at the id's path.
pub fn method_responses(
  text: String,
  calls: List(#(String, String)),
) -> Result(List(MethodResponse), Error) {
  use entries <- result.try(document(
    text,
    decode.at(["methodResponses"], decode.list(decode.dynamic)),
  ))
  entries
  |> list.index_map(fn(entry, index) { response(entry, index, calls) })
  |> result.all
}

/// The mailbox list and the `state` of a `Mailbox/get` response. The response
/// is the one the caller asked for (`Mailbox/get`); its `name` is not rechecked.
pub fn mailboxes(
  response: MethodResponse,
) -> Result(#(List(model.Mailbox), String), Error) {
  decode_at(response.arguments, mailbox_page_decoder(), "")
}

// Method arguments: the shape of each method's response, relative to its
// `arguments`, so a failure's path starts at the field the method answered.

fn mailbox_page_decoder() -> decode.Decoder(#(List(model.Mailbox), String)) {
  use state <- decode.field("state", decode.string)
  use list <- decode.field("list", decode.list(mailbox_decoder()))
  decode.success(#(list, state))
}

fn mailbox_decoder() -> decode.Decoder(model.Mailbox) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use parent_id <- decode.optional_field(
    "parentId",
    None,
    decode.optional(decode.string),
  )
  use role <- decode.optional_field(
    "role",
    None,
    decode.optional(decode.string),
  )
  use sort_order <- decode.field("sortOrder", decode.int)
  use total_emails <- decode.field("totalEmails", decode.int)
  use unread_emails <- decode.field("unreadEmails", decode.int)
  decode.success(model.Mailbox(
    id:,
    name:,
    parent_id:,
    role:,
    sort_order:,
    total_emails:,
    unread_emails:,
  ))
}

fn query_page_decoder() -> decode.Decoder(QueryPage) {
  use ids <- decode.field("ids", decode.list(decode.string))
  use query_state <- decode.field("queryState", decode.string)
  use can_calculate_changes <- decode.field("canCalculateChanges", decode.bool)
  use position <- decode.field("position", decode.int)
  use total <- decode.field("total", decode.int)
  use limit <- decode.optional_field("limit", None, decode.optional(decode.int))
  decode.success(QueryPage(
    ids:,
    query_state:,
    can_calculate_changes:,
    position:,
    total:,
    limit:,
  ))
}

fn email_page_decoder() -> decode.Decoder(EmailPage) {
  use emails <- decode.field("list", decode.list(email_decoder()))
  use state <- decode.field("state", decode.string)
  use not_found <- decode.optional_field(
    "notFound",
    [],
    decode.map(decode.optional(decode.list(decode.string)), or_empty),
  )
  decode.success(EmailPage(emails:, state:, not_found:))
}

fn email_decoder() -> decode.Decoder(normalise.Email) {
  use id <- decode.field("id", decode.string)
  use blob_id <- decode.field("blobId", decode.string)
  use thread_id <- decode.field("threadId", decode.string)
  use mailbox_ids <- decode.field("mailboxIds", flags_decoder())
  use keywords <- decode.field("keywords", flags_decoder())
  use size <- decode.field("size", decode.int)
  use received_at <- decode.field("receivedAt", utc_date())
  use message_id <- decode.optional_field(
    "messageId",
    None,
    decode.optional(decode.list(decode.string)),
  )
  use in_reply_to <- decode.optional_field(
    "inReplyTo",
    None,
    decode.optional(decode.list(decode.string)),
  )
  use references <- decode.optional_field(
    "references",
    None,
    decode.optional(decode.list(decode.string)),
  )
  use sender <- decode.optional_field(
    "sender",
    None,
    decode.optional(decode.list(email_address_decoder())),
  )
  use from <- decode.optional_field(
    "from",
    None,
    decode.optional(decode.list(email_address_decoder())),
  )
  use to <- decode.optional_field(
    "to",
    None,
    decode.optional(decode.list(email_address_decoder())),
  )
  use cc <- decode.optional_field(
    "cc",
    None,
    decode.optional(decode.list(email_address_decoder())),
  )
  use bcc <- decode.optional_field(
    "bcc",
    None,
    decode.optional(decode.list(email_address_decoder())),
  )
  use reply_to <- decode.optional_field(
    "replyTo",
    None,
    decode.optional(decode.list(email_address_decoder())),
  )
  use subject <- decode.optional_field(
    "subject",
    None,
    decode.optional(decode.string),
  )
  use sent_at <- decode.optional_field(
    "sentAt",
    None,
    decode.optional(decode.string),
  )
  use has_attachment <- decode.field("hasAttachment", decode.bool)
  use preview <- decode.field("preview", decode.string)
  use text_body <- decode.optional_field(
    "textBody",
    [],
    decode.map(decode.optional(decode.list(body_part_decoder())), or_empty),
  )
  use attachments <- decode.optional_field(
    "attachments",
    [],
    decode.map(decode.optional(decode.list(body_part_decoder())), or_empty),
  )
  use body_values <- decode.optional_field(
    "bodyValues",
    [],
    decode.map(
      decode.optional(decode.dict(decode.string, body_value_decoder())),
      dict_or_empty,
    ),
  )
  decode.success(normalise.Email(
    id:,
    blob_id:,
    thread_id:,
    mailbox_ids:,
    keywords:,
    size:,
    received_at:,
    message_id:,
    in_reply_to:,
    references:,
    sender:,
    from:,
    to:,
    cc:,
    bcc:,
    reply_to:,
    subject:,
    sent_at:,
    has_attachment:,
    preview:,
    text_body:,
    attachments:,
    body_values:,
  ))
}

fn email_address_decoder() -> decode.Decoder(normalise.EmailAddress) {
  use name <- decode.optional_field(
    "name",
    None,
    decode.optional(decode.string),
  )
  use email <- decode.field("email", decode.string)
  decode.success(normalise.EmailAddress(name:, email:))
}

fn body_part_decoder() -> decode.Decoder(normalise.BodyPart) {
  use part_id <- decode.optional_field(
    "partId",
    None,
    decode.optional(decode.string),
  )
  use blob_id <- decode.optional_field(
    "blobId",
    None,
    decode.optional(decode.string),
  )
  use size <- decode.field("size", decode.int)
  use name <- decode.optional_field(
    "name",
    None,
    decode.optional(decode.string),
  )
  use type_ <- decode.field("type", decode.string)
  use disposition <- decode.optional_field(
    "disposition",
    None,
    decode.optional(decode.string),
  )
  use cid <- decode.optional_field("cid", None, decode.optional(decode.string))
  decode.success(normalise.BodyPart(
    part_id:,
    blob_id:,
    size:,
    name:,
    type_:,
    disposition:,
    cid:,
  ))
}

/// RFC 8621 § 4.1.4: both flags default to false.
fn body_value_decoder() -> decode.Decoder(normalise.BodyValue) {
  use value <- decode.field("value", decode.string)
  use is_encoding_problem <- decode.optional_field(
    "isEncodingProblem",
    False,
    decode.bool,
  )
  use is_truncated <- decode.optional_field("isTruncated", False, decode.bool)
  decode.success(normalise.BodyValue(
    value:,
    is_encoding_problem:,
    is_truncated:,
  ))
}

fn thread_page_decoder() -> decode.Decoder(List(model.Thread)) {
  decode.field("list", decode.list(thread_decoder()), decode.success)
}

fn thread_decoder() -> decode.Decoder(model.Thread) {
  use id <- decode.field("id", decode.string)
  use email_ids <- decode.field("emailIds", decode.list(decode.string))
  decode.success(model.Thread(id:, email_ids:))
}

/// An RFC 8621 set: the keys whose value is `true`, in the dictionary's order.
/// The keys of a JMAP flag object (`mailboxIds`, `keywords`) whose value is
/// `true`, sorted, so a stored list never depends on map order (I3).
fn flags_decoder() -> decode.Decoder(List(String)) {
  decode.map(decode.dict(decode.string, decode.bool), fn(flags) {
    flags
    |> dict.to_list
    |> list.filter(fn(entry) { entry.1 })
    |> list.map(fn(entry) { entry.0 })
    |> list.sort(string.compare)
  })
}

fn or_empty(values: Option(List(a))) -> List(a) {
  case values {
    Some(values) -> values
    None -> []
  }
}

fn dict_or_empty(values: Option(Dict(k, v))) -> List(#(k, v)) {
  case values {
    Some(values) -> dict.to_list(values)
    None -> []
  }
}

// The session, in stages: decode the shape, then apply the rules, so a
// capability that is absent is `JmapRequest` and not `Decode`.

type RawSession {
  RawSession(
    api_url: String,
    primary_accounts: Dict(String, String),
    capabilities: Dict(String, Dynamic),
    accounts: Dict(String, Dynamic),
  )
}

fn raw_session_decoder() -> decode.Decoder(RawSession) {
  use api_url <- decode.field("apiUrl", decode.string)
  use primary_accounts <- decode.field(
    "primaryAccounts",
    decode.dict(decode.string, decode.string),
  )
  use capabilities <- decode.field(
    "capabilities",
    decode.dict(decode.string, decode.dynamic),
  )
  use accounts <- decode.field(
    "accounts",
    decode.dict(decode.string, decode.dynamic),
  )
  decode.success(RawSession(
    api_url:,
    primary_accounts:,
    capabilities:,
    accounts:,
  ))
}

fn check_https(api_url: String) -> Result(Nil, Error) {
  case string.starts_with(api_url, "https://") {
    True -> Ok(Nil)
    False -> Error(JmapRequest("api_url_not_https"))
  }
}

/// The mail account, which needs both the primary account mapping and the
/// capability it is mapped under.
fn mail_account(raw: RawSession) -> Result(String, Error) {
  case dict.get(raw.primary_accounts, mail_capability) {
    Error(Nil) -> Error(JmapRequest("no_mail_capability"))
    Ok(account_id) ->
      case dict.has_key(raw.capabilities, mail_capability) {
        True -> Ok(account_id)
        False -> Error(JmapRequest("no_mail_capability"))
      }
  }
}

fn core_limits(
  capabilities: Dict(String, Dynamic),
) -> Result(#(Int, Int), Error) {
  use #(max_objects_in_get, max_calls_in_request) <- result.try(
    case dict.get(capabilities, core_capability) {
      Error(Nil) -> Error(Decode("capabilities"))
      Ok(core) -> decode_at(core, core_decoder(), "capabilities")
    },
  )
  // Both limits bound what a request may ask for, so a non-positive value
  // would make every request invalid.
  case max_objects_in_get > 0 {
    False -> Error(Decode("capabilities.maxObjectsInGet"))
    True ->
      case max_calls_in_request > 0 {
        False -> Error(Decode("capabilities.maxCallsInRequest"))
        True -> Ok(#(max_objects_in_get, max_calls_in_request))
      }
  }
}

fn core_decoder() -> decode.Decoder(#(Int, Int)) {
  use max_objects_in_get <- decode.field("maxObjectsInGet", decode.int)
  use max_calls_in_request <- decode.field("maxCallsInRequest", decode.int)
  decode.success(#(max_objects_in_get, max_calls_in_request))
}

fn read_only(
  accounts: Dict(String, Dynamic),
  account_id: String,
) -> Result(Bool, Error) {
  case dict.get(accounts, account_id) {
    Error(Nil) -> Error(Decode("accounts"))
    Ok(account) ->
      decode_at(account, decode.at(["isReadOnly"], decode.bool), "accounts")
  }
}

// One `methodResponses` entry, at its index.

fn response(
  value: Dynamic,
  index: Int,
  calls: List(#(String, String)),
) -> Result(MethodResponse, Error) {
  let prefix = "methodResponses[" <> int.to_string(index) <> "]"
  use #(name, arguments, call_id) <- result.try(decode_at(
    value,
    entry_decoder(),
    prefix,
  ))
  case name == error_method {
    False -> {
      use _ <- result.try(matching_name(name, call_id, calls, prefix))
      Ok(MethodResponse(name:, arguments:, call_id:))
    }
    True -> method_error(arguments, call_id, calls, prefix)
  }
}

/// F8: a response must name the method that was sent under its call id, or an
/// `Email/get` reply could be read as `Mailbox/get`. An entry whose id is not
/// in `calls` has no sent method to compare with.
fn matching_name(
  name: String,
  call_id: String,
  calls: List(#(String, String)),
  prefix: String,
) -> Result(Nil, Error) {
  case list.find(calls, fn(call) { call.0 == call_id }) {
    Ok(#(_, method)) if method != name -> Error(Decode(path(prefix, ["0"])))
    _ -> Ok(Nil)
  }
}

fn entry_decoder() -> decode.Decoder(#(String, Dynamic, String)) {
  decode.then(decode.at([0], decode.string), fn(name) {
    decode.then(decode.at([1], decode.dynamic), fn(arguments) {
      decode.then(decode.at([2], decode.string), fn(call_id) {
        decode.success(#(name, arguments, call_id))
      })
    })
  })
}

fn method_error(
  arguments: Dynamic,
  call_id: String,
  calls: List(#(String, String)),
  prefix: String,
) -> Result(MethodResponse, Error) {
  use type_ <- result.try(decode_at(
    arguments,
    decode.at(["type"], decode.string),
    prefix <> "[1]",
  ))
  case list.find(calls, fn(call) { call.0 == call_id }) {
    Ok(#(_, method)) ->
      Error(JmapMethod(method:, type_: method_problem_type(type_)))
    Error(Nil) -> Error(Decode(path(prefix, ["2"])))
  }
}

/// A method-level problem type: the server's value when it is in RFC 8620
/// § 3.6.2 / § 5's set, else the fixed `"unknown"`, so a server's text cannot
/// reach an `Error` (I1).
fn method_problem_type(type_: String) -> String {
  case list.contains(method_problem_types, type_) {
    True -> type_
    False -> "unknown"
  }
}

// Paths.

/// Decode a JSON document with `decoder`. Every failure leaves through the
/// path choke point below, so no document text reaches the `Error`.
pub fn document(text: String, decoder: decode.Decoder(a)) -> Result(a, Error) {
  case json.parse(text, using: decode.dynamic) {
    Error(_) -> Error(Decode(root))
    Ok(dynamic) -> decode_at(dynamic, decoder, "")
  }
}

fn decode_at(
  value: Dynamic,
  decoder: decode.Decoder(a),
  prefix: String,
) -> Result(a, Error) {
  case decode.run(value, decoder) {
    Ok(decoded) -> Ok(decoded)
    Error(errors) -> Error(failure(errors, prefix))
  }
}

fn failure(errors: List(decode.DecodeError), prefix: String) -> Error {
  let segments = case errors {
    [decode.DecodeError(path: segments, ..), ..] -> segments
    [] -> []
  }
  Decode(path(prefix, segments))
}

/// Join a fixed prefix with the decode error's segments. Segments that read as
/// an integer are list indices (`[2]`); a segment in `path_fields` is a field
/// (`.id`); any other segment comes from the document and ends the path
/// here, naming the enclosing map. The fixed prefix is the decoder's own, never
/// a document value.
fn path(prefix: String, segments: List(String)) -> String {
  let text = prefix <> render(segments)
  let text = case string.starts_with(text, ".") {
    True -> string.drop_start(text, 1)
    False -> text
  }
  case text {
    "" -> root
    _ -> text
  }
}

fn render(segments: List(String)) -> String {
  case segments {
    [] -> ""
    [segment, ..rest] ->
      case list.contains(server_keyed_fields, segment) {
        // The next segment is a map key the server chose, so the path ends at
        // the map, before the key is even read as a list index or a field.
        True -> "." <> segment
        False ->
          case int.parse(segment) {
            Ok(index) -> "[" <> int.to_string(index) <> "]" <> render(rest)
            Error(Nil) ->
              case list.contains(path_fields, segment) {
                True -> "." <> segment <> render(rest)
                False -> ""
              }
          }
      }
  }
}
