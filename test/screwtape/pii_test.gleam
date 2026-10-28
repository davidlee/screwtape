//// VT-1: the PII stripping contract (PHASE-12, T1), transcribed row for row
//// from the phase spec's table. The table is the specification: no expected
//// value is adjusted to fit the implementation.
////
//// Notes on the literals: `…` is U+2026, the ellipsis a stripped URL leaves
//// behind; the last row contains the private-use codepoints U+E000 and U+E001,
//// which the stripper uses internally as mask markers and which therefore
//// carry no meaning in the input.

import gleam/list
import gleam/string
import gleeunit
import screwtape/pii

pub fn main() -> Nil {
  gleeunit.main()
}

/// Every `#(input, expected)` row: `strip(input)` must equal `expected`.
const table = [
  #("", ""),
  #("write to a.b@shop.example now", "write to [email] now"),
  #("Mixed Bob.Smith+tag@Mail.Example.COM.", "Mixed [email]."),
  #("Grüße an jürgen@exämple.de", "Grüße an [email]"),
  #(
    "see https://shop.example/track?id=123456789#x ok",
    "see https://shop.example/[\u{2026}] ok",
  ),
  #("http://shop.example:8080", "http://shop.example"),
  #("<https://shop.example>", "<https://shop.example>"),
  #("HTTPS://Shop.Example/A", "HTTPS://Shop.Example/[\u{2026}]"),
  #("https://user@shop.example:8443/p", "https://[email]/[\u{2026}]"),
  #("https://user:pw@shop.example/p", "https://[email]/[\u{2026}]"),
  #("server 192.168.10.200 down", "server [ip] down"),
  #(
    "on 2026-10-28 at 2026-10-28T14:05:00Z",
    "on 2026-10-28 at 2026-10-28T14:05:00Z",
  ),
  #(
    "12/12/2026, 1.2.26, 2026/10/28, 14:00, 09:30:15",
    "12/12/2026, 1.2.26, 2026/10/28, 14:00, 09:30:15",
  ),
  #("12.12.2026", "12.12.2026"),
  #("12.12.2026 14:00", "12.12.2026 14:00"),
  #("2026-10-28 14:00", "2026-10-28 14:00"),
  #("12.12.2026 3456", "[number]"),
  #("2026-10-28 12345", "[number]"),
  #("9 12.12.2026", "[number]"),
  #("32.13.2026", "[number]"),
  #("call 0412.345.678", "call [number]"),
  #("card 4111 1111 1111 1111 ok", "card [number] ok"),
  #("+61 412-345-678", "+[number]"),
  #("ref 12345678", "ref [number]"),
  #("ref 1234567", "ref 1234567"),
  #("a 1234  5678", "a 1234  5678"),
  #(
    "Hi bob@x.example, see https://t.example/a?b=1 from 10.0.0.1 on 12.12.2026 14:00, ref 1234 5678 9012.",
    "Hi [email], see https://t.example/[\u{2026}] from [ip] on 12.12.2026 14:00, ref [number].",
  ),
  #("x\u{E000}12345678\u{E001}y", "x[number]y"),
  // Added by the orchestrator after review: a slashed date or a time followed
  // by a space and a digit run is not a whole token, and a query or fragment
  // straight after the host is dropped.
  #("12/12/2026 12345678", "12/12/[number]"),
  #("2026/10/28 12345678", "2026/10/[number]"),
  #("14:00 12345678", "14:[number]"),
  #("https://shop.example?token=abc", "https://shop.example/[\u{2026}]"),
  #("https://shop.example#frag", "https://shop.example/[\u{2026}]"),
  #("https://shop.example:8443?t=1", "https://shop.example/[\u{2026}]"),
  // Added after review (VA-1, VA-2).
  #("\"alice\"@example.com", "[email]"),
  #("jose\u{0301}@example.com", "[email]"),
  #("o'connor@example.com", "[email]"),
  #("14:00:00.1234567890123456", "14:00:[number]"),
  #("12.12.2026 14:00:00.12345678", "12.12.2026 14:00:[number]"),
  #(
    "https://alice@bob@localhost/private?token=secret",
    "https://localhost/[\u{2026}]",
  ),
  #("https://[::1]:8443", "https://[::1]"),
  #("http://[::1]:8080/x", "http://[::1]/[\u{2026}]"),
  #("2026/10/28 14:00", "2026/10/28 14:00"),
  #("2026-10-28T14:05:00.123+10:00", "2026-10-28T14:05:00.123+10:00"),
  #("2026-10-28T14:05:00.1234567890123", "2026-10-28T14:05:[number]"),
]

pub fn vt_1_table_test() -> Nil {
  list.each(table, check_row)
}

/// One row, reported with its input so a failure names the case.
fn check_row(row: #(String, String)) -> Nil {
  let #(input, expected) = row
  let actual = pii.strip(input)
  case actual == expected {
    True -> Nil
    False -> {
      let message =
        "\ninput:\n"
        <> input
        <> "\nexpected:\n"
        <> expected
        <> "\nactual:\n"
        <> actual
      panic as message
    }
  }
}

/// A long near-address is scanned once per token (VA-2 F-5): a quadratic
/// matcher took seconds here.
pub fn long_near_address_test() -> Nil {
  let input = string.repeat("a", 64_000) <> "@x alice@example.com"
  let expected = string.repeat("a", 64_000) <> "@x [email]"
  check_row(#(input, expected))
}
