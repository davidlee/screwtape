//// A scripted `Send` for the client contract tests (SL-001 PHASE-10, EX-1).
////
//// `start` takes a script of `Step(method, reply)` entries, served one per
//// request by position. Every request is recorded — method, URL, headers, body
//// and the cap the caller passed — before it is answered, so a test can assert
//// how many requests arrived, what cap the client asked for and which header it
//// sent.
////
//// The cap is honoured as the real `Send` honours it: a reply body whose
//// `string.byte_size` exceeds the cap is not returned, the call fails
//// `Error(TooLarge)`.
////
//// A request whose method does not match its position, or one that arrives after
//// the script is spent, consumes the position (or nothing), is recorded with
//// `matched: False`, and is answered with an empty `500`. The client maps that to
//// `Error(Http("status_500"))`, so a wrong call shows up in the client's result
//// as well as in the recording.

import gleam/erlang/process
import gleam/http.{type Method}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/list
import gleam/string
import gleam/uri
import screwtape/jmap/client

/// What one position answers with.
pub type Reply =
  Result(Response(String), client.HttpFailure)

/// One scripted position: the method it expects and the reply it gives.
pub type Step {
  Step(method: Method, reply: Reply)
}

/// One received request as the client sent it, and whether its method matched
/// the position it was served from.
pub type Recorded {
  Recorded(
    method: Method,
    url: String,
    headers: List(#(String, String)),
    body: String,
    cap: Int,
    matched: Bool,
  )
}

pub opaque type Fixture {
  Fixture(state: process.Subject(Message))
}

type Message {
  Posted(reply_to: process.Subject(Reply), request: Recorded)
  Read(reply_to: process.Subject(List(Recorded)))
}

/// Start a scripted `Send`; entries are served in order, one per request.
pub fn start(script: List(Step)) -> Fixture {
  let ready = process.new_subject()
  let _ =
    process.spawn(fn() {
      let state = process.new_subject()
      process.send(ready, state)
      loop(state, script, [])
    })
  let assert Ok(state) = process.receive(ready, 1000)
  Fixture(state)
}

/// The `Send` to hand to `client.session` and `client.call`.
pub fn send(fixture: Fixture) -> client.Send {
  fn(request: Request(String), cap: Int) -> Reply {
    let recorded =
      Recorded(
        method: request.method,
        url: request.to_uri(request) |> uri.to_string,
        headers: request.headers,
        body: request.body,
        cap: cap,
        matched: False,
      )
    process.call(fixture.state, 1000, fn(reply_to) {
      Posted(reply_to: reply_to, request: recorded)
    })
  }
}

/// Every request received, in arrival order.
pub fn recorded(fixture: Fixture) -> List(Recorded) {
  process.call(fixture.state, 1000, Read)
}

/// How many requests the client sent.
pub fn request_count(fixture: Fixture) -> Int {
  fixture |> recorded |> list.length
}

/// The caps the client passed, in arrival order.
pub fn caps(fixture: Fixture) -> List(Int) {
  fixture |> recorded |> list.map(fn(request) { request.cap })
}

fn loop(
  state: process.Subject(Message),
  script: List(Step),
  seen: List(Recorded),
) -> Nil {
  case process.receive_forever(state) {
    Read(reply_to) -> {
      process.send(reply_to, list.reverse(seen))
      loop(state, script, seen)
    }
    Posted(reply_to:, request:) ->
      case script {
        [Step(expected, reply), ..rest] -> {
          let matched = expected == request.method
          let answer = case matched {
            True -> capped(reply, request.cap)
            False -> unmatched()
          }
          process.send(reply_to, answer)
          loop(state, rest, [Recorded(..request, matched: matched), ..seen])
        }
        [] -> {
          process.send(reply_to, unmatched())
          loop(state, [], [request, ..seen])
        }
      }
  }
}

fn unmatched() -> Reply {
  Ok(Response(status: 500, headers: [], body: ""))
}

fn capped(reply: Reply, cap: Int) -> Reply {
  case reply {
    Ok(response) ->
      case string.byte_size(response.body) > cap {
        True -> Error(client.TooLarge)
        False -> Ok(response)
      }
    Error(_) -> reply
  }
}
