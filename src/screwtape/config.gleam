//// The configuration document (PHASE-10; design § 5.2, DEC-009).
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
  )
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
  ))
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
  decode.success(Window(mailboxes:, max_age_days:, max_messages:))
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
  use _ <- result.try(check(
    string.starts_with(config.session_url, "https://"),
    "non_https:session_url",
  ))
  use _ <- result.try(check_ca_file(config.ca_file))
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

/// A `ca_file` is optional, but when given it is trusted instead of the system
/// store, so it must be a path we can be sure is absolute (DEC-018).
fn check_ca_file(ca_file: Option(String)) -> Result(Nil, Error) {
  case ca_file {
    None -> Ok(Nil)
    Some(path) -> check(string.starts_with(path, "/"), "relative_ca_file")
  }
}
