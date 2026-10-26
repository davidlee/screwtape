//// The process entry point: the one place that writes and exits (PHASE-10,
//// D7). `main` silences the logger, runs `cli.run` inside `guard/1`, writes the
//// outcome it returns, and halts with its exit code; the CLI itself does none
//// of those, so every command case can be a plain function call.
////
//// The order is the token-leak containment of design § 5.2: the logger goes
//// quiet before anything can crash, and the body runs in a process the guard
//// owns, so no crash inside it — and no reason it carries — reaches stderr.
//// Silence and guard are the only two effects that must happen here; a document
//// is printed through `io.print` so that halt's flush writes a byte-complete
//// document, and each stderr line through `io.println_error`.
////
//// The externals live here rather than in a `screwtape/ffi` wrapper because
//// this file is their only caller: a wrapper would add a module without hiding
//// anything.

import argv
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import screwtape/cli

@external(erlang, "screwtape_ffi", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "screwtape_ffi", "silence_logger")
fn silence_logger() -> Nil

@external(erlang, "screwtape_ffi", "guard")
fn guard(body: fn() -> a) -> a

@external(erlang, "screwtape_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

pub fn main() -> Nil {
  // Before anything else runs: an OTP report from a crash can print memory
  // that holds the bearer token (design § 5.2).
  silence_logger()
  // A crash in here writes one internal-error line and exits 1, never the
  // reason.
  let outcome = guard(fn() { cli.run(argv.load().arguments, getenv) })
  halt(write(outcome))
}

/// Write what the outcome holds — one document, then one line per error — and
/// answer its exit code.
fn write(outcome: cli.Outcome) -> Int {
  case outcome.stdout {
    None -> Nil
    Some(document) -> io.print(document <> "\n")
  }
  list.each(outcome.stderr, io.println_error)
  outcome.exit_code
}
