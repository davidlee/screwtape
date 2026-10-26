//// Turn JMAP Email objects into the normalised model (PHASE-03; design § 5.1,
//// § 5.5), converting HTML bodies and enforcing the per-message body bound.
////
//// Pure. This module imports only `gleam_stdlib`, `screwtape/model` and
//// `screwtape/html_text` (invariant I5, enforced by `just check-imports`), so
//// it cannot do I/O. It therefore cannot build an `Error` either: the input
//// records below are what `jmap/decode` produces, and a timestamp that does
//// not parse fails there, as `Decode(path)` (DEC-021).

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order, Eq}
import gleam/result
import gleam/string
import screwtape/html_text
import screwtape/model.{type UtcDate}

/// The Email properties the model needs (RFC 8621 § 4.1), as decoded.
pub type Email {
  Email(
    id: String,
    blob_id: String,
    thread_id: String,
    /// The keys of `mailboxIds` whose value is `true`.
    mailbox_ids: List(String),
    /// The keys of `keywords` whose value is `true`.
    keywords: List(String),
    size: Int,
    received_at: UtcDate,
    message_id: Option(List(String)),
    in_reply_to: Option(List(String)),
    references: Option(List(String)),
    sender: Option(List(EmailAddress)),
    from: Option(List(EmailAddress)),
    to: Option(List(EmailAddress)),
    cc: Option(List(EmailAddress)),
    bcc: Option(List(EmailAddress)),
    reply_to: Option(List(EmailAddress)),
    subject: Option(String),
    sent_at: Option(String),
    has_attachment: Bool,
    preview: String,
    text_body: List(BodyPart),
    attachments: List(BodyPart),
    /// `bodyValues`, keyed by `partId`.
    body_values: List(#(String, BodyValue)),
  )
}

pub type EmailAddress {
  EmailAddress(name: Option(String), email: String)
}

/// An `EmailBodyPart` (RFC 8621 § 4.1.4), leaf parts only.
pub type BodyPart {
  BodyPart(
    part_id: Option(String),
    blob_id: Option(String),
    size: Int,
    name: Option(String),
    type_: String,
    disposition: Option(String),
    cid: Option(String),
  )
}

/// An `EmailBodyValue` (RFC 8621 § 4.1.4).
pub type BodyValue {
  BodyValue(value: String, is_encoding_problem: Bool, is_truncated: Bool)
}

const ms_per_day = 86_400_000

const ms_per_hour = 3_600_000

const ms_per_minute = 60_000

const ms_per_second = 1000

/// Parse a JMAP `UTCDate` (RFC 8620 § 1.4: RFC 3339 `date-time`, `Z` only,
/// fractional seconds optional) to epoch milliseconds, dropping digits past
/// the millisecond.
pub fn utc_date(raw: String) -> Result(model.UtcDate, Nil) {
  use #(year, month, day, hour, minute, second, millisecond) <- result.try(
    parse_fields(raw),
  )
  use days <- result.try(days_since_epoch(year, month, day))

  Ok(model.UtcDate(
    raw: raw,
    ms: days
      * ms_per_day
      + hour
      * ms_per_hour
      + minute
      * ms_per_minute
      + second
      * ms_per_second
      + millisecond,
  ))
}

/// Parse the fixed shape `YYYY-MM-DDTHH:MM:SS[.d+]Z` to its civil fields,
/// checking the wall-clock time (the date's ranges belong to
/// `days_since_epoch`).
fn parse_fields(
  raw: String,
) -> Result(#(Int, Int, Int, Int, Int, Int, Int), Nil) {
  case string.to_graphemes(raw) {
    [
      y1,
      y2,
      y3,
      y4,
      "-",
      m1,
      m2,
      "-",
      d1,
      d2,
      "T",
      h1,
      h2,
      ":",
      n1,
      n2,
      ":",
      s1,
      s2,
      ..rest
    ] -> {
      use year <- result.try(number([y1, y2, y3, y4]))
      use month <- result.try(number([m1, m2]))
      use day <- result.try(number([d1, d2]))
      use hour <- result.try(number([h1, h2]))
      use minute <- result.try(number([n1, n2]))
      use second <- result.try(number([s1, s2]))
      use millisecond <- result.try(fraction_millis(rest))

      case valid_time(hour, minute, second) {
        True -> Ok(#(year, month, day, hour, minute, second, millisecond))
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// The decimal value of a list of digit graphemes, `Error` on anything that is
/// not a single decimal digit.
fn number(graphemes: List(String)) -> Result(Int, Nil) {
  list.fold(graphemes, Ok(0), fn(total, grapheme) {
    use total <- result.try(total)
    use digit <- result.try(digit_value(grapheme))
    Ok(total * 10 + digit)
  })
}

fn digit_value(grapheme: String) -> Result(Int, Nil) {
  case grapheme {
    "0" -> Ok(0)
    "1" -> Ok(1)
    "2" -> Ok(2)
    "3" -> Ok(3)
    "4" -> Ok(4)
    "5" -> Ok(5)
    "6" -> Ok(6)
    "7" -> Ok(7)
    "8" -> Ok(8)
    "9" -> Ok(9)
    _ -> Error(Nil)
  }
}

/// The fraction's milliseconds: its first three digits, right-padded with
/// zeros; digits past the third are dropped, never rounded. A timestamp with
/// no fraction contributes zero milliseconds.
fn fraction_millis(rest: List(String)) -> Result(Int, Nil) {
  case rest {
    ["Z"] -> Ok(0)
    [".", ..fraction] ->
      case list.last(fraction) {
        Ok("Z") ->
          fraction
          |> list.take(list.length(fraction) - 1)
          |> millis_from_digits
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn millis_from_digits(digits: List(String)) -> Result(Int, Nil) {
  case digits {
    [] -> Error(Nil)
    [first, second, third, ..] -> {
      use first <- result.try(digit_value(first))
      use second <- result.try(digit_value(second))
      use third <- result.try(digit_value(third))
      Ok(first * 100 + second * 10 + third)
    }
    [first, second] -> {
      use first <- result.try(digit_value(first))
      use second <- result.try(digit_value(second))
      Ok(first * 100 + second * 10)
    }
    [first] -> {
      use first <- result.try(digit_value(first))
      Ok(first * 100)
    }
  }
}

/// A leap second (60) is rejected: the model keeps whole milliseconds only.
fn valid_time(hour: Int, minute: Int, second: Int) -> Bool {
  hour >= 0
  && hour <= 23
  && minute >= 0
  && minute <= 59
  && second >= 0
  && second <= 59
}

/// Days from 1970-01-01 to `year`-`month`-`day`, or `Error` when the date is
/// not a real calendar date.
fn days_since_epoch(year: Int, month: Int, day: Int) -> Result(Int, Nil) {
  case valid_date(year, month, day) {
    True -> Ok(civil_day_count(year, month, day))
    False -> Error(Nil)
  }
}

fn valid_date(year: Int, month: Int, day: Int) -> Bool {
  month >= 1 && month <= 12 && day >= 1 && day <= days_in_month(year, month)
}

fn days_in_month(year: Int, month: Int) -> Int {
  case month {
    1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
    4 | 6 | 9 | 11 -> 30
    2 ->
      case is_leap_year(year) {
        True -> 29
        False -> 28
      }
    _ -> 0
  }
}

fn is_leap_year(year: Int) -> Bool {
  let divisible_by_four = year % 4 == 0
  case year % 100 == 0 {
    False -> divisible_by_four
    True -> year % 400 == 0
  }
}

/// Howard Hinnant's `days_from_civil`: days since 1970-01-01 in the proleptic
/// Gregorian calendar, without `gleam_time` (I5).
fn civil_day_count(year: Int, month: Int, day: Int) -> Int {
  let year = case month <= 2 {
    True -> year - 1
    False -> year
  }
  let era = case year >= 0 {
    True -> year / 400
    False -> {
      let adjusted = year - 399
      adjusted / 400
    }
  }
  let year_of_era = year - era * 400
  let month_index = case month > 2 {
    True -> month - 3
    False -> month + 9
  }
  let month_scaled = 153 * month_index + 2
  let day_of_year = month_scaled / 5 + day - 1
  let day_of_era =
    year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year

  era * 146_097 + day_of_era - 719_468
}

/// Normalise one Email delivered by a response whose Email state was
/// `email_state`. `textBody` parts are stored in order; HTML parts are
/// converted to text; the stored text of all parts together is at most
/// `max_body_bytes` bytes (RV-001 F-9).
pub fn message(
  email: Email,
  email_state: String,
  max_body_bytes: Int,
) -> model.Message {
  model.Message(
    id: email.id,
    thread_id: email.thread_id,
    blob_id: email.blob_id,
    received_at: email.received_at,
    sent_at: email.sent_at,
    subject: email.subject,
    preview: email.preview,
    size: email.size,
    has_attachment: email.has_attachment,
    is_seen: list.contains(email.keywords, "$seen"),
    is_flagged: list.contains(email.keywords, "$flagged"),
    keywords: email.keywords,
    email_state: email_state,
    mailbox_ids: email.mailbox_ids,
    header_ids: header_ids(email),
    addresses: addresses(email),
    bodies: bodies(email.text_body, email.body_values, max_body_bytes),
    attachments: list.map(email.attachments, attachment),
  )
}

/// RFC 5322 header ids, each list in its header's order; an absent header is
/// the empty list.
fn header_ids(email: Email) -> model.HeaderIds {
  model.HeaderIds(
    message_id: option.unwrap(email.message_id, []),
    in_reply_to: option.unwrap(email.in_reply_to, []),
    references: option.unwrap(email.references, []),
  )
}

/// The addresses in the fixed field order `from`, `sender`, `to`, `cc`, `bcc`,
/// `reply_to`, each field keeping its own order.
fn addresses(email: Email) -> List(model.Address) {
  list.flatten([
    addresses_of(email.from, model.From),
    addresses_of(email.sender, model.Sender),
    addresses_of(email.to, model.To),
    addresses_of(email.cc, model.Cc),
    addresses_of(email.bcc, model.Bcc),
    addresses_of(email.reply_to, model.ReplyTo),
  ])
}

fn addresses_of(
  addrs: Option(List(EmailAddress)),
  field: model.AddressField,
) -> List(model.Address) {
  addrs
  |> option.unwrap([])
  |> list.map(fn(address) {
    model.Address(field: field, name: address.name, email: address.email)
  })
}

/// Attachment metadata only; an absent id is stored as the empty string.
fn attachment(part: BodyPart) -> model.Attachment {
  model.Attachment(
    part_id: option.unwrap(part.part_id, ""),
    blob_id: option.unwrap(part.blob_id, ""),
    name: part.name,
    type_: part.type_,
    size: part.size,
    disposition: part.disposition,
    cid: part.cid,
  )
}

/// The fold's accumulator: the stored byte count so far, whether the message
/// bound already cut (so every later part stores nothing), and the bodies built
/// so far, reversed.
type BodyFold {
  BodyFold(stored_bytes: Int, is_cut: Bool, bodies: List(model.Body))
}

/// Store every `textBody` part in order under the running per-message bound.
fn bodies(
  parts: List(BodyPart),
  body_values: List(#(String, BodyValue)),
  max_body_bytes: Int,
) -> List(model.Body) {
  let fold =
    list.fold(parts, BodyFold(0, False, []), fn(fold, part) {
      body_step(fold, part, body_values, max_body_bytes)
    })

  list.reverse(fold.bodies)
}

/// Store one part: convert HTML, keep it when it fits the remaining bound, and
/// otherwise cut it to the longest UTF-8 prefix that does and mark the cut.
fn body_step(
  fold: BodyFold,
  part: BodyPart,
  body_values: List(#(String, BodyValue)),
  max_body_bytes: Int,
) -> BodyFold {
  let value = body_value(part.part_id, body_values)
  let #(text, conversion_failed) = body_text(part.type_, value.value)
  let body =
    model.Body(
      part_id: option.unwrap(part.part_id, ""),
      source: body_source(part.type_),
      text: text,
      is_truncated: False,
      truncated_by: None,
      is_encoding_problem: value.is_encoding_problem,
      conversion_failed: conversion_failed,
      max_body_value_bytes: max_body_bytes,
    )

  case fold.is_cut {
    True ->
      BodyFold(..fold, bodies: [
        limit_cut(model.Body(..body, text: "")),
        ..fold.bodies
      ])
    False -> {
      let remaining = max_body_bytes - fold.stored_bytes
      case string.byte_size(text) <= remaining {
        True ->
          BodyFold(
            stored_bytes: fold.stored_bytes + string.byte_size(text),
            is_cut: False,
            bodies: [server_cut(body, value.is_truncated), ..fold.bodies],
          )
        False -> {
          let prefix = utf8_prefix(text, remaining)
          BodyFold(
            stored_bytes: fold.stored_bytes + string.byte_size(prefix),
            is_cut: True,
            bodies: [limit_cut(model.Body(..body, text: prefix)), ..fold.bodies],
          )
        }
      }
    }
  }
}

/// The `bodyValues` entry for a part, or the empty value when the response
/// carries none.
fn body_value(
  part_id: Option(String),
  body_values: List(#(String, BodyValue)),
) -> BodyValue {
  case part_id {
    None -> empty_value()
    Some(id) ->
      case list.key_find(body_values, id) {
        Ok(value) -> value
        Error(Nil) -> empty_value()
      }
  }
}

fn empty_value() -> BodyValue {
  BodyValue(value: "", is_encoding_problem: False, is_truncated: False)
}

/// Only `text/html` is HTML; every other type is stored as it arrived.
fn body_source(type_: String) -> model.Source {
  case type_ {
    "text/html" -> model.Html
    _ -> model.PlainText
  }
}

/// The part's stored text: HTML is converted, and a conversion failure stores
/// nothing and records the failure.
fn body_text(type_: String, value: String) -> #(String, Bool) {
  case type_ {
    "text/html" ->
      case html_text.convert(value) {
        Ok(text) -> #(text, False)
        Error(Nil) -> #("", True)
      }
    _ -> #(value, False)
  }
}

/// Keep the server's own truncation mark when the per-message bound does not
/// cut the part itself.
fn server_cut(body: model.Body, is_truncated: Bool) -> model.Body {
  case is_truncated {
    True ->
      model.Body(..body, is_truncated: True, truncated_by: Some(model.Server))
    False -> body
  }
}

/// Mark a body cut by the per-message bound; our cut wins over the server's.
fn limit_cut(body: model.Body) -> model.Body {
  model.Body(..body, is_truncated: True, truncated_by: Some(model.MessageLimit))
}

/// The longest prefix of `text` whose UTF-8 byte size is at most `budget`, cut
/// between codepoints so no sequence is split.
fn utf8_prefix(text: String, budget: Int) -> String {
  text
  |> string.to_utf_codepoints
  |> keep_codepoints(budget, [])
  |> string.from_utf_codepoints
}

fn keep_codepoints(
  codepoints: List(UtfCodepoint),
  remaining: Int,
  kept: List(UtfCodepoint),
) -> List(UtfCodepoint) {
  case codepoints {
    [] -> list.reverse(kept)
    [codepoint, ..rest] -> {
      let width = utf8_width(string.utf_codepoint_to_int(codepoint))
      case width <= remaining {
        True -> keep_codepoints(rest, remaining - width, [codepoint, ..kept])
        False -> list.reverse(kept)
      }
    }
  }
}

/// A codepoint's width in UTF-8 bytes.
fn utf8_width(codepoint: Int) -> Int {
  case codepoint < 0x80 {
    True -> 1
    False ->
      case codepoint < 0x800 {
        True -> 2
        False ->
          case codepoint < 0x1_0000 {
            True -> 3
            False -> 4
          }
      }
  }
}

/// The ordering contract: received milliseconds, then message id (RV-001
/// F-23).
pub fn compare_received(a: model.Message, b: model.Message) -> Order {
  case int.compare(a.received_at.ms, b.received_at.ms) {
    Eq -> string.compare(a.id, b.id)
    other -> other
  }
}
