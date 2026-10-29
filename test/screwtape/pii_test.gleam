//// VT-1: the PII stripping contract (PHASE-12, T1), transcribed row for row
//// from the phase spec's table. The table is the specification: no expected
//// value is adjusted to fit the implementation.
////
//// Re-pointed for SL-005 PHASE-01 (DEC-043): the email rule is gone, so an
//// address passes through unchanged; a URL keeps its host, port and path and
//// loses only its userinfo, with a query or fragment becoming `?[…]` / `#[…]`;
//// and a 20+ run of letters and digits becomes `[token]` before the digit
//// rule. The IPv4, protected-date and digit-run rows are unchanged by that
//// decision, because rules 5 and 6 are untouched.
////
//// Notes on the literals: `…` is U+2026, the ellipsis a stripped URL leaves
//// behind; the forged-marker row contains the private-use codepoints U+E000
//// and U+E001, which the stripper uses internally as mask markers and which
//// therefore carry no meaning in the input.

import gleam/list
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleeunit
import gleeunit/should
import screwtape/pii

pub fn main() -> Nil {
  gleeunit.main()
}

/// Every `#(input, expected)` row: `strip(input)` must equal `expected`.
const table = [
  #("", ""),
  // Addresses pass through unchanged: there is no email rule any more.
  #("write to a.b@shop.example now", "write to a.b@shop.example now"),
  #(
    "Mixed Bob.Smith+tag@Mail.Example.COM.",
    "Mixed Bob.Smith+tag@Mail.Example.COM.",
  ),
  #("Grüße an jürgen@exämple.de", "Grüße an jürgen@exämple.de"),
  // The query or fragment collapses; the path survives.
  #(
    "see https://shop.example/track?id=123456789#x ok",
    "see https://shop.example/track?[\u{2026}] ok",
  ),
  // Port and path are kept.
  #("http://shop.example:8080", "http://shop.example:8080"),
  #(
    "https://shop.example:8443/admin/login",
    "https://shop.example:8443/admin/login",
  ),
  #("<https://shop.example>", "<https://shop.example>"),
  #("HTTPS://Shop.Example/A", "HTTPS://Shop.Example/A"),
  // Userinfo is dropped; what follows it stays.
  #("https://user@shop.example:8443/p", "https://shop.example:8443/p"),
  #("https://user:pw@shop.example/p", "https://shop.example/p"),
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
    "Hi bob@x.example, see https://t.example/a?[\u{2026}] from [ip] on 12.12.2026 14:00, ref [number].",
  ),
  #("x\u{E000}12345678\u{E001}y", "x[number]y"),
  // A slashed date or a time followed by a space and a digit run is not a
  // whole token, and a query or fragment straight after the host collapses.
  #("12/12/2026 12345678", "12/12/[number]"),
  #("2026/10/28 12345678", "2026/10/[number]"),
  #("14:00 12345678", "14:[number]"),
  // No path was ever there, so no slash is invented.
  #("https://shop.example?token=abc", "https://shop.example?[\u{2026}]"),
  #("https://shop.example#frag", "https://shop.example#[\u{2026}]"),
  #("https://shop.example:8443?t=1", "https://shop.example:8443?[\u{2026}]"),
  // Addresses that earlier rules used to catch now pass through whole.
  #("\"alice\"@example.com", "\"alice\"@example.com"),
  #("jose\u{0301}@example.com", "jose\u{0301}@example.com"),
  #("o'connor@example.com", "o'connor@example.com"),
  #("14:00:00.1234567890123456", "14:00:[number]"),
  #("12.12.2026 14:00:00.12345678", "12.12.2026 14:00:[number]"),
  // The last `@` of the authority ends the userinfo; the path is kept.
  #(
    "https://alice@bob@localhost/private?token=secret",
    "https://localhost/private?[\u{2026}]",
  ),
  #("https://[::1]:8443", "https://[::1]:8443"),
  #("http://[::1]:8080/x", "http://[::1]:8080/x"),
  #("2026/10/28 14:00", "2026/10/28 14:00"),
  #("2026-10-28T14:05:00.123+10:00", "2026-10-28T14:05:00.123+10:00"),
  #("2026-10-28T14:05:00.1234567890123", "2026-10-28T14:05:[number]"),
  // The token rule (rule 4): a run of 20 or more letters and digits holding
  // at least one of each is erased, in plain text and in a URL path alike.
  #("key Zx9Qw8Er7Ty6Ui5Op4As3Df2 ok", "key [token] ok"),
  #("hash d41d8cd98f00b204e9800998ecf8427e end", "hash [token] end"),
  #(
    "https://shop.example/reset/aB3dE5fG7hJ9kL1mN3pQ5rS7 done",
    "https://shop.example/reset/[token] done",
  ),
  // The token rule runs before the digit rule, so a token holding eight or
  // more digits is one `[token]`, not a `[number]` fragment.
  #("id a1234567890123456789xyz ok", "id [token] ok"),
  // Kept: 20+ letters only, a 19-character mixed run, and runs split by `-`
  // or `_` so each part is under 20. Lookalike domains and phrases survive.
  #("abcdefghijklmnopqrstuvwx", "abcdefghijklmnopqrstuvwx"),
  #("id aB3dE5fG7hJ9kL1mN3p ok", "id aB3dE5fG7hJ9kL1mN3p ok"),
  #(
    "id aB3dE5fG7hJ9-kL1mN3pQ5rS7_tUv9 ok",
    "id aB3dE5fG7hJ9-kL1mN3pQ5rS7_tUv9 ok",
  ),
  #(
    "https://paypa1-secure.example/login-verify-account-2024",
    "https://paypa1-secure.example/login-verify-account-2024",
  ),
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

/// A long run is scanned once, not once per character (VT-2, VA-2): the
/// token lookbehind lets a match attempt start only at a run's start. A
/// quadratic matcher took seconds on the near-address this replaces.
pub fn linear_letter_run_strips_in_under_a_second_test() -> Nil {
  let input = string.repeat("a", 16_384)
  strip_and_time(input, input)
}

/// The negative control for the token lookbehind: without it this run takes
/// seconds (each position rescans the rest of the run), with it about 5 ms.
/// At 16 KiB the quadratic scan still finishes in about 0.2 s.
pub fn linear_long_letter_run_needs_the_token_lookbehind_test() -> Nil {
  let input = string.repeat("a", 65_536)
  strip_and_time(input, input)
}

/// The same for the digit rule: one greedy pass over the run.
pub fn linear_digit_run_strips_in_under_a_second_test() -> Nil {
  let input = string.repeat("7", 16_384)
  strip_and_time(input, "[number]")
}

/// Strip `input`, check the result, and check the pass took under a second.
fn strip_and_time(input: String, expected: String) -> Nil {
  let start = timestamp.system_time()
  let actual = pii.strip(input)
  let elapsed =
    timestamp.difference(start, timestamp.system_time())
    |> duration.to_milliseconds
  actual |> should.equal(expected)
  should.be_true(elapsed < 1000)
}
