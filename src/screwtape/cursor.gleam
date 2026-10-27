//// The arrival cursor: an opaque position in `(received_at_ms, id)` order
//// that a consumer holds between `--after` pages (C2, C3).
////
//// Pure, and this module imports only `gleam_stdlib` (invariant I5, enforced
//// by `just check-imports`), so it cannot do I/O.

import gleam/int
import gleam/result
import gleam/string

/// `Start` is before every message; `After` is just past the message with this
/// arrival instant and id.
pub type Cursor {
  Start
  After(received_at_ms: Int, id: String)
}

/// The bounds `received_at_ms` must lie within: SQLite's signed 64-bit range,
/// beyond which a value cannot be bound.
const min_ms = -9_223_372_036_854_775_808

const max_ms = 9_223_372_036_854_775_807

/// The cursor just past the message with this arrival instant and id.
pub fn of(received_at_ms: Int, id: String) -> Cursor {
  After(received_at_ms, id)
}

/// `""` for `Start`, otherwise `"<ms>:<id>"`.
pub fn to_string(cursor: Cursor) -> String {
  case cursor {
    Start -> ""
    After(received_at_ms, id) -> int.to_string(received_at_ms) <> ":" <> id
  }
}

/// The cursor `text` spells, split at the first `:`. Only canonical text is
/// accepted: `parse(text)` is `Ok(c)` only when `to_string(c) == text`, so
/// `+05:x` and `007:x` are refused (C3).
pub fn parse(text: String) -> Result(Cursor, Nil) {
  case text {
    "" -> Ok(Start)
    _ -> {
      use #(raw_ms, id) <- result.try(string.split_once(text, ":"))
      use ms <- result.try(int.parse(raw_ms))
      let cursor = After(ms, id)
      case id != "" && in_int64(ms) && to_string(cursor) == text {
        True -> Ok(cursor)
        False -> Error(Nil)
      }
    }
  }
}

fn in_int64(ms: Int) -> Bool {
  ms >= min_ms && ms <= max_ms
}
