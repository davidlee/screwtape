//// The JMAP request body (PHASE-10, D5; design § 5.2).
////
//// `Method` is closed over the four methods of the scope and is the only source
//// of a JMAP method name: `Invocation` is opaque, so every call is built inside
//// this module from a `Method` (invariant I6). `method_name` is the one place
//// the wire spellings live.
////
//// Every request carries both capabilities of the scope. PHASE-05 adds the
//// Email/Thread argument builders; the closed `Method` already covers all four.

import gleam/function
import gleam/json
import gleam/list

/// The capabilities every request declares in `using`. They are the same URNs
/// `decode` reads the session under, so they live here once.
pub const core_capability = "urn:ietf:params:jmap:core"

pub const mail_capability = "urn:ietf:params:jmap:mail"

/// The JMAP methods of the scope, and no others.
pub type Method {
  MailboxGet
  EmailQuery
  EmailGet
  ThreadGet
}

/// The wire name of a method; produced only from a `Method`.
pub fn method_name(method: Method) -> String {
  case method {
    MailboxGet -> "Mailbox/get"
    EmailQuery -> "Email/query"
    EmailGet -> "Email/get"
    ThreadGet -> "Thread/get"
  }
}

/// One method call. Opaque: an invocation cannot be built outside this module,
/// so a method name cannot enter a request except through `Method` (I6).
pub opaque type Invocation {
  Invocation(method: Method, arguments: json.Json, call_id: String)
}

/// `Mailbox/get` with `ids: null`, which fetches every mailbox and its `state`.
pub fn mailbox_get(account_id: String, call_id: String) -> Invocation {
  Invocation(
    method: MailboxGet,
    arguments: json.object([
      #("accountId", json.string(account_id)),
      #("ids", json.null()),
    ]),
    call_id: call_id,
  )
}

/// The request document: `{using, methodCalls}`.
pub fn body(calls: List(Invocation)) -> json.Json {
  json.object([
    #("using", json.array([core_capability, mail_capability], json.string)),
    #("methodCalls", json.array(calls, encode_call)),
  ])
}

/// Each call's id and method name, in request order: what
/// `decode.method_responses` needs to attribute an error entry to the method
/// that produced the call it answers.
pub fn call_names(calls: List(Invocation)) -> List(#(String, String)) {
  list.map(calls, fn(invocation) {
    #(invocation.call_id, method_name(invocation.method))
  })
}

fn encode_call(invocation: Invocation) -> json.Json {
  json.array(
    [
      json.string(method_name(invocation.method)),
      invocation.arguments,
      json.string(invocation.call_id),
    ],
    function.identity,
  )
}
