//// The SQLite store (PHASE-04; design § 5.3).
////
//// One writer, `write_snapshot`, replaces every row in a single
//// `BEGIN IMMEDIATE` transaction, and runs pending migrations inside that same
//// transaction (RV-001 F-14), so a run that fails before its commit leaves the
//// schema and the data as they were (I2). `PRAGMA user_version` is the one
//// migration ledger; a store newer than this binary is refused untouched
//// (RV-001 F-22, I10).
////
//// Readers open the file read-only and run every query of one verb inside a
//// single read transaction (RV-001 F-15).
////
//// Errors carry fixed reason codes only, never SQLite's text (I1):
//// `no_snapshot`, `schema_mismatch`, `open_failed`, `write_failed`,
//// `read_failed`.
////
//// The schema is the migration chain itself: `schema_v1` is the only script,
//// so `supported_version()` is the chain's length. Every row is written with a
//// parameterised insert; nothing in this module quotes a value into SQL.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import screwtape/error.{type Error, Store}
import screwtape/model.{
  type AccountMeta, type Address, type AddressField, type Attachment, type Body,
  type HeaderIds, type Mailbox, type Message, type MessageSummary,
  type QueryState, type Snapshot, type Source, type Thread, type ThreadEntry,
  type TruncatedBy, type TypeState, type UtcDate, Address, Attachment, Bcc, Body,
  Cc, From, HeaderIds, Html, Mailbox, Message, MessageLimit, MessageSummary,
  PlainText, ReplyTo, Sender, Server, ThreadEntry, To, UtcDate,
}
import sqlight

pub opaque type Writer {
  Writer(connection: sqlight.Connection)
}

pub opaque type Reader {
  Reader(connection: sqlight.Connection, after_select: fn() -> Nil)
}

/// An open read transaction, handed to the query of `read`.
pub opaque type Tx {
  Tx(connection: sqlight.Connection, after_select: fn() -> Nil)
}

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

/// The fixed reason codes of `Error.Store` (I1).
const no_snapshot = "no_snapshot"

const schema_mismatch = "schema_mismatch"

const open_failed = "open_failed"

const write_failed = "write_failed"

const read_failed = "read_failed"

/// The schema version this binary reads and writes: the length of the
/// migration chain.
pub fn supported_version() -> Int {
  list.length(migrations())
}

/// The forward migration chain: script `i` takes version `i` to `i + 1`.
fn migrations() -> List(String) {
  [schema_v1]
}

/// Open (creating if absent) the store for writing: WAL, `busy_timeout` 5 s,
/// `foreign_keys` on. No migration runs here.
pub fn open_writer(path: String) -> Result(Writer, Error) {
  use connection <- result.try(
    sqlight.open(path) |> result.replace_error(Store(open_failed)),
  )

  case configure(connection) {
    Ok(Nil) -> Ok(Writer(connection))
    Error(error) -> {
      let _ = sqlight.close(connection)
      Error(error)
    }
  }
}

/// The per-connection pragmas of the writer. `foreign_keys` is per connection
/// and cannot be set inside a transaction, so it belongs here, before any.
fn configure(connection: sqlight.Connection) -> Result(Nil, Error) {
  use _ <- result.try(exec("PRAGMA journal_mode=WAL", connection, open_failed))
  use _ <- result.try(exec("PRAGMA busy_timeout=5000", connection, open_failed))
  exec("PRAGMA foreign_keys=ON", connection, open_failed)
}

pub fn close_writer(writer: Writer) -> Nil {
  let _ = sqlight.close(writer.connection)
  Nil
}

/// Replace the store's contents with `snapshot` in one transaction: refuse a
/// newer `user_version`, migrate, delete every row, insert, commit.
pub fn write_snapshot(
  writer: Writer,
  snapshot: Snapshot,
) -> Result(Nil, Error) {
  write_snapshot_with(writer, snapshot, migrations())
}

/// `write_snapshot` over a given migration chain: script `i` takes version `i`
/// to `i + 1`. Exposed so tests can inject a failing migration.
@internal
pub fn write_snapshot_with(
  writer: Writer,
  snapshot: Snapshot,
  migrations: List(String),
) -> Result(Nil, Error) {
  let connection = writer.connection

  let outcome = {
    use _ <- result.try(exec("BEGIN IMMEDIATE", connection, write_failed))
    use _ <- result.try(update_schema(connection, migrations))
    use _ <- result.try(delete_rows(connection))
    use _ <- result.try(insert_snapshot(connection, snapshot))
    exec("COMMIT", connection, write_failed)
  }

  case outcome {
    Ok(Nil) -> Ok(Nil)
    // A newer store is not ours to write, and nothing has been touched: the
    // rollback leaves the schema, the rows and `user_version` as they were.
    Error(error) -> {
      rollback(connection)
      case error {
        Store(reason) if reason == schema_mismatch -> Error(error)
        _ -> Error(Store(write_failed))
      }
    }
  }
}

/// Migrate the store up to `migrations`'s length, inside the write
/// transaction. A store past that length is refused before any DDL.
fn update_schema(
  connection: sqlight.Connection,
  migrations: List(String),
) -> Result(Nil, Error) {
  use current <- result.try(user_version(connection, write_failed))
  let supported = list.length(migrations)

  case current > supported {
    True -> Error(Store(schema_mismatch))
    False -> {
      use _ <- result.try(
        list.try_each(list.drop(from: migrations, up_to: current), fn(script) {
          exec(script, connection, write_failed)
        }),
      )
      exec(
        "PRAGMA user_version = " <> int.to_string(supported),
        connection,
        write_failed,
      )
    }
  }
}

/// Delete every row of every data table, children before parents, so the
/// foreign keys never see a dangling row mid-way.
fn delete_rows(connection: sqlight.Connection) -> Result(Nil, Error) {
  list.try_each(delete_order, fn(table) {
    exec("DELETE FROM " <> table, connection, write_failed)
  })
}

/// The tables in delete order: `body`, `attachment`, `address`,
/// `message_header_id` and `message_mailbox` point at `message`, and `message`,
/// `mailbox`, `query_state` and `type_state` point at `sync`.
const delete_order = [
  "body",
  "attachment",
  "address",
  "message_header_id",
  "message_mailbox",
  "thread_email",
  "message",
  "mailbox",
  "query_state",
  "type_state",
  "sync",
]

/// Insert the whole snapshot, parents before children.
fn insert_snapshot(
  connection: sqlight.Connection,
  snapshot: Snapshot,
) -> Result(Nil, Error) {
  let account_id = snapshot.account.account_id

  use _ <- result.try(insert_sync(connection, snapshot.account))
  use _ <- result.try(insert_type_states(
    connection,
    account_id,
    snapshot.states,
  ))
  use _ <- result.try(insert_query_state(connection, account_id, snapshot.query))
  use _ <- result.try(insert_mailboxes(
    connection,
    account_id,
    snapshot.mailboxes,
  ))
  use _ <- result.try(insert_messages(connection, account_id, snapshot.messages))
  use _ <- result.try(insert_message_mailboxes(
    connection,
    account_id,
    snapshot.messages,
  ))
  use _ <- result.try(insert_header_ids(
    connection,
    account_id,
    snapshot.messages,
  ))
  use _ <- result.try(insert_addresses(
    connection,
    account_id,
    snapshot.messages,
  ))
  use _ <- result.try(insert_bodies(connection, account_id, snapshot.messages))
  use _ <- result.try(insert_attachments(
    connection,
    account_id,
    snapshot.messages,
  ))
  insert_thread_emails(connection, account_id, snapshot.threads)
}

fn insert_sync(
  connection: sqlight.Connection,
  account: AccountMeta,
) -> Result(Nil, Error) {
  insert(connection, insert_sync_sql, [
    sqlight.text(account.account_id),
    sqlight.text(account.synced_at.raw),
    sqlight.text(account.api_url),
    sqlight.text(account.window_json),
    sqlight.int(account.max_objects_in_get),
    sqlight.int(account.max_calls_in_request),
    sqlight.bool(account.is_read_only),
  ])
}

fn insert_type_states(
  connection: sqlight.Connection,
  account_id: String,
  states: List(TypeState),
) -> Result(Nil, Error) {
  list.try_each(states, fn(state) {
    insert(connection, insert_type_state_sql, [
      sqlight.text(account_id),
      sqlight.text(state.type_),
      sqlight.text(state.state),
    ])
  })
}

fn insert_query_state(
  connection: sqlight.Connection,
  account_id: String,
  query: QueryState,
) -> Result(Nil, Error) {
  insert(connection, insert_query_state_sql, [
    sqlight.text(account_id),
    sqlight.text(query.filter_json),
    sqlight.text(query.sort_json),
    sqlight.bool(query.collapse_threads),
    sqlight.text(query.query_state),
    sqlight.bool(query.can_calculate_changes),
  ])
}

fn insert_mailboxes(
  connection: sqlight.Connection,
  account_id: String,
  mailboxes: List(Mailbox),
) -> Result(Nil, Error) {
  list.try_each(mailboxes, fn(mailbox) {
    insert(connection, insert_mailbox_sql, [
      sqlight.text(account_id),
      sqlight.text(mailbox.id),
      sqlight.text(mailbox.name),
      optional_text(mailbox.parent_id),
      optional_text(mailbox.role),
      sqlight.int(mailbox.sort_order),
      sqlight.int(mailbox.total_emails),
      sqlight.int(mailbox.unread_emails),
    ])
  })
}

fn insert_messages(
  connection: sqlight.Connection,
  account_id: String,
  messages: List(Message),
) -> Result(Nil, Error) {
  list.try_each(messages, fn(message) {
    insert(connection, insert_message_sql, [
      sqlight.text(account_id),
      sqlight.text(message.id),
      sqlight.text(message.thread_id),
      sqlight.text(message.blob_id),
      sqlight.text(message.received_at.raw),
      sqlight.int(message.received_at.ms),
      optional_text(message.sent_at),
      optional_text(message.subject),
      sqlight.text(message.preview),
      sqlight.int(message.size),
      sqlight.bool(message.has_attachment),
      sqlight.bool(message.is_seen),
      sqlight.bool(message.is_flagged),
      sqlight.text(keywords_json(message.keywords)),
      sqlight.text(message.email_state),
    ])
  })
}

fn insert_message_mailboxes(
  connection: sqlight.Connection,
  account_id: String,
  messages: List(Message),
) -> Result(Nil, Error) {
  use message <- list.try_each(messages)
  list.try_each(message.mailbox_ids, fn(mailbox_id) {
    insert(connection, insert_message_mailbox_sql, [
      sqlight.text(account_id),
      sqlight.text(message.id),
      sqlight.text(mailbox_id),
    ])
  })
}

fn insert_header_ids(
  connection: sqlight.Connection,
  account_id: String,
  messages: List(Message),
) -> Result(Nil, Error) {
  use message <- list.try_each(messages)
  list.try_each(numbered_header_ids(message.header_ids), fn(row) {
    let #(header, position, value) = row
    insert(connection, insert_message_header_id_sql, [
      sqlight.text(account_id),
      sqlight.text(message.id),
      sqlight.text(header),
      sqlight.int(position),
      sqlight.text(value),
    ])
  })
}

fn insert_addresses(
  connection: sqlight.Connection,
  account_id: String,
  messages: List(Message),
) -> Result(Nil, Error) {
  use message <- list.try_each(messages)
  list.try_each(numbered_addresses(message.addresses), fn(row) {
    let #(field, position, address) = row
    insert(connection, insert_address_sql, [
      sqlight.text(account_id),
      sqlight.text(message.id),
      sqlight.text(field),
      sqlight.int(position),
      optional_text(address.name),
      sqlight.text(address.email),
    ])
  })
}

fn insert_bodies(
  connection: sqlight.Connection,
  account_id: String,
  messages: List(Message),
) -> Result(Nil, Error) {
  use message <- list.try_each(messages)
  list.try_each(positioned(message.bodies), fn(row) {
    let #(position, body) = row
    insert(connection, insert_body_sql, [
      sqlight.text(account_id),
      sqlight.text(message.id),
      sqlight.int(position),
      sqlight.text(body.part_id),
      sqlight.text(source_text(body.source)),
      sqlight.text(body.text),
      sqlight.bool(body.is_truncated),
      optional_text(truncated_by_text(body.truncated_by)),
      sqlight.bool(body.is_encoding_problem),
      sqlight.bool(body.conversion_failed),
      sqlight.int(body.max_body_value_bytes),
    ])
  })
}

fn insert_attachments(
  connection: sqlight.Connection,
  account_id: String,
  messages: List(Message),
) -> Result(Nil, Error) {
  use message <- list.try_each(messages)
  list.try_each(message.attachments, fn(attachment: Attachment) {
    insert(connection, insert_attachment_sql, [
      sqlight.text(account_id),
      sqlight.text(message.id),
      sqlight.text(attachment.part_id),
      sqlight.text(attachment.blob_id),
      optional_text(attachment.name),
      sqlight.text(attachment.type_),
      sqlight.int(attachment.size),
      optional_text(attachment.disposition),
      optional_text(attachment.cid),
    ])
  })
}

fn insert_thread_emails(
  connection: sqlight.Connection,
  account_id: String,
  threads: List(Thread),
) -> Result(Nil, Error) {
  use thread <- list.try_each(threads)
  list.try_each(positioned(thread.email_ids), fn(row) {
    let #(position, message_id) = row
    insert(connection, insert_thread_email_sql, [
      sqlight.text(account_id),
      sqlight.text(thread.id),
      sqlight.int(position),
      sqlight.text(message_id),
    ])
  })
}

/// A list with each element's 0-based index, so a row's `position` keeps the
/// order the model had.
fn positioned(items: List(a)) -> List(#(Int, a)) {
  items |> list.index_map(fn(item, position) { #(position, item) })
}

/// Each address numbered within its own field, so `(field, position)` orders
/// the `to` list as the header had it.
fn numbered_addresses(
  addresses: List(Address),
) -> List(#(String, Int, Address)) {
  addresses
  |> list.fold(
    [],
    fn(numbered: List(#(String, Int, Address)), address: Address) {
      let field = address_field_text(address.field)
      let position =
        numbered
        |> list.filter(fn(row) { row.0 == field })
        |> list.length
      [#(field, position, address), ..numbered]
    },
  )
  |> list.reverse
}

/// Each RFC 5322 identifier numbered within its header's list.
fn numbered_header_ids(ids: HeaderIds) -> List(#(String, Int, String)) {
  [
    #("message_id", ids.message_id),
    #("in_reply_to", ids.in_reply_to),
    #("references", ids.references),
  ]
  |> list.flat_map(fn(entry) {
    let #(header, values) = entry
    values |> list.index_map(fn(value, position) { #(header, position, value) })
  })
}

/// Run one parameterised statement. An insert returns no rows.
fn insert(
  connection: sqlight.Connection,
  sql: String,
  values: List(sqlight.Value),
) -> Result(Nil, Error) {
  sqlight.query(
    sql,
    on: connection,
    with: values,
    expecting: decode.success(Nil),
  )
  |> result.replace_error(Store(write_failed))
  |> result.map(fn(_rows) { Nil })
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// Open the store read-only. A missing or never-written store is
/// `no_snapshot`; any other version than `supported_version()` is
/// `schema_mismatch`.
pub fn open_reader(path: String) -> Result(Reader, Error) {
  open_reader_with(path, fn() { Nil })
}

/// `open_reader` with a hook every `select` calls once it has its rows.
/// Exposed so the I8 test can commit a new snapshot between a read's queries.
@internal
pub fn open_reader_with(
  path: String,
  after_select: fn() -> Nil,
) -> Result(Reader, Error) {
  use connection <- result.try(
    sqlight.open(reader_uri(path)) |> result.map_error(open_read_error),
  )

  case check_version(connection) {
    Ok(Nil) -> Ok(Reader(connection, after_select))
    Error(error) -> {
      let _ = sqlight.close(connection)
      Error(error)
    }
  }
}

pub fn close_reader(reader: Reader) -> Nil {
  let _ = sqlight.close(reader.connection)
  Nil
}

/// Run `query` inside one read transaction, so all its selects see one
/// committed snapshot.
pub fn read(
  reader: Reader,
  query: fn(Tx) -> Result(a, Error),
) -> Result(a, Error) {
  let connection = reader.connection

  let outcome = {
    use _ <- result.try(exec("BEGIN", connection, read_failed))
    use _ <- result.try(version_verdict(user_version(connection, read_failed)))
    query(Tx(connection, reader.after_select))
  }

  let outcome =
    result.try(outcome, fn(value) {
      exec("COMMIT", connection, read_failed) |> result.replace(value)
    })
  case outcome {
    Ok(value) -> Ok(value)
    // A failed COMMIT leaves the transaction open too; the next read must not
    // meet it.
    Error(error) -> {
      rollback(connection)
      Error(error)
    }
  }
}

/// One select inside a read transaction.
pub fn select(
  tx: Tx,
  sql: String,
  with arguments: List(sqlight.Value),
  expecting decoder: decode.Decoder(a),
) -> Result(List(a), Error) {
  let rows =
    sqlight.query(sql, on: tx.connection, with: arguments, expecting: decoder)
    |> result.replace_error(Store(read_failed))
  tx.after_select()
  rows
}

// ---------------------------------------------------------------------------
// Read queries (design § 5.2 read verbs). Each runs inside `read`'s one
// transaction and decodes the inverse of the insert encodings below.
// ---------------------------------------------------------------------------

/// The account the snapshot belongs to: the `sync` row's `account_id`.
pub fn account_id(tx: Tx) -> Result(String, Error) {
  use rows <- result.try(select(
    tx,
    select_account_id_sql,
    [],
    decode.field(0, decode.string, decode.success),
  ))
  case rows {
    [id, ..] -> Ok(id)
    [] -> Error(Store(no_snapshot))
  }
}

/// Every mailbox, ordered by `sort_order`, then `name`, then `id`.
pub fn mailboxes(tx: Tx) -> Result(List(Mailbox), Error) {
  select(tx, select_mailboxes_sql, [], mailbox_decoder())
}

/// The summaries `query` selects, newest first: `received_at_ms` descending,
/// then `id` descending (design § 5.3 ordering, reversed by operator decision
/// PHASE-06 D5), then `offset` and `limit`.
pub fn messages(
  tx: Tx,
  query: ListQuery,
) -> Result(List(MessageSummary), Error) {
  let #(sql, arguments) = list_sql(query)
  use rows <- result.try(select(tx, sql, arguments, summary_row_decoder()))
  list.try_map(rows, fn(row) { summary_of_row(tx, row) })
}

/// The whole message `id`, or `None` if the store holds no such message.
/// Unordered relations come back in a canonical order: `mailbox_ids` sorted,
/// `addresses` by field (model order) then position, `attachments` by
/// `part_id`; the lists that keep a position come back in it.
pub fn message(tx: Tx, id: String) -> Result(Option(Message), Error) {
  use rows <- result.try(select(
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
/// message is in the store; `None` if the store holds no such thread.
pub fn thread(tx: Tx, id: String) -> Result(Option(List(ThreadEntry)), Error) {
  use message_ids <- result.try(select(
    tx,
    select_thread_emails_sql,
    [sqlight.text(id)],
    decode.field(0, decode.string, decode.success),
  ))
  case message_ids {
    [] -> Ok(None)
    _ -> {
      use entries <- result.try(
        list.try_map(message_ids, fn(message_id) {
          use summary <- result.try(summary_of(tx, message_id))
          Ok(ThreadEntry(message_id, summary))
        }),
      )
      Ok(Some(entries))
    }
  }
}

// ---------------------------------------------------------------------------
// Read decoders: the inverse of the insert encoders above
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
fn assemble_message(tx: Tx, row: MessageRow) -> Result(Message, Error) {
  use keywords <- result.try(keywords_from_json(row.keywords_json))
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
fn summary_of(tx: Tx, id: String) -> Result(Option(MessageSummary), Error) {
  use rows <- result.try(select(
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
fn summary_of_row(tx: Tx, row: SummaryRow) -> Result(MessageSummary, Error) {
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

fn mailbox_ids_of(tx: Tx, message_id: String) -> Result(List(String), Error) {
  select(
    tx,
    select_message_mailboxes_sql,
    [sqlight.text(message_id)],
    decode.field(0, decode.string, decode.success),
  )
}

/// The RFC 5322 identifiers of one message, each list in its `position` order.
fn header_ids_of(tx: Tx, message_id: String) -> Result(HeaderIds, Error) {
  use rows <- result.try(select(
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
          _ -> Error(Store(read_failed))
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

fn addresses_of(tx: Tx, message_id: String) -> Result(List(Address), Error) {
  use rows <- result.try(select(
    tx,
    select_addresses_sql,
    [sqlight.text(message_id)],
    address_row_decoder(),
  ))
  address_rows(rows)
}

/// The `From` addresses of one message, in position order: a summary's `from`.
fn from_addresses_of(
  tx: Tx,
  message_id: String,
) -> Result(List(Address), Error) {
  use rows <- result.try(select(
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
    use field <- result.try(address_field_from_text(field))
    Ok(Address(field: field, name: name, email: email))
  })
}

fn bodies_of(tx: Tx, message_id: String) -> Result(List(Body), Error) {
  use rows <- result.try(select(
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
    use source <- result.try(source_from_text(source_type))
    use truncated_by <- result.try(truncated_by_from_text(truncated_by))
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
  tx: Tx,
  message_id: String,
) -> Result(List(Attachment), Error) {
  select(
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

/// A case-insensitive substring of a `From` address's email or name. `instr`
/// keeps `%` and `_` literal, where `LIKE` would read them as wildcards.
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

/// The read-only URI of the store. SQLite reads `path` as a URI, so the three
/// characters that would change its meaning are percent-encoded (`%` first,
/// so the encodings of the other two are not doubled).
fn reader_uri(path: String) -> String {
  let escaped =
    path
    |> string.replace("%", "%25")
    |> string.replace("?", "%3F")
    |> string.replace("#", "%23")
  "file:" <> escaped <> "?mode=ro"
}

/// A missing file is "no store yet"; anything else is a broken open.
fn open_read_error(error: sqlight.Error) -> Error {
  case error {
    sqlight.SqlightError(code: sqlight.Cantopen, ..) -> Store(no_snapshot)
    _ -> Store(open_failed)
  }
}

/// The version check of `open_reader`, in a read transaction of its own: the
/// transaction is rolled back, whatever the verdict, so no lock is held.
fn check_version(connection: sqlight.Connection) -> Result(Nil, Error) {
  use _ <- result.try(exec("BEGIN", connection, read_failed))
  let verdict = version_verdict(user_version(connection, read_failed))
  rollback(connection)
  verdict
}

/// Version 0 is a store no sync has written; any other version but ours is a
/// store this binary must not read.
fn version_verdict(version: Result(Int, Error)) -> Result(Nil, Error) {
  use version <- result.try(version)
  let supported = supported_version()
  case version {
    0 -> Error(Store(no_snapshot))
    _ if version == supported -> Ok(Nil)
    _ -> Error(Store(schema_mismatch))
  }
}

// ---------------------------------------------------------------------------
// SQLite plumbing
// ---------------------------------------------------------------------------

/// Run one statement with no arguments, mapping its failure onto `reason`. No
/// SQLite message ever leaves this module (I1).
fn exec(
  sql: String,
  connection: sqlight.Connection,
  reason: String,
) -> Result(Nil, Error) {
  sqlight.exec(sql, on: connection)
  |> result.replace_error(Store(reason))
}

/// `PRAGMA user_version` of this connection.
fn user_version(
  connection: sqlight.Connection,
  reason: String,
) -> Result(Int, Error) {
  use rows <- result.try(
    sqlight.query(
      "PRAGMA user_version",
      on: connection,
      with: [],
      expecting: decode.field(0, decode.int, decode.success),
    )
    |> result.replace_error(Store(reason)),
  )
  case rows {
    [version, ..] -> Ok(version)
    [] -> Error(Store(reason))
  }
}

/// Roll back and forget the outcome: the caller is already reporting a failure.
fn rollback(connection: sqlight.Connection) -> Nil {
  let _ = sqlight.exec("ROLLBACK", on: connection)
  Nil
}

fn optional_text(value: Option(String)) -> sqlight.Value {
  sqlight.nullable(sqlight.text, value)
}

/// The keyword list as the JSON array `keywords_json` holds.
fn keywords_json(keywords: List(String)) -> String {
  json.to_string(json.array(keywords, json.string))
}

/// The inverse of `keywords_json`; a text that is not a JSON array of strings
/// is a decode failure, never a crash.
fn keywords_from_json(text: String) -> Result(List(String), Error) {
  json.parse(text, using: decode.list(decode.string))
  |> result.replace_error(Store(read_failed))
}

fn source_text(source: Source) -> String {
  case source {
    PlainText -> "text"
    Html -> "html"
  }
}

/// The inverse of `source_text`.
fn source_from_text(text: String) -> Result(Source, Error) {
  case text {
    "text" -> Ok(PlainText)
    "html" -> Ok(Html)
    _ -> Error(Store(read_failed))
  }
}

fn truncated_by_text(value: Option(TruncatedBy)) -> Option(String) {
  case value {
    Some(Server) -> Some("server")
    Some(MessageLimit) -> Some("message_limit")
    None -> None
  }
}

/// The inverse of `truncated_by_text`.
fn truncated_by_from_text(
  text: Option(String),
) -> Result(Option(TruncatedBy), Error) {
  case text {
    Some("server") -> Ok(Some(Server))
    Some("message_limit") -> Ok(Some(MessageLimit))
    Some(_) -> Error(Store(read_failed))
    None -> Ok(None)
  }
}

fn address_field_text(field: AddressField) -> String {
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
fn address_field_from_text(text: String) -> Result(AddressField, Error) {
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

// ---------------------------------------------------------------------------
// SQL
// ---------------------------------------------------------------------------

/// Schema version 1: the eleven tables of design § 5.3, their composite keys as
/// the table's Key column, the foreign keys the model implies, and the three
/// indexes the read verbs lean on. `message` keeps the raw receipt time and its
/// millisecond key (RV-001 F-17); `thread_email` has no foreign key to
/// `message`, because a thread may name messages outside the window.
const schema_v1 =
  "
CREATE TABLE sync (
  account_id TEXT PRIMARY KEY,
  synced_at TEXT NOT NULL,
  api_url TEXT NOT NULL,
  window_json TEXT NOT NULL,
  max_objects_in_get INTEGER NOT NULL,
  max_calls_in_request INTEGER NOT NULL,
  is_read_only INTEGER NOT NULL
);

CREATE TABLE type_state (
  account_id TEXT NOT NULL REFERENCES sync (account_id),
  type TEXT NOT NULL,
  state TEXT NOT NULL,
  PRIMARY KEY (account_id, type)
);

CREATE TABLE query_state (
  account_id TEXT NOT NULL REFERENCES sync (account_id),
  filter_json TEXT NOT NULL,
  sort_json TEXT NOT NULL,
  collapse_threads INTEGER NOT NULL,
  query_state TEXT NOT NULL,
  can_calculate_changes INTEGER NOT NULL,
  PRIMARY KEY (account_id, filter_json, sort_json)
);

CREATE TABLE mailbox (
  account_id TEXT NOT NULL REFERENCES sync (account_id),
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  parent_id TEXT,
  role TEXT,
  sort_order INTEGER NOT NULL,
  total_emails INTEGER NOT NULL,
  unread_emails INTEGER NOT NULL,
  PRIMARY KEY (account_id, id)
);

CREATE TABLE message (
  account_id TEXT NOT NULL REFERENCES sync (account_id),
  id TEXT NOT NULL,
  thread_id TEXT NOT NULL,
  blob_id TEXT NOT NULL,
  received_at TEXT NOT NULL,
  received_at_ms INTEGER NOT NULL,
  sent_at TEXT,
  subject TEXT,
  preview TEXT NOT NULL,
  size INTEGER NOT NULL,
  has_attachment INTEGER NOT NULL,
  is_seen INTEGER NOT NULL,
  is_flagged INTEGER NOT NULL,
  keywords_json TEXT NOT NULL,
  email_state TEXT NOT NULL,
  PRIMARY KEY (account_id, id)
);

CREATE TABLE message_mailbox (
  account_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  mailbox_id TEXT NOT NULL,
  PRIMARY KEY (account_id, message_id, mailbox_id),
  FOREIGN KEY (account_id, message_id) REFERENCES message (account_id, id),
  FOREIGN KEY (account_id, mailbox_id) REFERENCES mailbox (account_id, id)
);

CREATE TABLE message_header_id (
  account_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  header TEXT NOT NULL,
  position INTEGER NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (account_id, message_id, header, position),
  FOREIGN KEY (account_id, message_id) REFERENCES message (account_id, id)
);

CREATE TABLE address (
  account_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  field TEXT NOT NULL,
  position INTEGER NOT NULL,
  name TEXT,
  email TEXT NOT NULL,
  PRIMARY KEY (account_id, message_id, field, position),
  FOREIGN KEY (account_id, message_id) REFERENCES message (account_id, id)
);

CREATE TABLE body (
  account_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  position INTEGER NOT NULL,
  part_id TEXT NOT NULL,
  source_type TEXT NOT NULL,
  text TEXT NOT NULL,
  is_truncated INTEGER NOT NULL,
  truncated_by TEXT,
  is_encoding_problem INTEGER NOT NULL,
  conversion_failed INTEGER NOT NULL,
  max_body_value_bytes INTEGER NOT NULL,
  PRIMARY KEY (account_id, message_id, position),
  FOREIGN KEY (account_id, message_id) REFERENCES message (account_id, id)
);

CREATE TABLE attachment (
  account_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  part_id TEXT NOT NULL,
  blob_id TEXT NOT NULL,
  name TEXT,
  type TEXT NOT NULL,
  size INTEGER NOT NULL,
  disposition TEXT,
  cid TEXT,
  PRIMARY KEY (account_id, message_id, part_id),
  FOREIGN KEY (account_id, message_id) REFERENCES message (account_id, id)
);

CREATE TABLE thread_email (
  account_id TEXT NOT NULL REFERENCES sync (account_id),
  thread_id TEXT NOT NULL,
  position INTEGER NOT NULL,
  message_id TEXT NOT NULL,
  PRIMARY KEY (account_id, thread_id, position)
);

CREATE INDEX message_received_at_ms ON message (received_at_ms);
CREATE INDEX address_email ON address (email);
CREATE INDEX message_mailbox_mailbox_id ON message_mailbox (mailbox_id);
"

const insert_sync_sql =
  "INSERT INTO sync (account_id, synced_at, api_url, window_json,"
  <> " max_objects_in_get, max_calls_in_request, is_read_only)"
  <> " VALUES (?, ?, ?, ?, ?, ?, ?)"

const insert_type_state_sql =
  "INSERT INTO type_state (account_id, type, state) VALUES (?, ?, ?)"

const insert_query_state_sql =
  "INSERT INTO query_state (account_id, filter_json, sort_json,"
  <> " collapse_threads, query_state, can_calculate_changes)"
  <> " VALUES (?, ?, ?, ?, ?, ?)"

const insert_mailbox_sql =
  "INSERT INTO mailbox (account_id, id, name, parent_id, role, sort_order,"
  <> " total_emails, unread_emails) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"

const insert_message_sql =
  "INSERT INTO message (account_id, id, thread_id, blob_id, received_at,"
  <> " received_at_ms, sent_at, subject, preview, size, has_attachment,"
  <> " is_seen, is_flagged, keywords_json, email_state)"
  <> " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"

const insert_message_mailbox_sql =
  "INSERT INTO message_mailbox (account_id, message_id, mailbox_id)"
  <> " VALUES (?, ?, ?)"

const insert_message_header_id_sql =
  "INSERT INTO message_header_id (account_id, message_id, header, position,"
  <> " value) VALUES (?, ?, ?, ?, ?)"

const insert_address_sql =
  "INSERT INTO address (account_id, message_id, field, position, name, email)"
  <> " VALUES (?, ?, ?, ?, ?, ?)"

const insert_body_sql =
  "INSERT INTO body (account_id, message_id, position, part_id, source_type,"
  <> " text, is_truncated, truncated_by, is_encoding_problem, conversion_failed,"
  <> " max_body_value_bytes) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"

const insert_attachment_sql =
  "INSERT INTO attachment (account_id, message_id, part_id, blob_id, name,"
  <> " type, size, disposition, cid) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"

const insert_thread_email_sql =
  "INSERT INTO thread_email (account_id, thread_id, position, message_id)"
  <> " VALUES (?, ?, ?, ?)"

const select_account_id_sql = "SELECT account_id FROM sync"

const select_mailboxes_sql =
  "SELECT id, name, parent_id, role, sort_order, total_emails, unread_emails"
  <> " FROM mailbox ORDER BY sort_order, name, id"

const select_summaries_sql =
  "SELECT id, thread_id, received_at, received_at_ms, subject, preview,"
  <> " is_seen, is_flagged, has_attachment FROM message"

const select_summary_sql =
  "SELECT id, thread_id, received_at, received_at_ms, subject, preview,"
  <> " is_seen, is_flagged, has_attachment FROM message WHERE id = ?"

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
