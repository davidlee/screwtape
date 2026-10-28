//// The configuration document (PHASE-10, PHASE-13; design § 5.2, DEC-009,
//// DEC-033).
////
//// `parse` is total over its input: a document that does not decode and a
//// document that decodes but breaks a rule both come back as
//// `Error.Config(reason)`, whose reason names the failing check — or, for a
//// number, the field — and never quotes a value. The file, the JSON and the
//// path all come from the operator, and the reason is printed and inspected.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some, is_some}
import gleam/result
import gleam/string
import screwtape/error.{type Error, Config as ConfigError}

/// The part of the window the peer chooses; the encoding (`inbox` as a role
/// before a name) is resolved against the mailbox list, not here.
pub type Window {
  Window(
    mailboxes: List(String),
    max_age_days: Option(Int),
    max_messages: Option(Int),
    retain_messages: Option(Int),
  )
}

/// The classifier endpoint the `classify` verb asks (EX-2): the base URL, the
/// credential its token comes from, and the model it names.
pub type Jev {
  Jev(base_url: String, credential_name: String, model: String)
}

pub type Config {
  Config(
    session_url: String,
    credential_name: String,
    store_path: String,
    window: Window,
    max_body_bytes: Int,
    max_pages: Int,
    max_total_bytes: Int,
    request_timeout_ms: Int,
    ca_file: Option(String),
    jev: Option(Jev),
  )
}

/// Decode and then check the document. Every failure is `Config`; there is no
/// partial result to fall back to.
pub fn parse(text: String) -> Result(Config, Error) {
  case json.parse(from: text, using: decoder()) {
    Error(_) -> Error(ConfigError("invalid_json"))
    Ok(config) -> validate(config)
  }
}

fn decoder() -> decode.Decoder(Config) {
  use session_url <- decode.field("session_url", decode.string)
  use credential_name <- decode.field("credential_name", decode.string)
  use store_path <- decode.field("store_path", decode.string)
  use window <- decode.field("window", window_decoder())
  use max_body_bytes <- decode.field("max_body_bytes", decode.int)
  use max_pages <- decode.field("max_pages", decode.int)
  use max_total_bytes <- decode.field("max_total_bytes", decode.int)
  use request_timeout_ms <- decode.field("request_timeout_ms", decode.int)
  use ca_file <- decode.optional_field(
    "ca_file",
    None,
    decode.optional(decode.string),
  )
  use jev <- decode.optional_field("jev", None, decode.optional(jev_decoder()))
  decode.success(Config(
    session_url:,
    credential_name:,
    store_path:,
    window:,
    max_body_bytes:,
    max_pages:,
    max_total_bytes:,
    request_timeout_ms:,
    ca_file:,
    jev:,
  ))
}

fn jev_decoder() -> decode.Decoder(Jev) {
  use base_url <- decode.field("base_url", decode.string)
  use credential_name <- decode.field("credential_name", decode.string)
  use model <- decode.field("model", decode.string)
  decode.success(Jev(base_url:, credential_name:, model:))
}

/// The window as JSON, for the `sync` row's provenance (`window_json`).
pub fn window_json(window: Window) -> String {
  json.object([
    #("mailboxes", json.array(window.mailboxes, json.string)),
    #("max_age_days", json.nullable(window.max_age_days, json.int)),
    #("max_messages", json.nullable(window.max_messages, json.int)),
    #("retain_messages", json.nullable(window.retain_messages, json.int)),
  ])
  |> json.to_string
}

fn window_decoder() -> decode.Decoder(Window) {
  use mailboxes <- decode.field("mailboxes", decode.list(decode.string))
  use max_age_days <- decode.optional_field(
    "max_age_days",
    None,
    decode.optional(decode.int),
  )
  use max_messages <- decode.optional_field(
    "max_messages",
    None,
    decode.optional(decode.int),
  )
  use retain_messages <- decode.optional_field(
    "retain_messages",
    None,
    decode.optional(decode.int),
  )
  decode.success(Window(
    mailboxes:,
    max_age_days:,
    max_messages:,
    retain_messages:,
  ))
}

fn validate(config: Config) -> Result(Config, Error) {
  let window = config.window
  use _ <- result.try(check(!list.is_empty(window.mailboxes), "empty_mailboxes"))
  use _ <- result.try(check(
    is_some(window.max_age_days) || is_some(window.max_messages),
    "no_window_bound",
  ))
  use _ <- result.try(positive(config.max_body_bytes, "max_body_bytes"))
  use _ <- result.try(positive(config.max_pages, "max_pages"))
  use _ <- result.try(positive(config.max_total_bytes, "max_total_bytes"))
  use _ <- result.try(positive(config.request_timeout_ms, "request_timeout_ms"))
  use _ <- result.try(positive_if_set(window.max_age_days, "max_age_days"))
  use _ <- result.try(positive_if_set(window.max_messages, "max_messages"))
  use _ <- result.try(positive_if_set(window.retain_messages, "retain_messages"))
  use _ <- result.try(check(
    case window.retain_messages {
      None -> True
      Some(_) -> is_some(window.max_messages)
    },
    "retain_without_max_messages",
  ))
  use _ <- result.try(check(
    case window.retain_messages, window.max_messages {
      Some(retain), Some(max) -> retain >= max
      _, _ -> True
    },
    "retain_below_max_messages",
  ))
  use _ <- result.try(check(
    string.starts_with(config.session_url, "https://"),
    "non_https:session_url",
  ))
  use _ <- result.try(check_ca_file(config.ca_file))
  use _ <- result.try(check_jev(config.jev))
  Ok(config)
}

fn check(passes: Bool, reason: String) -> Result(Nil, Error) {
  case passes {
    True -> Ok(Nil)
    False -> Error(ConfigError(reason))
  }
}

/// A bound that is present must be positive; absent is not this check's
/// business (that is `no_window_bound`).
fn positive(value: Int, field: String) -> Result(Nil, Error) {
  check(value > 0, "non_positive:" <> field)
}

fn positive_if_set(value: Option(Int), field: String) -> Result(Nil, Error) {
  case value {
    None -> Ok(Nil)
    Some(number) -> positive(number, field)
  }
}

/// The optional `jev` block, checked only when present (EX-2, DEC-033): the
/// first failing rule is the reason, and none of them quotes a value.
fn check_jev(jev: Option(Jev)) -> Result(Nil, Error) {
  case jev {
    None -> Ok(Nil)
    Some(jev) -> {
      use _ <- result.try(check(
        is_jev_url(jev.base_url),
        "non_https:jev.base_url",
      ))
      use _ <- result.try(check(
        !string.ends_with(jev.base_url, "/"),
        "trailing_slash:jev.base_url",
      ))
      use _ <- result.try(check(
        !string.is_empty(jev.credential_name),
        "empty:jev.credential_name",
      ))
      use _ <- result.try(check(
        !string.contains(jev.credential_name, "/"),
        "invalid:jev.credential_name",
      ))
      check(!string.is_empty(jev.model), "empty:jev.model")
    }
  }
}

/// The classifier is reached over TLS, or over plain HTTP only on loopback with
/// a numeric port and no path (DEC-033).
fn is_jev_url(url: String) -> Bool {
  string.starts_with(url, "https://")
  || url == "http://127.0.0.1"
  || is_loopback_port(url)
}

fn is_loopback_port(url: String) -> Bool {
  let prefix = "http://127.0.0.1:"
  case string.starts_with(url, prefix) {
    False -> False
    True -> {
      let port = string.drop_start(from: url, up_to: string.length(prefix))
      !string.is_empty(port)
      && port |> string.to_graphemes |> list.all(is_ascii_digit)
    }
  }
}

fn is_ascii_digit(grapheme: String) -> Bool {
  string.contains("0123456789", grapheme)
}

/// A `ca_file` is optional, but when given it is trusted instead of the system
/// store, so it must be a path we can be sure is absolute (DEC-018).
fn check_ca_file(ca_file: Option(String)) -> Result(Nil, Error) {
  case ca_file {
    None -> Ok(Nil)
    Some(path) -> check(string.starts_with(path, "/"), "relative_ca_file")
  }
}
