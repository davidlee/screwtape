//// EX-4 / VT-2: the main/FFI edge, exercised against the shipped modules.
////
//// Each test runs Erlang code through `support/subprocess.erl_eval`, which
//// puts the erlang-shipment's `<app>/ebin` directories on the code path. That
//// is the deliberate reading of D2 for EX-4: the behaviour under test is
//// `screwtape_ffi` as it ships, while the shipment's own `entrypoint.sh run`
//// main path is exercised by the later subprocess test.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import support/subprocess

pub fn subprocess_runs_erl_test() {
  // Self-test of the helper: no screwtape module involved.
  let record =
    unwrap(subprocess.erl_eval("io:put_chars(\"ok\"), erlang:halt(0)"))
  assert_exit(record, 0, "helper self-test")
  record.stdout |> should.equal(<<"ok">>)
  record.stderr |> should.equal("")
}

pub fn halt_flushes_large_stdout_test() {
  // ~4.6 MiB (>= 4 MiB) of deterministic JSON, written immediately before
  // halt(0). Asserted on bytes, never on timing (R2).
  let count = 700_000
  let expression =
    "io:put_chars([$[ , lists:join($,, [integer_to_list(I) || I <- lists:seq(0, "
    <> int.to_string(count - 1)
    <> ")]), $]]), screwtape_ffi:halt(0)"
  let expected =
    "["
    <> string.join(
      list.index_map(list.repeat(Nil, count), fn(_, index) {
        int.to_string(index)
      }),
      ",",
    )
    <> "]"

  should.be_true(string.byte_size(expected) >= 4 * 1024 * 1024)

  let record = unwrap(subprocess.erl_eval(expression))
  assert_exit(record, 0, "halt flush")
  bit_array.byte_size(record.stdout)
  |> should.equal(string.byte_size(expected))
  record.stdout |> should.equal(bit_array.from_string(expected))
}

pub fn guard_emits_internal_error_line_test() {
  let record =
    unwrap(subprocess.erl_eval(
      "screwtape_ffi:silence_logger(), screwtape_ffi:guard(fun() -> erlang:error(boom) end)",
    ))
  assert_exit(record, 1, "guard/error")
  record.stdout |> should.equal(<<>>)
  record.stderr
  |> should.equal("{\"level\":\"error\",\"error\":\"internal\"}\n")
}

pub fn guard_emits_internal_error_line_on_throw_test() {
  let record =
    unwrap(subprocess.erl_eval(
      "screwtape_ffi:silence_logger(), screwtape_ffi:guard(fun() -> throw(boom) end)",
    ))
  assert_exit(record, 1, "guard/throw")
  record.stdout |> should.equal(<<>>)
  record.stderr
  |> should.equal("{\"level\":\"error\",\"error\":\"internal\"}\n")
}

pub fn guard_emits_internal_error_line_on_exit_test() {
  let record =
    unwrap(subprocess.erl_eval(
      "screwtape_ffi:silence_logger(), screwtape_ffi:guard(fun() -> exit(boom) end)",
    ))
  assert_exit(record, 1, "guard/exit")
  record.stdout |> should.equal(<<>>)
  record.stderr
  |> should.equal("{\"level\":\"error\",\"error\":\"internal\"}\n")
}

pub fn guard_contains_a_linked_process_crash_test() {
  // A crash in a process linked to the guarded body must stop outside the
  // top-level process: gleam's generated wrapper does not trap exits, so an
  // exit signal there prints the reason (a bearer token, in production) to
  // stderr. `trap_exit` is turned off explicitly to match that wrapper.
  let expression =
    "erlang:process_flag(trap_exit, false), "
    <> "screwtape_ffi:silence_logger(), "
    <> "screwtape_ffi:guard(fun() -> "
    <> "spawn_link(fun() -> exit({leak, \"SENTINEL-LINK\"}) end), "
    <> "timer:sleep(2000), "
    <> "ok "
    <> "end), "
    <> "screwtape_ffi:halt(0)"
  let record = unwrap(subprocess.erl_eval(expression))
  assert_exit(record, 1, "guard/linked exit")
  record.stdout |> should.equal(<<>>)
  record.stderr
  |> should.equal("{\"level\":\"error\",\"error\":\"internal\"}\n")
  assert_no_sentinel(record, "SENTINEL")
}

pub fn guard_does_not_leak_a_raised_reason_test() {
  // The reason itself carries the sentinel: no part of it may be printed.
  let record =
    unwrap(subprocess.erl_eval(
      "screwtape_ffi:silence_logger(), screwtape_ffi:guard(fun() -> erlang:error({leak, \"SENTINEL-RAISE\"}) end)",
    ))
  assert_exit(record, 1, "guard/raise sentinel")
  record.stdout |> should.equal(<<>>)
  record.stderr
  |> should.equal("{\"level\":\"error\",\"error\":\"internal\"}\n")
  assert_no_sentinel(record, "SENTINEL")
}

pub fn guard_returns_the_fun_value_test() {
  let record =
    unwrap(subprocess.erl_eval(
      "io:put_chars(integer_to_list(screwtape_ffi:guard(fun() -> 42 end))), screwtape_ffi:halt(0)",
    ))
  assert_exit(record, 0, "guard/return")
  record.stdout |> should.equal(<<"42">>)
  record.stderr |> should.equal("")
}

// The logger's handler may be asynchronous, so both cases give it time to
// write before halting; the control proves the silenced case is not vacuous.
const log_then_halt = "logger:error(\"leak\"), timer:sleep(200), erlang:halt(0)"

pub fn logger_writes_without_silence_control_test() {
  let record = unwrap(subprocess.erl_eval(log_then_halt))
  assert_exit(record, 0, "logger control")
  let output = bit_array.to_string(record.stdout) |> should.be_ok
  string.contains(output <> record.stderr, "leak") |> should.be_true
}

pub fn silence_logger_suppresses_otp_logs_test() {
  let record =
    unwrap(subprocess.erl_eval(
      "screwtape_ffi:silence_logger(), " <> log_then_halt,
    ))
  assert_exit(record, 0, "silence_logger")
  record.stdout |> should.equal(<<>>)
  record.stderr |> should.equal("")
}

fn unwrap(result: Result(a, subprocess.Failure)) -> a {
  case result {
    Ok(value) -> value
    Error(failure) -> {
      let message = subprocess.failure_message(failure)
      panic as message
    }
  }
}

fn assert_no_sentinel(record: subprocess.Record, sentinel: String) -> Nil {
  let stdout = bit_array.to_string(record.stdout) |> should.be_ok
  string.contains(stdout <> record.stderr, sentinel) |> should.be_false
}

fn assert_exit(record: subprocess.Record, expected: Int, label: String) -> Nil {
  case record.exit_code == expected {
    True -> Nil
    False -> fail_exit(record, expected, label)
  }
}

fn fail_exit(record: subprocess.Record, expected: Int, label: String) -> Nil {
  let message =
    label
    <> ": expected exit "
    <> int.to_string(expected)
    <> ", got "
    <> int.to_string(record.exit_code)
    <> "\nstderr: "
    <> record.stderr
  panic as message
}
