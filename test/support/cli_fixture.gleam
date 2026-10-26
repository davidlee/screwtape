//// Test support: the config file, the credentials directory and the stderr
//// line that the CLI contract tests and the token-leak suite both build
//// (PHASE-10, EX-4/EX-5).
////
//// Moved here from `test/screwtape/cli_test.gleam` when the token-leak suite
//// needed the same shapes with overridable bounds, so neither suite keeps a
//// copy: `config_text_with` is the one writer, and `config_text` is it with the
//// bounds a passing run wants. A config is written with `gleam_json`, so no
//// path needs escaping; a failure line is decoded to its `error` field, so a
//// case does not depend on the line's layout.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import support/temp

/// The byte budget a config carries unless a case tightens it: large enough
/// that no fixture body can reach it.
pub const default_max_total_bytes = 268_435_456

/// The request timeout a config carries unless a case shortens it.
pub const default_request_timeout_ms = 30_000

/// A valid configuration document (the shape `config_test` generates) with the
/// default bounds.
pub fn config_text(session_url: String, ca_file: Option(String)) -> String {
  config_text_with(
    session_url,
    ca_file,
    default_max_total_bytes,
    default_request_timeout_ms,
  )
}

/// The same document with the two bounds the token-leak cases tighten: a small
/// `max_total_bytes` (the session body breaches it) or a short
/// `request_timeout_ms` (a withheld reply times out).
pub fn config_text_with(
  session_url: String,
  ca_file: Option(String),
  max_total_bytes: Int,
  request_timeout_ms: Int,
) -> String {
  let fields = [
    #("session_url", json.string(session_url)),
    #("credential_name", json.string("fastmail")),
    #("store_path", json.string("/tmp/screwtape-cli-test/mail.sqlite3")),
    #(
      "window",
      json.object([
        #("mailboxes", json.array(["inbox"], json.string)),
        #("max_age_days", json.int(30)),
        #("max_messages", json.int(2000)),
      ]),
    ),
    #("max_body_bytes", json.int(262_144)),
    #("max_pages", json.int(20)),
    #("max_total_bytes", json.int(max_total_bytes)),
    #("request_timeout_ms", json.int(request_timeout_ms)),
  ]
  let fields = case ca_file {
    None -> fields
    Some(path) -> list.append(fields, [#("ca_file", json.string(path))])
  }
  json.object(fields) |> json.to_string
}

/// A fresh temp directory holding a config file with `text`, named
/// `<dir>/config.json`; returns the directory and the path.
pub fn config_dir(prefix: String, text: String) -> #(String, String) {
  let dir = temp.dir(prefix)
  let path = dir <> "/config.json"
  temp.write(path, bit_array.from_string(text))
  #(dir, path)
}

/// A fresh temp directory holding the credential file `fastmail`, whose trimmed
/// contents are `secret`.
pub fn credential_dir(secret: String) -> String {
  let dir = temp.dir("cli-credentials")
  temp.write(dir <> "/fastmail", bit_array.from_string(secret <> "\n"))
  dir
}

/// The error line as a decoded document's `error` field, so a case does not
/// depend on the exact line layout.
pub fn error_kind(line: String) -> Result(String, Nil) {
  case json.parse(line, using: decode.dynamic) {
    Error(_) -> Error(Nil)
    Ok(document) ->
      decode.run(document, decode.at(["error"], decode.string))
      |> result.map_error(fn(_) { Nil })
  }
}
