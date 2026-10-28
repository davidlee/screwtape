//// The JMAP client over an injected `http.Send` (design § 5.2, DEC-006).
//// The transport types and the status and failure mappings live in
//// `screwtape/http`; this module keeps the budget and the one JMAP branch — a
//// non-2xx `Http(...)` whose body reads as a problem document.
////
//// `session` fetches the session document with the bearer token and binds a
//// `Client` to it; `call` posts one JMAP request to the session's own `apiUrl`
//// and decodes the method responses. Both go through one private exchange, so
//// the `Budget` exists once: an exhausted budget refuses the request before it
//// is sent (a cap of 0 crashes httpc, RV-001 F-29), each request is capped at
//// the bytes still allowed, and every response body is charged — whatever its
//// status — before the status is acted on.
////
//// The budget is a value the client threads: a successful `call` hands back
//// the client with the bytes it received taken off. A failed request ends the
//// run (EX-2), so its charge needs no later reader. A `Send` failure carries no
//// request and no transport reason, and no `Error` raised here carries server
//// text, a request or the token.

import gleam/http as method
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import screwtape/credential.{type Token}
import screwtape/error.{type Error}
import screwtape/http
import screwtape/jmap/decode.{type MethodResponse, type Session}
import screwtape/jmap/request as jmap_request

/// The response bytes a run may still receive, across every request.
pub opaque type Budget {
  Budget(remaining: Int)
}

/// A client bound to a decoded session, its token and the budget left.
pub opaque type Client {
  Client(send: http.Send, token: Token, session: Session, budget: Budget)
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
  send: http.Send,
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
    |> request.set_method(method.Post)
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
// charge the received body, then map the status. The status mapping is
// `screwtape/http`'s; only a non-2xx `Http(...)` gives the body a second
// reading, as a JMAP problem document.

fn exchange(
  send: http.Send,
  token: Token,
  req: Request(String),
  budget: Budget,
) -> Result(#(Response(String), Budget), Error) {
  let cap = remaining(budget)
  case cap <= 0 {
    True -> Error(error.LimitExceeded("max_total_bytes"))
    False -> {
      use response <- result.try(
        send(authorized(req, token), cap)
        |> result.map_error(http.failure(_, "max_total_bytes")),
      )
      let budget = charge(budget, response)
      case http.status(response) {
        Ok(ok_response) -> Ok(#(ok_response, budget))
        Error(error.Http(reason)) ->
          case decode.problem(response.body) {
            Ok(type_) -> Error(error.JmapRequest(type_))
            Error(Nil) -> Error(error.Http(reason))
          }
        Error(other) -> Error(other)
      }
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

fn session_request(url: String) -> Result(Request(String), Nil) {
  request.to(url)
  |> result.map(fn(req) { request.set_method(req, method.Get) })
}
