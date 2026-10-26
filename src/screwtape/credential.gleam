//// The bearer token, held so that only `bearer` can read it (PHASE-10, D3;
//// design § 5.2).
////
//// A `Token` wraps a closure over the secret rather than the secret itself, so
//// `string.inspect` renders `Token(//fn() { ... })` and a debug print — or an
//// `Error` carrying the value — shows nothing. The closure does not cover a
//// crash: no `let assert`, no `panic`, and no route that puts the secret into a
//// reason, in this module at all.
////
//// The file is read through `file:read_file/1` rather than a dependency (§ 10 is
//// pinned, A4). Its bytes never become an `Error`: bytes that are not UTF-8 are
//// as good as unreadable, so they read as `Credential("missing")`.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/string
import screwtape/error.{type Error, Credential}

pub opaque type Token {
  Token(reveal: fn() -> String)
}

/// Read `<dir>/<name>`, trim the surrounding whitespace and keep the rest.
///
/// Missing or unreadable → `Credential("missing")`; empty after the trim (a
/// whitespace-only file included) → `Credential("empty")`.
pub fn read(dir: String, name: String) -> Result(Token, Error) {
  case read_file(dir <> "/" <> name) {
    Ok(bytes) ->
      case bit_array.to_string(bytes) {
        Ok(text) -> token(text)
        // Not UTF-8: a secret we cannot read is a secret we do not have.
        Error(Nil) -> Error(Credential("missing"))
      }
    Error(_) -> Error(Credential("missing"))
  }
}

/// The one call to `reveal`, so the header value exists in as few frames as
/// possible (design § 5.2 crash rules).
pub fn bearer(token: Token) -> #(String, String) {
  #("authorization", "Bearer " <> token.reveal())
}

fn token(text: String) -> Result(Token, Error) {
  let secret = string.trim(text)
  case secret == "" {
    True -> Error(Credential("empty"))
    False -> Ok(Token(fn() { secret }))
  }
}

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)
