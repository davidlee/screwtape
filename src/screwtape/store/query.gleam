//// The read verbs' queries (design § 5.2): `mailboxes`, `list`, `read` and
//// `thread`, each run inside `store.read`'s one transaction, so every value a
//// verb prints comes from one committed snapshot (I8).
////
//// `message` deliberately uses one select per relation: the row, then its
//// mailboxes, header ids, addresses, bodies and attachments, each decoded by
//// the inverse of the encoding in `screwtape/store/codec`.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import screwtape/error.{type Error, Store}
import screwtape/model.{
  type Address, type Attachment, type Body, type HeaderIds, type Mailbox,
  type Message, type MessageSummary, type Prior, type QueryState,
  type ThreadPage, type UtcDate, Address, Attachment, Body, HeaderIds, Mailbox,
  Message, MessageSummary, Prior, QueryState, ThreadEntry, ThreadPage, UtcDate,
}
import screwtape/store
import screwtape/store/codec
import sqlight

/// What `list` asks for (design § 5.2). The filters are optional and combine
/// with AND; `mailbox_ids` matches a message in any of them.
pub type ListQuery {
  ListQuery(
    mailbox_ids: Option(List(String)),
    since_ms: Option(Int),
    from: Option(String),
    unread: Bool,
    limit: Int,
    offset: Int,
  )
}

// ---------------------------------------------------------------------------
// Read queries (design § 5.2 read verbs). Each runs inside `read`'s one
// transaction and decodes the inverse of the encodings in
// `screwtape/store/codec`.
// ---------------------------------------------------------------------------

/// The account the snapshot belongs to: the `sync` row's `account_id`.
pub fn account_id(tx: store.Tx) -> Result(String, Error) {
  use rows <- result.try(store.select(
    tx,
    select_account_id_sql,
    [],
    decode.field(0, decode.string, decode.success),
  ))
  no_snapshot_when_empty(rows)
}

/// Every mailbox, ordered by `sort_order`, then `name`, then `id`.
pub fn mailboxes(tx: store.Tx) -> Result(List(Mailbox), Error) {
  store.select(tx, select_mailboxes_sql, [], mailbox_decoder())
}

/// The summaries `query` selects, newest first: `received_at_ms` descending,
/// then `id` descending (design § 5.3 ordering, reversed by operator decision
/// PHASE-06 D5), then `offset` and `limit`.
pub fn messages(
  tx: store.Tx,
  query: ListQuery,
) -> Result(List(MessageSummary), Error) {
  let #(sql, arguments) = list_sql(query)
  use rows <- result.try(store.select(tx, sql, arguments, summary_row_decoder()))
  list.try_map(rows, fn(row) { summary_of_row(tx, row) })
}

/// The whole message `id`, or `None` if the store holds no such message.
/// Unordered relations come back in a canonical order: `mailbox_ids` sorted,
/// `addresses` by field (model order) then position, `attachments` by
/// `part_id`; the lists that keep a position come back in it.
pub fn message(tx: store.Tx, id: String) -> Result(Option(Message), Error) {
  use rows <- result.try(store.select(
    tx,
    select_message_sql,
    [sqlight.text(id)],
    message_row_decoder(),
  ))
  case rows {
    [row, ..] -> assemble_message(tx, row) |> result.map(Some)
    [] -> Ok(None)
  }
}

/// Thread `id`'s message ids in position order, each with its summary when the
/// message is in the store; `None` if the store holds no such thread. `total`
/// counts the whole thread; `entries` is its last `limit` ids in thread order,
/// so a page shorter than `total` is truncated.
pub fn thread(
  tx: store.Tx,
  id: String,
  limit: Int,
) -> Result(Option(ThreadPage), Error) {
  use message_ids <- result.try(store.select(
    tx,
    select_thread_emails_sql,
    [sqlight.text(id)],
    decode.field(0, decode.string, decode.success),
  ))
  case message_ids {
    [] -> Ok(None)
    _ -> {
      let total = list.length(message_ids)
      let kept = list.drop(message_ids, total - limit)
      use entries <- result.try(
        list.try_map(kept, fn(message_id) {
          use summary <- result.try(summary_of(tx, message_id))
          Ok(ThreadEntry(message_id, summary))
        }),
      )
      Ok(Some(ThreadPage(total: total, entries: entries)))
    }
  }
}

/// The committed store as a value (design § 5.2), so a run can reason about
/// what it would otherwise rewrite (I-M5). Every read runs in `tx`, so all of
/// it sees one committed snapshot (I8).
///
/// A store with no usable snapshot — no `sync` row, no `Email` `type_state`
/// row, no `query_state` row — is `Store("no_snapshot")`.
///
/// `messages` come back by `received_at_ms`, then id, ascending; the order is
/// not a contract of `Prior`.
pub fn prior(tx: store.Tx) -> Result(Prior, Error) {
  use account_id <- result.try(account_id(tx))
  use #(api_url, window_json) <- result.try(sync_row(tx))
  use email_state <- result.try(email_state(tx))
  use stored_mailboxes <- result.try(mailboxes(tx))
  use query <- result.try(query_state(tx))
  use ids <- result.try(message_ids(tx))
  use stored_messages <- result.try(
    list.try_map(ids, fn(id) {
      use found <- result.try(message(tx, id))
      option.to_result(found, Store(store.read_failed))
    }),
  )
  Ok(Prior(
    account_id: account_id,
    api_url: api_url,
    email_state: email_state,
    window_json: window_json,
    mailboxes: stored_mailboxes,
    query: query,
    messages: stored_messages,
  ))
}

/// The `sync` row's server and window: the pair every reuse compares against.
/// One select for both columns, so `sync` is read once.
fn sync_row(tx: store.Tx) -> Result(#(String, String), Error) {
  use rows <- result.try(store.select(
    tx,
    select_sync_row_sql,
    [],
    decode.field(0, decode.string, fn(api_url) {
      decode.field(1, decode.string, fn(window_json) {
        decode.success(#(api_url, window_json))
      })
    }),
  ))
  no_snapshot_when_empty(rows)
}

/// The `type_state` state of `Email`. No `Email` row means no usable snapshot,
/// not the first state the table happens to hold.
fn email_state(tx: store.Tx) -> Result(String, Error) {
  use rows <- result.try(store.select(
    tx,
    select_email_state_sql,
    [sqlight.text("Email")],
    decode.field(0, decode.string, decode.success),
  ))
  no_snapshot_when_empty(rows)
}

/// The run's `query_state` row: one row per committed snapshot (DEC-008).
fn query_state(tx: store.Tx) -> Result(QueryState, Error) {
  use rows <- result.try(store.select(
    tx,
    select_query_state_sql,
    [],
    query_state_decoder(),
  ))
  no_snapshot_when_empty(rows)
}

/// Every message id, in the store's order; `Ok([])` for a store with none.
fn message_ids(tx: store.Tx) -> Result(List(String), Error) {
  store.select(
    tx,
    select_message_ids_sql,
    [],
    decode.field(0, decode.string, decode.success),
  )
}

/// The first row, or `no_snapshot`: each table a snapshot cannot do without
/// answers its absence the same way.
fn no_snapshot_when_empty(rows: List(a)) -> Result(a, Error) {
  case rows {
    [row, ..] -> Ok(row)
    [] -> Error(Store(store.no_snapshot))
  }
}

// ---------------------------------------------------------------------------
// Read decoders: the inverse of the encoders in `screwtape/store/codec`
// ---------------------------------------------------------------------------

/// One `message` row, before its relations are gathered.
type MessageRow {
  MessageRow(
    id: String,
    thread_id: String,
    blob_id: String,
    received_at: String,
    received_at_ms: Int,
    sent_at: Option(String),
    subject: Option(String),
    preview: String,
    size: Int,
    has_attachment: Bool,
    is_seen: Bool,
    is_flagged: Bool,
    keywords_json: String,
    email_state: String,
  )
}

/// The columns `list` and `thread` print, before the relations are gathered.
type SummaryRow {
  SummaryRow(
    id: String,
    thread_id: String,
    received_at: UtcDate,
    subject: Option(String),
    preview: String,
    is_seen: Bool,
    is_flagged: Bool,
    has_attachment: Bool,
  )
}

fn mailbox_decoder() -> decode.Decoder(Mailbox) {
  use id <- decode.field(0, decode.string)
  use name <- decode.field(1, decode.string)
  use parent_id <- decode.field(2, decode.optional(decode.string))
  use role <- decode.field(3, decode.optional(decode.string))
  use sort_order <- decode.field(4, decode.int)
  use total_emails <- decode.field(5, decode.int)
  use unread_emails <- decode.field(6, decode.int)
  decode.success(Mailbox(
    id: id,
    name: name,
    parent_id: parent_id,
    role: role,
    sort_order: sort_order,
    total_emails: total_emails,
    unread_emails: unread_emails,
  ))
}

/// The five columns of `query_state`, its two flags decoded from their
/// `INTEGER` columns.
fn query_state_decoder() -> decode.Decoder(QueryState) {
  use filter_json <- decode.field(0, decode.string)
  use sort_json <- decode.field(1, decode.string)
  use collapse_threads <- decode.field(2, sqlight.decode_bool())
  use query_state <- decode.field(3, decode.string)
  use can_calculate_changes <- decode.field(4, sqlight.decode_bool())
  decode.success(QueryState(
    filter_json: filter_json,
    sort_json: sort_json,
    collapse_threads: collapse_threads,
    query_state: query_state,
    can_calculate_changes: can_calculate_changes,
  ))
}

fn summary_row_decoder() -> decode.Decoder(SummaryRow) {
  use id <- decode.field(0, decode.string)
  use thread_id <- decode.field(1, decode.string)
  use received_at <- decode.field(2, decode.string)
  use received_at_ms <- decode.field(3, decode.int)
  use subject <- decode.field(4, decode.optional(decode.string))
  use preview <- decode.field(5, decode.string)
  use is_seen <- decode.field(6, sqlight.decode_bool())
  use is_flagged <- decode.field(7, sqlight.decode_bool())
  use has_attachment <- decode.field(8, sqlight.decode_bool())
  decode.success(SummaryRow(
    id: id,
    thread_id: thread_id,
    received_at: UtcDate(raw: received_at, ms: received_at_ms),
    subject: subject,
    preview: preview,
    is_seen: is_seen,
    is_flagged: is_flagged,
    has_attachment: has_attachment,
  ))
}

fn message_row_decoder() -> decode.Decoder(MessageRow) {
  use id <- decode.field(0, decode.string)
  use thread_id <- decode.field(1, decode.string)
  use blob_id <- decode.field(2, decode.string)
  use received_at <- decode.field(3, decode.string)
  use received_at_ms <- decode.field(4, decode.int)
  use sent_at <- decode.field(5, decode.optional(decode.string))
  use subject <- decode.field(6, decode.optional(decode.string))
  use preview <- decode.field(7, decode.string)
  use size <- decode.field(8, decode.int)
  use has_attachment <- decode.field(9, sqlight.decode_bool())
  use is_seen <- decode.field(10, sqlight.decode_bool())
  use is_flagged <- decode.field(11, sqlight.decode_bool())
  use keywords_json <- decode.field(12, decode.string)
  use email_state <- decode.field(13, decode.string)
  decode.success(MessageRow(
    id: id,
    thread_id: thread_id,
    blob_id: blob_id,
    received_at: received_at,
    received_at_ms: received_at_ms,
    sent_at: sent_at,
    subject: subject,
    preview: preview,
    size: size,
    has_attachment: has_attachment,
    is_seen: is_seen,
    is_flagged: is_flagged,
    keywords_json: keywords_json,
    email_state: email_state,
  ))
}

/// `#(field, name, email)` of an `address` row.
fn address_row_decoder() -> decode.Decoder(#(String, Option(String), String)) {
  use field <- decode.field(0, decode.string)
  use name <- decode.field(1, decode.optional(decode.string))
  use email <- decode.field(2, decode.string)
  decode.success(#(field, name, email))
}

/// `#(header, value)` of a `message_header_id` row.
fn header_row_decoder() -> decode.Decoder(#(String, String)) {
  use header <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(header, value))
}

/// A `body` row, its enum columns still text.
fn body_row_decoder() -> decode.Decoder(
  #(String, String, String, Bool, Option(String), Bool, Bool, Int),
) {
  use part_id <- decode.field(0, decode.string)
  use source_type <- decode.field(1, decode.string)
  use text <- decode.field(2, decode.string)
  use is_truncated <- decode.field(3, sqlight.decode_bool())
  use truncated_by <- decode.field(4, decode.optional(decode.string))
  use is_encoding_problem <- decode.field(5, sqlight.decode_bool())
  use conversion_failed <- decode.field(6, sqlight.decode_bool())
  use max_body_value_bytes <- decode.field(7, decode.int)
  decode.success(#(
    part_id,
    source_type,
    text,
    is_truncated,
    truncated_by,
    is_encoding_problem,
    conversion_failed,
    max_body_value_bytes,
  ))
}

fn attachment_decoder() -> decode.Decoder(Attachment) {
  use part_id <- decode.field(0, decode.string)
  use blob_id <- decode.field(1, decode.string)
  use name <- decode.field(2, decode.optional(decode.string))
  use type_ <- decode.field(3, decode.string)
  use size <- decode.field(4, decode.int)
  use disposition <- decode.field(5, decode.optional(decode.string))
  use cid <- decode.field(6, decode.optional(decode.string))
  decode.success(Attachment(
    part_id: part_id,
    blob_id: blob_id,
    name: name,
    type_: type_,
    size: size,
    disposition: disposition,
    cid: cid,
  ))
}

// ---------------------------------------------------------------------------
// Assembling a read result from its selects
// ---------------------------------------------------------------------------

/// The whole message of one `message` row: its relations each in their own
/// select, so one read serves one committed snapshot (I8).
fn assemble_message(tx: store.Tx, row: MessageRow) -> Result(Message, Error) {
  use keywords <- result.try(
    codec.keywords_from_json(row.keywords_json)
    |> result.replace_error(Store(store.read_failed)),
  )
  use mailbox_ids <- result.try(mailbox_ids_of(tx, row.id))
  use header_ids <- result.try(header_ids_of(tx, row.id))
  use addresses <- result.try(addresses_of(tx, row.id))
  use bodies <- result.try(bodies_of(tx, row.id))
  use attachments <- result.try(attachments_of(tx, row.id))
  Ok(Message(
    id: row.id,
    thread_id: row.thread_id,
    blob_id: row.blob_id,
    received_at: UtcDate(raw: row.received_at, ms: row.received_at_ms),
    sent_at: row.sent_at,
    subject: row.subject,
    preview: row.preview,
    size: row.size,
    has_attachment: row.has_attachment,
    is_seen: row.is_seen,
    is_flagged: row.is_flagged,
    keywords: keywords,
    email_state: row.email_state,
    mailbox_ids: mailbox_ids,
    header_ids: header_ids,
    addresses: addresses,
    bodies: bodies,
    attachments: attachments,
  ))
}

/// The summary `thread` prints for a message the store holds, or `None` if it
/// holds none with that id.
fn summary_of(
  tx: store.Tx,
  id: String,
) -> Result(Option(MessageSummary), Error) {
  use rows <- result.try(store.select(
    tx,
    select_summary_sql,
    [sqlight.text(id)],
    summary_row_decoder(),
  ))
  case rows {
    [row, ..] -> summary_of_row(tx, row) |> result.map(Some)
    [] -> Ok(None)
  }
}

/// The summary of one `message` row: its `From` addresses in position order
/// and its mailbox ids sorted, each in its own select. Shared by `messages`
/// and `thread`.
fn summary_of_row(
  tx: store.Tx,
  row: SummaryRow,
) -> Result(MessageSummary, Error) {
  use from <- result.try(from_addresses_of(tx, row.id))
  use mailbox_ids <- result.try(mailbox_ids_of(tx, row.id))
  Ok(MessageSummary(
    id: row.id,
    thread_id: row.thread_id,
    received_at: row.received_at,
    subject: row.subject,
    preview: row.preview,
    from: from,
    is_seen: row.is_seen,
    is_flagged: row.is_flagged,
    has_attachment: row.has_attachment,
    mailbox_ids: mailbox_ids,
  ))
}

fn mailbox_ids_of(
  tx: store.Tx,
  message_id: String,
) -> Result(List(String), Error) {
  store.select(
    tx,
    select_message_mailboxes_sql,
    [sqlight.text(message_id)],
    decode.field(0, decode.string, decode.success),
  )
}

/// The RFC 5322 identifiers of one message, each list in its `position` order.
fn header_ids_of(tx: store.Tx, message_id: String) -> Result(HeaderIds, Error) {
  use rows <- result.try(store.select(
    tx,
    select_header_ids_sql,
    [sqlight.text(message_id)],
    header_row_decoder(),
  ))
  use ids <- result.try(
    list.fold(
      rows,
      Ok(HeaderIds(message_id: [], in_reply_to: [], references: [])),
      fn(ids, row) {
        use ids <- result.try(ids)
        let #(header, value) = row
        case header {
          "message_id" ->
            Ok(HeaderIds(..ids, message_id: [value, ..ids.message_id]))
          "in_reply_to" ->
            Ok(HeaderIds(..ids, in_reply_to: [value, ..ids.in_reply_to]))
          "references" ->
            Ok(HeaderIds(..ids, references: [value, ..ids.references]))
          _ -> Error(Store(store.read_failed))
        }
      },
    ),
  )
  Ok(HeaderIds(
    message_id: list.reverse(ids.message_id),
    in_reply_to: list.reverse(ids.in_reply_to),
    references: list.reverse(ids.references),
  ))
}

fn addresses_of(
  tx: store.Tx,
  message_id: String,
) -> Result(List(Address), Error) {
  use rows <- result.try(store.select(
    tx,
    select_addresses_sql,
    [sqlight.text(message_id)],
    address_row_decoder(),
  ))
  address_rows(rows)
}

/// The `From` addresses of one message, in position order: a summary's `from`.
fn from_addresses_of(
  tx: store.Tx,
  message_id: String,
) -> Result(List(Address), Error) {
  use rows <- result.try(store.select(
    tx,
    select_from_addresses_sql,
    [sqlight.text(message_id)],
    address_row_decoder(),
  ))
  address_rows(rows)
}

fn address_rows(
  rows: List(#(String, Option(String), String)),
) -> Result(List(Address), Error) {
  list.try_map(rows, fn(row) {
    let #(field, name, email) = row
    use field <- result.try(
      codec.address_field_from_text(field)
      |> result.replace_error(Store(store.read_failed)),
    )
    Ok(Address(field: field, name: name, email: email))
  })
}

fn bodies_of(tx: store.Tx, message_id: String) -> Result(List(Body), Error) {
  use rows <- result.try(store.select(
    tx,
    select_bodies_sql,
    [sqlight.text(message_id)],
    body_row_decoder(),
  ))
  list.try_map(rows, fn(row) {
    let #(
      part_id,
      source_type,
      text,
      is_truncated,
      truncated_by,
      is_encoding_problem,
      conversion_failed,
      max_body_value_bytes,
    ) = row
    use source <- result.try(
      codec.source_from_text(source_type)
      |> result.replace_error(Store(store.read_failed)),
    )
    use truncated_by <- result.try(
      codec.truncated_by_from_text(truncated_by)
      |> result.replace_error(Store(store.read_failed)),
    )
    Ok(Body(
      part_id: part_id,
      source: source,
      text: text,
      is_truncated: is_truncated,
      truncated_by: truncated_by,
      is_encoding_problem: is_encoding_problem,
      conversion_failed: conversion_failed,
      max_body_value_bytes: max_body_value_bytes,
    ))
  })
}

fn attachments_of(
  tx: store.Tx,
  message_id: String,
) -> Result(List(Attachment), Error) {
  store.select(
    tx,
    select_attachments_sql,
    [sqlight.text(message_id)],
    attachment_decoder(),
  )
}

// ---------------------------------------------------------------------------
// The `list` query's filters
// ---------------------------------------------------------------------------

/// The `list` query's `WHERE` clause and its arguments: every filter given is
/// ANDed with the others, and every value is a parameter.
fn list_where(query: ListQuery) -> #(String, List(sqlight.Value)) {
  let #(clauses, arguments) =
    [
      mailbox_filter(query.mailbox_ids),
      since_filter(query.since_ms),
      from_filter(query.from),
      unread_filter(query.unread),
    ]
    |> list.fold(#([], []), fn(acc, filter) {
      let #(clauses, arguments) = acc
      case filter {
        Some(#(clause, values)) -> #(
          list.append(clauses, [clause]),
          list.append(arguments, values),
        )
        None -> acc
      }
    })
  let where = case clauses {
    [] -> ""
    _ -> " WHERE " <> string.join(clauses, " AND ")
  }
  #(where, arguments)
}

/// A message in any of the listed mailboxes, once: `EXISTS`, not a join.
fn mailbox_filter(
  mailbox_ids: Option(List(String)),
) -> Option(#(String, List(sqlight.Value))) {
  case mailbox_ids {
    None -> None
    Some([]) -> Some(#("0", []))
    Some(ids) -> {
      let placeholders = ids |> list.map(fn(_id) { "?" }) |> string.join(", ")
      Some(#(
        "EXISTS (SELECT 1 FROM message_mailbox WHERE"
          <> " message_mailbox.message_id = message.id AND mailbox_id IN ("
          <> placeholders
          <> "))",
        list.map(ids, sqlight.text),
      ))
    }
  }
}

fn since_filter(
  since_ms: Option(Int),
) -> Option(#(String, List(sqlight.Value))) {
  case since_ms {
    None -> None
    Some(value) -> Some(#("received_at_ms >= ?", [sqlight.int(value)]))
  }
}

/// An ASCII case-insensitive substring (SQLite `lower`) of a `From` address's
/// email or name. `instr` keeps `%` and `_` literal, where `LIKE` would read
/// them as wildcards.
fn from_filter(from: Option(String)) -> Option(#(String, List(sqlight.Value))) {
  case from {
    None -> None
    Some(value) ->
      Some(
        #(
          "EXISTS (SELECT 1 FROM address WHERE address.message_id = message.id"
            <> " AND field = 'from' AND (instr(lower(email), lower(?)) > 0"
            <> " OR instr(lower(coalesce(name, '')), lower(?)) > 0))",
          [sqlight.text(value), sqlight.text(value)],
        ),
      )
  }
}

fn unread_filter(unread: Bool) -> Option(#(String, List(sqlight.Value))) {
  case unread {
    True -> Some(#("is_seen = 0", []))
    False -> None
  }
}

/// The `list` query's statement: its filters, the newest-first order, and the
/// page.
fn list_sql(query: ListQuery) -> #(String, List(sqlight.Value)) {
  let #(where, arguments) = list_where(query)
  #(
    select_summaries_sql
      <> where
      <> " ORDER BY received_at_ms DESC, id DESC LIMIT ? OFFSET ?",
    list.append(arguments, [sqlight.int(query.limit), sqlight.int(query.offset)]),
  )
}

const select_account_id_sql = "SELECT account_id FROM sync"

const select_mailboxes_sql =
  "SELECT id, name, parent_id, role, sort_order, total_emails, unread_emails"
  <> " FROM mailbox ORDER BY sort_order, name, id"

const select_summaries_sql =
  "SELECT id, thread_id, received_at, received_at_ms, subject, preview,"
  <> " is_seen, is_flagged, has_attachment FROM message"

const select_summary_sql = select_summaries_sql <> " WHERE id = ?"

const select_message_sql =
  "SELECT id, thread_id, blob_id, received_at, received_at_ms, sent_at,"
  <> " subject, preview, size, has_attachment, is_seen, is_flagged,"
  <> " keywords_json, email_state FROM message WHERE id = ?"

const select_message_mailboxes_sql =
  "SELECT mailbox_id FROM message_mailbox WHERE message_id = ?"
  <> " ORDER BY mailbox_id"

const select_header_ids_sql =
  "SELECT header, value FROM message_header_id WHERE message_id = ?"
  <> " ORDER BY header, position"

/// The addresses in the model's field order (`From` first), each field in its
/// stored `position` order.
const select_addresses_sql =
  "SELECT field, name, email FROM address WHERE message_id = ?"
  <> " ORDER BY CASE field WHEN 'from' THEN 0 WHEN 'sender' THEN 1"
  <> " WHEN 'to' THEN 2 WHEN 'cc' THEN 3 WHEN 'bcc' THEN 4"
  <> " WHEN 'reply_to' THEN 5 ELSE 6 END, position"

const select_from_addresses_sql =
  "SELECT field, name, email FROM address WHERE message_id = ?"
  <> " AND field = 'from' ORDER BY position"

const select_bodies_sql =
  "SELECT part_id, source_type, text, is_truncated, truncated_by,"
  <> " is_encoding_problem, conversion_failed, max_body_value_bytes"
  <> " FROM body WHERE message_id = ? ORDER BY position"

const select_attachments_sql =
  "SELECT part_id, blob_id, name, type, size, disposition, cid"
  <> " FROM attachment WHERE message_id = ? ORDER BY part_id"

const select_thread_emails_sql =
  "SELECT message_id FROM thread_email WHERE thread_id = ? ORDER BY position"

const select_sync_row_sql = "SELECT api_url, window_json FROM sync"

/// `Email` is bound as a parameter, never quoted into the SQL.
const select_email_state_sql = "SELECT state FROM type_state WHERE type = ?"

/// One row per committed snapshot (DEC-008), so `LIMIT 1` is not lossy.
const select_query_state_sql =
  "SELECT filter_json, sort_json, collapse_threads, query_state,"
  <> " can_calculate_changes FROM query_state LIMIT 1"

const select_message_ids_sql =
  "SELECT id FROM message ORDER BY received_at_ms, id"
