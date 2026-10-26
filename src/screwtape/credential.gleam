//// The bearer token, held so that only `bearer` can read it (PHASE-10, D3;
//// design § 5.2).
////
//// A `Token` wraps a closure over the secret rather than the secret itself, so
//// `string.inspect` renders `Token(//fn() { ... })` and a debug print — or an
//// `Error` carrying the value — shows nothing. The closure does not cover a
//// crash: no `let assert`, no `panic`, and no route that puts the secret into a
//// reason, in this module at all.
////
//// The file is read through `screwtape/file`, which reaches `file:read_file/1`
//// rather than a dependency (§ 10 is pinned, A4). Its bytes never become an
//// `Error`: bytes that are not UTF-8 are as good as unreadable, so they read as
//// `Credential("missing")`.

import gleam/list
import gleam/string
import screwtape/error.{type Error, Credential}
import screwtape/file

pub opaque type Token {
  Token(reveal: fn() -> String)
}

/// Read `<dir>/<name>`, trim the surrounding whitespace and keep the rest.
///
/// Missing or unreadable → `Credential("missing")`; empty after the trim (a
/// whitespace-only file included) → `Credential("empty")`; a control byte left
/// after the trim (< 0x20 or 0x7f, which would corrupt the header) →
/// `Credential("invalid")`.
pub fn read(dir: String, name: String) -> Result(Token, Error) {
  case file.read_text(dir <> "/" <> name) {
    Ok(text) -> token(text)
    Error(Nil) -> Error(Credential("missing"))
  }
}

/// The one call to `reveal`, so the header value exists in as few frames as
/// possible (design § 5.2 crash rules).
pub fn bearer(token: Token) -> #(String, String) {
  #("authorization", "Bearer " <> token.reveal())
}

fn token(text: String) -> Result(Token, Error) {
  let secret = string.trim(text)
  case secret == "", has_control_byte(secret) {
    True, _ -> Error(Credential("empty"))
    _, True -> Error(Credential("invalid"))
    False, False -> Ok(Token(fn() { secret }))
  }
}

fn has_control_byte(text: String) -> Bool {
  text
  |> string.to_utf_codepoints
  |> list.any(fn(codepoint) {
    let code = string.utf_codepoint_to_int(codepoint)
    code < 0x20 || code == 0x7f
  })
}
