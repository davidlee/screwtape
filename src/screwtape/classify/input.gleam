//// The `read` line the classifier consumes (PHASE-12, T2; design § 5.2).
////
//// `line` decodes exactly the fields `render.read` prints for the classifier
//// and nothing else: the read contract allows additions (DEC-029), so every
//// unlisted field is ignored. A failure is a `Decode(path)` built by
//// `error.decode_failure`, whose path names only our own field names and list
//// indices — never a key or a value from the input.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import screwtape/error.{type Error, Decode}

/// One address as `read` prints it: the display name, when it has one, and the
/// address itself. The one address type serves input and the window (POL-001).
pub type Address {
  Address(name: Option(String), email: String)
}

/// One body of the message: its printed text and the two flags the classifier
/// reads.
pub type MailBody {
  MailBody(text: String, is_truncated: Bool, conversion_failed: Bool)
}

/// One `read` document as the classifier sees it: the summary fields it keeps,
/// the six address lists as printed, the bodies and the attachments as
/// `#(type, name)`.
pub type Mail {
  Mail(
    id: String,
    cursor: String,
    subject: Option(String),
    from: List(Address),
    sender: List(Address),
    reply_to: List(Address),
    to: List(Address),
    cc: List(Address),
    bcc: List(Address),
    bodies: List(MailBody),
    attachments: List(#(String, Option(String))),
    output_truncated: Bool,
  )
}

/// Decode one line of `read` output. Not JSON, or JSON that is not an object,
/// is `Decode("$")`; a wrong or missing version is `Decode("version")` and is
/// reported before a wrong kind (`Decode("kind")`).
pub fn line(text: String) -> Result(Mail, Error) {
  case json.parse(text, using: decode.dynamic) {
    Error(_) -> Error(Decode("$"))
    Ok(document) ->
      decode.run(document, decoder())
      |> result.map_error(error.decode_failure(_, ""))
  }
}

/// Split stdin into lines: on `"\n"`, dropping every line that is blank after
/// `string.trim`, so a trailing newline is not a line and a run of blank lines
/// adds nothing.
pub fn lines(stdin: String) -> List(String) {
  stdin
  |> string.split("\n")
  |> list.filter(fn(line) { !string.is_empty(string.trim(line)) })
}

// The envelope: version, then kind, then data. `decode.failure` inside
// `decode.at` places the error at the field that was wrong.

fn decoder() -> decode.Decoder(Mail) {
  use version <- decode.field("version", decode.int)
  case version {
    1 -> after_version()
    _ -> decode.at(["version"], decode.failure(empty_mail(), "version"))
  }
}

fn after_version() -> decode.Decoder(Mail) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "read" -> decode.at(["data"], document_decoder())
    _ -> decode.at(["kind"], decode.failure(empty_mail(), "kind"))
  }
}

fn document_decoder() -> decode.Decoder(Mail) {
  use id <- decode.field("id", decode.string)
  use cursor <- decode.field("cursor", decode.string)
  use subject <- decode.field("subject", decode.optional(decode.string))
  use from <- decode.field("from", decode.list(address_decoder()))
  use sender <- decode.field("sender", decode.list(address_decoder()))
  use reply_to <- decode.field("reply_to", decode.list(address_decoder()))
  use to <- decode.field("to", decode.list(address_decoder()))
  use cc <- decode.field("cc", decode.list(address_decoder()))
  use bcc <- decode.field("bcc", decode.list(address_decoder()))
  use bodies <- decode.field("bodies", decode.list(body_decoder()))
  use attachments <- decode.field(
    "attachments",
    decode.list(attachment_decoder()),
  )
  use output_truncated <- decode.field("output_truncated", decode.bool)
  decode.success(Mail(
    id: id,
    cursor: cursor,
    subject: subject,
    from: from,
    sender: sender,
    reply_to: reply_to,
    to: to,
    cc: cc,
    bcc: bcc,
    bodies: bodies,
    attachments: attachments,
    output_truncated: output_truncated,
  ))
}

/// An address prints `{"name", "email"}`; a null name is no name.
fn address_decoder() -> decode.Decoder(Address) {
  use name <- decode.field("name", decode.optional(decode.string))
  use email <- decode.field("email", decode.string)
  decode.success(Address(name: name, email: email))
}

fn body_decoder() -> decode.Decoder(MailBody) {
  use text <- decode.field("text", decode.string)
  use is_truncated <- decode.field("is_truncated", decode.bool)
  use conversion_failed <- decode.field("conversion_failed", decode.bool)
  decode.success(MailBody(
    text: text,
    is_truncated: is_truncated,
    conversion_failed: conversion_failed,
  ))
}

fn attachment_decoder() -> decode.Decoder(#(String, Option(String))) {
  use type_ <- decode.field("type", decode.string)
  use name <- decode.field("name", decode.optional(decode.string))
  decode.success(#(type_, name))
}

/// The placeholder a failed envelope check must carry; it is never returned.
fn empty_mail() -> Mail {
  Mail(
    id: "",
    cursor: "",
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
