//// The Jev client over an injected `http.Send` (PHASE-12, T5; design § 5.2).
////
//// `ask` makes one POST to `base_url <> "/v1/systemone"` with the bearer token
//// and the request body from `screwtape/jev`, under a fixed response cap —
//// answers are small. The transport types and the status mapping live in
//// `screwtape/http`; this module keeps only the one Jev branch: a request that
//// exceeded the model's context window. Per DEC-039 a 400 decides that branch
//// in exactly two ways: direct Jev's `detail.error_type`, or the LLM gateway's
//// `error.message` holding that code as JSON text. The branch is decided by
//// comparison only, against a body that never becomes an `Error`; every other
//// non-2xx answer is its status alone.

import gleam/dynamic/decode
import gleam/http as method
import gleam/http/request.{type Request}
import gleam/json.{type Json}
import gleam/result
import gleam/string
import screwtape/credential.{type Token}
import screwtape/error.{type Error}
import screwtape/http
import screwtape/jev

/// The response bytes one answer may occupy: answers are small.
pub const response_bytes = 65_536

/// Where one Jev deployment lives, and the model a reply must report.
pub type Endpoint {
  Endpoint(base_url: String, model: String)
}

/// The error code that means the request exceeded the model's context window.
const context_code = "max_tokens_exceeded"

/// The same code inside the JSON text the LLM gateway (LiteLLM) leaves in
/// `error.message`: the double quotes and no spaces are part of the match.
const gateway_context_literal = "\"error_type\":\"" <> context_code <> "\""

/// Post `state` and `questions` to the endpoint and decode the reply. A URL we
/// cannot parse is `Config("jev_url")`; a transport failure is `http.failure`'s;
/// a 413, or a 400 that DEC-039 recognises as the context-window error, is
/// `LimitExceeded("jev_context")`; any other 400 is `Http("status_400")`.
pub fn ask(
  send: http.Send,
  token: Token,
  endpoint: Endpoint,
  state: Json,
  questions: List(jev.Question),
) -> Result(jev.Reply, Error) {
  use req <- result.try(
    request.to(endpoint.base_url <> "/v1/systemone")
    |> result.map_error(fn(_) { error.Config("jev_url") }),
  )
  let req =
    req
    |> request.set_method(method.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(jev.request_body(endpoint.model, state, questions))
  use response <- result.try(
    send(authorized(req, token), response_bytes)
    |> result.map_error(http.failure(_, "jev_response_bytes")),
  )
  case response.status {
    413 -> Error(error.LimitExceeded("jev_context"))
    400 ->
      case max_tokens_exceeded(response.body) {
        True -> Error(error.LimitExceeded("jev_context"))
        False -> Error(error.Http("status_400"))
      }
    _ -> {
      use ok_response <- result.try(http.status(response))
      jev.reply(ok_response.body, questions, endpoint.model)
    }
  }
}

/// The headers every request carries: the bearer token and the accept that
/// every Jev answer is JSON. The token is revealed here, once per request.
fn authorized(req: Request(String), token: Token) -> Request(String) {
  let #(name, value) = credential.bearer(token)
  req
  |> request.set_header(name, value)
  |> request.set_header("accept", "application/json")
}

/// Whether the body is the context-window error, per DEC-039: direct Jev puts
/// the code at `detail.error_type`, and the LLM gateway keeps Jev's error only
/// as text inside `error.message`. Either location matches, independently. Each
/// is read as a string and compared — never returned — so a body's own text
/// cannot reach an `Error`.
fn max_tokens_exceeded(body: String) -> Bool {
  let direct =
    decode.at(["detail", "error_type"], decode.string)
    |> decode.map(fn(code) { code == context_code })
  let gateway =
    decode.at(["error", "message"], decode.string)
    |> decode.map(fn(message) {
      string.contains(message, gateway_context_literal)
    })
  matches(body, direct) || matches(body, gateway)
}

/// Run one recognition against the body: it matches only when the decoder
/// succeeds with `True`, so a failed shape or an unreadable body is `False`.
fn matches(body: String, decoder: decode.Decoder(Bool)) -> Bool {
  case json.parse(body, using: decoder) {
    Ok(found) -> found
    Error(_) -> False
  }
}
