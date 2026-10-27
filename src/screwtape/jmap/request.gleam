//// The JMAP request body (PHASE-10, D5; design § 5.2).
////
//// `Method` is closed over the JMAP methods of the scope and is the only
//// source of a JMAP method name: `Invocation` is opaque, so every call is built
//// inside this module from a `Method` (invariant I6). `method_name` is the one
//// place the wire spellings live.
////
//// Every request carries both capabilities of the scope. A run's first
//// request is `opening`, three calls under distinct ids (ISS-001); every later
//// request carries one call (PHASE-05 A1), under the one `call_id`.

import gleam/function
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

/// The capabilities every request declares in `using`. They are the same URNs
/// `decode` reads the session under, so they live here once.
pub const core_capability = "urn:ietf:params:jmap:core"

pub const mail_capability = "urn:ietf:params:jmap:mail"

/// The call id of a one-call request, and of the opening's `Mailbox/get`.
pub const call_id = "c0"

/// The Email properties a run fetches: exactly what `normalise.Email` reads
/// (PHASE-05 A12).
const email_properties = [
  "id", "blobId", "threadId", "mailboxIds", "keywords", "size", "receivedAt",
  "messageId", "inReplyTo", "references", "sender", "from", "to", "cc", "bcc",
  "replyTo", "subject", "sentAt", "hasAttachment", "preview", "textBody",
  "attachments", "bodyValues",
]

/// The body part properties `normalise.BodyPart` reads.
const body_properties = [
  "partId", "blobId", "size", "name", "type", "disposition", "cid",
]

/// The mutable Email properties a light get fetches: what
/// `normalise.refresh` replaces, and no bodies.
const light_properties = ["id", "mailboxIds", "keywords"]

/// The JMAP methods of the scope, and no others.
pub type Method {
  MailboxGet
  EmailQuery
  EmailGet
  ThreadGet
  EmailChanges
}

/// The wire name of a method; produced only from a `Method`.
pub fn method_name(method: Method) -> String {
  case method {
    MailboxGet -> "Mailbox/get"
    EmailQuery -> "Email/query"
    EmailGet -> "Email/get"
    ThreadGet -> "Thread/get"
    EmailChanges -> "Email/changes"
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

/// The window's Email/query filter (design § 5.2, PHASE-05 D2): an `OR` of
/// `inMailbox` over `mailbox_ids`, inside an `AND` with `after` when the window
/// has an age bound. The `query_state` row stores this same value.
pub fn email_query_filter(
  mailbox_ids: List(String),
  after: Option(String),
) -> json.Json {
  let mailboxes =
    json.object([
      #("operator", json.string("OR")),
      #(
        "conditions",
        json.array(mailbox_ids, fn(id) {
          json.object([#("inMailbox", json.string(id))])
        }),
      ),
    ])
  case after {
    None -> mailboxes
    Some(date) ->
      json.object([
        #("operator", json.string("AND")),
        #(
          "conditions",
          json.preprocessed_array([
            mailboxes,
            json.object([#("after", json.string(date))]),
          ]),
        ),
      ])
  }
}

/// Newest first by `receivedAt`; the `query_state` row stores this same value.
pub fn email_query_sort() -> json.Json {
  json.preprocessed_array([
    json.object([
      #("property", json.string("receivedAt")),
      #("isAscending", json.bool(False)),
    ]),
  ])
}

/// One page of ids: `Email/query` from `position`, with `limit` when the run
/// knows one, every thread member listed, and `total` asked for so paging can
/// stop at it (PHASE-05 A2, A3).
pub fn email_query(
  account_id: String,
  filter: json.Json,
  position: Int,
  limit: Option(Int),
  call_id: String,
) -> Invocation {
  let arguments = [
    #("accountId", json.string(account_id)),
    #("filter", filter),
    #("sort", email_query_sort()),
    #("collapseThreads", json.bool(False)),
    #("position", json.int(position)),
    #("calculateTotal", json.bool(True)),
  ]
  let arguments = case limit {
    None -> arguments
    Some(limit) -> list.append(arguments, [#("limit", json.int(limit))])
  }
  Invocation(
    method: EmailQuery,
    arguments: json.object(arguments),
    call_id: call_id,
  )
}

/// The content of `ids`: the model's properties, text bodies fetched, each
/// part's value capped at `max_body_value_bytes`.
pub fn email_get(
  account_id: String,
  ids: List(String),
  max_body_value_bytes: Int,
  call_id: String,
) -> Invocation {
  Invocation(
    method: EmailGet,
    arguments: json.object([
      #("accountId", json.string(account_id)),
      #("ids", json.array(ids, json.string)),
      #("properties", json.array(email_properties, json.string)),
      #("bodyProperties", json.array(body_properties, json.string)),
      #("fetchTextBodyValues", json.bool(True)),
      #("maxBodyValueBytes", json.int(max_body_value_bytes)),
    ]),
    call_id: call_id,
  )
}

/// The changes since `since_state`, at most `max_changes` of them: the state
/// they leave the account in and the ids created, updated and destroyed.
pub fn email_changes(
  account_id: String,
  since_state: String,
  max_changes: Int,
  call_id: String,
) -> Invocation {
  Invocation(
    method: EmailChanges,
    arguments: json.object([
      #("accountId", json.string(account_id)),
      #("sinceState", json.string(since_state)),
      #("maxChanges", json.int(max_changes)),
    ]),
    call_id: call_id,
  )
}

/// The mutable fields of `ids` only (design § 5.2): what
/// `normalise.refresh` replaces, with no body values, so a refresh pays for
/// nothing it discards.
pub fn email_get_light(
  account_id: String,
  ids: List(String),
  call_id: String,
) -> Invocation {
  Invocation(
    method: EmailGet,
    arguments: json.object([
      #("accountId", json.string(account_id)),
      #("ids", json.array(ids, json.string)),
      #("properties", json.array(light_properties, json.string)),
    ]),
    call_id: call_id,
  )
}

/// The member ids of the threads `ids`.
pub fn thread_get(
  account_id: String,
  ids: List(String),
  call_id: String,
) -> Invocation {
  Invocation(
    method: ThreadGet,
    arguments: json.object([
      #("accountId", json.string(account_id)),
      #("ids", json.array(ids, json.string)),
    ]),
    call_id: call_id,
  )
}

/// A run's first request (design § 5.2, ISS-001): `Mailbox/get`, then an
/// `Email/get` and a `Thread/get` with `ids: []`, which fetch nothing but
/// answer each type's `state` before phase 1. Each call has its own id, so a
/// method error names the call it answers.
pub fn opening(
  account_id: String,
  max_body_value_bytes: Int,
) -> List(Invocation) {
  [
    mailbox_get(account_id, call_id),
    email_get(account_id, [], max_body_value_bytes, "c1"),
    thread_get(account_id, [], "c2"),
  ]
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
