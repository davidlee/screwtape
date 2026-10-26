//// Contract tests for the production `Send` over `screwtape_http`
//// (PHASE-02, D2). Criteria: EX-1 (one httpc request, every failure mapped
//// onto `HttpFailure`), EX-3 / VT-1 (an oversized error body fails `TooLarge`
//// *while* `local_jmap` still withholds its end, both framings), EX-4 / VT-2
//// (a 503 with `Retry-After: 0` is exactly one request, plain or oversized).
////
//// The Erlang binding is declared here for now (D2); PHASE-10's cli owns the
//// production one. Requests are POSTed with a JSON body because JMAP uses
//// POST, and every call passes the server's per-run CA (`Some(ca_path)`).

import gleam/bit_array
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, get_header}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/jmap/client
import support/local_jmap

pub fn main() -> Nil {
  gleeunit.main()
}

/// The byte ceiling handed to `Send` as its cap (RV-001 F-29: positive).
const cap = 1024

/// Comfortably over `cap`, so a fixed-length or chunked body breaches it in
/// several whole chunks before the withheld end.
const oversized_body_bytes = 9216

/// Under `cap`, so a withheld end is the only way the client can hang.
const small_body_bytes = 64

/// Long enough that a buffer-then-check adapter would report `Timeout`
/// instead of `TooLarge` (VT-1's discriminating timeout).
const long_timeout_ms = 5000

/// Short, for the withheld-but-under-the-cap timeout test.
const short_timeout_ms = 300

/// A cap far above anything scripted, for tests that only care about routing.
const roomy_cap = 65_536

const retry_after_zero = #("retry-after", "0")

fn post_to(url: String) -> Request(String) {
  let assert Ok(req) = request.to(url)
  req
  |> request.set_method(http.Post)
  |> request.set_header("content-type", "application/json")
  |> request.set_body("{\"using\":[\"urn:ietf:params:jmap:core\"]}")
}

fn send_to(
  server: local_jmap.Server,
  cap: Int,
  timeout_ms: Int,
) -> Result(Response(String), client.HttpFailure) {
  send(
    post_to(local_jmap.url(server, "/jmap")),
    cap,
    timeout_ms,
    Some(server.ca_path),
  )
}

fn fixed_length(
  status: Int,
  headers: List(#(String, String)),
  body: String,
  withhold_end: Bool,
) -> local_jmap.Reply {
  local_jmap.Reply(
    status: status,
    headers: headers,
    framing: local_jmap.ContentLength,
    body: bit_array.from_string(body),
    withhold_end: withhold_end,
  )
}

fn chunked(
  status: Int,
  headers: List(#(String, String)),
  chunk_size: Int,
  body: String,
  withhold_end: Bool,
) -> local_jmap.Reply {
  local_jmap.Reply(
    status: status,
    headers: headers,
    framing: local_jmap.Chunked(chunk_size: chunk_size),
    body: bit_array.from_string(body),
    withhold_end: withhold_end,
  )
}

fn oversized_body() -> String {
  string.repeat("x", oversized_body_bytes)
}

fn small_body() -> String {
  string.repeat("y", small_body_bytes)
}

/// A fixed-length 500 whose body exceeds the cap and whose last byte is
/// withheld: the ceiling must reject on the headers, before any of it arrives.
pub fn fixed_length_500_too_large_while_withheld_test() {
  let server =
    local_jmap.start([
      fixed_length(500, [], oversized_body(), True),
    ])

  let result = send_to(server, cap, long_timeout_ms)
  let still_withholding = local_jmap.withholding(server)
  local_jmap.release(server)
  local_jmap.stop(server)

  result |> should.equal(Error(client.TooLarge))
  still_withholding |> should.be_true
}

/// The same ceiling with chunked framing: the chunk header past the cap must
/// fail it, not the withheld final chunk.
pub fn chunked_500_too_large_while_withheld_test() {
  let server =
    local_jmap.start([
      chunked(500, [], 512, oversized_body(), True),
    ])

  let result = send_to(server, cap, long_timeout_ms)
  let still_withholding = local_jmap.withholding(server)
  local_jmap.release(server)
  local_jmap.stop(server)

  result |> should.equal(Error(client.TooLarge))
  still_withholding |> should.be_true
}

/// VT-2: a 503 is returned as a response, not retried, even though a 200 is
/// queued behind it and OTP's default autoretry would reach for it.
pub fn retry_after_503_one_request_test() {
  let server =
    local_jmap.start([
      fixed_length(503, [retry_after_zero], small_body(), False),
      fixed_length(200, [], small_body(), False),
    ])

  let result = send_to(server, roomy_cap, long_timeout_ms)
  let count = local_jmap.request_count(server)
  local_jmap.stop(server)

  let assert Ok(response) = result
  count |> should.equal(1)
  response.status |> should.equal(503)
}

/// VT-2, the oversized half: the 503's body is over the cap, so it fails
/// `TooLarge` — still after exactly one request.
pub fn oversized_503_too_large_one_request_test() {
  let server =
    local_jmap.start([
      fixed_length(503, [retry_after_zero], oversized_body(), False),
      fixed_length(200, [], small_body(), False),
    ])

  let result = send_to(server, cap, long_timeout_ms)
  let count = local_jmap.request_count(server)
  local_jmap.stop(server)

  count |> should.equal(1)
  result |> should.equal(Error(client.TooLarge))
}

/// A success still looks like a success: status, body and a header (keys are
/// lowercase in gleam_http, D2).
pub fn ok_200_round_trip_test() {
  let server =
    local_jmap.start([
      fixed_length(200, [#("x-screwtape", "fixture")], "{\"ok\":true}", False),
    ])

  let result = send_to(server, cap, long_timeout_ms)
  local_jmap.stop(server)

  let assert Ok(response) = result
  response.status |> should.equal(200)
  response.body |> should.equal("{\"ok\":true}")
  get_header(response, "x-screwtape")
  |> should.equal(Ok("fixture"))
  list.key_find(response.headers, "x-screwtape")
  |> should.equal(Ok("fixture"))
}

/// A 2xx is capped like any other response: an oversized success body fails
/// `TooLarge` while the server still withholds its end.
pub fn oversized_200_too_large_while_withheld_test() {
  let server =
    local_jmap.start([
      fixed_length(200, [], oversized_body(), True),
    ])

  let result = send_to(server, cap, long_timeout_ms)
  let still_withholding = local_jmap.withholding(server)
  local_jmap.release(server)
  local_jmap.stop(server)

  result |> should.equal(Error(client.TooLarge))
  still_withholding |> should.be_true
}

/// A body beyond ASCII survives the round trip byte for byte: `body_format`
/// binary is kept, so nothing re-encodes it into a longer form.
pub fn ok_200_non_ascii_body_round_trip_test() {
  let server =
    local_jmap.start([
      local_jmap.Reply(
        status: 200,
        headers: [],
        framing: local_jmap.ContentLength,
        body: <<"caf", 0xC3, 0xA9>>,
        withhold_end: False,
      ),
    ])

  let result = send_to(server, cap, long_timeout_ms)
  local_jmap.stop(server)

  let assert Ok(response) = result
  response.status |> should.equal(200)
  response.body |> should.equal("café")
  response.body
  |> bit_array.from_string
  |> bit_array.byte_size
  |> should.equal(5)
}

/// I1: a followed redirect would re-send the authorization header, so a 301
/// is returned as-is. `/other` resolves against the same server, where a
/// followed request would show up in the count (and meet the spent script).
pub fn redirect_301_not_followed_test() {
  let server =
    local_jmap.start([
      fixed_length(301, [#("location", "/other")], "moved", False),
      fixed_length(200, [], small_body(), False),
    ])

  let result = send_to(server, roomy_cap, long_timeout_ms)
  let count = local_jmap.request_count(server)
  local_jmap.stop(server)

  let assert Ok(response) = result
  count |> should.equal(1)
  response.status |> should.equal(301)
}

/// The CA that signed the peer's certificate is not the one we trust: TLS
/// verification must fail rather than fall back to the system store.
pub fn untrusted_ca_tls_failed_test() {
  let untrusted = local_jmap.start([fixed_length(200, [], "nope", False)])
  let trusted = local_jmap.start([fixed_length(200, [], "nope", False)])

  let result =
    send(
      post_to(local_jmap.url(untrusted, "/jmap")),
      roomy_cap,
      long_timeout_ms,
      Some(trusted.ca_path),
    )
  local_jmap.stop(untrusted)
  local_jmap.stop(trusted)

  result |> should.equal(Error(client.TlsFailed))
}

/// A CA file that cannot be read is a TLS verdict, not a connect failure:
/// httpc reports it as `{options, ...}` before the socket ever matters.
pub fn missing_ca_file_tls_failed_test() {
  let server = local_jmap.start([fixed_length(200, [], "nope", False)])

  let result =
    send(
      post_to(local_jmap.url(server, "/jmap")),
      roomy_cap,
      long_timeout_ms,
      Some("/nonexistent/ca.pem"),
    )
  local_jmap.stop(server)

  result |> should.equal(Error(client.TlsFailed))
}

/// `None` means the system store (DEC-018). The per-run CA is not in it, so
/// verification must fail instead of silently trusting what is installed.
pub fn system_cas_reject_local_ca_tls_failed_test() {
  let server = local_jmap.start([fixed_length(200, [], "nope", False)])

  let result =
    send(
      post_to(local_jmap.url(server, "/jmap")),
      roomy_cap,
      long_timeout_ms,
      None,
    )
  local_jmap.stop(server)

  result |> should.equal(Error(client.TlsFailed))
}

/// Nothing is listening on the port any more: a connection failure, not a
/// timeout and not a TLS verdict. The CA comes from a second live server, so
/// this is not the missing-file case by accident.
pub fn closed_port_connect_failed_test() {
  let server = local_jmap.start([fixed_length(200, [], "gone", False)])
  let url = local_jmap.url(server, "/jmap")
  local_jmap.stop(server)

  let live = local_jmap.start([fixed_length(200, [], "still here", False)])
  let ca_path = live.ca_path

  let result = send(post_to(url), roomy_cap, long_timeout_ms, Some(ca_path))
  local_jmap.stop(live)

  result |> should.equal(Error(client.ConnectFailed))
}

/// Under the cap, so no ceiling applies; the withheld end can only surface as
/// the timeout.
pub fn withheld_under_cap_times_out_test() {
  let server =
    local_jmap.start([
      fixed_length(200, [], small_body(), True),
    ])

  let result = send_to(server, roomy_cap, short_timeout_ms)
  let still_withholding = local_jmap.withholding(server)
  let count = local_jmap.request_count(server)
  local_jmap.release(server)
  local_jmap.stop(server)

  result |> should.equal(Error(client.Timeout))
  still_withholding |> should.be_true
  count |> should.equal(1)
}

/// A body that is not UTF-8 cannot become a `Response(String)`; it is a
/// failure of its own rather than a crash in the caller.
pub fn invalid_utf8_body_bad_utf8_test() {
  let server =
    local_jmap.start([
      local_jmap.Reply(
        status: 200,
        headers: [],
        framing: local_jmap.ContentLength,
        body: <<0xff, 0xfe, 0xfd>>,
        withhold_end: False,
      ),
    ])

  let result = send_to(server, cap, long_timeout_ms)
  local_jmap.stop(server)

  result |> should.equal(Error(client.BadUtf8))
}

/// D2: the Erlang adapter's entry point, one synchronous httpc request.
@external(erlang, "screwtape_http", "send")
fn send(
  req: Request(String),
  cap: Int,
  timeout_ms: Int,
  ca_file: Option(String),
) -> Result(Response(String), client.HttpFailure)
