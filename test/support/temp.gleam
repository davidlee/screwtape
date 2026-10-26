//// Temporary directories and files for tests (PHASE-01/EX-7).
////
//// Everything lives under `TMPDIR` (falling back to `/tmp`), so the Nix build
//// sandbox stays clean; names carry a unique integer and the OS pid so
//// concurrent runs cannot collide.
////
//// A file written through `write` is mode 8#600, like the empty files
//// `temp_ffi:file/1` makes. `temp_ffi` also serves `local_tls_ffi` and
//// `subprocess_ffi` directly, which is why its empty-file and delete functions
//// have no Gleam wrapper here.

/// Create a fresh temporary directory and return its path.
pub fn dir(prefix: String) -> String {
  dir_ffi(prefix)
}

/// Delete a temporary directory and everything in it.
pub fn remove_dir(path: String) -> Nil {
  remove_dir_ffi(path)
}

/// Write `content` to `path`, replacing any file already there, and set the
/// mode to 8#600. A path that cannot be written crashes the test here.
pub fn write(path: String, content: BitArray) -> Nil {
  write_ffi(path, content)
}

@external(erlang, "temp_ffi", "dir")
fn dir_ffi(prefix: String) -> String

@external(erlang, "temp_ffi", "remove_dir")
fn remove_dir_ffi(path: String) -> Nil

@external(erlang, "temp_ffi", "write")
fn write_ffi(path: String, content: BitArray) -> Nil
