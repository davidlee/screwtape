//// Reading a whole file as text (PHASE-10, A4).
////
//// There is no file dependency in the pinned set (§ 10), so the read goes
//// through `file:read_file/1`. This module is the one place that external
//// lives: `credential` and `cli` both read through here, so a missing file and
//// a file whose bytes are not UTF-8 are one outcome (`Error(Nil)`) turned into
//// each caller's own `Error` — neither carries a path or any of the contents.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}

/// The file at `path` as UTF-8 text, or `Error(Nil)` when it cannot be read or
/// its bytes are not UTF-8.
pub fn read_text(path: String) -> Result(String, Nil) {
  case read_file(path) {
    Ok(bytes) -> bit_array.to_string(bytes)
    Error(_) -> Error(Nil)
  }
}

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)
