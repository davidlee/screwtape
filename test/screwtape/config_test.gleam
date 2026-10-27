//// Contract tests for `screwtape/config` (PHASE-10; design § 5.2; VT-4).
////
//// One valid document is generated and then broken one field at a time, so each
//// test differs from a passing parse in exactly the check it exercises. Reasons
//// name the failing field and never quote a value: an `Error` is printed and
//// inspected, and a config may hold a path or a URL.

import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/config
import screwtape/error

pub fn main() -> Nil {
  gleeunit.main()
}

const session_url = "https://api.fastmail.com/jmap/session"

const store_path = "/home/operator/.local/state/screwtape/mail.sqlite3"

const mailboxes = "[\"inbox\"]"

const window_bounds = "\"max_age_days\":30,\"max_messages\":2000"

const numbers =
  "\"max_body_bytes\":262144,\"max_pages\":20,\"max_total_bytes\":268435456,\"request_timeout_ms\":30000"

/// The design's own example document, byte for byte, with `ca_file` optional.
fn valid_text(ca_file: Option(String)) -> String {
  "{\"session_url\":\""
  <> session_url
  <> "\",\"credential_name\":\"fastmail\",\"store_path\":\""
  <> store_path
  <> "\",\"window\":{\"mailboxes\":"
  <> mailboxes
  <> ","
  <> window_bounds
  <> "},"
  <> numbers
  <> ca_file_text(ca_file)
  <> "}"
}

fn ca_file_text(ca_file: Option(String)) -> String {
  case ca_file {
    None -> ""
    Some(path) -> ",\"ca_file\":" <> json.to_string(json.string(path))
  }
}

/// Swap one fragment of the valid document for another.
fn broken(from: String, into: String) -> String {
  string.replace(valid_text(None), from, into)
}

pub fn parse_full_valid_config_test() {
  let result = config.parse(valid_text(None))

  let assert Ok(parsed) = result
  parsed.session_url |> should.equal(session_url)
  parsed.credential_name |> should.equal("fastmail")
  parsed.store_path |> should.equal(store_path)
  parsed.window.mailboxes |> should.equal(["inbox"])
  parsed.window.max_age_days |> should.equal(Some(30))
  parsed.window.max_messages |> should.equal(Some(2000))
  parsed.window.retain_messages |> should.equal(None)
  parsed.max_body_bytes |> should.equal(262_144)
  parsed.max_pages |> should.equal(20)
  parsed.max_total_bytes |> should.equal(268_435_456)
  parsed.request_timeout_ms |> should.equal(30_000)
  parsed.ca_file |> should.equal(None)
}

pub fn parse_several_mailboxes_test() {
  let text = broken(mailboxes, "[\"inbox\",\"sent\",\"1234-abc\"]")
  let result = config.parse(text)

  let assert Ok(parsed) = result
  parsed.window.mailboxes
  |> should.equal(["inbox", "sent", "1234-abc"])
}

pub fn empty_mailboxes_test() {
  config.parse(broken(mailboxes, "[]"))
  |> should.equal(Error(error.Config("empty_mailboxes")))
}

pub fn no_window_bound_test() {
  config.parse(broken(",\"max_age_days\":30,\"max_messages\":2000", ""))
  |> should.equal(Error(error.Config("no_window_bound")))
}

pub fn non_positive_max_age_days_test() {
  config.parse(broken("\"max_age_days\":30", "\"max_age_days\":0"))
  |> should.equal(Error(error.Config("non_positive:max_age_days")))
}

pub fn non_positive_max_messages_test() {
  config.parse(broken("\"max_messages\":2000", "\"max_messages\":-5"))
  |> should.equal(Error(error.Config("non_positive:max_messages")))
}

pub fn retain_messages_decoded_test() {
  let text =
    broken(
      window_bounds,
      "\"max_age_days\":30,\"max_messages\":2000,\"retain_messages\":2000",
    )
  let result = config.parse(text)

  // Set, and equal to `max_messages`: retention may not be below the window.
  let assert Ok(parsed) = result
  parsed.window.retain_messages |> should.equal(Some(2000))

  // Explicit null, as the Home Manager module writes it, means unset.
  let assert Ok(parsed) =
    config.parse(broken(
      window_bounds,
      "\"max_age_days\":30,\"max_messages\":2000,\"retain_messages\":null",
    ))
  parsed.window.retain_messages |> should.equal(None)
}

pub fn non_positive_retain_messages_test() {
  // Refusal 1 is checked before the cross-field rules, so the missing
  // `max_messages` here cannot mask the non-positive reason.
  config.parse(broken(
    window_bounds,
    "\"max_age_days\":30,\"retain_messages\":0",
  ))
  |> should.equal(Error(error.Config("non_positive:retain_messages")))
  config.parse(broken(
    window_bounds,
    "\"max_age_days\":30,\"retain_messages\":-5",
  ))
  |> should.equal(Error(error.Config("non_positive:retain_messages")))
}

pub fn retain_without_max_messages_test() {
  // An age-only window is refused by design: retention extends a count window,
  // and an age-only one would fetch bodies retention then discards.
  config.parse(broken(
    window_bounds,
    "\"max_age_days\":30,\"retain_messages\":2000",
  ))
  |> should.equal(Error(error.Config("retain_without_max_messages")))
}

pub fn retain_below_max_messages_test() {
  config.parse(broken(
    window_bounds,
    "\"max_age_days\":30,\"max_messages\":2000,\"retain_messages\":1999",
  ))
  |> should.equal(Error(error.Config("retain_below_max_messages")))
  config.parse(broken(
    window_bounds,
    "\"max_age_days\":30,\"max_messages\":2000,\"retain_messages\":1000",
  ))
  |> should.equal(Error(error.Config("retain_below_max_messages")))
}

pub fn non_positive_body_bytes_test() {
  config.parse(broken("\"max_body_bytes\":262144", "\"max_body_bytes\":-1"))
  |> should.equal(Error(error.Config("non_positive:max_body_bytes")))
}

pub fn non_positive_max_pages_test() {
  config.parse(broken("\"max_pages\":20", "\"max_pages\":0"))
  |> should.equal(Error(error.Config("non_positive:max_pages")))
}

pub fn non_positive_total_bytes_test() {
  config.parse(broken("\"max_total_bytes\":268435456", "\"max_total_bytes\":0"))
  |> should.equal(Error(error.Config("non_positive:max_total_bytes")))
}

pub fn non_positive_timeout_test() {
  config.parse(broken(
    "\"request_timeout_ms\":30000",
    "\"request_timeout_ms\":0",
  ))
  |> should.equal(Error(error.Config("non_positive:request_timeout_ms")))
}

pub fn non_https_session_url_test() {
  config.parse(broken("https://api.fastmail.com", "http://api.fastmail.com"))
  |> should.equal(Error(error.Config("non_https:session_url")))
}

pub fn non_https_scheme_less_url_test() {
  config.parse(broken("\"https://", "\"//"))
  |> should.equal(Error(error.Config("non_https:session_url")))
}

pub fn ca_file_relative_rejected_test() {
  config.parse(valid_text(Some("certs/ca.pem")))
  |> should.equal(Error(error.Config("relative_ca_file")))
  config.parse(valid_text(Some("ca.pem")))
  |> should.equal(Error(error.Config("relative_ca_file")))
}

pub fn ca_file_absolute_accepted_test() {
  let result = config.parse(valid_text(Some("/etc/ssl/certs/ca-bundle.crt")))

  let assert Ok(parsed) = result
  parsed.ca_file |> should.equal(Some("/etc/ssl/certs/ca-bundle.crt"))
}

pub fn ca_file_absent_accepted_test() {
  let result = config.parse(valid_text(None))

  let assert Ok(parsed) = result
  parsed.ca_file |> should.equal(None)
}

pub fn invalid_json_test() {
  config.parse("{\"session_url\":")
  |> should.equal(Error(error.Config("invalid_json")))
  config.parse("")
  |> should.equal(Error(error.Config("invalid_json")))
  config.parse("[]")
  |> should.equal(Error(error.Config("invalid_json")))
}

pub fn missing_field_invalid_json_test() {
  config.parse(broken(",\"max_pages\":20", ""))
  |> should.equal(Error(error.Config("invalid_json")))
}

/// A rejected document's diagnostic names the check and nothing else: no URL,
/// no path, no credential name.
pub fn config_error_never_echoes_values_test() {
  let text = broken("https://api.fastmail.com", "http://SECRET-host.example")
  let result = config.parse(text)

  let assert Error(problem) = result
  let line = error.to_json_line(problem)
  line |> string.contains("SECRET") |> should.be_false
  line |> string.contains("api.fastmail.com") |> should.be_false
  line
  |> should.equal(
    "{\"level\":\"error\",\"error\":\"config\",\"reason\":\"non_https:session_url\"}",
  )
  error.exit_code(problem) |> should.equal(2)
}

/// Every rejection is `Config`, so every rejection exits 2 (design § 5.2).
pub fn every_rejection_exits_two_test() {
  let rejections =
    [
      broken(mailboxes, "[]"),
      broken(",\"max_age_days\":30,\"max_messages\":2000", ""),
      broken("\"max_pages\":20", "\"max_pages\":0"),
      broken("https://api.fastmail.com", "http://api.fastmail.com"),
      valid_text(Some("ca.pem")),
      "not json",
    ]
    |> list.map(config.parse)

  let codes =
    list.map(rejections, fn(result) {
      let assert Error(problem) = result
      error.exit_code(problem)
    })
  codes |> should.equal([2, 2, 2, 2, 2, 2])
}

/// The `sync` row's provenance: the window as given, an unset bound as null.
pub fn window_json_test() {
  config.Window(
    mailboxes: ["inbox", "Work"],
    max_age_days: None,
    max_messages: Some(5),
    retain_messages: None,
  )
  |> config.window_json
  |> should.equal(
    "{\"mailboxes\":[\"inbox\",\"Work\"],\"max_age_days\":null,\"max_messages\":5,\"retain_messages\":null}",
  )
}

/// A change to retention changes the provenance string (EX-3), which is why
/// M1's three-key `window_json` mismatches on the first M2 run.
pub fn window_json_changes_with_retain_messages_test() {
  let window = fn(retain_messages) {
    config.Window(
      mailboxes: ["inbox"],
      max_age_days: None,
      max_messages: Some(10),
      retain_messages: retain_messages,
    )
  }
  let without = window(None) |> config.window_json
  let with = window(Some(20)) |> config.window_json

  with |> should.not_equal(without)
  with |> string.contains("\"retain_messages\":20") |> should.be_true
}
