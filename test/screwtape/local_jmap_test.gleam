//// Self-tests for `local_jmap` (PHASE-02/EX-2, DEC-018).
////
//// The client here is plain httpc: `verify_peer` against the per-run CA, no
//// `max_body_size`, no retry or timeout tuning. That is the point — these
//// tests characterise the *server* (script order, both framings, the request
//// count, and a body end that only the test releases), not the production
//// adapter that PHASE-02/T4 builds on top.

import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import support/local_jmap

pub fn main() -> Nil {
  gleeunit.main()
}

/// Status, headers and body as httpc saw them.
type Fetch =
  #(Int, List(#(String, String)), String)

/// The Erlang reference of a request still in flight.
type Pending

fn fetch(server: local_jmap.Server) -> Result(Fetch, String) {
  http_get(local_jmap.url(server, "/jmap"), server.ca_path)
}

/// httpc does not promise a case for header names, so look them up that way.
fn header(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  headers
  |> list.find(fn(pair) { string.lowercase(pair.0) == string.lowercase(name) })
  |> result.map(fn(pair) { pair.1 })
}

/// A body long enough that framing mistakes show, but cheap to compare.
fn body() -> String {
  string.repeat("scripted response body. ", 30)
}

/// Wait for the server to reach its release receive. `await` returning `None`
/// only says the client has no body yet, not that the server has registered as
/// withholding, so the two are separate waits; the spin is short and bounded.
fn wait_until_withholding(
  server: local_jmap.Server,
  remaining_ms: Int,
) -> Bool {
  case local_jmap.withholding(server) {
    True -> True
    False if remaining_ms <= 0 -> False
    False -> {
      process.sleep(5)
      wait_until_withholding(server, remaining_ms - 5)
    }
  }
}

fn scripted(
  framing: local_jmap.Framing,
  withhold_end: Bool,
) -> local_jmap.Reply {
  local_jmap.Reply(
    status: 200,
    headers: [#("X-Screwtape", "fixture")],
    framing: framing,
    body: bit_array.from_string(body()),
    withhold_end: withhold_end,
  )
}

pub fn status_and_header_arrive_test() {
  let server = local_jmap.start([scripted(local_jmap.ContentLength, False)])
  let fetched = fetch(server)
  local_jmap.stop(server)

  let assert Ok(#(status, headers, received)) = fetched
  status |> should.equal(200)
  header(headers, "x-screwtape") |> should.equal(Ok("fixture"))
  received |> should.equal(body())
}

pub fn content_length_body_decodes_whole_test() {
  let server = local_jmap.start([scripted(local_jmap.ContentLength, False)])
  let fetched = fetch(server)
  local_jmap.stop(server)

  let assert Ok(#(_status, _headers, received)) = fetched
  received |> should.equal(body())
}

pub fn chunked_body_decodes_whole_test() {
  let server =
    local_jmap.start([scripted(local_jmap.Chunked(chunk_size: 16), False)])
  let fetched = fetch(server)
  local_jmap.stop(server)

  let assert Ok(#(_status, _headers, received)) = fetched
  received |> should.equal(body())
}

/// Replies go out in script order and every request is counted, including one
/// the script no longer covers (which gets a bare 500).
pub fn request_count_counts_every_request_test() {
  let server =
    local_jmap.start([
      scripted(local_jmap.ContentLength, False),
      scripted(local_jmap.Chunked(chunk_size: 64), False),
    ])
  let first = fetch(server)
  let second = fetch(server)
  let after_script = local_jmap.request_count(server)
  let third = fetch(server)
  let after_overflow = local_jmap.request_count(server)
  local_jmap.stop(server)

  let assert Ok(_) = first
  let assert Ok(_) = second
  after_script |> should.equal(2)
  let assert Ok(#(status, _headers, _received)) = third
  status |> should.equal(500)
  after_overflow |> should.equal(3)
}

/// A Content-Length body missing its last byte does not complete; `release`
/// delivers it, and `withholding` reports the whole interval.
pub fn withheld_content_length_body_waits_for_release_test() {
  let server =
    local_jmap.start([
      scripted(local_jmap.ContentLength, True),
    ])
  let pending = http_get_async(local_jmap.url(server, "/jmap"), server.ca_path)

  // Wait until the server is really holding the last byte back, then give the
  // client 200 ms — many loopback round trips — to prove it is still open.
  wait_until_withholding(server, 5000) |> should.be_true
  await(pending, 200) |> should.equal(None)

  local_jmap.release(server)
  let fetched = await(pending, 5000)
  let still_withholding = local_jmap.withholding(server)
  local_jmap.stop(server)

  let assert Some(Ok(#(_status, _headers, received))) = fetched
  received |> should.equal(body())
  still_withholding |> should.be_false
}

/// The same, with the final chunk and the `0\r\n\r\n` terminator withheld.
pub fn withheld_chunked_body_waits_for_release_test() {
  let server =
    local_jmap.start([
      scripted(local_jmap.Chunked(chunk_size: 16), True),
    ])
  let pending = http_get_async(local_jmap.url(server, "/jmap"), server.ca_path)

  wait_until_withholding(server, 5000) |> should.be_true
  await(pending, 200) |> should.equal(None)

  local_jmap.release(server)
  let fetched = await(pending, 5000)
  let still_withholding = local_jmap.withholding(server)
  local_jmap.stop(server)

  let assert Some(Ok(#(_status, _headers, received))) = fetched
  received |> should.equal(body())
  still_withholding |> should.be_false
}

/// The plain httpc client and the in-flight plumbing are local_tls_ffi's, the
/// same ones skeleton_test drives.
@external(erlang, "local_tls_ffi", "http_get")
fn http_get(url: String, ca_path: String) -> Result(Fetch, String)

@external(erlang, "local_tls_ffi", "http_get_async")
fn http_get_async(url: String, ca_path: String) -> Pending

/// `None` means still in flight; the reply is not consumed, so a later `await`
/// still receives it.
@external(erlang, "local_tls_ffi", "await")
fn await(pending: Pending, timeout_ms: Int) -> Option(Result(Fetch, String))
