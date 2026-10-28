//// VT-4: the bounded classifier state `state.build` derives from one `Mail`
//// (PHASE-12, T3; design § 5.2).
////
//// Every assertion parses the JSON `build` returns, so the test holds the
//// contract rather than one printer's field order. The two cut-on-arrival tests
//// start from real `render.read` output, because that is where the partial word
//// this module must drop comes from.

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
import screwtape/classify/input.{type Mail, Mail, MailBody}
import screwtape/classify/state
import screwtape/model.{
  type Body, type UtcDate, Body, Message, PlainText, UtcDate,
}
import screwtape/render
import support/snapshot_fixture

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// The parsed state
// ---------------------------------------------------------------------------

type State {
  State(
    subject: Option(String),
    sender_domains: List(String),
    sender_domains_omitted: Int,
    bodies: List(BodyOut),
    bodies_omitted: Int,
    attachments: List(AttachmentOut),
    attachments_omitted: Int,
  )
}

type BodyOut {
  BodyOut(text: String, is_truncated: Bool, conversion_failed: Bool)
}

type AttachmentOut {
  AttachmentOut(type_: String, name: Option(String))
}

// ---------------------------------------------------------------------------
// Bounds
// ---------------------------------------------------------------------------

pub fn bodies_are_bounded_and_counted_test() {
  let bodies = list.repeat(MailBody("body", False, False), 12)
  let s = state_of(Mail(..base_mail(), bodies: bodies))
  list.length(s.bodies) |> should.equal(10)
  s.bodies_omitted |> should.equal(2)
  list.each(s.bodies, fn(body) { body.text |> should.equal("body") })
}

pub fn body_text_total_is_shared_in_order_test() {
  let body = MailBody(string.repeat("a", 20_000), False, False)
  let s = state_of(Mail(..base_mail(), bodies: [body, body]))
  total_bytes(s.bodies) |> should.equal(16_384)
  let assert [first, second] = s.bodies
  string.byte_size(first.text) |> should.equal(16_384)
  first.is_truncated |> should.be_true
  second.text |> should.equal("")
}

pub fn body_after_an_exhausted_budget_is_empty_and_flagged_test() {
  let whole = MailBody(string.repeat("a", 16_384), False, False)
  let s =
    state_of(
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
    state_of(Mail(..base_mail(), bodies: [whole, MailBody("", False, False)]))
  s.bodies
  |> should.equal([
    BodyOut(string.repeat("a", 16_384), False, False),
    BodyOut("", False, False),
  ])
}

pub fn body_text_is_cut_on_a_codepoint_test() {
  let body = MailBody(string.repeat("€", 6000), False, False)
  let s = state_of(Mail(..base_mail(), bodies: [body]))
  let assert [sent] = s.bodies
  string.byte_size(sent.text) |> should.equal(16_383)
  string.to_utf_codepoints(sent.text)
  |> list.length
  |> should.equal(5461)
  sent.is_truncated |> should.be_true
}

pub fn subject_is_cut_to_512_bytes_test() {
  let s = state_of(Mail(..base_mail(), subject: Some(string.repeat("s", 600))))
  s.subject |> should.equal(Some(string.repeat("s", 512)))
}

pub fn sender_domains_are_lowercased_deduped_and_counted_test() {
  let long_domain = string.repeat("d", 254)
  let unique =
    list.index_map(list.repeat(Nil, 9), fn(_, index) {
      "user@d" <> int.to_string(index + 3) <> ".example"
    })
  let senders =
    list.append(
      [
        "A@ONE.Example",
        "b@two.example",
        "c@one.example",
        "no-at-sender",
        "x@" <> long_domain,
      ],
      unique,
    )
  let s = state_of(Mail(..base_mail(), senders: senders))
  s.sender_domains
  |> should.equal([
    "one.example",
    "two.example",
    "d3.example",
    "d4.example",
    "d5.example",
    "d6.example",
    "d7.example",
    "d8.example",
    "d9.example",
    "d10.example",
  ])
  s.sender_domains_omitted |> should.equal(3)
}

pub fn attachments_are_bounded_and_counted_test() {
  let attachment = #("text/plain", Some("name"))
  let attachments = list.repeat(attachment, 22)
  let s = state_of(Mail(..base_mail(), attachments: attachments))
  list.length(s.attachments) |> should.equal(20)
  s.attachments_omitted |> should.equal(2)
}

pub fn attachment_type_and_name_are_cut_to_128_bytes_test() {
  let attachment = #(string.repeat("t", 200), Some(string.repeat("n", 200)))
  let s = state_of(Mail(..base_mail(), attachments: [attachment]))
  s.attachments
  |> should.equal([
    AttachmentOut(string.repeat("t", 128), Some(string.repeat("n", 128))),
  ])
}

// ---------------------------------------------------------------------------
// Text handling
// ---------------------------------------------------------------------------

pub fn control_characters_are_removed_test() {
  let mail =
    Mail(
      ..base_mail(),
      subject: Some("s\u{0000}u\u{001F}b\t\n\r\u{007F}j"),
      bodies: [MailBody("b\u{0001}o\u{007F}dy", False, False)],
      attachments: [#("app\u{0002}/pdf", Some("n\u{007F}ame"))],
    )
  let s = state_of(mail)
  s.subject |> should.equal(Some("sub\t\n\rj"))
  s.bodies |> should.equal([BodyOut("body", False, False)])
  s.attachments |> should.equal([AttachmentOut("app/pdf", Some("name"))])
}

pub fn pii_strip_applies_to_subject_body_and_attachment_type_and_name_test() {
  let mail =
    Mail(
      ..base_mail(),
      subject: Some("write bob@shop.example"),
      bodies: [MailBody("mail bob@shop.example", False, False)],
      attachments: [#("mailto:bob@shop.example", Some("from bob@shop.example"))],
    )
  let s = state_of(mail)
  s.subject |> should.equal(Some("write [email]"))
  s.bodies |> should.equal([BodyOut("mail [email]", False, False)])
  s.attachments
  |> should.equal([AttachmentOut("mailto:[email]", Some("from [email]"))])
}

pub fn attachment_type_is_stripped_before_it_is_cut_test() {
  let attachment = #("see https://shop.example/track?id=123456789", None)
  let s = state_of(Mail(..base_mail(), attachments: [attachment]))
  s.attachments
  |> should.equal([AttachmentOut("see https://shop.example/[…]", None)])
}

pub fn empty_sender_domain_is_dropped_and_counted_test() {
  let s = state_of(Mail(..base_mail(), senders: ["a@", "b@shop.example"]))
  s.sender_domains |> should.equal(["shop.example"])
  s.sender_domains_omitted |> should.equal(1)
}

pub fn sender_domain_is_pii_stripped_test() {
  let s =
    state_of(Mail(..base_mail(), senders: ["x@Shop.Example?ref=12345678"]))
  s.sender_domains |> should.equal(["shop.example?ref=[number]"])
  s.sender_domains_omitted |> should.equal(0)
}

pub fn sender_domain_is_kept_at_253_bytes_and_dropped_at_254_test() {
  let at_253 = string.repeat("d", 253)
  let at_254 = string.repeat("d", 254)
  let s =
    state_of(Mail(..base_mail(), senders: ["a@" <> at_253, "b@" <> at_254]))
  s.sender_domains |> should.equal([at_253])
  s.sender_domains_omitted |> should.equal(1)
}

pub fn stripping_that_lengthens_stays_within_the_body_total_test() {
  let text = string.repeat("a@b.c ", 1000)
  let bodies = list.repeat(MailBody(text, False, False), 10)
  let s = state_of(Mail(..base_mail(), bodies: bodies))
  total_bytes(s.bodies) |> should.equal(16_384)
  let assert [_, _, third, ..] = s.bodies
  third.is_truncated |> should.be_true
}

pub fn a_truncated_body_loses_its_partial_word_test() {
  let s =
    state_of(
      Mail(..base_mail(), bodies: [MailBody("keep partial", True, False)]),
    )
  s.bodies |> should.equal([BodyOut("keep ", True, False)])
}

pub fn conversion_failed_passes_through_test() {
  let s = state_of(Mail(..base_mail(), bodies: [MailBody("text", False, True)]))
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
  let s = state_of(mail)
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
  let s = state_of(mail)
  s.bodies |> should.equal([BodyOut("", True, False)])
}

// ---------------------------------------------------------------------------
// Field set
// ---------------------------------------------------------------------------

pub fn state_holds_only_the_contract_fields_test() {
  let mail =
    Mail(
      ..base_mail(),
      subject: Some("Subject"),
      senders: ["alice@shop.example"],
      bodies: [MailBody("Body", False, False)],
      attachments: [#("application/pdf", Some("invoice.pdf"))],
    )
  keys_of(json_value(mail))
  |> should.equal([
    "attachments",
    "attachments_omitted",
    "bodies",
    "bodies_omitted",
    "sender_domains",
    "sender_domains_omitted",
    "subject",
  ])
  body_keys(mail)
  |> should.equal([["conversion_failed", "is_truncated", "text"]])
  attachment_keys(mail) |> should.equal([["name", "type"]])
  let raw = state.build(mail) |> json.to_string
  list.each(
    ["M1", "1:M1", "Alice", "alice", "provenance", "account_id"],
    fn(sentinel) { string.contains(raw, sentinel) |> should.be_false },
  )
}

pub fn absent_subject_is_null_and_empty_lists_are_empty_test() {
  let s = state_of(base_mail())
  s.subject |> should.equal(None)
  s.sender_domains |> should.equal([])
  s.sender_domains_omitted |> should.equal(0)
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
    senders: [],
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

fn state_of(mail: Mail) -> State {
  let encoded = state.build(mail) |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, using: state_decoder())
  decoded
}

fn json_value(mail: Mail) -> Dynamic {
  let assert Ok(value) =
    state.build(mail) |> json.to_string |> json.parse(using: decode.dynamic)
  value
}

fn keys_of(value: Dynamic) -> List(String) {
  let assert Ok(object) =
    decode.run(value, decode.dict(decode.string, decode.dynamic))
  object |> dict.keys |> list.sort(string.compare)
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

fn state_decoder() -> decode.Decoder(State) {
  use subject <- decode.field("subject", decode.optional(decode.string))
  use sender_domains <- decode.field(
    "sender_domains",
    decode.list(decode.string),
  )
  use sender_domains_omitted <- decode.field(
    "sender_domains_omitted",
    decode.int,
  )
  use bodies <- decode.field("bodies", decode.list(body_decoder()))
  use bodies_omitted <- decode.field("bodies_omitted", decode.int)
  use attachments <- decode.field(
    "attachments",
    decode.list(attachment_decoder()),
  )
  use attachments_omitted <- decode.field("attachments_omitted", decode.int)
  decode.success(State(
    subject: subject,
    sender_domains: sender_domains,
    sender_domains_omitted: sender_domains_omitted,
    bodies: bodies,
    bodies_omitted: bodies_omitted,
    attachments: attachments,
    attachments_omitted: attachments_omitted,
  ))
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
