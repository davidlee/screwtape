//// The JMAP client over an injected `Send` (design § 5.2, DEC-006).
////
//// `session` fetches the session document with the bearer token and binds a
//// `Client` to it; `call` posts one JMAP request to the session's own `apiUrl`
//// and decodes the method responses. Both go through one private exchange, so
//// the `Budget` and the status mapping exist once: an exhausted budget refuses
//// the request before it is sent (a cap of 0 crashes httpc, RV-001 F-29), each
//// request is capped at the bytes still allowed, and every response body is
//// charged — whatever its status — before the status is acted on.
////
//// The budget is a value the client threads: a successful `call` hands back
//// the client with the bytes it received taken off. A failed request ends the
//// run (EX-2), so its charge needs no later reader. A `Send` failure carries no
//// request and no transport reason, and no `Error` raised here carries server
//// text, a request or the token.

import gleam/http.{Get, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import screwtape/credential.{type Token}
import screwtape/error.{type Error}
import screwtape/jmap/decode.{type MethodResponse, type Session}
import screwtape/jmap/request as jmap_request

/// Why a request produced no response. No variant carries the request or a
/// transport reason, either of which could hold the bearer token.
pub type HttpFailure {
  Timeout
  ConnectFailed
  TlsFailed
  BadUtf8
  TooLarge
}

/// The second argument caps the response body bytes this call may receive;
/// it must be positive (RV-001 F-29).
pub type Send =
  fn(Request(String), Int) -> Result(Response(String), HttpFailure)

/// The response bytes a run may still receive, across every request.
pub opaque type Budget {
  Budget(remaining: Int)
}

/// A client bound to a decoded session, its token and the budget left.
pub opaque type Client {
  Client(send: Send, token: Token, session: Session, budget: Budget)
}

/// A budget of `max_total_bytes` response bytes for a run.
pub fn budget(max_total_bytes: Int) -> Budget {
  Budget(max_total_bytes)
}

/// The response bytes still allowed under `max_total_bytes`.
pub fn remaining(budget: Budget) -> Int {
  budget.remaining
}

/// Fetch the session at `url` and bind a client to it. A URL we cannot parse is
/// `Config("session_url")`; the body must decode as a session.
pub fn session(
  send: Send,
  token: Token,
  url: String,
  budget: Budget,
) -> Result(Client, Error) {
  use req <- result.try(
    session_request(url)
    |> result.map_error(fn(_) { error.Config("session_url") }),
  )
  use #(response, budget) <- result.try(exchange(send, token, req, budget))
  use session <- result.try(decode.session(response.body))
  Ok(Client(send:, token:, session:, budget:))
}

/// Post `calls` to the session's `apiUrl` and decode the method responses. An
/// `apiUrl` we cannot parse is `Decode("apiUrl")`; the client handed back
/// carries the same budget, now short of this response's bytes. Response i
/// answers call i: an unequal count, or a response whose call id is not its
/// call's, is `Decode("methodResponses")`.
pub fn call(
  client: Client,
  calls: List(jmap_request.Invocation),
) -> Result(#(Client, List(MethodResponse)), Error) {
  use req <- result.try(
    request.to(client.session.api_url)
    |> result.map_error(fn(_) { error.Decode("apiUrl") }),
  )
  let req =
    req
    |> request.set_method(Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(json.to_string(jmap_request.body(calls)))
  use #(response, budget) <- result.try(exchange(
    client.send,
    client.token,
    req,
    client.budget,
  ))
  let names = jmap_request.call_names(calls)
  let call_ids = list.map(names, fn(call) { call.0 })
  use responses <- result.try(decode.method_responses(response.body, names))
  case list.map(responses, fn(response) { response.call_id }) == call_ids {
    True -> Ok(#(Client(..client, budget:), responses))
    False -> Error(error.Decode("methodResponses"))
  }
}

/// Post the one call `invocation` and answer its one response. `call` already
/// refuses any other count; the fallback keeps the match total.
pub fn call_one(
  client: Client,
  invocation: jmap_request.Invocation,
) -> Result(#(Client, MethodResponse), Error) {
  use #(client, responses) <- result.try(call(client, [invocation]))
  case responses {
    [response] -> Ok(#(client, response))
    _ -> Error(error.Decode("methodResponses"))
  }
}

/// The session the client is bound to.
pub fn session_of(client: Client) -> Session {
  client.session
}

/// The budget left after the client's last successful exchange.
pub fn budget_of(client: Client) -> Budget {
  client.budget
}

// The one exchange: refuse an exhausted budget, send under the bytes left,
// charge the received body, then map the status.

fn exchange(
  send: Send,
  token: Token,
  req: Request(String),
  budget: Budget,
) -> Result(#(Response(String), Budget), Error) {
  let cap = remaining(budget)
  case cap <= 0 {
    True -> Error(error.LimitExceeded("max_total_bytes"))
    False -> {
      use response <- result.try(
        send(authorized(req, token), cap) |> result.map_error(send_failure),
      )
      let budget = charge(budget, response)
      use response <- result.map(status(response))
      #(response, budget)
    }
  }
}

/// The headers every request carries: the bearer token, and the accept that
/// every JMAP answer is JSON. The token is revealed here, once per request.
fn authorized(req: Request(String), token: Token) -> Request(String) {
  let #(name, value) = credential.bearer(token)
  req
  |> request.set_header(name, value)
  |> request.set_header("accept", "application/json")
}

/// A body was received, so its bytes are spent — whatever the status, and
/// before the status is acted on.
fn charge(budget: Budget, response: Response(String)) -> Budget {
  Budget(budget.remaining - string.byte_size(response.body))
}

/// D2: 2xx is the call's; 401/403 are `Auth`; 429 is `RateLimited`; any other
/// non-2xx is the JMAP problem document's type, else its status as `Http`.
fn status(response: Response(String)) -> Result(Response(String), Error) {
  let code = response.status
  case code >= 200 && code < 300 {
    True -> Ok(response)
    False ->
      case code {
        401 | 403 -> Error(error.Auth(code))
        429 -> Error(error.RateLimited)
        _ ->
          case decode.problem(response.body) {
            Ok(type_) -> Error(error.JmapRequest(type_))
            Error(Nil) -> Error(error.Http("status_" <> int.to_string(code)))
          }
      }
  }
}

/// A transport failure is a fixed reason; `TooLarge` is the budget's ceiling,
/// not the transport's.
fn send_failure(failure: HttpFailure) -> Error {
  case failure {
    Timeout -> error.Http("timeout")
    ConnectFailed -> error.Http("connect_failed")
    TlsFailed -> error.Http("tls_failed")
    BadUtf8 -> error.Http("bad_utf8")
    TooLarge -> error.LimitExceeded("max_total_bytes")
  }
}

fn session_request(url: String) -> Result(Request(String), Nil) {
  request.to(url)
  |> result.map(fn(req) { request.set_method(req, Get) })
}
