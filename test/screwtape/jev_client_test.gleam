//// VT-6: the Jev client (PHASE-12, T5; design § 5.2 `screwtape/jev/client`).
////
//// One POST to `base_url <> "/v1/systemone"` under a fixed response cap, then
//// the status mapping. The two 400 fixtures are spec-derived (see
//// `test/fixtures/jev/PROVENANCE.md`); every `Error` asserted here is compared
//// whole, so a non-2xx body carrying server text would fail the test.

import gleam/http as method
import gleam/http/response.{Response}
import gleam/json
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/classify/schema
import screwtape/error.{type Error, Auth, Http, LimitExceeded, RateLimited}
import screwtape/file
import screwtape/jev
import screwtape/jev/client
import support/cli_fixture
import support/fixture_send

pub fn main() -> Nil {
  gleeunit.main()
}

/// The bearer secret no `Error` here may render.
const secret = "SENTINEL-jev-client-0123456789abcdef"

const base_url = "https://jev.example.test"

const model = "typesafe/jev-1.14.0"

/// The URL the one POST goes to.
const url = base_url <> "/v1/systemone"

// ---------------------------------------------------------------- helpers

fn endpoint() -> client.Endpoint {
  client.Endpoint(base_url: base_url, model: model)
}

fn state() -> json.Json {
  json.object([
    #("from", json.string("sender@example.test")),
    #("subject", json.string("A subject")),
  ])
}

fn ok(status: Int, body: String) -> fixture_send.Reply {
  Ok(Response(status: status, headers: [], body: body))
}

fn status_reply(status: Int, body: String) -> fixture_send.Reply {
  ok(status, body)
}

/// The reply the one `ask` reads; the fixture is served by a `Post` position.
fn ask(
  reply: fixture_send.Reply,
) -> #(Result(jev.Reply, Error), fixture_send.Fixture) {
  let fixture = fixture_send.start([fixture_send.Step(method.Post, reply)])
  let result =
    client.ask(
      fixture_send.send(fixture),
      cli_fixture.token(secret),
      endpoint(),
      state(),
      schema.mail_1(),
    )
  #(result, fixture)
}

fn fixture(name: String) -> String {
  let assert Ok(text) = file.read_text("test/fixtures/jev/" <> name)
  text
}

fn ask_status(status: Int, body: String) -> Result(jev.Reply, Error) {
  ask(status_reply(status, body)).0
}

fn header(recorded: fixture_send.Recorded, name: String) -> String {
  case list.find(recorded.headers, fn(pair) { pair.0 == name }) {
    Ok(pair) -> pair.1
    Error(Nil) -> ""
  }
}

// ---------------------------------------------------------------- the request

pub fn request_shape_test() {
  let #(result, fixture) = ask(status_reply(200, fixture("mail-1-reply.json")))
  result |> should.be_ok
  let assert [recorded] = fixture_send.recorded(fixture)
  recorded.url |> should.equal(url)
  recorded.method |> should.equal(method.Post)
  recorded.cap |> should.equal(client.response_bytes)
  recorded.cap |> should.equal(65_536)
  recorded.body
  |> should.equal(jev.request_body(model, state(), schema.mail_1()))
}

pub fn request_headers_test() {
  let #(_, fixture) = ask(status_reply(200, fixture("mail-1-reply.json")))
  let assert [recorded] = fixture_send.recorded(fixture)
  header(recorded, "authorization") |> should.equal("Bearer " <> secret)
  header(recorded, "content-type") |> should.equal("application/json")
  header(recorded, "accept") |> should.equal("application/json")
}

// ---------------------------------------------------------------- the status

pub fn unauthorized_test() {
  ask_status(401, "") |> should.equal(Error(Auth(401)))
}

pub fn rate_limited_test() {
  ask_status(429, "") |> should.equal(Error(RateLimited))
}

pub fn other_status_test() {
  ask_status(529, "upstream is busy") |> should.equal(Error(Http("status_529")))
}

pub fn too_large_test() {
  ask_status(200, string.repeat("a", client.response_bytes + 1))
  |> should.equal(Error(LimitExceeded("jev_response_bytes")))
}

// ---------------------------------------------------------------- the context

pub fn context_400_fixture_test() {
  ask_status(400, fixture("max-tokens-exceeded-400.json"))
  |> should.equal(Error(LimitExceeded("jev_context")))
}

pub fn context_400_string_detail_test() {
  ask_status(400, "{\"detail\":\"max_tokens_exceeded\"}")
  |> should.equal(Error(LimitExceeded("jev_context")))
}

pub fn context_413_test() {
  ask_status(413, "request entity too large")
  |> should.equal(Error(LimitExceeded("jev_context")))
}

pub fn other_400_test() {
  ask_status(
    400,
    "{\"detail\":{\"code\":\"other_code\",\"message\":\"secret server text\"}}",
  )
  |> should.equal(Error(Http("status_400")))
}

pub fn unreadable_400_test() {
  ask_status(400, "not json, secret server text")
  |> should.equal(Error(Http("status_400")))
}

// ---------------------------------------------------------------- the reply

pub fn reply_test() {
  let #(result, _) = ask(status_reply(200, fixture("mail-1-reply.json")))
  let assert Ok(reply) = result
  reply.model |> should.equal("jev-1.14.0")
  reply.answers |> list.length |> should.equal(8)
}
