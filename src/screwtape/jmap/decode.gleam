//// Decoding the JMAP session, method responses and problem documents
//// (PHASE-10, D6; design § 5.2).
////
//// A failure is either `JmapRequest` — a session without the mail capability,
//// or an `apiUrl` that is not `https` — or `JmapMethod(method, type)` for a
//// method-level error, or `Decode(path)`. `path` names a location built only
//// from fixed field names and list indices: never a document key, never a field
//// value, never any of the input text. Where a location passes through a map
//// keyed by server data (`accounts`, `capabilities`), the path names the map
//// only.
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
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import screwtape/error.{type Error, Decode, JmapMethod, JmapRequest}

pub const mail_capability = "urn:ietf:params:jmap:mail"

pub const core_capability = "urn:ietf:params:jmap:core"

/// The location of a whole document, for JSON that does not parse at all.
const root = "$"

/// The method name that marks an error entry in `methodResponses`.
const error_method = "error"

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

/// The mailbox fields the scope uses; the full Mailbox model is PHASE-05's.
pub type MailboxSummary {
  MailboxSummary(id: String, name: String, role: Option(String))
}

/// Decode a JMAP session document.
pub fn session(text: String) -> Result(Session, Error) {
  use raw <- result.try(decode_document(text, raw_session_decoder()))
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

/// An RFC 7807 problem document's `type`, or `Error(Nil)` for anything else.
pub fn problem(text: String) -> Result(String, Nil) {
  case json.parse(text, using: decode.dynamic) {
    Error(_) -> Error(Nil)
    Ok(dynamic) ->
      case decode.run(dynamic, decode.at(["type"], decode.string)) {
        Ok(type_) -> Ok(type_)
        Error(_) -> Error(Nil)
      }
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
  use entries <- result.try(decode_document(
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
) -> Result(#(List(MailboxSummary), String), Error) {
  decode_at(response.arguments, mailbox_get_decoder(), "")
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
  case dict.get(capabilities, core_capability) {
    Error(Nil) -> Error(Decode("capabilities"))
    Ok(core) -> decode_at(core, core_decoder(), "capabilities")
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

fn mailbox_get_decoder() -> decode.Decoder(#(List(MailboxSummary), String)) {
  use state <- decode.field("state", decode.string)
  use mailboxes <- decode.field("list", decode.list(mailbox_decoder()))
  decode.success(#(mailboxes, state))
}

fn mailbox_decoder() -> decode.Decoder(MailboxSummary) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use role <- decode.optional_field(
    "role",
    None,
    decode.optional(decode.string),
  )
  decode.success(MailboxSummary(id:, name:, role:))
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
    False -> Ok(MethodResponse(name:, arguments:, call_id:))
    True -> method_error(arguments, call_id, calls, prefix)
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
    Ok(#(_, method)) -> Error(JmapMethod(method:, type_: type_))
    Error(Nil) -> Error(Decode(path(prefix, ["2"])))
  }
}

// Paths.

fn decode_document(
  text: String,
  decoder: decode.Decoder(a),
) -> Result(a, Error) {
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
/// an integer are list indices (`[2]`); the rest are fields (`.id`). The
/// decoder itself produces the segments; none of them is a document value.
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
  list.fold(segments, "", fn(acc, segment) {
    case int.parse(segment) {
      Ok(index) -> acc <> "[" <> int.to_string(index) <> "]"
      Error(Nil) -> acc <> "." <> segment
    }
  })
}
