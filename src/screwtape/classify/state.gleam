//// The bounded window the classifier sees for one message (SL-005 PHASE-02;
//// design § 5.1, § 5.3, § 5.6).
////
//// `window` keeps only what a classifier needs: the subject, the six address
//// lists, the bodies and the attachments. Every text loses its control
//// characters (including the bidi overrides), is cut to a named bound with
//// `utf8.prefix`, and drops its partial last word when the cut happened here
//// or on arrival — a whitespace-free prefix is kept whole. `window` never
//// strips PII: `encode(window, text)` is the one encoder, so `seen` is
//// `encode(w, identity)` and `state` is `encode(w, pii.strip)`, and the bounds
//// hold on `seen`.
////
//// A body `render.read` cut on arrival (`output_truncated`) or one already
//// flagged truncated loses its last partial word, so an address or number the
//// cut left half-recognised is never sent.

import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import screwtape/classify/input.{type Address, type Mail, type MailBody, Address}
import screwtape/utf8

/// The body texts' shared byte budget, spent in body order.
const body_text_bytes = 16_384

/// The most bodies sent; the rest are counted in `bodies_omitted`.
const max_bodies = 10

/// The subject's byte bound.
const subject_bytes = 512

/// The most entries kept per address list; the rest are counted.
const max_addresses = 10

/// The byte bound for an address name.
const address_name_bytes = 128

/// The RFC 5321 path limit for one email; an email over it drops its entry.
const address_email_bytes = 254

/// The most attachments sent; the rest are counted.
const max_attachments = 20

/// The byte bound for an attachment's `type` and `name`.
const attachment_text_bytes = 128

/// One address list of the window: the entries kept, in `read` order, and the
/// count of those dropped (oversize email) or past the tenth.
pub type Addresses {
  Addresses(entries: List(Address), omitted: Int)
}

/// One body of the window: the text after its bounds and the two flags.
pub type WindowBody {
  WindowBody(text: String, is_truncated: Bool, conversion_failed: Bool)
}

/// One message after every bound, mirroring the encoded JSON: nothing has been
/// stripped, so `encode` can produce both `seen` and `state` from it.
pub type Window {
  Window(
    subject: Option(String),
    from: Addresses,
    sender: Addresses,
    reply_to: Addresses,
    to: Addresses,
    cc: Addresses,
    bcc: Addresses,
    bodies: List(WindowBody),
    bodies_omitted: Int,
    attachments: List(#(String, Option(String))),
    attachments_omitted: Int,
  )
}

/// Build the window for one `read` line: every bound applied, no PII stripped.
pub fn window(mail: Mail) -> Window {
  let #(bodies, bodies_omitted) =
    window_bodies(mail.bodies, mail.output_truncated)
  let #(attachments, attachments_omitted) = window_attachments(mail.attachments)
  Window(
    subject: option_text(mail.subject, subject_bytes),
    from: addresses(mail.from),
    sender: addresses(mail.sender),
    reply_to: addresses(mail.reply_to),
    to: addresses(mail.to),
    cc: addresses(mail.cc),
    bcc: addresses(mail.bcc),
    bodies: bodies,
    bodies_omitted: bodies_omitted,
    attachments: attachments,
    attachments_omitted: attachments_omitted,
  )
}

/// The one encoder: every string value, and only a string value, passes
/// through `text`, in the contract's field order.
pub fn encode(window: Window, text: fn(String) -> String) -> Json {
  json.object(
    list.flatten([
      [#("subject", optional_json(window.subject, text))],
      address_fields("from", window.from, text),
      address_fields("sender", window.sender, text),
      address_fields("reply_to", window.reply_to, text),
      address_fields("to", window.to, text),
      address_fields("cc", window.cc, text),
      address_fields("bcc", window.bcc, text),
      [
        #(
          "bodies",
          json.array(window.bodies, fn(body) { body_json(body, text) }),
        ),
        #("bodies_omitted", json.int(window.bodies_omitted)),
        #(
          "attachments",
          json.array(window.attachments, fn(attachment) {
            attachment_json(attachment, text)
          }),
        ),
        #("attachments_omitted", json.int(window.attachments_omitted)),
      ],
    ]),
  )
}

fn optional_json(value: Option(String), text: fn(String) -> String) -> Json {
  case value {
    None -> json.null()
    Some(value) -> json.string(text(value))
  }
}

/// A list and its `_omitted` count, adjacent as the contract orders them.
fn address_fields(
  name: String,
  addresses: Addresses,
  text: fn(String) -> String,
) -> List(#(String, Json)) {
  let entries =
    json.array(addresses.entries, fn(entry) {
      json.object([
        #("name", optional_json(entry.name, text)),
        #("email", json.string(text(entry.email))),
      ])
    })
  [#(name, entries), #(name <> "_omitted", json.int(addresses.omitted))]
}

fn body_json(body: WindowBody, text: fn(String) -> String) -> Json {
  json.object([
    #("text", json.string(text(body.text))),
    #("is_truncated", json.bool(body.is_truncated)),
    #("conversion_failed", json.bool(body.conversion_failed)),
  ])
}

fn attachment_json(
  attachment: #(String, Option(String)),
  text: fn(String) -> String,
) -> Json {
  let #(type_, name) = attachment
  json.object([
    #("type", json.string(text(type_))),
    #("name", optional_json(name, text)),
  ])
}

// ---------------------------------------------------------------------------
// Addresses: read order, ten kept, oversize emails dropped and counted
// ---------------------------------------------------------------------------

fn addresses(entries: List(Address)) -> Addresses {
  let #(kept, omitted) =
    list.fold(entries, #([], 0), fn(acc, entry) {
      let #(kept, omitted) = acc
      let email = strip_controls(entry.email)
      case string.byte_size(email) > address_email_bytes {
        True -> #(kept, omitted + 1)
        False ->
          case list.length(kept) < max_addresses {
            True -> {
              let kept_entry =
                Address(
                  name: option_text(entry.name, address_name_bytes),
                  email: email,
                )
              #([kept_entry, ..kept], omitted)
            }
            False -> #(kept, omitted + 1)
          }
      }
    })
  Addresses(entries: list.reverse(kept), omitted: omitted)
}

// ---------------------------------------------------------------------------
// Bodies: the first ten, against one shared budget charged with `utf8.spend`
// ---------------------------------------------------------------------------

fn window_bodies(
  bodies: List(MailBody),
  output_truncated: Bool,
) -> #(List(WindowBody), Int) {
  let last_with_text = last_nonempty_index(bodies)
  let taken = list.take(bodies, max_bodies)
  let #(printed, _, _) =
    list.fold(taken, #([], 0, body_text_bytes), fn(acc, body) {
      let #(printed, index, remaining) = acc
      let cut = is_cut_on_arrival(index, body, last_with_text, output_truncated)
      let #(printed_body, remaining) = window_body(body, cut, remaining)
      #([printed_body, ..printed], index + 1, remaining)
    })
  let omitted = list.length(bodies) - list.length(taken)
  #(list.reverse(printed), omitted)
}

fn window_body(
  body: MailBody,
  cut_on_arrival: Bool,
  remaining: Int,
) -> #(WindowBody, Int) {
  // Once the shared budget is spent there is nothing to send: only the flags
  // are reported, and an input with no text is not called truncated.
  case remaining <= 0 {
    True -> #(
      WindowBody(
        text: "",
        is_truncated: cut_on_arrival
          || body.is_truncated
          || !string.is_empty(body.text),
        conversion_failed: body.conversion_failed,
      ),
      0,
    )
    False -> {
      let #(sent, cut) = bounded_text(body.text, remaining, cut_on_arrival)
      #(
        WindowBody(
          text: sent,
          is_truncated: cut || body.is_truncated,
          conversion_failed: body.conversion_failed,
        ),
        utf8.spend(sent, remaining),
      )
    }
  }
}

/// The index of the last body whose input text is non-empty, if any.
fn last_nonempty_index(bodies: List(MailBody)) -> Option(Int) {
  let #(_, last) =
    list.fold(bodies, #(0, None), fn(acc, body) {
      let #(index, last) = acc
      let next = case string.byte_size(body.text) > 0 {
        True -> Some(index)
        False -> last
      }
      #(index + 1, next)
    })
  last
}

/// A body is cut on arrival when `read` flagged it, or when the line was cut
/// and this body is the last one with text or follows it. If no body has text,
/// every body is cut.
fn is_cut_on_arrival(
  index: Int,
  body: MailBody,
  last_with_text: Option(Int),
  output_truncated: Bool,
) -> Bool {
  case body.is_truncated {
    True -> True
    False ->
      case output_truncated {
        False -> False
        True ->
          case last_with_text {
            None -> True
            Some(last) -> index >= last
          }
      }
  }
}

// ---------------------------------------------------------------------------
// Attachments: the first twenty, each type and name at its bound
// ---------------------------------------------------------------------------

fn window_attachments(
  attachments: List(#(String, Option(String))),
) -> #(List(#(String, Option(String))), Int) {
  let taken = list.take(attachments, max_attachments)
  let omitted = list.length(attachments) - list.length(taken)
  let kept =
    list.map(taken, fn(attachment) {
      let #(type_, name) = attachment
      #(
        field_text(type_, attachment_text_bytes),
        option_text(name, attachment_text_bytes),
      )
    })
  #(kept, omitted)
}

// ---------------------------------------------------------------------------
// One text: controls removed, cut to its bound, then the partial word dropped
// ---------------------------------------------------------------------------

/// The three text steps, and whether the text was cut (here or on arrival).
fn bounded_text(
  text: String,
  bound: Int,
  cut_on_arrival: Bool,
) -> #(String, Bool) {
  let cleaned = strip_controls(text)
  let cut = utf8.prefix(cleaned, bound)
  let was_cut =
    cut_on_arrival || string.byte_size(cut) < string.byte_size(cleaned)
  let kept = case was_cut {
    True -> drop_last_word(cut)
    False -> cut
  }
  #(kept, was_cut)
}

/// A field that is never cut on arrival: only its bounded text is wanted.
fn field_text(text: String, bound: Int) -> String {
  let #(kept, _) = bounded_text(text, bound, False)
  kept
}

fn option_text(value: Option(String), bound: Int) -> Option(String) {
  option.map(value, field_text(_, bound))
}

/// Remove the controls: U+0000-U+001F except tab, LF and CR, U+007F, the bidi
/// overrides U+202A-U+202E and the bidi isolates U+2066-U+2069.
fn strip_controls(text: String) -> String {
  text
  |> string.to_utf_codepoints
  |> list.filter(fn(codepoint) {
    !is_control(string.utf_codepoint_to_int(codepoint))
  })
  |> string.from_utf_codepoints
}

fn is_control(value: Int) -> Bool {
  case value {
    0x09 | 0x0A | 0x0D -> False
    _ ->
      value < 0x20
      || value == 0x7F
      || value >= 0x202A
      && value <= 0x202E
      || value >= 0x2066
      && value <= 0x2069
  }
}

/// Keep everything up to and including the last whitespace; a text with no
/// whitespace is kept whole.
fn drop_last_word(text: String) -> String {
  case keep_to_last_whitespace(string.to_utf_codepoints(text) |> list.reverse) {
    [] -> text
    kept -> kept |> list.reverse |> string.from_utf_codepoints
  }
}

fn keep_to_last_whitespace(
  codepoints: List(UtfCodepoint),
) -> List(UtfCodepoint) {
  case codepoints {
    [] -> []
    [codepoint, ..rest] ->
      case is_whitespace(string.utf_codepoint_to_int(codepoint)) {
        True -> [codepoint, ..rest]
        False -> keep_to_last_whitespace(rest)
      }
  }
}

fn is_whitespace(value: Int) -> Bool {
  value == 0x20 || value == 0x09 || value == 0x0A || value == 0x0D
}
