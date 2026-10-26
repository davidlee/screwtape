//// Contract tests for `screwtape/normalise` (PHASE-03, T4a; EX-3, EX-4, EX-5;
//// VT-2, VT-3, VT-5).
////
//// These are the tests of the wiring contract: the exact `UtcDate` parse,
//// the `compare_received` ordering, and the one `Message` shape the rest of
//// the pipeline reads. The body-bound cases are deliberately pairs that each
//// fit `max_body_bytes` on their own and only fail when counted together, so
//// a per-part-only bound cannot pass them.
////
//// `Email` is built once by `base_email()` and bent per test with record update, so
//// each case differs from the baseline in exactly the field it exercises.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/model
import screwtape/normalise

pub fn main() -> Nil {
  gleeunit.main()
}

const received = "2026-01-01T00:00:00Z"

/// A baseline Email: no headers, no addresses, no bodies, no attachments.
fn base_email() -> normalise.Email {
  normalise.Email(
    id: "email-1",
    blob_id: "blob-1",
    thread_id: "thread-1",
    mailbox_ids: [],
    keywords: [],
    size: 100,
    received_at: model.UtcDate(raw: received, ms: 1_767_225_600_000),
    message_id: None,
    in_reply_to: None,
    references: None,
    sender: None,
    from: None,
    to: None,
    cc: None,
    bcc: None,
    reply_to: None,
    subject: None,
    sent_at: None,
    has_attachment: False,
    preview: "",
    text_body: [],
    attachments: [],
    body_values: [],
  )
}

fn part(id: String, type_: String, text: String) -> normalise.BodyPart {
  normalise.BodyPart(
    part_id: Some(id),
    blob_id: None,
    size: string.byte_size(text),
    name: None,
    type_: type_,
    disposition: None,
    cid: None,
  )
}

fn plain(id: String, text: String) -> normalise.BodyPart {
  part(id, "text/plain", text)
}

fn html(id: String, text: String) -> normalise.BodyPart {
  part(id, "text/html", text)
}

/// A `bodyValues` entry keyed by `part_id`.
fn value_of(id: String, text: String) -> #(String, normalise.BodyValue) {
  #(
    id,
    normalise.BodyValue(
      value: text,
      is_encoding_problem: False,
      is_truncated: False,
    ),
  )
}

fn value_with(
  id: String,
  text: String,
  is_encoding_problem: Bool,
  is_truncated: Bool,
) -> #(String, normalise.BodyValue) {
  #(
    id,
    normalise.BodyValue(
      value: text,
      is_encoding_problem: is_encoding_problem,
      is_truncated: is_truncated,
    ),
  )
}

/// A `Message` that only `compare_received` reads, built without going through
/// `normalise.message` so the ordering contract is tested on its own.
fn sortable(id: String, received_at: model.UtcDate) -> model.Message {
  model.Message(
    id: id,
    thread_id: "thread-1",
    blob_id: "blob-1",
    received_at: received_at,
    sent_at: None,
    subject: None,
    preview: "",
    size: 0,
    has_attachment: False,
    is_seen: False,
    is_flagged: False,
    keywords: [],
    email_state: "state-1",
    mailbox_ids: [],
    header_ids: model.HeaderIds(message_id: [], in_reply_to: [], references: []),
    addresses: [],
    bodies: [],
    attachments: [],
  )
}

fn body_texts(message: model.Message) -> List(String) {
  message.bodies |> list.map(fn(body) { body.text })
}

fn body_truncations(
  message: model.Message,
) -> List(#(Bool, Option(model.TruncatedBy))) {
  message.bodies
  |> list.map(fn(body) { #(body.is_truncated, body.truncated_by) })
}

// UTCDate.

pub fn utc_date_epoch_test() {
  normalise.utc_date("1970-01-01T00:00:00Z")
  |> should.equal(Ok(model.UtcDate(raw: "1970-01-01T00:00:00Z", ms: 0)))

  normalise.utc_date("2000-01-01T00:00:00Z")
  |> should.equal(
    Ok(model.UtcDate(raw: "2000-01-01T00:00:00Z", ms: 946_684_800_000)),
  )

  normalise.utc_date("2024-02-29T23:59:59Z")
  |> should.equal(
    Ok(model.UtcDate(raw: "2024-02-29T23:59:59Z", ms: 1_709_251_199_000)),
  )
}

/// The raw text is provenance: it survives exactly, fraction and all. A
/// fraction contributes its first three digits and no more (truncation, not
/// rounding); no fraction adds nothing.
pub fn utc_date_fractional_truncates_to_milliseconds_test() {
  normalise.utc_date("2024-02-29T23:59:59.5Z")
  |> should.equal(
    Ok(model.UtcDate(raw: "2024-02-29T23:59:59.5Z", ms: 1_709_251_199_500)),
  )

  normalise.utc_date("2024-02-29T23:59:59.123456Z")
  |> should.equal(
    Ok(model.UtcDate(raw: "2024-02-29T23:59:59.123456Z", ms: 1_709_251_199_123)),
  )

  normalise.utc_date("2024-02-29T23:59:59Z")
  |> should.equal(
    Ok(model.UtcDate(raw: "2024-02-29T23:59:59Z", ms: 1_709_251_199_000)),
  )
}

/// `--since` at midnight is inclusive: the first instant of a day with a
/// fractional part is strictly after the day's plain midnight.
pub fn utc_date_midnight_fraction_is_after_midnight_test() {
  let assert Ok(midnight) = normalise.utc_date("2026-10-26T00:00:00Z")
  let assert Ok(half_past) = normalise.utc_date("2026-10-26T00:00:00.500Z")

  half_past.ms |> should.equal(midnight.ms + 500)
}

pub fn utc_date_rejects_non_utc_and_invalid_test() {
  [
    "",
    "2026-01-01T00:00:00",
    "2026-01-01T00:00:00+01:00",
    "2026-13-01T00:00:00Z",
    "2026-02-30T00:00:00Z",
    "2026-01-01 00:00:00Z",
    "2026-01-01T00:00:00Zjunk",
    "2026-01-01T00:00:00.Z",
    "2026-01-01t00:00:00Z",
    "2026-01-01T00:00:00z",
  ]
  |> list.each(fn(raw) { normalise.utc_date(raw) |> should.equal(Error(Nil)) })
}

// Ordering.

/// Sub-millisecond digits are dropped, so two raws in the same millisecond
/// tie; the tie breaks by id, whichever argument order the sort sees.
pub fn compare_received_same_millisecond_orders_by_id_test() {
  let assert Ok(first) = normalise.utc_date("2026-01-01T00:00:00.1231Z")
  let assert Ok(second) = normalise.utc_date("2026-01-01T00:00:00.1234Z")

  first.ms |> should.equal(second.ms)

  let a = sortable("a", first)
  let b = sortable("b", second)

  [b, a]
  |> list.sort(normalise.compare_received)
  |> list.map(fn(message) { message.id })
  |> should.equal(["a", "b"])

  [a, b]
  |> list.sort(normalise.compare_received)
  |> list.map(fn(message) { message.id })
  |> should.equal(["a", "b"])
}

/// A later millisecond wins even when its id would sort first.
pub fn compare_received_ms_wins_over_id_test() {
  let early = model.UtcDate(raw: "2026-01-01T00:00:00Z", ms: 1_767_225_600_000)
  let late = model.UtcDate(raw: "2026-01-01T00:00:01Z", ms: 1_767_225_601_000)

  let z = sortable("z", early)
  let a = sortable("a", late)

  [a, z]
  |> list.sort(normalise.compare_received)
  |> list.map(fn(message) { message.id })
  |> should.equal(["z", "a"])
}

// Message shape.

/// A multipart/alternative's `textBody` already names only the text/plain part
/// the server chose; normalise stores that one, unconverted.
pub fn message_multipart_alternative_keeps_the_plain_part_test() {
  let email =
    normalise.Email(
      ..base_email(),
      text_body: [plain("p1", "the plain text")],
      body_values: [value_of("p1", "the plain text")],
    )

  let message = normalise.message(email, "state-1", 1024)

  message.bodies |> list.length |> should.equal(1)

  let assert [body] = message.bodies
  body.source |> should.equal(model.PlainText)
  body.text |> should.equal("the plain text")
}

pub fn message_html_only_converts_html_to_text_test() {
  let email =
    normalise.Email(
      ..base_email(),
      text_body: [html("p1", "<p>Hello <b>world</b></p>")],
      body_values: [value_of("p1", "<p>Hello <b>world</b></p>")],
    )

  let message = normalise.message(email, "state-1", 1024)

  let assert [body] = message.bodies
  body.source |> should.equal(model.Html)
  body.text |> should.equal("Hello world")
  body.conversion_failed |> should.be_false
}

pub fn message_html_conversion_failure_is_recorded_test() {
  let email =
    normalise.Email(
      ..base_email(),
      text_body: [html("p1", "</</")],
      body_values: [value_of("p1", "</</")],
    )

  let message = normalise.message(email, "state-1", 1024)

  let assert [body] = message.bodies
  body.text |> should.equal("")
  body.conversion_failed |> should.be_true
}

pub fn message_is_encoding_problem_is_per_part_test() {
  let email =
    normalise.Email(
      ..base_email(),
      text_body: [plain("p1", "damaged"), plain("p2", "clean")],
      body_values: [
        value_with("p1", "damaged", True, False),
        value_with("p2", "clean", False, False),
      ],
    )

  let message = normalise.message(email, "state-1", 1024)

  let assert [first, second] = message.bodies
  first.is_encoding_problem |> should.be_true
  second.is_encoding_problem |> should.be_false
}

/// RFC 5322 ids stay apart from the JMAP id and thread id, each list in its
/// header's order; absent headers are empty lists, never a missing field.
pub fn message_in_reply_to_and_references_are_header_ids_test() {
  let email =
    normalise.Email(
      ..base_email(),
      id: "jmap-email-id",
      thread_id: "jmap-thread-id",
      message_id: Some(["a@x"]),
      in_reply_to: Some(["b@x"]),
      references: Some(["c@x", "b@x"]),
    )

  let message = normalise.message(email, "state-1", 1024)

  message.header_ids
  |> should.equal(
    model.HeaderIds(message_id: ["a@x"], in_reply_to: ["b@x"], references: [
      "c@x",
      "b@x",
    ]),
  )

  let absent = normalise.message(base_email(), "state-1", 1024)
  absent.header_ids
  |> should.equal(
    model.HeaderIds(message_id: [], in_reply_to: [], references: []),
  )
}

pub fn message_mailbox_ids_and_keywords_test() {
  let email =
    normalise.Email(..base_email(), mailbox_ids: ["mb-1", "mb-2"], keywords: [
      "$seen",
      "$flagged",
      "custom",
    ])

  let message = normalise.message(email, "state-1", 1024)

  message.mailbox_ids |> should.equal(["mb-1", "mb-2"])
  message.is_seen |> should.be_true
  message.is_flagged |> should.be_true
  message.keywords |> should.equal(["$seen", "$flagged", "custom"])

  let bare = normalise.message(base_email(), "state-1", 1024)
  bare.mailbox_ids |> should.equal([])
  bare.is_seen |> should.be_false
  bare.is_flagged |> should.be_false
}

/// Addresses come out in the fixed field order, and within each field in the
/// order the header gave them.
pub fn message_addresses_grouped_by_field_test() {
  let email =
    normalise.Email(
      ..base_email(),
      from: Some([
        normalise.EmailAddress(name: Some("From One"), email: "from@x"),
      ]),
      sender: Some([
        normalise.EmailAddress(name: None, email: "sender@x"),
      ]),
      to: Some([
        normalise.EmailAddress(name: Some("To One"), email: "to1@x"),
        normalise.EmailAddress(name: Some("To Two"), email: "to2@x"),
      ]),
      cc: Some([normalise.EmailAddress(name: None, email: "cc@x")]),
      bcc: Some([normalise.EmailAddress(name: None, email: "bcc@x")]),
      reply_to: Some([
        normalise.EmailAddress(name: Some("Reply To"), email: "reply@x"),
      ]),
    )

  let message = normalise.message(email, "state-1", 1024)

  message.addresses
  |> should.equal([
    model.Address(field: model.From, name: Some("From One"), email: "from@x"),
    model.Address(field: model.Sender, name: None, email: "sender@x"),
    model.Address(field: model.To, name: Some("To One"), email: "to1@x"),
    model.Address(field: model.To, name: Some("To Two"), email: "to2@x"),
    model.Address(field: model.Cc, name: None, email: "cc@x"),
    model.Address(field: model.Bcc, name: None, email: "bcc@x"),
    model.Address(
      field: model.ReplyTo,
      name: Some("Reply To"),
      email: "reply@x",
    ),
  ])
}

/// Non-ASCII text is carried as bytes, not reinterpreted.
pub fn message_unicode_survives_byte_identical_test() {
  let text = "Grüße ☃ 日本"

  let email =
    normalise.Email(
      ..base_email(),
      subject: Some(text),
      from: Some([normalise.EmailAddress(name: Some(text), email: "gruss@x")]),
      text_body: [plain("p1", text)],
      body_values: [value_of("p1", text)],
    )

  let message = normalise.message(email, "state-1", 1024)

  message.subject |> should.equal(Some(text))

  let assert [body] = message.bodies
  body.text |> should.equal(text)
  string.byte_size(body.text) |> should.equal(string.byte_size(text))

  let assert [from] = message.addresses
  from.name |> should.equal(Some(text))
}

pub fn message_email_state_and_attachment_metadata_test() {
  let email =
    normalise.Email(
      ..base_email(),
      text_body: [plain("p1", "body one"), plain("p2", "body two")],
      body_values: [value_of("p1", "body one"), value_of("p2", "body two")],
      attachments: [
        normalise.BodyPart(
          part_id: Some("att-1"),
          blob_id: Some("blob-att-1"),
          size: 1234,
          name: Some("report.pdf"),
          type_: "application/pdf",
          disposition: Some("attachment"),
          cid: Some("cid-1@x"),
        ),
        normalise.BodyPart(
          part_id: None,
          blob_id: None,
          size: 1,
          name: None,
          type_: "text/plain",
          disposition: None,
          cid: None,
        ),
      ],
    )

  let message = normalise.message(email, "state-42", 777)

  message.email_state |> should.equal("state-42")

  message.bodies
  |> list.each(fn(body) { body.max_body_value_bytes |> should.equal(777) })

  message.attachments
  |> should.equal([
    model.Attachment(
      part_id: "att-1",
      blob_id: "blob-att-1",
      name: Some("report.pdf"),
      type_: "application/pdf",
      size: 1234,
      disposition: Some("attachment"),
      cid: Some("cid-1@x"),
    ),
    model.Attachment(
      part_id: "",
      blob_id: "",
      name: None,
      type_: "text/plain",
      size: 1,
      disposition: None,
      cid: None,
    ),
  ])
}

// The per-message body bound (EX-3).

/// The stored bytes are counted across parts in order. The first part that no
/// longer fits is cut to `remaining` bytes; every later part stores nothing,
/// but is still marked as cut by this bound.
pub fn message_limit_plain_parts_test() {
  let email =
    normalise.Email(
      ..base_email(),
      text_body: [
        plain("p1", "abcdef"),
        plain("p2", "ghijkl"),
        plain("p3", "x"),
      ],
      body_values: [
        value_of("p1", "abcdef"),
        value_of("p2", "ghijkl"),
        value_of("p3", "x"),
      ],
    )

  let message = normalise.message(email, "state-1", 10)

  body_texts(message) |> should.equal(["abcdef", "ghij", ""])
  body_truncations(message)
  |> should.equal([
    #(False, None),
    #(True, Some(model.MessageLimit)),
    #(True, Some(model.MessageLimit)),
  ])
}

/// A cut lands on a character boundary: the three remaining bytes can hold
/// `é` (2 bytes) but not `☃` (3 more), so neither character is split.
pub fn message_limit_utf8_never_splits_a_character_test() {
  let email =
    normalise.Email(
      ..base_email(),
      text_body: [plain("p1", "abcde"), plain("p2", "é☃x")],
      body_values: [value_of("p1", "abcde"), value_of("p2", "é☃x")],
    )

  let message = normalise.message(email, "state-1", 8)

  string.byte_size("é") |> should.equal(2)
  body_texts(message) |> should.equal(["abcde", "é"])
  body_truncations(message)
  |> should.equal([
    #(False, None),
    #(True, Some(model.MessageLimit)),
  ])
}

/// The bound counts converted text, not the raw HTML: the first part's HTML is
/// 20 bytes and must still be stored whole because its text is 6.
pub fn message_limit_counts_html_after_conversion_test() {
  let email =
    normalise.Email(
      ..base_email(),
      text_body: [
        html("p1", "<p><b>abcdef</b></p>"),
        html("p2", "<i>ghijkl</i>"),
      ],
      body_values: [
        value_of("p1", "<p><b>abcdef</b></p>"),
        value_of("p2", "<i>ghijkl</i>"),
      ],
    )

  let message = normalise.message(email, "state-1", 10)

  message.bodies
  |> list.map(fn(body) { body.source })
  |> should.equal([model.Html, model.Html])

  body_texts(message) |> should.equal(["abcdef", "ghij"])
  body_truncations(message)
  |> should.equal([
    #(False, None),
    #(True, Some(model.MessageLimit)),
  ])
}

/// A part the server already truncated stays marked as the server's cut when
/// the per-message bound does not cut it further.
pub fn message_limit_keeps_a_server_truncated_part_test() {
  let email =
    normalise.Email(
      ..base_email(),
      text_body: [plain("p1", "abcdef")],
      body_values: [value_with("p1", "abcdef", False, True)],
    )

  let message = normalise.message(email, "state-1", 100)

  let assert [body] = message.bodies
  body.text |> should.equal("abcdef")
  body.is_truncated |> should.be_true
  body.truncated_by |> should.equal(Some(model.Server))
}

/// When the server truncated a part and the per-message bound cuts it again,
/// the stored text is our cut, so the mark is ours.
pub fn message_limit_wins_over_server_truncation_test() {
  let email =
    normalise.Email(
      ..base_email(),
      text_body: [plain("p1", "abcdef")],
      body_values: [value_with("p1", "abcdef", False, True)],
    )

  let message = normalise.message(email, "state-1", 4)

  let assert [body] = message.bodies
  body.text |> should.equal("abcd")
  body.truncated_by |> should.equal(Some(model.MessageLimit))
}

/// The scalar properties are copied to their own fields, none swapped.
pub fn message_copies_scalar_fields_test() {
  let email =
    normalise.Email(
      ..base_email(),
      id: "e-id",
      blob_id: "b-id",
      thread_id: "t-id",
      size: 4321,
      subject: Some("subject"),
      sent_at: Some("2026-01-01T10:00:00+10:00"),
      has_attachment: True,
      preview: "preview text",
    )

  let message = normalise.message(email, "state-1", 1024)

  #(message.id, message.blob_id, message.thread_id, message.size)
  |> should.equal(#("e-id", "b-id", "t-id", 4321))
  message.received_at |> should.equal(email.received_at)
  message.sent_at |> should.equal(Some("2026-01-01T10:00:00+10:00"))
  message.has_attachment |> should.be_true
  message.preview |> should.equal("preview text")
}
