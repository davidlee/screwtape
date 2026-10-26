//// Test support: run a subprocess with stdout and stderr captured separately.
////
//// `open_port` cannot split a child's two output streams, so `subprocess_ffi`
//// routes stderr into a temp file through `/bin/sh` and reads it back after
//// `exit_status`; stdout comes back over the port as bytes.
////
//// Nothing here skips silently. A missing erlang-shipment fails the calling
//// test with the paths that were searched (phase sheet R1): a skipped control
//// is a false green.
////
//// `erl_eval` runs an Erlang expression against the *shipped* modules
//// (`erl -noshell -pa <shipment>/*/ebin -eval <expr>`), so the FFI under test
//// is the artifact that ships, without adding test hooks to production code.

import gleam/list
import gleam/string

/// Exit status plus the two streams, kept apart. `stdout` stays bytes so a
/// test can compare it exactly; `stderr` is text because it is asserted as a
/// line.
pub type Record {
  Record(exit_code: Int, stdout: BitArray, stderr: String)
}

/// Why a subprocess could not be run at all. A non-zero `exit_code` is not a
/// failure: it is the result under test.
pub type Failure {
  /// No shipment directory; the list holds every path that was searched.
  ShipmentNotFound(searched: List(String))
  /// The shipment exists but its `<app>/ebin` directories do not.
  ShippedCodeUnreadable(shipment: String, reason: String)
  /// `erl` is not on PATH.
  ErlNotFound
  /// `open_port` or the temp file failed.
  SpawnFailed(reason: String)
}

/// Runs `executable` with `args`, collecting stdout and stderr separately.
pub fn run(executable: String, args: List(String)) -> Result(Record, Failure) {
  case run_ffi(executable, args) {
    Ok(#(exit_code, stdout, stderr)) -> Ok(Record(exit_code, stdout, stderr))
    Error(reason) -> Error(SpawnFailed(reason))
  }
}

/// Runs an Erlang expression with every shipped ebin on the code path.
pub fn erl_eval(expression: String) -> Result(Record, Failure) {
  case shipment_dir() {
    Error(failure) -> Error(failure)
    Ok(shipment) ->
      case ebin_dirs(shipment) {
        Error(reason) -> Error(ShippedCodeUnreadable(shipment, reason))
        Ok([]) ->
          Error(ShippedCodeUnreadable(
            shipment,
            "no <app>/ebin directories found",
          ))
        Ok(ebins) ->
          case erl_path() {
            Error(failure) -> Error(failure)
            Ok(erl) ->
              run(
                erl,
                list.append(
                  ["-noshell", "-pa"],
                  list.append(ebins, ["-eval", expression]),
                ),
              )
          }
      }
  }
}

/// `$SCREWTAPE_SHIPMENT` when set, else `build/erlang-shipment` when it
/// exists, else an error naming both. Never a silent skip.
pub fn shipment_dir() -> Result(String, Failure) {
  case getenv("SCREWTAPE_SHIPMENT") {
    Ok(dir) -> shipped_code(dir)
    Error(Nil) -> shipped_code("build/erlang-shipment")
  }
}

fn shipped_code(dir: String) -> Result(String, Failure) {
  case is_dir(dir) {
    True -> Ok(dir)
    False -> Error(ShipmentNotFound([dir]))
  }
}

/// The shipment's own entry point; later phases spawn `entrypoint(shipment)`
/// with `["run"]` (phase sheet R1, D2).
pub fn entrypoint(shipment: String) -> String {
  shipment <> "/entrypoint.sh"
}

/// A human-readable failure, meant to be the message of a test panic.
pub fn failure_message(failure: Failure) -> String {
  case failure {
    ShipmentNotFound(searched) ->
      "erlang-shipment not found: looked in "
      <> string.join(searched, ", ")
      <> " (build it with `just test`, or set SCREWTAPE_SHIPMENT)"
    ShippedCodeUnreadable(shipment, reason) ->
      "cannot use the erlang-shipment at " <> shipment <> ": " <> reason
    ErlNotFound -> "cannot find `erl` on PATH"
    SpawnFailed(reason) -> "cannot run subprocess: " <> reason
  }
}

fn erl_path() -> Result(String, Failure) {
  case find_executable("erl") {
    Ok(path) -> Ok(path)
    Error(Nil) -> Error(ErlNotFound)
  }
}

@external(erlang, "subprocess_ffi", "run")
fn run_ffi(
  executable: String,
  args: List(String),
) -> Result(#(Int, BitArray, String), String)

@external(erlang, "subprocess_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "subprocess_ffi", "is_dir")
fn is_dir(path: String) -> Bool

@external(erlang, "subprocess_ffi", "ebin_dirs")
fn ebin_dirs(dir: String) -> Result(List(String), String)

@external(erlang, "subprocess_ffi", "find_executable")
fn find_executable(name: String) -> Result(String, Nil)
