//// The store's encoding of model values; both directions live together so they
//// cannot drift.
////
//// Each pair here is the whole of one column's text form: the encoder
//// `write_snapshot` uses and the decoder the read queries use are written
//// against each other, so a value written by one side and read by the other
//// cannot disagree. A text neither side can read is `read_failed`, the store's
//// fixed reason code, never SQLite's text (I1).

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import screwtape/error.{type Error, Store}
import screwtape/model.{
  type AddressField, type Source, type TruncatedBy, Bcc, Cc, From, Html,
  MessageLimit, PlainText, ReplyTo, Sender, Server, To,
}

/// The store's `read_failed` reason code (I1). Spelled here because this module
/// sits below `screwtape/store`, which imports it: a text neither side can read
/// is that failure, never SQLite's text.
const read_failed = "read_failed"

/// The keyword list as the JSON array `keywords_json` holds.
pub fn keywords_json(keywords: List(String)) -> String {
  json.to_string(json.array(keywords, json.string))
}

/// The inverse of `keywords_json`; a text that is not a JSON array of strings
/// is a decode failure, never a crash.
pub fn keywords_from_json(text: String) -> Result(List(String), Error) {
  json.parse(text, using: decode.list(decode.string))
  |> result.replace_error(Store(read_failed))
}

pub fn source_text(source: Source) -> String {
  case source {
    PlainText -> "text"
    Html -> "html"
  }
}

/// The inverse of `source_text`.
pub fn source_from_text(text: String) -> Result(Source, Error) {
  case text {
    "text" -> Ok(PlainText)
    "html" -> Ok(Html)
    _ -> Error(Store(read_failed))
  }
}

pub fn truncated_by_text(value: Option(TruncatedBy)) -> Option(String) {
  case value {
    Some(Server) -> Some("server")
    Some(MessageLimit) -> Some("message_limit")
    None -> None
  }
}

/// The inverse of `truncated_by_text`.
pub fn truncated_by_from_text(
  text: Option(String),
) -> Result(Option(TruncatedBy), Error) {
  case text {
    Some("server") -> Ok(Some(Server))
    Some("message_limit") -> Ok(Some(MessageLimit))
    Some(_) -> Error(Store(read_failed))
    None -> Ok(None)
  }
}

pub fn address_field_text(field: AddressField) -> String {
  case field {
    From -> "from"
    Sender -> "sender"
    To -> "to"
    Cc -> "cc"
    Bcc -> "bcc"
    ReplyTo -> "reply_to"
  }
}

/// The inverse of `address_field_text`.
pub fn address_field_from_text(text: String) -> Result(AddressField, Error) {
  case text {
    "from" -> Ok(From)
    "sender" -> Ok(Sender)
    "to" -> Ok(To)
    "cc" -> Ok(Cc)
    "bcc" -> Ok(Bcc)
    "reply_to" -> Ok(ReplyTo)
    _ -> Error(Store(read_failed))
  }
}
