//// A scripted `Send` for the client contract tests (SL-001 PHASE-10, EX-1).
////
//// `start` takes a script of `Step` entries, served one per request by position.
//// A `Step` matches by HTTP method; an `Expect` matches a POST by the JMAP method
//// its first call names, so a test can script by method name and position.
//// Every request is recorded — method, URL, headers, body and the cap the caller
//// passed — before it is answered, so a test can assert how many requests
//// arrived, what cap the client asked for and which header it sent.
////
//// `recorded_calls` reads the first JMAP call of each recorded body back, in
//// arrival order, `calls_of` every call of one request, and `ids_of` is a
//// call's `ids` argument. `unmatched_count` counts
//// the requests no position answered, including those after the script ran out.
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

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{type Method, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri
import screwtape/jmap/client
import screwtape/jmap/request as jmap_request

/// What one position answers with.
pub type Reply =
  Result(Response(String), client.HttpFailure)

/// One scripted position. `Step` matches by HTTP method only; `Expect` matches a
/// POST by the JMAP method its first call names.
pub type Step {
  Step(method: Method, reply: Reply)
  Expect(call: jmap_request.Method, reply: Reply)
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

/// One call a request carried: its method name, arguments and call id, as
/// parsed from an entry of `methodCalls`.
pub type RecordedCall {
  RecordedCall(name: String, arguments: Dynamic, call_id: String)
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

/// The calls the client sent, in arrival order. A request whose body is not a
/// JMAP request document (the session GET) contributes nothing.
pub fn recorded_calls(fixture: Fixture) -> List(RecordedCall) {
  fixture
  |> recorded
  |> list.filter_map(fn(request) {
    case call_of(request.body) {
      Some(call) -> Ok(call)
      None -> Error(Nil)
    }
  })
}

/// Every call `request` carried, in order (`recorded_calls` reads only the
/// first of each request).
pub fn calls_of(request: Recorded) -> List(RecordedCall) {
  calls_in(request.body)
}

/// How many requests no scripted position matched, including those that
/// arrived after the script ran out.
pub fn unmatched_count(fixture: Fixture) -> Int {
  fixture
  |> recorded
  |> list.filter(fn(request) { !request.matched })
  |> list.length
}

/// The `ids` argument of a call: empty when absent or null.
pub fn ids_of(call: RecordedCall) -> List(String) {
  case
    decode.run(call.arguments, decode.at(["ids"], decode.list(decode.string)))
  {
    Ok(ids) -> ids
    Error(_) -> []
  }
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
        [step, ..rest] -> {
          let matched = matches(step, request)
          let reply = case step {
            Step(_, reply) | Expect(_, reply) -> reply
          }
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

fn matches(step: Step, received: Recorded) -> Bool {
  case step {
    Step(method:, ..) -> method == received.method
    Expect(call:, ..) ->
      case received.method == Post, call_of(received.body) {
        True, Some(recorded) -> recorded.name == jmap_request.method_name(call)
        _, _ -> False
      }
  }
}

fn call_of(body: String) -> Option(RecordedCall) {
  case calls_in(body) {
    [call, ..] -> Some(call)
    [] -> None
  }
}

/// Every entry of a request body's `methodCalls`, in order; nothing for a body
/// that is not a JMAP request document.
fn calls_in(body: String) -> List(RecordedCall) {
  let entry = {
    use name <- decode.then(decode.at([0], decode.string))
    use arguments <- decode.then(decode.at([1], decode.dynamic))
    use call_id <- decode.then(decode.at([2], decode.string))
    decode.success(RecordedCall(name:, arguments:, call_id:))
  }
  case json.parse(body, using: decode.at(["methodCalls"], decode.list(entry))) {
    Ok(calls) -> calls
    Error(_) -> []
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
