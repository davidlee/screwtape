//// VT-6: the Jev client (PHASE-12, T5; design § 5.2 `screwtape/jev/client`).
////
//// One POST to `base_url <> "/v1/systemone"` under a fixed response cap, then
//// the status mapping. The reply fixture is recorded; the 400 fixtures are the
//// recorded gateway envelope and the direct body derived from its
//// `error.message` (see `test/fixtures/jev/PROVENANCE.md`); every `Error`
//// asserted here is compared whole, so a non-2xx body carrying server text
//// would fail the test.

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
      schema.mail_2(),
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

/// A 400 body shaped like the LLM gateway's envelope (LiteLLM), carrying
/// `message` verbatim.
fn gateway_envelope(message: String) -> String {
  json.object([
    #(
      "error",
      json.object([
        #("message", json.string(message)),
        #("type", json.string("invalid_request_error")),
        #("param", json.null()),
        #("code", json.string("400")),
      ]),
    ),
  ])
  |> json.to_string
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
  |> should.equal(jev.request_body(model, state(), schema.mail_2()))
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

pub fn context_400_gateway_fixture_test() {
  ask_status(400, fixture("max-tokens-exceeded-400.gateway.json"))
  |> should.equal(Error(LimitExceeded("jev_context")))
}

pub fn context_400_direct_fixture_test() {
  ask_status(400, fixture("max-tokens-exceeded-400.direct.json"))
  |> should.equal(Error(LimitExceeded("jev_context")))
}

pub fn gateway_message_without_the_literal_400_test() {
  ask_status(
    400,
    gateway_envelope("litellm.BadRequestError: secret server text"),
  )
  |> should.equal(Error(Http("status_400")))
}

pub fn gateway_message_with_bare_code_400_test() {
  ask_status(
    400,
    gateway_envelope("litellm.BadRequestError: max_tokens_exceeded"),
  )
  |> should.equal(Error(Http("status_400")))
}

/// DEC-039 recognises either location, so a body carrying both shapes matches:
/// an unmatched `detail.error_type` must not mask the gateway's message.
pub fn both_shapes_gateway_match_400_test() {
  let body =
    json.object([
      #("detail", json.object([#("error_type", json.string("other_code"))])),
      #(
        "error",
        json.object([
          #(
            "message",
            json.string(
              "litellm.BadRequestError: {\"detail\":{\"error_type\":\"max_tokens_exceeded\"}}",
            ),
          ),
        ]),
      ),
    ])
    |> json.to_string
  ask_status(400, body) |> should.equal(Error(LimitExceeded("jev_context")))
}

pub fn non_object_400_test() {
  ask_status(400, "[]") |> should.equal(Error(Http("status_400")))
}

pub fn other_error_type_400_test() {
  ask_status(400, "{\"detail\":{\"error_type\":\"other_code\"}}")
  |> should.equal(Error(Http("status_400")))
}

pub fn string_detail_400_test() {
  ask_status(400, "{\"detail\":\"max_tokens_exceeded\"}")
  |> should.equal(Error(Http("status_400")))
}

pub fn detail_code_400_test() {
  ask_status(400, "{\"detail\":{\"code\":\"max_tokens_exceeded\"}}")
  |> should.equal(Error(Http("status_400")))
}

pub fn gateway_body_500_test() {
  ask_status(500, fixture("max-tokens-exceeded-400.gateway.json"))
  |> should.equal(Error(Http("status_500")))
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
