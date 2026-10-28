//// The one `Error` type of the whole program (PHASE-10, D1; design § 5.2).
////
//// Every payload is a fixed type string, an int or a method name. No variant
//// can carry server text, a request body, a URL or a credential: an `Error` is
//// printed to stderr as a JSON line, and it is inspected in the token-leak
//// suite, so anything it held would be shown.
////
//// `Store` and `QueryUnstable` are defined here now so the type is closed once;
//// PHASE-04/05 raise them.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string

pub type Error {
  /// A configuration file that is unusable; `reason` names the failing check.
  Config(reason: String)
  /// No credentials directory, a missing file, a file with no secret, or a
  /// secret holding a control byte (`"invalid"`).
  Credential(reason: String)
  /// A transport failure; `reason` is `"timeout"`, `"connect_failed"`,
  /// `"tls_failed"`, `"bad_utf8"` or `"status_<n>"`.
  Http(reason: String)
  /// The server refused the credential with this status (401/403).
  Auth(status: Int)
  /// The server asked us to slow down (429), with no retry.
  RateLimited
  /// A JMAP problem document's fixed `type`, or one we raise ourselves.
  JmapRequest(type_: String)
  /// A JMAP method-level error for this method and problem type.
  JmapMethod(method: String, type_: String)
  /// A response whose shape was not what we could decode; `path` locates it and
  /// never quotes the input.
  Decode(path: String)
  /// A run ceiling was reached; `bound` names it (`"max_total_bytes"`, ...).
  LimitExceeded(bound: String)
  /// A query's `queryState` moved under us, or failed to restart.
  QueryUnstable
  /// The store refused an operation; `reason` is a fixed code.
  Store(reason: String)
  /// The command line was not one we accept; `reason` is a fixed code.
  Usage(reason: String)
}

/// One JSON object on stderr, with no trailing newline: the caller writes the
/// line, so it owns the separator.
pub fn to_json_line(error: Error) -> String {
  let fields = case error {
    Config(reason) -> [#("reason", json.string(reason))]
    Credential(reason) -> [#("reason", json.string(reason))]
    Http(reason) -> [#("reason", json.string(reason))]
    Auth(status) -> [#("status", json.int(status))]
    RateLimited -> []
    JmapRequest(type_) -> [#("type", json.string(type_))]
    JmapMethod(method, type_) -> [
      #("method", json.string(method)),
      #("type", json.string(type_)),
    ]
    Decode(path) -> [#("path", json.string(path))]
    LimitExceeded(bound) -> [#("bound", json.string(bound))]
    QueryUnstable -> []
    Store(reason) -> [#("reason", json.string(reason))]
    Usage(reason) -> [#("reason", json.string(reason))]
  }

  [
    #("level", json.string("error")),
    #("error", json.string(variant_name(error))),
  ]
  |> list.append(fields)
  |> json.object
  |> json.to_string
}

/// The path of a decode failure: the first error's segments, list indices as
/// `[n]` and field names as `.name`, joined after `prefix` (a leading `.` is
/// dropped; an empty result is `"$"`). Only for decoders that name fixed
/// fields: one that iterates a map would put a document key in the path.
pub fn decode_failure(
  errors: List(decode.DecodeError),
  prefix: String,
) -> Error {
  let segments = case errors {
    [decode.DecodeError(path: segments, ..), ..] -> segments
    [] -> []
  }
  Decode(failure_path(prefix, segments))
}

fn failure_path(prefix: String, segments: List(String)) -> String {
  let rendered =
    segments
    |> list.map(fn(segment) {
      case int.parse(segment) {
        Ok(_) -> "[" <> segment <> "]"
        Error(_) -> "." <> segment
      }
    })
    |> string.concat
  let text = prefix <> rendered
  let text = case string.starts_with(text, ".") {
    True -> string.drop_start(text, 1)
    False -> text
  }
  case text {
    "" -> "$"
    _ -> text
  }
}

/// 2 for a usage or configuration mistake, 1 for every runtime failure (design
/// § 5.2). 0 never: an `Error` is always a failure.
pub fn exit_code(error: Error) -> Int {
  case error {
    Usage(_) | Config(_) -> 2
    _ -> 1
  }
}

/// The snake_case tag used in the JSON line; a name that no other field of ours
/// uses, so the line stays a single flat object.
fn variant_name(error: Error) -> String {
  case error {
    Config(_) -> "config"
    Credential(_) -> "credential"
    Http(_) -> "http"
    Auth(_) -> "auth"
    RateLimited -> "rate_limited"
    JmapRequest(_) -> "jmap_request"
    JmapMethod(_, _) -> "jmap_method"
    Decode(_) -> "decode"
    LimitExceeded(_) -> "limit_exceeded"
    QueryUnstable -> "query_unstable"
    Store(_) -> "store"
    Usage(_) -> "usage"
  }
}
