//// The JSON output documents (PHASE-06, PHASE-13; design § 5.2, § 5.1): every
//// verb's stdout is one `{"version": 1, "kind": <verb>, "data": …}` envelope,
//// and `envelope` is its only writer.
////
//// Pure: model values in, JSON text out. Optional values print as `null`,
//// never omitted; times print their raw `UtcDate` text.

import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import screwtape/classify/schema
import screwtape/cursor
import screwtape/jev
import screwtape/model.{
  type Address, type AddressField, type Attachment, type Body, type Mailbox,
  type Message, type MessageSummary, type Source, type ThreadEntry,
  type ThreadPage, type TruncatedBy, Bcc, Cc, From, Html, MessageLimit,
  MessageSummary, PlainText, ReplyTo, Sender, Server, To,
}
import screwtape/utf8

/// The versioned envelope around one verb's `data`.
pub fn envelope(kind: String, data: Json) -> String {
  json.object([
    #("version", json.int(1)),
    #("kind", json.string(kind)),
    #("data", data),
  ])
  |> json.to_string
}

/// `classify`: the classified state's provenance plus `seen` (the window
/// before `pii.strip`) and `answers`, one key per question in the schema's
/// order (EX-6).
pub fn classify(
  id id: String,
  cursor cursor: String,
  seen seen: Json,
  reply reply: jev.Reply,
) -> String {
  envelope(
    "classify",
    json.object([
      #("id", json.string(id)),
      #("cursor", json.string(cursor)),
      #("schema", json.string(schema.id)),
      #("model", json.string(reply.model)),
      #("seen", seen),
      #("answers", json.object(list.map(reply.answers, answer_entry))),
    ]),
  )
}

/// `classify --state`: the same provenance with `seen` and the `state` the
/// classifier would send (that window after `pii.strip`), so a consumer can
/// inspect it without asking (EX-6).
pub fn classify_state(
  id id: String,
  cursor cursor: String,
  seen seen: Json,
  state state: Json,
) -> String {
  envelope(
    "classify_state",
    json.object([
      #("id", json.string(id)),
      #("cursor", json.string(cursor)),
      #("schema", json.string(schema.id)),
      #("seen", seen),
      #("state", state),
    ]),
  )
}

fn answer_entry(entry: #(jev.Question, jev.Answer)) -> #(String, Json) {
  #(jev.question_name(entry.0), answer_json(entry.1))
}

/// One answer in its question type's shape: a choice's label distribution, a
/// noul's probability, or a score's distribution keyed by level index.
fn answer_json(answer: jev.Answer) -> Json {
  case answer {
    jev.ChoiceAnswer(choice, confidence, probabilities) ->
      json.object([
        #("choice", json.string(choice)),
        #("confidence", json.float(confidence)),
        #(
          "probabilities",
          json.object(
            list.map(probabilities, fn(entry) {
              #(entry.0, json.float(entry.1))
            }),
          ),
        ),
      ])
    jev.NoulAnswer(noul) -> json.object([#("noul", json.float(noul))])
    jev.ScoreAnswer(score, confidence, probabilities) ->
      json.object([
        #("score", json.float(score)),
        #("confidence", json.float(confidence)),
        #(
          "probabilities",
          json.object(
            list.index_map(probabilities, fn(probability, index) {
              #(int.to_string(index), json.float(probability))
            }),
          ),
        ),
      ])
  }
}

/// `mailboxes`: `{"items": [mailbox]}`, in the order given.
pub fn mailboxes(mailboxes: List(Mailbox)) -> String {
  envelope(
    "mailboxes",
    json.object([#("items", json.array(mailboxes, mailbox_json))]),
  )
}

/// `list`: `{"offset", "limit", "items": [summary]}`.
pub fn list(
  offset offset: Int,
  limit limit: Int,
  items items: List(MessageSummary),
) -> String {
  list_body(#("offset", json.int(offset)), limit, items)
}

/// `list --after`: `{"after", "limit", "items": [summary]}`, the cursor the
/// consumer held in place of `offset`, its items oldest first (C2).
pub fn list_after(
  after after: cursor.Cursor,
  limit limit: Int,
  items items: List(MessageSummary),
) -> String {
  list_body(#("after", json.string(cursor.to_string(after))), limit, items)
}

/// The one `list` body both pages print, so only their first key differs
/// (design § 5.2).
fn list_body(
  position: #(String, Json),
  limit: Int,
  items: List(MessageSummary),
) -> String {
  envelope(
    "list",
    json.object([
      position,
      #("limit", json.int(limit)),
      #("items", json.array(items, summary_json)),
    ]),
  )
}

/// `read`: the summary's fields plus the whole message, its provenance, and
/// `output_truncated`. With `max_bytes`, the bodies' texts share that many
/// bytes in body order, each cut on a codepoint boundary.
pub fn read(
  account_id account_id: String,
  message message: Message,
  max_bytes max_bytes: Option(Int),
) -> String {
  let #(bodies, output_truncated) = print_bodies(message.bodies, max_bytes)

  envelope(
    "read",
    json.object(
      list.append(summary_fields(summary_of(message)), [
        #("sent_at", json.nullable(message.sent_at, json.string)),
        #("size", json.int(message.size)),
        #("keywords", json.array(message.keywords, json.string)),
        #("sender", address_json(addresses_of(message.addresses, Sender))),
        #("to", address_json(addresses_of(message.addresses, To))),
        #("cc", address_json(addresses_of(message.addresses, Cc))),
        #("bcc", address_json(addresses_of(message.addresses, Bcc))),
        #("reply_to", address_json(addresses_of(message.addresses, ReplyTo))),
        #("message_id", json.array(message.header_ids.message_id, json.string)),
        #(
          "in_reply_to",
          json.array(message.header_ids.in_reply_to, json.string),
        ),
        #("references", json.array(message.header_ids.references, json.string)),
        #("bodies", json.preprocessed_array(bodies)),
        #("attachments", json.array(message.attachments, attachment_json)),
        #(
          "provenance",
          json.object([
            #("account_id", json.string(account_id)),
            #("email_state", json.string(message.email_state)),
          ]),
        ),
        #("output_truncated", json.bool(output_truncated)),
      ]),
    ),
  )
}

/// `thread`: `{"id", "total", "truncated", "items": [summary + in_store: true
/// | {id, in_store: false}]}`. `truncated` marks a page shorter than `total`.
pub fn thread(id: String, page: ThreadPage) -> String {
  envelope(
    "thread",
    json.object([
      #("id", json.string(id)),
      #("total", json.int(page.total)),
      #("truncated", json.bool(page.total > list.length(page.entries))),
      #("items", json.array(page.entries, thread_entry_json)),
    ]),
  )
}

/// The fields every summary-shaped document (`list`, `thread`, `read`) prints,
/// so their shapes cannot drift apart.
fn summary_fields(summary: MessageSummary) -> List(#(String, Json)) {
  [
    #("id", json.string(summary.id)),
    #("thread_id", json.string(summary.thread_id)),
    #("received_at", json.string(summary.received_at.raw)),
    #("subject", json.nullable(summary.subject, json.string)),
    #("from", address_json(summary.from)),
    #("preview", json.string(summary.preview)),
    #("is_seen", json.bool(summary.is_seen)),
    #("is_flagged", json.bool(summary.is_flagged)),
    #("mailbox_ids", json.array(summary.mailbox_ids, json.string)),
    #("has_attachment", json.bool(summary.has_attachment)),
    // The arrival position a consumer holds between `--after` pages (C2, C3).
    #(
      "cursor",
      json.string(
        cursor.to_string(cursor.of(summary.received_at.ms, summary.id)),
      ),
    ),
  ]
}

fn summary_json(summary: MessageSummary) -> Json {
  json.object(summary_fields(summary))
}

/// The summary a whole `Message` yields for `read`: its `from` addresses are
/// the ones the summary would hold.
fn summary_of(message: Message) -> MessageSummary {
  MessageSummary(
    id: message.id,
    thread_id: message.thread_id,
    received_at: message.received_at,
    subject: message.subject,
    preview: message.preview,
    from: addresses_of(message.addresses, From),
    is_seen: message.is_seen,
    is_flagged: message.is_flagged,
    has_attachment: message.has_attachment,
    mailbox_ids: message.mailbox_ids,
  )
}

fn mailbox_json(mailbox: Mailbox) -> Json {
  json.object([
    #("id", json.string(mailbox.id)),
    #("name", json.string(mailbox.name)),
    #("parent_id", json.nullable(mailbox.parent_id, json.string)),
    #("role", json.nullable(mailbox.role, json.string)),
    #("sort_order", json.int(mailbox.sort_order)),
    #("total_emails", json.int(mailbox.total_emails)),
    #("unread_emails", json.int(mailbox.unread_emails)),
  ])
}

/// One `{name, email}` address list, in position order.
fn address_json(addresses: List(Address)) -> Json {
  json.array(addresses, fn(address) {
    json.object([
      #("name", json.nullable(address.name, json.string)),
      #("email", json.string(address.email)),
    ])
  })
}

/// The addresses of one header field, in the order the message holds them.
fn addresses_of(
  addresses: List(Address),
  field: AddressField,
) -> List(Address) {
  list.filter(addresses, fn(address) { address.field == field })
}

fn thread_entry_json(entry: ThreadEntry) -> Json {
  case entry.summary {
    Some(summary) ->
      json.object(
        list.append(summary_fields(summary), [
          #("in_store", json.bool(True)),
        ]),
      )
    None ->
      json.object([
        #("id", json.string(entry.id)),
        #("in_store", json.bool(False)),
      ])
  }
}

fn body_json(body: Body, text: String) -> Json {
  json.object([
    #("part_id", json.string(body.part_id)),
    #("source_type", json.string(source_type(body.source))),
    #("text", json.string(text)),
    #("is_truncated", json.bool(body.is_truncated)),
    #("truncated_by", json.nullable(body.truncated_by, truncated_by_json)),
    #("is_encoding_problem", json.bool(body.is_encoding_problem)),
    #("conversion_failed", json.bool(body.conversion_failed)),
  ])
}

fn source_type(source: Source) -> String {
  case source {
    PlainText -> "text"
    Html -> "html"
  }
}

fn truncated_by_json(truncated_by: TruncatedBy) -> Json {
  case truncated_by {
    Server -> json.string("server")
    MessageLimit -> json.string("message_limit")
  }
}

fn attachment_json(attachment: Attachment) -> Json {
  json.object([
    #("part_id", json.string(attachment.part_id)),
    #("blob_id", json.string(attachment.blob_id)),
    #("name", json.nullable(attachment.name, json.string)),
    #("type", json.string(attachment.type_)),
    #("size", json.int(attachment.size)),
    #("disposition", json.nullable(attachment.disposition, json.string)),
    #("cid", json.nullable(attachment.cid, json.string)),
  ])
}

/// Print the bodies under the shared `max_bytes` budget: each text is cut with
/// `utf8.prefix`, and the returned flag is true iff any text was shortened.
fn print_bodies(
  bodies: List(Body),
  max_bytes: Option(Int),
) -> #(List(Json), Bool) {
  case max_bytes {
    None -> #(list.map(bodies, fn(body) { body_json(body, body.text) }), False)
    Some(budget) -> {
      let #(printed, _, truncated) =
        list.fold(bodies, #([], budget, False), fn(acc, body) {
          let #(printed, remaining, truncated) = acc
          let text = utf8.prefix(body.text, remaining)
          #(
            [body_json(body, text), ..printed],
            utf8.spend(body.text, remaining),
            truncated || string.byte_size(text) < string.byte_size(body.text),
          )
        })
      #(list.reverse(printed), truncated)
    }
  }
}
