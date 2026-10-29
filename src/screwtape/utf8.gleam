//// UTF-8 string helpers: prefixes cut on codepoint boundaries, and the one
//// shared budget spend (design § 5.6).
////
//// Pure, and this module imports only `gleam_stdlib` (invariant I5, enforced
//// by `just check-imports`), so it cannot do I/O.

import gleam/list
import gleam/string

/// The longest prefix of `text` whose UTF-8 byte size is at most `budget`, cut
/// between codepoints so no sequence is split.
pub fn prefix(text: String, budget: Int) -> String {
  text
  |> string.to_utf_codepoints
  |> keep_codepoints(budget, [])
  |> string.from_utf_codepoints
}

fn keep_codepoints(
  codepoints: List(UtfCodepoint),
  remaining: Int,
  kept: List(UtfCodepoint),
) -> List(UtfCodepoint) {
  case codepoints {
    [] -> list.reverse(kept)
    [codepoint, ..rest] -> {
      let width = utf8_width(string.utf_codepoint_to_int(codepoint))
      case width <= remaining {
        True -> keep_codepoints(rest, remaining - width, [codepoint, ..kept])
        False -> list.reverse(kept)
      }
    }
  }
}

/// The budget left after `text` under `remaining`: its byte size, capped at
/// what remains. The caller chooses what is charged: `render.read` passes the
/// uncut text, so a cut spends everything; `classify/state` passes the text it
/// kept, so bytes a cut gave back go to the next body.
pub fn spend(text: String, remaining: Int) -> Int {
  let size = string.byte_size(text)
  case size < remaining {
    True -> remaining - size
    False -> 0
  }
}

/// A codepoint's width in UTF-8 bytes.
fn utf8_width(codepoint: Int) -> Int {
  case codepoint < 0x80 {
    True -> 1
    False ->
      case codepoint < 0x800 {
        True -> 2
        False ->
          case codepoint < 0x1_0000 {
            True -> 3
            False -> 4
          }
      }
  }
}
