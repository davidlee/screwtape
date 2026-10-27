//// Contract tests for `screwtape/render` (PHASE-06, T5; design § 5.2, § 5.1;
//// finding D7 "output shapes").
////
//// `render` is pure: model values in, one JSON document out, and `envelope`
//// is the only writer of the `{"version": 1, "kind", "data"}` wrapper around
//// it. Optional values print as `null`, never omitted.
////
//// Every assertion parses the document back into a comparable `Value` with its
//// object keys sorted, so the tests pin the shapes — including the fields D7
//// keeps out — and not the text's key order or spacing.

import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/cursor
import screwtape/model.{
  type Address, type AddressField, type Attachment, type Body, type Mailbox,
  type Message, type MessageSummary, type Source, type TruncatedBy, type UtcDate,
  Address, Attachment, Bcc, Body, Cc, From, HeaderIds, Html, Mailbox, Message,
  MessageLimit, MessageSummary, PlainText, ReplyTo, Sender, Server, ThreadEntry,
  ThreadPage, To, UtcDate,
}
import screwtape/render

pub fn main() -> Nil {
  gleeunit.main()
}

const account = "acct-r"

// ---------------------------------------------------------------------------
// Parsing: one document to one `Value`, keys sorted so order never matters.
// ---------------------------------------------------------------------------

type Value {
  VNull
  VBool(Bool)
  VInt(Int)
  VFloat(Float)
  VString(String)
  VList(List(Value))
  VObject(List(#(String, Value)))
}

fn json_value() -> decode.Decoder(Value) {
  decode.recursive(fn() {
    decode.one_of(decode.map(decode.string, VString), or: [
      decode.map(decode.optional(decode.int), fn(number) {
        case number {
          Some(value) -> VInt(value)
          None -> VNull
        }
      }),
      decode.map(decode.float, VFloat),
      decode.map(decode.bool, VBool),
      decode.map(decode.list(of: json_value()), VList),
      decode.map(decode.dict(decode.string, json_value()), fn(fields) {
        fields
        |> dict.to_list
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> VObject
      }),
    ])
  })
}

fn parse(text: String) -> Value {
  let assert Ok(value) = json.parse(text, using: json_value())
  value
}

fn obj(fields: List(#(String, Value))) -> Value {
  fields
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> VObject
}

fn arr(values: List(Value)) -> Value {
  VList(values)
}

fn str(text: String) -> Value {
  VString(text)
}

fn int(number: Int) -> Value {
  VInt(number)
}

fn bool(flag: Bool) -> Value {
  VBool(flag)
}

fn null() -> Value {
  VNull
}

fn strings(values: List(String)) -> Value {
  values |> list.map(VString) |> VList
}

fn optional(value: Option(a), some: fn(a) -> Value) -> Value {
  case value {
    Some(inner) -> some(inner)
    None -> VNull
  }
}

fn at_field(value: Value, name: String) -> Value {
  let assert VObject(fields) = value
  let assert Ok(field) = list.find(fields, fn(field) { field.0 == name })
  field.1
}

fn has_field(value: Value, name: String) -> Bool {
  case value {
    VObject(fields) -> list.any(fields, fn(field) { field.0 == name })
    _ -> False
  }
}

fn with_field(value: Value, name: String, field: Value) -> Value {
  let assert VObject(fields) = value
  obj([#(name, field), ..fields])
}

/// The one document every verb prints.
fn envelope_doc(kind: String, data: Value) -> Value {
  obj([#("version", int(1)), #("kind", str(kind)), #("data", data)])
}

// ---------------------------------------------------------------------------
// Model builders: only the fields a case cares about are varied.
// ---------------------------------------------------------------------------

fn date(raw: String) -> UtcDate {
  UtcDate(raw: raw, ms: 0)
}

fn address(
  field: AddressField,
  name: Option(String),
  email: String,
) -> Address {
  Address(field: field, name: name, email: email)
}

fn addresses(entries: List(#(Option(String), String))) -> Value {
  entries
  |> list.map(fn(entry) {
    let #(name, email) = entry
    obj([#("name", optional(name, str)), #("email", str(email))])
  })
  |> VList
}

fn mailbox(
  id: String,
  name: String,
  parent_id: Option(String),
  role: Option(String),
  sort_order: Int,
) -> Mailbox {
  Mailbox(
    id: id,
    name: name,
    parent_id: parent_id,
    role: role,
    sort_order: sort_order,
    total_emails: sort_order * 10,
    unread_emails: sort_order,
  )
}

fn mailbox_json(
  id: String,
  name: String,
  parent_id: Option(String),
  role: Option(String),
  sort_order: Int,
) -> Value {
  obj([
    #("id", str(id)),
    #("name", str(name)),
    #("parent_id", optional(parent_id, str)),
    #("role", optional(role, str)),
    #("sort_order", int(sort_order)),
    #("total_emails", int(sort_order * 10)),
    #("unread_emails", int(sort_order)),
  ])
}

fn summary(
  id: String,
  thread_id: String,
  received_at: String,
  subject: Option(String),
  from: List(Address),
  is_seen: Bool,
  is_flagged: Bool,
  mailbox_ids: List(String),
  has_attachment: Bool,
) -> MessageSummary {
  MessageSummary(
    id: id,
    thread_id: thread_id,
    received_at: date(received_at),
    subject: subject,
    preview: "Preview " <> id,
    from: from,
    is_seen: is_seen,
    is_flagged: is_flagged,
    has_attachment: has_attachment,
    mailbox_ids: mailbox_ids,
  )
}

fn summary_json(
  id: String,
  thread_id: String,
  received_at: String,
  subject: Option(String),
  from: Value,
  is_seen: Bool,
  is_flagged: Bool,
  mailbox_ids: List(String),
  has_attachment: Bool,
) -> Value {
  obj([
    #("id", str(id)),
    #("thread_id", str(thread_id)),
    #("received_at", str(received_at)),
    #("subject", optional(subject, str)),
    #("from", from),
    #("preview", str("Preview " <> id)),
    #("is_seen", bool(is_seen)),
    #("is_flagged", bool(is_flagged)),
    #("mailbox_ids", strings(mailbox_ids)),
    #("has_attachment", bool(has_attachment)),
    #("cursor", cursor_json(date(received_at).ms, id)),
  ])
}

/// The `cursor` field every summary-shaped document prints: the summary's
/// arrival instant and id, as `<ms>:<id>` (VT-2, PHASE-04).
fn cursor_json(received_at_ms: Int, id: String) -> Value {
  cursor.to_string(cursor.of(received_at_ms, id)) |> str
}

fn body(
  part_id: String,
  source: Source,
  text: String,
  truncated_by: Option(TruncatedBy),
  is_encoding_problem: Bool,
  conversion_failed: Bool,
) -> Body {
  Body(
    part_id: part_id,
    source: source,
    text: text,
    is_truncated: truncated_by != None,
    truncated_by: truncated_by,
    is_encoding_problem: is_encoding_problem,
    conversion_failed: conversion_failed,
    // Never printed (D7), so any value will do.
    max_body_value_bytes: 4096,
  )
}

fn body_json(
  part_id: String,
  source_type: String,
  text: String,
  is_truncated: Bool,
  truncated_by: Value,
  is_encoding_problem: Bool,
  conversion_failed: Bool,
) -> Value {
  obj([
    #("part_id", str(part_id)),
    #("source_type", str(source_type)),
    #("text", str(text)),
    #("is_truncated", bool(is_truncated)),
    #("truncated_by", truncated_by),
    #("is_encoding_problem", bool(is_encoding_problem)),
    #("conversion_failed", bool(conversion_failed)),
  ])
}

fn attachment(
  part_id: String,
  blob_id: String,
  name: Option(String),
  type_: String,
  size: Int,
  disposition: Option(String),
  cid: Option(String),
) -> Attachment {
  Attachment(
    part_id: part_id,
    blob_id: blob_id,
    name: name,
    type_: type_,
    size: size,
    disposition: disposition,
    cid: cid,
  )
}

fn attachment_json(
  part_id: String,
  blob_id: String,
  name: Option(String),
  type_: String,
  size: Int,
  disposition: Option(String),
  cid: Option(String),
) -> Value {
  obj([
    #("part_id", str(part_id)),
    #("blob_id", str(blob_id)),
    #("name", optional(name, str)),
    #("type", str(type_)),
    #("size", int(size)),
    #("disposition", optional(disposition, str)),
    #("cid", optional(cid, str)),
  ])
}

/// A message that fills every `read` field: every address field, every
/// header-id kind, both body sources, each `truncated_by`, both attachment
/// shapes, and each body flag.
fn message() -> Message {
  Message(
    id: "m1",
    thread_id: "th1",
    blob_id: "blob-1",
    received_at: date("2026-10-26T10:15:30Z"),
    sent_at: Some("2026-10-26T10:15:00+00:00"),
    subject: Some("Invoice"),
    preview: "Your invoice",
    size: 4096,
    has_attachment: True,
    is_seen: True,
    is_flagged: False,
    keywords: ["$seen", "custom"],
    email_state: "state-email-1",
    mailbox_ids: ["mb1", "mb2"],
    header_ids: HeaderIds(
      message_id: ["mid1@example.test"],
      in_reply_to: ["mid0@example.test"],
      references: ["mid0@example.test", "root@example.test"],
    ),
    addresses: [
      address(From, Some("Acme"), "billing@acme.test"),
      address(Sender, None, "sender@acme.test"),
      address(To, Some("Me"), "me@example.test"),
      address(To, None, "you@example.test"),
      address(Cc, None, "cc@example.test"),
      address(Bcc, Some("Hidden"), "bcc@example.test"),
      address(ReplyTo, Some("Reply"), "reply@acme.test"),
    ],
    bodies: [
      body("1", PlainText, "Plain body", None, False, False),
      body("2", PlainText, "Second body", Some(Server), True, False),
      body("3", Html, "<p>Html body</p>", Some(MessageLimit), False, True),
    ],
    attachments: [
      attachment(
        "1",
        "blob-a1",
        Some("invoice.pdf"),
        "application/pdf",
        1024,
        Some("attachment"),
        Some("cid-1"),
      ),
      attachment("2", "blob-a2", None, "image/png", 64, None, None),
    ],
  )
}

fn with_bodies(bodies: List(Body)) -> Message {
  let base = message()
  Message(..base, bodies: bodies)
}

// ---------------------------------------------------------------------------
// Envelope
// ---------------------------------------------------------------------------

pub fn envelope_prints_version_kind_and_data_test() {
  render.envelope(
    "sync",
    json.object([#("items", json.array(["a", "b"], json.string))]),
  )
  |> parse
  |> should.equal(envelope_doc("sync", obj([#("items", strings(["a", "b"]))])))
}

// ---------------------------------------------------------------------------
// mailboxes
// ---------------------------------------------------------------------------

pub fn mailboxes_prints_every_field_in_order_test() {
  let inbox = mailbox("mb2", "Inbox", Some("mb-root"), Some("inbox"), 1)
  let archive = mailbox("mb1", "Archive", None, None, 2)

  render.mailboxes([inbox, archive])
  |> parse
  |> should.equal(envelope_doc(
    "mailboxes",
    obj([
      #(
        "items",
        arr([
          mailbox_json("mb2", "Inbox", Some("mb-root"), Some("inbox"), 1),
          mailbox_json("mb1", "Archive", None, None, 2),
        ]),
      ),
    ]),
  ))
}

// ---------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------

/// The two summaries both `list` pages print, and the JSON each must print as.
fn list_summaries() -> List(MessageSummary) {
  [
    summary(
      "m1",
      "th1",
      "2026-10-25T21:04:11Z",
      Some("Invoice"),
      [address(From, Some("Acme"), "billing@acme.test")],
      False,
      False,
      ["mb1"],
      True,
    ),
    summary(
      "m2",
      "th2",
      "2026-10-24T08:00:00Z",
      None,
      [address(From, None, "other@example.test")],
      True,
      True,
      ["mb2", "mb1"],
      False,
    ),
  ]
}

fn list_items_json() -> Value {
  arr([
    summary_json(
      "m1",
      "th1",
      "2026-10-25T21:04:11Z",
      Some("Invoice"),
      addresses([#(Some("Acme"), "billing@acme.test")]),
      False,
      False,
      ["mb1"],
      True,
    ),
    summary_json(
      "m2",
      "th2",
      "2026-10-24T08:00:00Z",
      None,
      addresses([#(None, "other@example.test")]),
      True,
      True,
      ["mb2", "mb1"],
      False,
    ),
  ])
}

pub fn list_echoes_offset_and_limit_and_prints_each_summary_test() {
  render.list(offset: 20, limit: 25, items: list_summaries())
  |> parse
  |> should.equal(envelope_doc(
    "list",
    obj([
      #("offset", int(20)),
      #("limit", int(25)),
      #("items", list_items_json()),
    ]),
  ))
}

/// VT-2 (PHASE-04): `list_after` echoes the arrival cursor it was given —
/// `Start` prints `""` — in place of `offset`, and prints each summary with
/// its `cursor` field, in the key order `after`, `limit`, `items`.
pub fn list_after_echoes_the_cursor_and_limit_and_prints_each_summary_test() {
  render.list_after(after: cursor.Start, limit: 25, items: list_summaries())
  |> parse
  |> should.equal(envelope_doc(
    "list",
    obj([
      #("after", str("")),
      #("limit", int(25)),
      #("items", list_items_json()),
    ]),
  ))

  render.list_after(
    after: cursor.of(1_792_886_400_000, "m-1"),
    limit: 25,
    items: list_summaries(),
  )
  |> parse
  |> should.equal(envelope_doc(
    "list",
    obj([
      #("after", str("1792886400000:m-1")),
      #("limit", int(25)),
      #("items", list_items_json()),
    ]),
  ))
}

// ---------------------------------------------------------------------------
// read
// ---------------------------------------------------------------------------

pub fn read_prints_the_whole_message_with_provenance_test() {
  let expected =
    obj([
      // The summary's fields, `from` reusing the summary's.
      #("id", str("m1")),
      #("thread_id", str("th1")),
      #("received_at", str("2026-10-26T10:15:30Z")),
      #("subject", str("Invoice")),
      #("from", addresses([#(Some("Acme"), "billing@acme.test")])),
      #("preview", str("Your invoice")),
      #("is_seen", bool(True)),
      #("is_flagged", bool(False)),
      #("mailbox_ids", strings(["mb1", "mb2"])),
      #("has_attachment", bool(True)),
      #("cursor", cursor_json(date("2026-10-26T10:15:30Z").ms, "m1")),
      // What `read` adds.
      #("sent_at", str("2026-10-26T10:15:00+00:00")),
      #("size", int(4096)),
      #("keywords", strings(["$seen", "custom"])),
      #("sender", addresses([#(None, "sender@acme.test")])),
      #(
        "to",
        addresses([
          #(Some("Me"), "me@example.test"),
          #(None, "you@example.test"),
        ]),
      ),
      #("cc", addresses([#(None, "cc@example.test")])),
      #("bcc", addresses([#(Some("Hidden"), "bcc@example.test")])),
      #("reply_to", addresses([#(Some("Reply"), "reply@acme.test")])),
      #("message_id", strings(["mid1@example.test"])),
      #("in_reply_to", strings(["mid0@example.test"])),
      #("references", strings(["mid0@example.test", "root@example.test"])),
      #(
        "bodies",
        arr([
          body_json("1", "text", "Plain body", False, null(), False, False),
          body_json(
            "2",
            "text",
            "Second body",
            True,
            str("server"),
            True,
            False,
          ),
          body_json(
            "3",
            "html",
            "<p>Html body</p>",
            True,
            str("message_limit"),
            False,
            True,
          ),
        ]),
      ),
      #(
        "attachments",
        arr([
          attachment_json(
            "1",
            "blob-a1",
            Some("invoice.pdf"),
            "application/pdf",
            1024,
            Some("attachment"),
            Some("cid-1"),
          ),
          attachment_json("2", "blob-a2", None, "image/png", 64, None, None),
        ]),
      ),
      #(
        "provenance",
        obj([
          #("account_id", str(account)),
          #("email_state", str("state-email-1")),
        ]),
      ),
      #("output_truncated", bool(False)),
    ])

  render.read(account_id: account, message: message(), max_bytes: None)
  |> parse
  |> should.equal(envelope_doc("read", expected))
}

pub fn read_omits_blob_id_and_max_body_value_bytes_test() {
  let data =
    render.read(account_id: account, message: message(), max_bytes: None)
    |> parse
    |> at_field("data")

  data |> has_field("blob_id") |> should.be_false

  let assert VList(bodies) = at_field(data, "bodies")
  let assert [first, ..] = bodies
  first |> has_field("max_body_value_bytes") |> should.be_false
}

// ---------------------------------------------------------------------------
// --max-bytes
// ---------------------------------------------------------------------------

fn read_bodies(output: String) -> Value {
  output
  |> parse
  |> at_field("data")
  |> at_field("bodies")
}

fn output_truncated(output: String) -> Value {
  output
  |> parse
  |> at_field("data")
  |> at_field("output_truncated")
}

fn body_texts(output: String) -> List(Value) {
  let assert VList(bodies) = read_bodies(output)
  bodies |> list.map(fn(body) { at_field(body, "text") })
}

fn two_body_message() -> Message {
  with_bodies([
    body("1", PlainText, "abcdef", None, False, False),
    body("2", PlainText, "0123456789", None, False, False),
  ])
}

pub fn max_bytes_over_the_text_keeps_every_body_test() {
  let output =
    render.read(
      account_id: account,
      message: two_body_message(),
      max_bytes: Some(17),
    )

  body_texts(output) |> should.equal([str("abcdef"), str("0123456789")])
  output_truncated(output) |> should.equal(bool(False))
}

pub fn max_bytes_at_the_total_keeps_every_body_test() {
  let output =
    render.read(
      account_id: account,
      message: two_body_message(),
      max_bytes: Some(16),
    )

  body_texts(output) |> should.equal([str("abcdef"), str("0123456789")])
  output_truncated(output) |> should.equal(bool(False))
}

pub fn max_bytes_under_the_total_cuts_the_text_test() {
  let output =
    render.read(
      account_id: account,
      message: two_body_message(),
      max_bytes: Some(8),
    )

  body_texts(output) |> should.equal([str("abcdef"), str("01")])
  output_truncated(output) |> should.equal(bool(True))
}

pub fn max_bytes_running_out_inside_a_body_blanks_the_rest_test() {
  let output =
    render.read(
      account_id: account,
      message: two_body_message(),
      max_bytes: Some(4),
    )

  body_texts(output) |> should.equal([str("abcd"), str("")])
  output_truncated(output) |> should.equal(bool(True))
}

pub fn max_bytes_does_not_split_a_multibyte_char_test() {
  // "a" is one byte and "é" two: a budget of 2 leaves one byte for "é", which
  // is dropped whole rather than split.
  let output =
    render.read(
      account_id: account,
      message: with_bodies([
        body("1", PlainText, "aé", None, False, False),
        body("2", PlainText, "b", None, False, False),
      ]),
      max_bytes: Some(2),
    )

  body_texts(output) |> should.equal([str("a"), str("")])
  output_truncated(output) |> should.equal(bool(True))
}

pub fn max_bytes_zero_blanks_all_text_test() {
  let output =
    render.read(
      account_id: account,
      message: two_body_message(),
      max_bytes: Some(0),
    )

  body_texts(output) |> should.equal([str(""), str("")])
  output_truncated(output) |> should.equal(bool(True))
}

pub fn max_bytes_keeps_the_stored_body_flags_test() {
  let output =
    render.read(
      account_id: account,
      message: with_bodies([
        body("1", PlainText, "abcdef", Some(Server), False, False),
        body("2", PlainText, "0123456789", None, False, False),
      ]),
      max_bytes: Some(4),
    )

  read_bodies(output)
  |> should.equal(
    arr([
      body_json("1", "text", "abcd", True, str("server"), False, False),
      body_json("2", "text", "", False, null(), False, False),
    ]),
  )
  output_truncated(output) |> should.equal(bool(True))
}

// ---------------------------------------------------------------------------
// thread
// ---------------------------------------------------------------------------

pub fn thread_prints_summaries_and_out_of_store_ids_in_order_test() {
  let first =
    summary(
      "m1",
      "th1",
      "2026-10-25T21:04:11Z",
      Some("Invoice"),
      [address(From, Some("Acme"), "billing@acme.test")],
      True,
      False,
      ["mb1"],
      True,
    )
  let third =
    summary(
      "m3",
      "th1",
      "2026-10-24T08:00:00Z",
      None,
      [address(From, None, "other@example.test")],
      False,
      True,
      ["mb2"],
      False,
    )

  render.thread(
    "th1",
    ThreadPage(total: 3, entries: [
      ThreadEntry(id: "m1", summary: Some(first)),
      ThreadEntry(id: "m0", summary: None),
      ThreadEntry(id: "m3", summary: Some(third)),
    ]),
  )
  |> parse
  |> should.equal(envelope_doc(
    "thread",
    obj([
      #("id", str("th1")),
      #("total", int(3)),
      #("truncated", bool(False)),
      #(
        "items",
        arr([
          with_field(
            summary_json(
              "m1",
              "th1",
              "2026-10-25T21:04:11Z",
              Some("Invoice"),
              addresses([#(Some("Acme"), "billing@acme.test")]),
              True,
              False,
              ["mb1"],
              True,
            ),
            "in_store",
            bool(True),
          ),
          obj([#("id", str("m0")), #("in_store", bool(False))]),
          with_field(
            summary_json(
              "m3",
              "th1",
              "2026-10-24T08:00:00Z",
              None,
              addresses([#(None, "other@example.test")]),
              False,
              True,
              ["mb2"],
              False,
            ),
            "in_store",
            bool(True),
          ),
        ]),
      ),
    ]),
  ))
}

/// C6: a page shorter than the thread is `truncated: true`, and `total` still
/// counts the whole thread's ids, not the printed entries.
pub fn thread_page_shorter_than_total_is_truncated_test() {
  let held =
    summary(
      "m1",
      "th1",
      "2026-10-25T21:04:11Z",
      Some("Invoice"),
      [address(From, Some("Acme"), "billing@acme.test")],
      True,
      False,
      ["mb1"],
      True,
    )

  render.thread(
    "th1",
    ThreadPage(total: 5, entries: [
      ThreadEntry(id: "m1", summary: Some(held)),
      ThreadEntry(id: "m0", summary: None),
      ThreadEntry(id: "m3", summary: None),
    ]),
  )
  |> parse
  |> should.equal(envelope_doc(
    "thread",
    obj([
      #("id", str("th1")),
      #("total", int(5)),
      #("truncated", bool(True)),
      #(
        "items",
        arr([
          with_field(
            summary_json(
              "m1",
              "th1",
              "2026-10-25T21:04:11Z",
              Some("Invoice"),
              addresses([#(Some("Acme"), "billing@acme.test")]),
              True,
              False,
              ["mb1"],
              True,
            ),
            "in_store",
            bool(True),
          ),
          obj([#("id", str("m0")), #("in_store", bool(False))]),
          obj([#("id", str("m3")), #("in_store", bool(False))]),
        ]),
      ),
    ]),
  ))
}
