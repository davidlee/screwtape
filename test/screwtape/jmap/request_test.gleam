//// Contract tests for `screwtape/jmap/request` (PHASE-10, D5; VT-3).
////
//// The `Method` type is closed over the four JMAP methods of the scope, and
//// every method name in a request is produced by `method_name`. The body is
//// asserted by parsing the encoded JSON back into a concrete record, so the
//// wire shape is what is tested rather than an internal representation.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None}
import gleeunit
import gleeunit/should
import screwtape/jmap/request

pub fn main() -> Nil {
  gleeunit.main()
}

/// One decoded `methodCalls` entry, in the shape `Mailbox/get` sends.
type Call {
  Call(name: String, account_id: String, ids: Option(String), call_id: String)
}

pub fn method_name_covers_the_four_methods_test() {
  request.method_name(request.MailboxGet) |> should.equal("Mailbox/get")
  request.method_name(request.EmailQuery) |> should.equal("Email/query")
  request.method_name(request.EmailGet) |> should.equal("Email/get")
  request.method_name(request.ThreadGet) |> should.equal("Thread/get")
}

pub fn body_uses_both_capabilities_test() {
  request.body([])
  |> json.to_string
  |> using_urns()
  |> should.equal(["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"])
}

pub fn body_with_no_calls_has_no_method_calls_test() {
  request.body([])
  |> json.to_string
  |> calls()
  |> should.equal([])
}

pub fn mailbox_get_arguments_test() {
  [request.mailbox_get("acct-1", "c0")]
  |> request.body
  |> json.to_string
  |> calls()
  |> should.equal([Call("Mailbox/get", "acct-1", None, "c0")])
}

pub fn body_keeps_the_calls_in_order_test() {
  [request.mailbox_get("acct-1", "c0"), request.mailbox_get("acct-1", "c1")]
  |> request.body
  |> json.to_string
  |> calls()
  |> should.equal([
    Call("Mailbox/get", "acct-1", None, "c0"),
    Call("Mailbox/get", "acct-1", None, "c1"),
  ])
}

fn using_urns(text: String) -> List(String) {
  let assert Ok(urns) =
    json.parse(text, using: decode.at(["using"], decode.list(decode.string)))
  urns
}

fn calls(text: String) -> List(Call) {
  let assert Ok(calls) =
    json.parse(
      text,
      using: decode.at(["methodCalls"], decode.list(call_decoder())),
    )
  calls
}

fn call_decoder() -> decode.Decoder(Call) {
  decode.then(decode.at([0], decode.string), fn(name) {
    decode.then(
      decode.at([1], decode.at(["accountId"], decode.string)),
      fn(account_id) {
        decode.then(
          decode.at([1], decode.at(["ids"], decode.optional(decode.string))),
          fn(ids) {
            decode.then(decode.at([2], decode.string), fn(call_id) {
              decode.success(Call(name, account_id, ids, call_id))
            })
          },
        )
      },
    )
  })
}
