//// The one `Error` type's two renderings (PHASE-10, D1): the stderr JSON line
//// and the process exit code. Every payload is a fixed string, an int or a
//// method name — never server text or request data — so a line can be asserted
//// exactly.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/error.{
  Auth, Config, Credential, Decode, Http, JmapMethod, JmapRequest, LimitExceeded,
  QueryUnstable, RateLimited, Store, Usage,
}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn to_json_line_jmap_method_test() {
  JmapMethod("Email/get", "serverFail")
  |> error.to_json_line
  |> should.equal(
    "{\"level\":\"error\",\"error\":\"jmap_method\",\"method\":\"Email/get\",\"type\":\"serverFail\"}",
  )
}

pub fn to_json_line_config_test() {
  Config("empty_mailboxes")
  |> error.to_json_line
  |> should.equal(
    "{\"level\":\"error\",\"error\":\"config\",\"reason\":\"empty_mailboxes\"}",
  )
}

pub fn to_json_line_auth_test() {
  Auth(401)
  |> error.to_json_line
  |> should.equal("{\"level\":\"error\",\"error\":\"auth\",\"status\":401}")
}

pub fn to_json_line_no_fields_test() {
  RateLimited
  |> error.to_json_line
  |> should.equal("{\"level\":\"error\",\"error\":\"rate_limited\"}")
  QueryUnstable
  |> error.to_json_line
  |> should.equal("{\"level\":\"error\",\"error\":\"query_unstable\"}")
}

pub fn to_json_line_other_variants_test() {
  Credential("missing")
  |> error.to_json_line
  |> should.equal(
    "{\"level\":\"error\",\"error\":\"credential\",\"reason\":\"missing\"}",
  )
  Http("timeout")
  |> error.to_json_line
  |> should.equal(
    "{\"level\":\"error\",\"error\":\"http\",\"reason\":\"timeout\"}",
  )
  JmapRequest("no_mail_capability")
  |> error.to_json_line
  |> should.equal(
    "{\"level\":\"error\",\"error\":\"jmap_request\",\"type\":\"no_mail_capability\"}",
  )
  Decode("methodResponses[0][1].list[2].id")
  |> error.to_json_line
  |> should.equal(
    "{\"level\":\"error\",\"error\":\"decode\",\"path\":\"methodResponses[0][1].list[2].id\"}",
  )
  LimitExceeded("max_total_bytes")
  |> error.to_json_line
  |> should.equal(
    "{\"level\":\"error\",\"error\":\"limit_exceeded\",\"bound\":\"max_total_bytes\"}",
  )
  Store("schema_mismatch")
  |> error.to_json_line
  |> should.equal(
    "{\"level\":\"error\",\"error\":\"store\",\"reason\":\"schema_mismatch\"}",
  )
  Usage("unknown_verb")
  |> error.to_json_line
  |> should.equal(
    "{\"level\":\"error\",\"error\":\"usage\",\"reason\":\"unknown_verb\"}",
  )
}

pub fn to_json_line_no_trailing_newline_test() {
  let line = error.to_json_line(RateLimited)
  line
  |> string.ends_with("\n")
  |> should.be_false
  line
  |> string.contains("\n")
  |> should.be_false
}

pub fn exit_code_usage_and_config_are_two_test() {
  error.exit_code(Usage("unknown_verb")) |> should.equal(2)
  error.exit_code(Config("invalid_json")) |> should.equal(2)
}

pub fn exit_code_runtime_failures_are_one_test() {
  error.exit_code(Credential("missing")) |> should.equal(1)
  error.exit_code(Http("status_500")) |> should.equal(1)
  error.exit_code(Auth(403)) |> should.equal(1)
  error.exit_code(RateLimited) |> should.equal(1)
  error.exit_code(JmapRequest("no_mail_capability")) |> should.equal(1)
  error.exit_code(JmapMethod("Email/get", "serverFail")) |> should.equal(1)
  error.exit_code(Decode("session")) |> should.equal(1)
  error.exit_code(LimitExceeded("max_pages")) |> should.equal(1)
  error.exit_code(QueryUnstable) |> should.equal(1)
  error.exit_code(Store("no_snapshot")) |> should.equal(1)
}

// The shared decode-failure helper (PHASE-12, T2).

pub fn decode_failure_names_indices_and_fields_test() {
  let data = dynamic.list([dynamic.string("x"), dynamic.int(1)])
  let assert Error(errors) = decode.run(data, decode.list(decode.int))
  error.decode_failure(errors, "data.bodies")
  |> should.equal(Decode("data.bodies[0]"))
}

pub fn decode_failure_drops_the_leading_dot_test() {
  let assert Error(errors) =
    decode.run(
      dynamic.properties([#(dynamic.string("subject"), dynamic.int(1))]),
      decode.at(["subject"], decode.string),
    )
  error.decode_failure(errors, "")
  |> should.equal(Decode("subject"))
}

pub fn decode_failure_at_the_root_is_dollar_test() {
  let assert Error(errors) = decode.run(dynamic.string("x"), decode.int)
  error.decode_failure(errors, "") |> should.equal(Decode("$"))
}
