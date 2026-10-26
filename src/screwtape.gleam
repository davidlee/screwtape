//// The process entry point. Deliberately minimal (phase sheet D1): PHASE-10
//// replaces the body with the real CLI dispatch; PHASE-01 only needs a process
//// the tests can spawn that exercises the FFI edge (EX-4, VT-2).
////
//// The externals live here rather than in a `screwtape/ffi` wrapper because
//// this file is their only caller: a wrapper would add a module without hiding
//// anything.

@external(erlang, "screwtape_ffi", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "screwtape_ffi", "silence_logger")
fn silence_logger() -> Nil

@external(erlang, "screwtape_ffi", "guard")
fn guard(body: fn() -> a) -> a

pub fn main() -> Nil {
  // Before anything else runs: an OTP report from a crash can print memory
  // that holds the bearer token (design § 5.2).
  silence_logger()
  // The body PHASE-10 replaces. Anything raised inside it exits 1 with a single
  // internal-error line and no reason, so a token in the reason cannot leak.
  guard(fn() { Nil })
  halt(0)
}
