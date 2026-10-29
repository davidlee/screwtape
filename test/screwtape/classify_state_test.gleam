//// EX-8, VT-1, VT-2, VT-3, VT-6: the bounded window `state.window` derives
//// from one `Mail`, and the one encoder `state.encode` (SL-005 PHASE-02;
//// design § 5.1, § 5.3, § 5.6).
////
//// Every assertion parses the JSON `encode` returns, so the test holds the
//// contract rather than one printer's field order. `seen` is
//// `encode(w, identity)` and `state` is `encode(w, pii.strip)`; the bounds are
//// on `seen`, so the bound tests decode `seen`. The two cut-on-arrival tests
//// start from real `render.read` output, because that is where the partial
//// word this module must drop comes from.

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/classify/input.{type Mail, Address, Mail, MailBody}
import screwtape/classify/state
import screwtape/model.{
  type Body, type UtcDate, Body, Message, PlainText, UtcDate,
}
import screwtape/pii
import screwtape/render
import screwtape/utf8
import support/snapshot_fixture

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// The parsed window: `seen` and `state` share one shape and one decoder
// ---------------------------------------------------------------------------

type State {
  State(
    subject: Option(String),
    from: List(EntryOut),
    from_omitted: Int,
    sender: List(EntryOut),
    sender_omitted: Int,
    reply_to: List(EntryOut),
    reply_to_omitted: Int,
    to: List(EntryOut),
    to_omitted: Int,
    cc: List(EntryOut),
    cc_omitted: Int,
    bcc: List(EntryOut),
    bcc_omitted: Int,
    bodies: List(BodyOut),
    bodies_omitted: Int,
    attachments: List(AttachmentOut),
    attachments_omitted: Int,
  )
}

type EntryOut {
  EntryOut(name: Option(String), email: String)
}

type BodyOut {
  BodyOut(text: String, is_truncated: Bool, conversion_failed: Bool)
}

type AttachmentOut {
  AttachmentOut(type_: String, name: Option(String))
}

// ---------------------------------------------------------------------------
// Bounds: the subject, the bodies and the attachments
// ---------------------------------------------------------------------------

pub fn bodies_are_bounded_and_counted_test() {
  let bodies = list.repeat(MailBody("body", False, False), 12)
  let s = seen_of(Mail(..base_mail(), bodies: bodies))
  list.length(s.bodies) |> should.equal(10)
  s.bodies_omitted |> should.equal(2)
  list.each(s.bodies, fn(body) { body.text |> should.equal("body") })
}

pub fn body_text_total_is_shared_in_order_test() {
  let body = MailBody(string.repeat("a", 20_000), False, False)
  let s = seen_of(Mail(..base_mail(), bodies: [body, body]))
  total_bytes(s.bodies) |> should.equal(16_384)
  let assert [first, second] = s.bodies
  string.byte_size(first.text) |> should.equal(16_384)
  first.is_truncated |> should.be_true
  second.text |> should.equal("")
}

pub fn body_after_an_exhausted_budget_is_empty_and_flagged_test() {
  let whole = MailBody(string.repeat("a", 16_384), False, False)
  let s =
    seen_of(
      Mail(..base_mail(), bodies: [
        whole,
        MailBody("bob@shop.example", False, False),
      ]),
    )
  s.bodies
  |> should.equal([
    BodyOut(string.repeat("a", 16_384), False, False),
    BodyOut("", True, False),
  ])
  total_bytes(s.bodies) |> should.equal(16_384)
}

pub fn empty_body_after_an_exhausted_budget_is_not_flagged_test() {
  let whole = MailBody(string.repeat("a", 16_384), False, False)
  let s =
    seen_of(Mail(..base_mail(), bodies: [whole, MailBody("", False, False)]))
  s.bodies
  |> should.equal([
    BodyOut(string.repeat("a", 16_384), False, False),
    BodyOut("", False, False),
  ])
}

pub fn body_text_is_cut_on_a_codepoint_test() {
  let body = MailBody(string.repeat("€", 6000), False, False)
  let s = seen_of(Mail(..base_mail(), bodies: [body]))
  let assert [sent] = s.bodies
  string.byte_size(sent.text) |> should.equal(16_383)
  string.to_utf_codepoints(sent.text)
  |> list.length
  |> should.equal(5461)
  sent.is_truncated |> should.be_true
}

pub fn subject_is_cut_to_512_bytes_test() {
  let s = seen_of(Mail(..base_mail(), subject: Some(string.repeat("s", 600))))
  s.subject |> should.equal(Some(string.repeat("s", 512)))
}

pub fn attachments_are_bounded_and_counted_test() {
  let attachment = #("text/plain", Some("name"))
  let attachments = list.repeat(attachment, 22)
  let s = seen_of(Mail(..base_mail(), attachments: attachments))
  list.length(s.attachments) |> should.equal(20)
  s.attachments_omitted |> should.equal(2)
}

pub fn attachment_type_and_name_are_cut_to_128_bytes_test() {
  let attachment = #(string.repeat("t", 200), Some(string.repeat("n", 200)))
  let s = seen_of(Mail(..base_mail(), attachments: [attachment]))
  s.attachments
  |> should.equal([
    AttachmentOut(string.repeat("t", 128), Some(string.repeat("n", 128))),
  ])
}

// ---------------------------------------------------------------------------
// VT-2: the partial word is dropped when a text is cut here
// ---------------------------------------------------------------------------

pub fn subject_cut_mid_word_drops_the_partial_word_test() {
  // 80 words of `abcdefgh `; 512 bytes end after the 57th word's eighth byte,
  // before its space, so that word is partial and dropped.
  let subject = string.repeat("abcdefgh ", 80)
  let s = seen_of(Mail(..base_mail(), subject: Some(subject)))
  s.subject |> should.equal(Some(string.repeat("abcdefgh ", 56)))
}

pub fn whitespace_free_prefix_is_kept_whole_test() {
  let s =
    seen_of(
      Mail(..base_mail(), subject: Some(string.repeat("s", 600)), bodies: [
        MailBody(string.repeat("b", 20_000), False, False),
      ]),
    )
  s.subject |> should.equal(Some(string.repeat("s", 512)))
  let assert [body] = s.bodies
  body.text |> should.equal(string.repeat("b", 16_384))
  body.is_truncated |> should.be_true
}

pub fn name_cut_mid_word_drops_the_partial_word_test() {
  let s =
    seen_of(
      Mail(..base_mail(), from: [
        Address(name: Some(string.repeat("name ", 40)), email: "a@b.example"),
      ]),
    )
  s.from
  |> should.equal([
    EntryOut(Some(string.repeat("name ", 25)), "a@b.example"),
  ])
}

pub fn attachment_type_and_name_cut_mid_word_drop_the_partial_word_test() {
  let s =
    seen_of(
      Mail(..base_mail(), attachments: [
        #(string.repeat("type ", 40), Some(string.repeat("word ", 40))),
      ]),
    )
  s.attachments
  |> should.equal([
    AttachmentOut(string.repeat("type ", 25), Some(string.repeat("word ", 25))),
  ])
}

pub fn body_cut_here_drops_its_partial_word_and_frees_the_bytes_for_the_next_test() {
  // 16,384 / 5 = 3276 words, then four bytes of the 3277th: the drop frees four
  // bytes, so the next body still has room.
  let s =
    seen_of(
      Mail(..base_mail(), bodies: [
        MailBody(string.repeat("word ", 4000), False, False),
        MailBody("xy", False, False),
      ]),
    )
  let assert [first, second] = s.bodies
  first.text |> should.equal(string.repeat("word ", 3276))
  first.is_truncated |> should.be_true
  second.text |> should.equal("xy")
  second.is_truncated |> should.be_false
}

pub fn control_removal_alone_is_not_truncation_is_truncated_false_test() {
  let s =
    seen_of(
      Mail(..base_mail(), subject: Some("alpha\u{0007} beta"), bodies: [
        MailBody("one\u{202E}two three", False, False),
      ]),
    )
  // The controls go; the words after the space stay (nothing was cut).
  s.subject |> should.equal(Some("alpha beta"))
  let assert [body] = s.bodies
  body.text |> should.equal("onetwo three")
  body.is_truncated |> should.be_false
}

// ---------------------------------------------------------------------------
// Text handling
// ---------------------------------------------------------------------------

pub fn control_characters_are_removed_test() {
  let bidi =
    "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"
  let mail =
    Mail(
      ..base_mail(),
      subject: Some("s\u{0000}u\u{001F}b\t\n\r\u{007F}j" <> bidi),
      bodies: [MailBody("b\u{0001}o\u{007F}dy", False, False)],
      attachments: [#("app\u{0002}/pdf", Some("n\u{007F}ame"))],
    )
  let s = seen_of(mail)
  s.subject |> should.equal(Some("sub\t\n\rj"))
  s.bodies |> should.equal([BodyOut("body", False, False)])
  s.attachments |> should.equal([AttachmentOut("app/pdf", Some("name"))])
}

pub fn pii_strip_applies_a_token_rule_to_subject_body_and_attachment_fields_test() {
  let mail =
    Mail(
      ..base_mail(),
      subject: Some("key Zx9Qw8Er7Ty6Ui5Op4As3Df2 ok"),
      bodies: [MailBody("key Zx9Qw8Er7Ty6Ui5Op4As3Df2 ok", False, False)],
      attachments: [
        #("app/Zx9Qw8Er7Ty6Ui5Op4As3Df2", Some("name Zx9Qw8Er7Ty6Ui5Op4As3Df2")),
      ],
    )
  let s = state_of(mail)
  s.subject |> should.equal(Some("key [token] ok"))
  s.bodies |> should.equal([BodyOut("key [token] ok", False, False)])
  s.attachments
  |> should.equal([AttachmentOut("app/[token]", Some("name [token]"))])
}

pub fn attachment_type_is_cut_before_it_is_stripped_test() {
  // The URL sits inside the first 128 bytes; the cut drops the filler after it,
  // and only then does the strip lengthen `?id=1` to `?[…]`.
  let type_ =
    "https://shop.example/track?id=1 " <> string.repeat("x", 120) <> " tail"
  let mail = Mail(..base_mail(), attachments: [#(type_, None)])
  let s = seen_of(mail)
  let assert [attachment] = s.attachments
  attachment.type_ |> should.equal("https://shop.example/track?id=1 ")
  string.byte_size(attachment.type_) |> should.equal(32)
  let st = state_of(mail)
  let assert [stripped] = st.attachments
  stripped.type_ |> should.equal(pii.strip(attachment.type_))
  string.byte_size(stripped.type_)
  |> should.equal(string.byte_size(attachment.type_) + 1)
}

pub fn stripping_that_lengthens_stays_within_the_body_total_test() {
  // The query `?q` (two bytes) becomes `?[…]` (six bytes): each 11-byte URL
  // grows by 4, so a `state` text can pass its `seen` bound.
  let text = string.repeat("http://h?q ", 1000)
  let bodies = list.repeat(MailBody(text, False, False), 10)
  let mail = Mail(..base_mail(), bodies: bodies)
  let seen = seen_of(mail)
  let st = state_of(mail)
  total_bytes(seen.bodies) |> should.equal(16_384)
  should.be_true(total_bytes(st.bodies) > 16_384)
  list.zip(seen.bodies, st.bodies)
  |> list.each(fn(pair) {
    let #(seen_body, state_body) = pair
    state_body.text |> should.equal(pii.strip(seen_body.text))
  })
  let assert [first, _second, _third, ..] = seen.bodies
  first.is_truncated |> should.be_false
}

pub fn a_truncated_body_loses_its_partial_word_test() {
  let s =
    seen_of(
      Mail(..base_mail(), bodies: [MailBody("keep partial", True, False)]),
    )
  s.bodies |> should.equal([BodyOut("keep ", True, False)])
}

pub fn conversion_failed_passes_through_test() {
  let s = seen_of(Mail(..base_mail(), bodies: [MailBody("text", False, True)]))
  s.bodies |> should.equal([BodyOut("text", False, True)])
}

// ---------------------------------------------------------------------------
// Cut on arrival, from real `render.read` output
// ---------------------------------------------------------------------------

pub fn read_output_cut_mid_address_drops_the_fragment_test() {
  let message =
    Message(..snapshot_fixture.bare_message("M1", at()), bodies: [
      model_body("write to person@example.com now"),
    ])
  let read = render.read(account_id: "A", message: message, max_bytes: Some(15))
  let assert Ok(mail) = input.line(read)
  mail.output_truncated |> should.be_true
  let s = seen_of(mail)
  let assert [body] = s.bodies
  body.text |> should.equal("write to ")
  body.is_truncated |> should.be_true
  list.each(["@", "person", "example"], fn(fragment) {
    string.contains(body.text, fragment) |> should.be_false
  })
}

pub fn read_output_cut_to_nothing_is_cut_on_arrival_test() {
  let message =
    Message(..snapshot_fixture.bare_message("M2", at()), bodies: [
      model_body("€"),
    ])
  let read = render.read(account_id: "A", message: message, max_bytes: Some(1))
  let assert Ok(mail) = input.line(read)
  mail.bodies |> should.equal([MailBody("", False, False)])
  let s = seen_of(mail)
  s.bodies |> should.equal([BodyOut("", True, False)])
}

// ---------------------------------------------------------------------------
// VT-3: the six address lists
// ---------------------------------------------------------------------------

pub fn six_lists_are_kept_in_order_test() {
  let mail =
    Mail(
      ..base_mail(),
      from: [
        Address(name: Some("Alice"), email: "alice@one.example"),
        Address(name: None, email: "bob@two.example"),
        Address(name: Some("Alice"), email: "alice@one.example"),
      ],
      sender: [Address(name: Some("Sender"), email: "sender@example.com")],
      reply_to: [Address(name: None, email: "reply@example.com")],
      to: [Address(name: Some("To"), email: "to@example.com")],
      cc: [Address(name: Some("Cc"), email: "cc@example.com")],
      bcc: [Address(name: None, email: "bcc@example.com")],
    )
  let s = seen_of(mail)
  // Read order, and no deduplication of the repeated `alice` entry.
  s.from
  |> should.equal([
    EntryOut(Some("Alice"), "alice@one.example"),
    EntryOut(None, "bob@two.example"),
    EntryOut(Some("Alice"), "alice@one.example"),
  ])
  s.sender
  |> should.equal([EntryOut(Some("Sender"), "sender@example.com")])
  s.reply_to |> should.equal([EntryOut(None, "reply@example.com")])
  s.to |> should.equal([EntryOut(Some("To"), "to@example.com")])
  s.cc |> should.equal([EntryOut(Some("Cc"), "cc@example.com")])
  s.bcc |> should.equal([EntryOut(None, "bcc@example.com")])
  // A None name is JSON null.
  state.encode(state.window(mail), fn(text) { text })
  |> json.to_string
  |> string.contains("\"name\":null")
  |> should.be_true
}

pub fn each_list_keeps_ten_and_counts_the_rest_test() {
  let twelve =
    list.index_map(list.repeat(Nil, 12), fn(_, index) {
      Address(
        name: None,
        email: "user" <> int.to_string(index) <> "@example.com",
      )
    })
  let mail = Mail(..base_mail(), from: twelve, reply_to: twelve, bcc: twelve)
  let s = seen_of(mail)
  list.length(s.from) |> should.equal(10)
  list.length(s.reply_to) |> should.equal(10)
  list.length(s.bcc) |> should.equal(10)
  s.from_omitted |> should.equal(2)
  s.reply_to_omitted |> should.equal(2)
  s.bcc_omitted |> should.equal(2)
  s.from
  |> list.map(fn(entry) { entry.email })
  |> should.equal([
    "user0@example.com",
    "user1@example.com",
    "user2@example.com",
    "user3@example.com",
    "user4@example.com",
    "user5@example.com",
    "user6@example.com",
    "user7@example.com",
    "user8@example.com",
    "user9@example.com",
  ])
  s.sender_omitted |> should.equal(0)
  s.to_omitted |> should.equal(0)
  s.cc_omitted |> should.equal(0)
}

pub fn oversize_email_drops_its_entry_and_is_counted_test() {
  let at_254 = string.repeat("d", 254)
  let at_255 = string.repeat("d", 255)
  let nine =
    list.index_map(list.repeat(Nil, 9), fn(_, index) {
      Address(
        name: None,
        email: "user" <> int.to_string(index) <> "@example.com",
      )
    })
  // The oversize entry sits among the first ten: it takes no slot, so all ten
  // valid entries survive, including the one at exactly 254 bytes.
  let from = [
    Address(name: None, email: at_254),
    Address(name: None, email: at_255),
    ..nine
  ]
  let s = seen_of(Mail(..base_mail(), from: from))
  list.length(s.from) |> should.equal(10)
  s.from_omitted |> should.equal(1)
  s.from |> list.first |> should.equal(Ok(EntryOut(None, at_254)))
  s.from
  |> list.last
  |> should.equal(Ok(EntryOut(None, "user8@example.com")))
}

pub fn names_lose_controls_and_bidi_overrides_test() {
  let s =
    seen_of(
      Mail(..base_mail(), from: [
        Address(
          name: Some("a\u{202E}b\u{2066}c\u{0007}d"),
          email: "keep \u{0007} this",
        ),
      ]),
    )
  // The name is cleaned; the email only loses controls — it is never cut and
  // never loses a word.
  s.from |> should.equal([EntryOut(Some("abcd"), "keep  this")])
}

// ---------------------------------------------------------------------------
// VT-1: `state` is `seen` with `pii.strip` on every string
// ---------------------------------------------------------------------------

pub fn state_is_seen_with_pii_strip_on_every_string_test() {
  let text = "http://u:p@h/x?q=1 abcdefghij0123456789 12345678"
  let mail =
    Mail(
      ..base_mail(),
      subject: Some(text),
      from: [
        Address(name: Some("Alice"), email: "abcdefghij0123456789@example.com"),
        Address(name: None, email: "bob@example.com"),
      ],
      sender: [Address(name: None, email: "sender@example.com")],
      reply_to: [
        Address(name: Some("Reply 12345678"), email: "reply@example.com"),
      ],
      to: [Address(name: Some("To"), email: "to@example.com")],
      cc: [Address(name: None, email: "cc@example.com")],
      bcc: [Address(name: Some("Bcc"), email: "bcc@example.com")],
      bodies: [
        MailBody(text, False, False),
        MailBody("plain", True, False),
        MailBody(text, False, True),
      ],
      attachments: [
        #("application/pdf", Some(text)),
        #("text/plain", None),
      ],
    )
  let seen = tree(state.encode(state.window(mail), fn(value) { value }))
  let st = tree(state.encode(state.window(mail), pii.strip))
  strip_strings(seen) |> should.equal(st)
  // The test is not vacuous: the strip changes at least one string.
  should.be_true(seen != st)
}

// ---------------------------------------------------------------------------
// VT-6: the worst-case encoded size (ASM-006)
// ---------------------------------------------------------------------------

/// The filler unit: nine bytes that `pii.strip` turns into fourteen — each
/// query `?` becomes `?[…]`, so placeholders grow the worst case.
const filler_unit = "http://? "

fn filler(bytes: Int) -> String {
  utf8.prefix(string.repeat(filler_unit, bytes / 9 + 1), bytes)
}

pub fn worst_case_state_size_is_pinned_test() {
  let address = Address(name: Some(filler(128)), email: filler(254))
  let addresses = list.repeat(address, 10)
  let bodies =
    list.flatten([
      list.repeat(MailBody(filler(1638), False, False), 9),
      [MailBody(filler(1642), False, False)],
    ])
  let attachment = #(filler(128), Some(filler(128)))
  let mail =
    Mail(
      ..base_mail(),
      subject: Some(filler(512)),
      from: addresses,
      sender: addresses,
      reply_to: addresses,
      to: addresses,
      cc: addresses,
      bcc: addresses,
      bodies: bodies,
      attachments: list.repeat(attachment, 20),
    )
  let w = state.window(mail)
  let seen = state.encode(w, fn(value) { value }) |> json.to_string
  let st = state.encode(w, pii.strip) |> json.to_string
  // Pinned: 47,588 bytes of `seen` and 72,373 bytes of `state` (ASM-006).
  string.byte_size(seen) |> should.equal(47_588)
  string.byte_size(st) |> should.equal(72_373)
  // Every body is at its bound and nothing was cut: 9 * 1638 + 1642 = 16384.
  let seen_entry = seen_of(mail)
  total_bytes(seen_entry.bodies) |> should.equal(16_384)
  list.each(seen_entry.bodies, fn(body) { body.is_truncated |> should.be_false })
}

// ---------------------------------------------------------------------------
// EX-8: the field set is the contract, positively
// ---------------------------------------------------------------------------

pub fn state_holds_only_the_contract_fields_test() {
  let mail =
    Mail(
      ..base_mail(),
      subject: Some("Subject"),
      from: [Address(name: Some("Alice"), email: "alice@shop.example")],
      bodies: [MailBody("Body", False, False)],
      attachments: [#("application/pdf", Some("invoice.pdf"))],
    )
  keys_of(json_value(mail))
  |> should.equal([
    "attachments",
    "attachments_omitted",
    "bcc",
    "bcc_omitted",
    "bodies",
    "bodies_omitted",
    "cc",
    "cc_omitted",
    "from",
    "from_omitted",
    "reply_to",
    "reply_to_omitted",
    "sender",
    "sender_omitted",
    "subject",
    "to",
    "to_omitted",
  ])
  entry_keys(mail) |> should.equal([["email", "name"]])
  body_keys(mail)
  |> should.equal([["conversion_failed", "is_truncated", "text"]])
  attachment_keys(mail) |> should.equal([["name", "type"]])
}

pub fn fields_are_encoded_in_contract_order_test() {
  state.encode(state.window(base_mail()), fn(text) { text })
  |> json.to_string
  |> should.equal(
    "{\"subject\":null,"
    <> "\"from\":[],\"from_omitted\":0,"
    <> "\"sender\":[],\"sender_omitted\":0,"
    <> "\"reply_to\":[],\"reply_to_omitted\":0,"
    <> "\"to\":[],\"to_omitted\":0,"
    <> "\"cc\":[],\"cc_omitted\":0,"
    <> "\"bcc\":[],\"bcc_omitted\":0,"
    <> "\"bodies\":[],\"bodies_omitted\":0,"
    <> "\"attachments\":[],\"attachments_omitted\":0}",
  )
}

pub fn absent_subject_is_null_and_empty_lists_are_empty_test() {
  let s = seen_of(base_mail())
  s.subject |> should.equal(None)
  s.from |> should.equal([])
  s.from_omitted |> should.equal(0)
  s.sender |> should.equal([])
  s.sender_omitted |> should.equal(0)
  s.reply_to |> should.equal([])
  s.reply_to_omitted |> should.equal(0)
  s.to |> should.equal([])
  s.to_omitted |> should.equal(0)
  s.cc |> should.equal([])
  s.cc_omitted |> should.equal(0)
  s.bcc |> should.equal([])
  s.bcc_omitted |> should.equal(0)
  s.bodies |> should.equal([])
  s.bodies_omitted |> should.equal(0)
  s.attachments |> should.equal([])
  s.attachments_omitted |> should.equal(0)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn base_mail() -> Mail {
  Mail(
    id: "M1",
    cursor: "1:M1",
    subject: None,
    from: [],
    sender: [],
    reply_to: [],
    to: [],
    cc: [],
    bcc: [],
    bodies: [],
    attachments: [],
    output_truncated: False,
  )
}

fn at() -> UtcDate {
  UtcDate(raw: "2026-10-26T10:15:30Z", ms: 1_793_009_730_000)
}

fn model_body(text: String) -> Body {
  Body(
    part_id: "1",
    source: PlainText,
    text: text,
    is_truncated: False,
    truncated_by: None,
    is_encoding_problem: False,
    conversion_failed: False,
    max_body_value_bytes: 4096,
  )
}

fn seen_of(mail: Mail) -> State {
  decode_state(state.encode(state.window(mail), fn(text) { text }))
}

fn state_of(mail: Mail) -> State {
  decode_state(state.encode(state.window(mail), pii.strip))
}

fn decode_state(encoded: json.Json) -> State {
  let assert Ok(decoded) =
    encoded |> json.to_string |> json.parse(using: state_decoder())
  decoded
}

fn json_value(mail: Mail) -> Dynamic {
  let assert Ok(value) =
    state.encode(state.window(mail), pii.strip)
    |> json.to_string
    |> json.parse(using: decode.dynamic)
  value
}

fn keys_of(value: Dynamic) -> List(String) {
  let assert Ok(object) =
    decode.run(value, decode.dict(decode.string, decode.dynamic))
  object |> dict.keys |> list.sort(string.compare)
}

fn entry_keys(mail: Mail) -> List(List(String)) {
  let assert Ok(entries) =
    decode.run(
      json_value(mail),
      decode.field("from", decode.list(decode.dynamic), decode.success),
    )
  list.map(entries, keys_of)
}

fn body_keys(mail: Mail) -> List(List(String)) {
  let assert Ok(bodies) =
    decode.run(
      json_value(mail),
      decode.field("bodies", decode.list(decode.dynamic), decode.success),
    )
  list.map(bodies, keys_of)
}

fn attachment_keys(mail: Mail) -> List(List(String)) {
  let assert Ok(attachments) =
    decode.run(
      json_value(mail),
      decode.field("attachments", decode.list(decode.dynamic), decode.success),
    )
  list.map(attachments, keys_of)
}

fn total_bytes(bodies: List(BodyOut)) -> Int {
  list.fold(bodies, 0, fn(total, body) { total + string.byte_size(body.text) })
}

// ---------------------------------------------------------------------------
// A generic JSON tree, so `state` can be compared with `seen` string by string
// ---------------------------------------------------------------------------

type Value {
  VString(String)
  VInt(Int)
  VBool(Bool)
  VNull
  VList(List(Value))
  VObject(List(#(String, Value)))
}

fn tree(encoded: json.Json) -> Value {
  let assert Ok(dynamic) =
    encoded |> json.to_string |> json.parse(using: decode.dynamic)
  value_of(dynamic)
}

fn value_of(dynamic: Dynamic) -> Value {
  case decode.run(dynamic, decode.string) {
    Ok(text) -> VString(text)
    Error(_) ->
      case decode.run(dynamic, decode.int) {
        Ok(number) -> VInt(number)
        Error(_) ->
          case decode.run(dynamic, decode.bool) {
            Ok(flag) -> VBool(flag)
            Error(_) ->
              case decode.run(dynamic, decode.list(decode.dynamic)) {
                Ok(items) -> VList(list.map(items, value_of))
                Error(_) ->
                  case
                    decode.run(
                      dynamic,
                      decode.dict(decode.string, decode.dynamic),
                    )
                  {
                    Ok(fields) -> VObject(object_fields(fields))
                    Error(_) -> VNull
                  }
              }
          }
      }
  }
}

/// The object's fields by key, so two encodings compare whatever their order.
fn object_fields(fields: dict.Dict(String, Dynamic)) -> List(#(String, Value)) {
  fields
  |> dict.to_list
  |> list.map(fn(field) { #(field.0, value_of(field.1)) })
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
}

fn strip_strings(value: Value) -> Value {
  case value {
    VString(text) -> VString(pii.strip(text))
    VList(items) -> VList(list.map(items, strip_strings))
    VObject(fields) ->
      VObject(
        list.map(fields, fn(field) { #(field.0, strip_strings(field.1)) }),
      )
    VInt(_) | VBool(_) | VNull -> value
  }
}

// ---------------------------------------------------------------------------
// The one decoder: `seen` and `state` have the same shape
// ---------------------------------------------------------------------------

fn state_decoder() -> decode.Decoder(State) {
  use subject <- decode.field("subject", decode.optional(decode.string))
  use from <- decode.field("from", decode.list(entry_decoder()))
  use from_omitted <- decode.field("from_omitted", decode.int)
  use sender <- decode.field("sender", decode.list(entry_decoder()))
  use sender_omitted <- decode.field("sender_omitted", decode.int)
  use reply_to <- decode.field("reply_to", decode.list(entry_decoder()))
  use reply_to_omitted <- decode.field("reply_to_omitted", decode.int)
  use to <- decode.field("to", decode.list(entry_decoder()))
  use to_omitted <- decode.field("to_omitted", decode.int)
  use cc <- decode.field("cc", decode.list(entry_decoder()))
  use cc_omitted <- decode.field("cc_omitted", decode.int)
  use bcc <- decode.field("bcc", decode.list(entry_decoder()))
  use bcc_omitted <- decode.field("bcc_omitted", decode.int)
  use bodies <- decode.field("bodies", decode.list(body_decoder()))
  use bodies_omitted <- decode.field("bodies_omitted", decode.int)
  use attachments <- decode.field(
    "attachments",
    decode.list(attachment_decoder()),
  )
  use attachments_omitted <- decode.field("attachments_omitted", decode.int)
  decode.success(State(
    subject: subject,
    from: from,
    from_omitted: from_omitted,
    sender: sender,
    sender_omitted: sender_omitted,
    reply_to: reply_to,
    reply_to_omitted: reply_to_omitted,
    to: to,
    to_omitted: to_omitted,
    cc: cc,
    cc_omitted: cc_omitted,
    bcc: bcc,
    bcc_omitted: bcc_omitted,
    bodies: bodies,
    bodies_omitted: bodies_omitted,
    attachments: attachments,
    attachments_omitted: attachments_omitted,
  ))
}

fn entry_decoder() -> decode.Decoder(EntryOut) {
  use name <- decode.field("name", decode.optional(decode.string))
  use email <- decode.field("email", decode.string)
  decode.success(EntryOut(name: name, email: email))
}

fn body_decoder() -> decode.Decoder(BodyOut) {
  use text <- decode.field("text", decode.string)
  use is_truncated <- decode.field("is_truncated", decode.bool)
  use conversion_failed <- decode.field("conversion_failed", decode.bool)
  decode.success(BodyOut(
    text: text,
    is_truncated: is_truncated,
    conversion_failed: conversion_failed,
  ))
}

fn attachment_decoder() -> decode.Decoder(AttachmentOut) {
  use type_ <- decode.field("type", decode.string)
  use name <- decode.field("name", decode.optional(decode.string))
  decode.success(AttachmentOut(type_: type_, name: name))
}
