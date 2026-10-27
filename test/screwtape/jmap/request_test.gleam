//// Contract tests for `screwtape/jmap/request` (PHASE-10, D5; VT-3).
////
//// The `Method` type is closed over the JMAP methods of the scope, and
//// every method name in a request is produced by `method_name`. The body is
//// asserted by parsing the encoded JSON back into a concrete record, so the
//// wire shape is what is tested rather than an internal representation.

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some, unwrap}
import gleam/string
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

pub fn method_name_covers_the_methods_test() {
  request.method_name(request.MailboxGet) |> should.equal("Mailbox/get")
  request.method_name(request.EmailQuery) |> should.equal("Email/query")
  request.method_name(request.EmailGet) |> should.equal("Email/get")
  request.method_name(request.ThreadGet) |> should.equal("Thread/get")
  request.method_name(request.EmailChanges)
  |> should.equal("Email/changes")
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

/// The client needs each call id paired with the method that was sent, in the
/// order the calls went out, so an error entry can name its method.
pub fn call_names_pairs_each_call_in_order_test() {
  [request.mailbox_get("acct-1", "c0"), request.mailbox_get("acct-1", "c1")]
  |> request.call_names
  |> should.equal([#("c0", "Mailbox/get"), #("c1", "Mailbox/get")])
}

pub fn call_names_of_no_calls_is_empty_test() {
  request.call_names([]) |> should.equal([])
}

/// Every builder names its own method, and `call_names` reports that name for
/// each call id: a builder that sent another method would be attributed to the
/// wrong one on an error entry.
pub fn call_names_name_each_builder_test() {
  [
    request.mailbox_get("acct-1", "c0"),
    request.email_query(
      "acct-1",
      request.email_query_filter(["mb-1"], None),
      0,
      None,
      "c1",
    ),
    request.email_get("acct-1", ["m1"], 1024, "c2"),
    request.thread_get("acct-1", ["t1"], "c3"),
  ]
  |> request.call_names
  |> should.equal([
    #("c0", request.method_name(request.MailboxGet)),
    #("c1", request.method_name(request.EmailQuery)),
    #("c2", request.method_name(request.EmailGet)),
    #("c3", request.method_name(request.ThreadGet)),
  ])
}

/// One mailbox still gets an `OR` wrapper: a bare `inMailbox` object would be
/// a different filter from the one `query_state` stores, so the same window
/// must encode identically however many mailboxes it names.
pub fn email_query_filter_wraps_even_one_mailbox_in_or_test() {
  request.email_query_filter(["mb-1"], None)
  |> decode_filter
  |> should.equal(or([in_mailbox("mb-1")]))
}

/// The mailboxes appear as `inMailbox` conditions in the order given: a
/// filter that sorted or deduplicated them would query a different set.
pub fn email_query_filter_lists_each_mailbox_in_order_test() {
  request.email_query_filter(["mb-1", "mb-2"], None)
  |> decode_filter
  |> should.equal(or([in_mailbox("mb-1"), in_mailbox("mb-2")]))
}

/// An age bound nests the OR inside an AND with `after`, so the window reads
/// "in these mailboxes and received after this instant"; a builder that put
/// `after` beside the OR at the top level would filter differently.
pub fn email_query_filter_nests_after_in_and_test() {
  request.email_query_filter(["mb-1"], Some("2026-09-26T09:00:00Z"))
  |> decode_filter
  |> should.equal(
    Filter(operator: Some("AND"), in_mailbox: None, after: None, conditions: [
      or([in_mailbox("mb-1")]),
      after("2026-09-26T09:00:00Z"),
    ]),
  )
}

/// The page is asked from `position`, newest first, threads uncollapsed and
/// `total` calculated; a builder that dropped `calculateTotal` would make the
/// run's stop condition unreadable.
pub fn email_query_arguments_test() {
  let sent =
    sent(request.email_query(
      "acct-1",
      request.email_query_filter(["mb-1"], None),
      5,
      Some(3),
      "c0",
    ))

  sent.name |> should.equal(request.method_name(request.EmailQuery))
  sent.call_id |> should.equal("c0")
  field(sent.arguments, "accountId", decode.string) |> should.equal("acct-1")
  field(sent.arguments, "filter", filter_decoder())
  |> should.equal(or([in_mailbox("mb-1")]))
  field(sent.arguments, "sort", decode.list(sort_decoder()))
  |> should.equal([Sort("receivedAt", False)])
  field(sent.arguments, "collapseThreads", decode.bool) |> should.be_false
  field(sent.arguments, "position", decode.int) |> should.equal(5)
  field(sent.arguments, "calculateTotal", decode.bool) |> should.be_true
  optional_int(sent.arguments, "limit") |> should.equal(Some(3))
}

/// Without a known page size the `limit` key is absent, not null: a server
/// that saw `null` would reject the argument.
pub fn email_query_omits_limit_when_unknown_test() {
  let sent =
    sent(request.email_query(
      "acct-1",
      request.email_query_filter(["mb-1"], None),
      0,
      None,
      "c0",
    ))

  optional_int(sent.arguments, "limit") |> should.equal(None)
  decode.run(sent.arguments, decode.at(["limit"], decode.dynamic))
  |> should.be_error
}

/// The content call asks for exactly the properties the model reads, fetches
/// text body values under the part cap, and names each part property; a
/// builder missing `fetchTextBodyValues` would get no body text at all.
pub fn email_get_arguments_test() {
  let sent = sent(request.email_get("acct-1", ["m1", "m2"], 4096, "c0"))

  sent.name |> should.equal(request.method_name(request.EmailGet))
  sent.call_id |> should.equal("c0")
  field(sent.arguments, "accountId", decode.string) |> should.equal("acct-1")
  field(sent.arguments, "ids", decode.list(decode.string))
  |> should.equal(["m1", "m2"])
  field(sent.arguments, "fetchTextBodyValues", decode.bool)
  |> should.be_true
  field(sent.arguments, "maxBodyValueBytes", decode.int) |> should.equal(4096)
  let properties =
    field(sent.arguments, "properties", decode.list(decode.string))
  ["receivedAt", "bodyValues", "textBody", "attachments", "mailboxIds"]
  |> list.each(fn(property) {
    list.contains(properties, property) |> should.be_true
  })
  field(sent.arguments, "bodyProperties", decode.list(decode.string))
  |> list.contains("partId")
  |> should.be_true
}

/// The light get asks for exactly the mutable fields and no body values: the
/// body keys of `email_get` would cost bytes a refresh throws away, and a
/// `properties` list missing `mailboxIds`/`keywords` would leave
/// `normalise.refresh` nothing to set.
pub fn email_get_light_arguments_test() {
  let sent = sent(request.email_get_light("acct-1", ["m1", "m2"], "c0"))

  sent.name |> should.equal(request.method_name(request.EmailGet))
  sent.call_id |> should.equal("c0")
  field(sent.arguments, "accountId", decode.string) |> should.equal("acct-1")
  field(sent.arguments, "ids", decode.list(decode.string))
  |> should.equal(["m1", "m2"])
  field(sent.arguments, "properties", decode.list(decode.string))
  |> should.equal(["id", "mailboxIds", "keywords"])
  [
    "bodyProperties", "fetchTextBodyValues", "fetchHTMLBodyValues",
    "maxBodyValueBytes",
  ]
  |> list.each(fn(key) {
    decode.run(sent.arguments, decode.at([key], decode.dynamic))
    |> should.be_error
  })
  fields(sent.arguments) |> should.equal(["accountId", "ids", "properties"])
}

/// A changes call names the account, the state it starts from and the largest
/// page it accepts; a server default would fire `too_many_changes` every run.
pub fn email_changes_arguments_test() {
  let sent = sent(request.email_changes("acct-1", "state-e1", 250, "c0"))

  sent.name |> should.equal(request.method_name(request.EmailChanges))
  sent.call_id |> should.equal("c0")
  field(sent.arguments, "accountId", decode.string) |> should.equal("acct-1")
  field(sent.arguments, "sinceState", decode.string)
  |> should.equal("state-e1")
  field(sent.arguments, "maxChanges", decode.int) |> should.equal(250)
  fields(sent.arguments)
  |> should.equal(["accountId", "maxChanges", "sinceState"])
}

/// A thread call names the account and the thread ids, nothing else.
pub fn thread_get_arguments_test() {
  let sent = sent(request.thread_get("acct-1", ["t1", "t2"], "c0"))

  sent.name |> should.equal(request.method_name(request.ThreadGet))
  sent.call_id |> should.equal("c0")
  field(sent.arguments, "accountId", decode.string) |> should.equal("acct-1")
  field(sent.arguments, "ids", decode.list(decode.string))
  |> should.equal(["t1", "t2"])
}

/// The opening request (design § 5.2) is three gets under its own call ids, in
/// this order: `Mailbox/get` with `ids: null` (every mailbox and its state),
/// then `Email/get` and `Thread/get` with `ids: []`, which fetch nothing but
/// answer each type's `state`. Catches a builder that dropped or reordered a
/// call, reused a call id, or asked the content get for objects, which would
/// cost the opening its states or spend it on the wrong method.
pub fn opening_wire_shape_test() {
  let assert Ok([mailboxes, emails, threads]) =
    json.parse(
      request.body(request.opening("acct-1", 1000)) |> json.to_string,
      using: decode.at(["methodCalls"], decode.list(sent_decoder())),
    )

  mailboxes.name |> should.equal(request.method_name(request.MailboxGet))
  mailboxes.call_id |> should.equal("c0")
  field(mailboxes.arguments, "accountId", decode.string)
  |> should.equal("acct-1")
  // `ids` is present and null, not an empty list (which fetches nothing) and
  // not absent.
  field(mailboxes.arguments, "ids", decode.optional(decode.string))
  |> should.equal(None)
  decode.run(mailboxes.arguments, decode.at(["ids"], decode.dynamic))
  |> should.be_ok

  emails.name |> should.equal(request.method_name(request.EmailGet))
  emails.call_id |> should.equal("c1")
  field(emails.arguments, "accountId", decode.string) |> should.equal("acct-1")
  field(emails.arguments, "ids", decode.list(decode.string))
  |> should.equal([])
  field(emails.arguments, "maxBodyValueBytes", decode.int)
  |> should.equal(1000)

  threads.name |> should.equal(request.method_name(request.ThreadGet))
  threads.call_id |> should.equal("c2")
  field(threads.arguments, "accountId", decode.string)
  |> should.equal("acct-1")
  field(threads.arguments, "ids", decode.list(decode.string))
  |> should.equal([])
}

/// One decoded `methodCalls` entry with its arguments left dynamic, so each
/// test decodes only the fields it asserts on.
type Sent {
  Sent(name: String, arguments: Dynamic, call_id: String)
}

fn sent_decoder() -> decode.Decoder(Sent) {
  decode.then(decode.at([0], decode.string), fn(name) {
    decode.then(decode.at([1], decode.dynamic), fn(arguments) {
      decode.then(decode.at([2], decode.string), fn(call_id) {
        decode.success(Sent(name:, arguments:, call_id:))
      })
    })
  })
}

fn sent(invocation: request.Invocation) -> Sent {
  let assert Ok([call]) =
    json.parse(
      request.body([invocation]) |> json.to_string,
      using: decode.at(["methodCalls"], decode.list(sent_decoder())),
    )
  call
}

fn field(arguments: Dynamic, name: String, decoder: decode.Decoder(a)) -> a {
  let assert Ok(value) = decode.run(arguments, decode.at([name], decoder))
  value
}

/// The argument object's keys, sorted: a key added later is caught even when no
/// test denies it by name.
fn fields(arguments: Dynamic) -> List(String) {
  let assert Ok(names) =
    decode.run(arguments, decode.dict(decode.string, decode.dynamic))
  names |> dict.keys |> list.sort(string.compare)
}

fn optional_int(arguments: Dynamic, name: String) -> Option(Int) {
  let assert Ok(value) =
    decode.run(
      arguments,
      decode.optionally_at([name], None, decode.optional(decode.int)),
    )
  value
}

/// The `filter` argument decoded back into the tree the builder emitted.
type Filter {
  Filter(
    operator: Option(String),
    in_mailbox: Option(String),
    after: Option(String),
    conditions: List(Filter),
  )
}

fn filter_decoder() -> decode.Decoder(Filter) {
  use operator <- decode.optional_field(
    "operator",
    None,
    decode.optional(decode.string),
  )
  use in_mailbox <- decode.optional_field(
    "inMailbox",
    None,
    decode.optional(decode.string),
  )
  use after <- decode.optional_field(
    "after",
    None,
    decode.optional(decode.string),
  )
  use conditions <- decode.optional_field(
    "conditions",
    None,
    decode.optional(decode.list(filter_decoder())),
  )
  decode.success(Filter(
    operator:,
    in_mailbox:,
    after:,
    conditions: unwrap(conditions, []),
  ))
}

fn decode_filter(filter: json.Json) -> Filter {
  let assert Ok(decoded) =
    json.parse(json.to_string(filter), using: filter_decoder())
  decoded
}

fn in_mailbox(id: String) -> Filter {
  Filter(operator: None, in_mailbox: Some(id), after: None, conditions: [])
}

fn or(conditions: List(Filter)) -> Filter {
  Filter(operator: Some("OR"), in_mailbox: None, after: None, conditions:)
}

fn after(date: String) -> Filter {
  Filter(operator: None, in_mailbox: None, after: Some(date), conditions: [])
}

type Sort {
  Sort(property: String, is_ascending: Bool)
}

fn sort_decoder() -> decode.Decoder(Sort) {
  use property <- decode.field("property", decode.string)
  use is_ascending <- decode.field("isAscending", decode.bool)
  decode.success(Sort(property:, is_ascending:))
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
