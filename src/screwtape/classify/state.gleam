//// The bounded state the classifier sees for one message (PHASE-12, T3;
//// design § 5.2).
////
//// `build` keeps only what a classifier needs: the subject, the senders'
//// domains, the bodies and the attachments. Every text loses its control
//// characters, PII is stripped from the subject, body texts, attachment types
//// and attachment names, and every field is cut to a named bound with
//// `utf8.prefix`, so the encoded state is bounded whatever the message holds.
////
//// A body `render.read` cut on arrival (`output_truncated`) or one already
//// flagged truncated loses its last partial word before stripping, so an
//// address or number the cut left half-recognised is never sent.

import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import screwtape/classify/input.{type Mail, type MailBody}
import screwtape/pii
import screwtape/utf8

/// The body texts' shared byte budget, spent in body order.
const body_text_bytes = 16_384

/// The most bodies sent; the rest are counted in `bodies_omitted`.
const max_bodies = 10

/// The subject's byte bound.
const subject_bytes = 512

/// The most sender domains sent; the rest are counted.
const max_sender_domains = 10

/// The DNS limit for one sender domain.
const sender_domain_bytes = 253

/// The most attachments sent; the rest are counted.
const max_attachments = 20

/// The byte bound for an attachment's `type` and `name`.
const attachment_text_bytes = 128

/// Build the classifier state for one `read` line.
pub fn build(mail: Mail) -> Json {
  let #(sender_domains, sender_domains_omitted) = sender_domains(mail.senders)
  let #(bodies, bodies_omitted) =
    build_bodies(mail.bodies, mail.output_truncated)
  let #(attachments, attachments_omitted) = build_attachments(mail.attachments)
  json.object([
    #("subject", subject_json(mail.subject)),
    #("sender_domains", json.array(sender_domains, json.string)),
    #("sender_domains_omitted", json.int(sender_domains_omitted)),
    #("bodies", json.preprocessed_array(bodies)),
    #("bodies_omitted", json.int(bodies_omitted)),
    #("attachments", json.preprocessed_array(attachments)),
    #("attachments_omitted", json.int(attachments_omitted)),
  ])
}

fn subject_json(subject: Option(String)) -> Json {
  case subject {
    None -> json.null()
    Some(text) ->
      text
      |> strip_controls
      |> pii.strip
      |> utf8.prefix(subject_bytes)
      |> json.string
  }
}

fn build_bodies(
  bodies: List(MailBody),
  output_truncated: Bool,
) -> #(List(Json), Int) {
  let last_with_text = last_nonempty_index(bodies)
  let kept = list.take(bodies, max_bodies)
  let #(printed, _, _) =
    list.fold(kept, #([], 0, body_text_bytes), fn(acc, body) {
      let #(printed, index, remaining) = acc
      let cut = is_cut_on_arrival(index, body, last_with_text, output_truncated)
      let #(printed_body, remaining) = body_json(body, cut, remaining)
      #([printed_body, ..printed], index + 1, remaining)
    })
  let omitted = list.length(bodies) - list.length(kept)
  #(list.reverse(printed), omitted)
}

fn body_json(
  body: MailBody,
  cut_on_arrival: Bool,
  remaining: Int,
) -> #(Json, Int) {
  // Once the shared budget is spent there is nothing to send, so the text is
  // not stripped or word-dropped at all: only the flags are reported.
  case remaining <= 0 {
    True -> #(
      json.object([
        #("text", json.string("")),
        #(
          "is_truncated",
          json.bool(
            cut_on_arrival
            || body.is_truncated
            || string.byte_size(body.text) > 0,
          ),
        ),
        #("conversion_failed", json.bool(body.conversion_failed)),
      ]),
      0,
    )
    False -> {
      let text = strip_controls(body.text)
      let text = case cut_on_arrival {
        True -> drop_last_word(text)
        False -> text
      }
      let stripped = pii.strip(text)
      let sent = utf8.prefix(stripped, remaining)
      let is_truncated =
        cut_on_arrival
        || string.byte_size(sent) < string.byte_size(stripped)
        || body.is_truncated
      #(
        json.object([
          #("text", json.string(sent)),
          #("is_truncated", json.bool(is_truncated)),
          #("conversion_failed", json.bool(body.conversion_failed)),
        ]),
        spend(sent, remaining),
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

fn build_attachments(
  attachments: List(#(String, Option(String))),
) -> #(List(Json), Int) {
  let kept = list.take(attachments, max_attachments)
  let omitted = list.length(attachments) - list.length(kept)
  let printed =
    list.map(kept, fn(attachment) {
      let #(type_, name) = attachment
      let sent_type =
        type_
        |> strip_controls
        |> pii.strip
        |> utf8.prefix(attachment_text_bytes)
      let sent_name = case name {
        None -> json.null()
        Some(text) ->
          text
          |> strip_controls
          |> pii.strip
          |> utf8.prefix(attachment_text_bytes)
          |> json.string
      }
      json.object([
        #("type", json.string(sent_type)),
        #("name", sent_name),
      ])
    })
  #(printed, omitted)
}

/// The text after the last `@`, control-stripped, lowercased and PII-stripped,
/// deduplicated in order. A sender without `@`, with an empty domain or with a
/// domain over 253 bytes is dropped and counted, as are unique domains past
/// the tenth.
fn sender_domains(senders: List(String)) -> #(List(String), Int) {
  let #(kept, omitted, _) =
    list.fold(senders, #([], 0, []), fn(acc, sender) {
      let #(kept, omitted, seen) = acc
      case domain_of(sender) {
        None -> #(kept, omitted + 1, seen)
        Some(raw) -> {
          let domain = raw |> strip_controls |> string.lowercase |> pii.strip
          case domain == "" {
            True -> #(kept, omitted + 1, seen)
            False ->
              case string.byte_size(domain) > sender_domain_bytes {
                True -> #(kept, omitted + 1, seen)
                False ->
                  case list.contains(seen, domain) {
                    True -> #(kept, omitted, seen)
                    False ->
                      case list.length(kept) < max_sender_domains {
                        True -> #([domain, ..kept], omitted, [domain, ..seen])
                        False -> #(kept, omitted + 1, [domain, ..seen])
                      }
                  }
              }
          }
        }
      }
    })
  #(list.reverse(kept), omitted)
}

fn domain_of(sender: String) -> Option(String) {
  case string.split(sender, "@") {
    [_, _, ..] as parts -> Some(list.last(parts) |> result.unwrap(""))
    _ -> None
  }
}

/// Remove U+0000-U+001F except tab, LF and CR, and U+007F.
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
    _ -> value < 0x20 || value == 0x7F
  }
}

/// Drop everything after the last whitespace, keeping the whitespace itself;
/// drop all of it when there is no whitespace.
fn drop_last_word(text: String) -> String {
  text
  |> string.to_utf_codepoints
  |> list.reverse
  |> from_last_whitespace
  |> list.reverse
  |> string.from_utf_codepoints
}

fn from_last_whitespace(codepoints: List(UtfCodepoint)) -> List(UtfCodepoint) {
  case codepoints {
    [] -> []
    [codepoint, ..rest] ->
      case is_whitespace(string.utf_codepoint_to_int(codepoint)) {
        True -> [codepoint, ..rest]
        False -> from_last_whitespace(rest)
      }
  }
}

fn is_whitespace(value: Int) -> Bool {
  value == 0x20 || value == 0x09 || value == 0x0A || value == 0x0D
}

/// The budget left after a body under `remaining`, as `render.print_bodies`
/// spends it: the text's byte size, capped at what remains.
fn spend(text: String, remaining: Int) -> Int {
  let size = string.byte_size(text)
  case size < remaining {
    True -> remaining - size
    False -> 0
  }
}
