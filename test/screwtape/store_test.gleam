//// Contract tests for `screwtape/store` (PHASE-04, T3; EX-1, EX-3..EX-6;
//// VT-1..VT-4).
////
//// These are the tests of the store's contract with everything above it: the
//// schema of design § 5.3, migrations that run inside `write_snapshot`'s
//// transaction only, a write that refuses a newer store untouched, and a
//// read-only reader that serves one committed snapshot. "Unchanged" always
//// means a byte-for-byte equal logical dump (`support/store_dump`), so a
//// leftover table, row or `user_version` bump is visible.
////
//// Every test builds its store under a fresh temporary directory and removes
//// it, so the sandbox stays clean. The dump is taken only between connections,
//// so it reads what was committed.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order, Eq}
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/error.{type Error, Store}
import screwtape/model
import screwtape/store
import sqlight
import support/snapshot_fixture
import support/store_dump
import support/temp

pub fn main() -> Nil {
  gleeunit.main()
}

/// The fixture account. Every id and text of `snapshot_fixture.full` carries
/// it, so a dump that still mentions it still holds a row of that snapshot.
const account = "acct-a"

/// The eleven tables of design § 5.3.
const tables = [
  "address",
  "attachment",
  "body",
  "mailbox",
  "message",
  "message_header_id",
  "message_mailbox",
  "query_state",
  "sync",
  "thread_email",
  "type_state",
]

// ---------------------------------------------------------------------------
// Setup helpers
// ---------------------------------------------------------------------------

/// A fresh temporary directory and a store path inside it that does not exist
/// yet. The directory is returned so the test can remove it.
fn fresh_path(prefix: String) -> #(String, String) {
  let dir = temp.dir("screwtape-store-" <> prefix)
  #(dir, dir <> "/screwtape.db")
}

/// Create the store file as an empty (zero-byte) file and close at once: the
/// state a first `sync` meets, and the "before" of a pending migration.
fn create_empty_file(path: String) -> Nil {
  let assert Ok(connection) = sqlight.open(path)
  let assert Ok(Nil) = sqlight.close(connection)
  Nil
}

/// A store holding `snapshot`, written through the real writer and closed.
fn written(snapshot: model.Snapshot) -> #(String, String) {
  let #(dir, path) = fresh_path("written")
  let assert Ok(writer) = store.open_writer(path)
  let assert Ok(Nil) = store.write_snapshot(writer, snapshot)
  store.close_writer(writer)
  #(dir, path)
}

/// Run one statement on `path` through a plain sqlight connection, as an
/// operator (or a newer binary) would: outside the store.
fn raw_exec(path: String, sql: String) -> Nil {
  let assert Ok(connection) = sqlight.open(path)
  let assert Ok(Nil) = sqlight.exec(sql, on: connection)
  let assert Ok(Nil) = sqlight.close(connection)
  Nil
}

/// Open the store read-only, run `query` in one read, and close the reader.
fn read_from(
  path: String,
  query: fn(store.Tx) -> Result(a, Error),
) -> Result(a, Error) {
  let assert Ok(reader) = store.open_reader(path)
  let result = store.read(reader, query)
  store.close_reader(reader)
  result
}

// ---------------------------------------------------------------------------
// Decoders
// ---------------------------------------------------------------------------

fn string_column(index: Int) -> decode.Decoder(String) {
  decode.field(index, decode.string, decode.success)
}

/// A `(tbl_name, sql)` row of `sqlite_schema`.
fn index_decoder() -> decode.Decoder(#(String, String)) {
  use table <- decode.field(0, decode.string)
  use sql <- decode.field(1, decode.string)
  decode.success(#(table, sql))
}

/// A `body` row: `part_id, source_type, text, is_truncated, truncated_by`.
fn body_decoder() -> decode.Decoder(
  #(String, String, String, Int, Option(String)),
) {
  use part_id <- decode.field(0, decode.string)
  use source_type <- decode.field(1, decode.string)
  use text <- decode.field(2, decode.string)
  use is_truncated <- decode.field(3, decode.int)
  use truncated_by <- decode.field(4, decode.optional(decode.string))
  decode.success(#(part_id, source_type, text, is_truncated, truncated_by))
}

/// An `address` row: `field, name, email`.
fn address_decoder() -> decode.Decoder(#(String, Option(String), String)) {
  use field <- decode.field(0, decode.string)
  use name <- decode.field(1, decode.optional(decode.string))
  use email <- decode.field(2, decode.string)
  decode.success(#(field, name, email))
}

/// A `message_header_id` row: `header, value`.
fn header_decoder() -> decode.Decoder(#(String, String)) {
  use header <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(header, value))
}

// ---------------------------------------------------------------------------
// The expected rows, derived from the fixture model (design § 5.3 encodings)
// ---------------------------------------------------------------------------

fn bool_int(value: Bool) -> Int {
  case value {
    True -> 1
    False -> 0
  }
}

fn source_text(source: model.Source) -> String {
  case source {
    model.PlainText -> "text"
    model.Html -> "html"
  }
}

fn truncated_by_text(value: Option(model.TruncatedBy)) -> Option(String) {
  case value {
    Some(model.Server) -> Some("server")
    Some(model.MessageLimit) -> Some("message_limit")
    None -> None
  }
}

fn address_field_text(field: model.AddressField) -> String {
  case field {
    model.From -> "from"
    model.Sender -> "sender"
    model.To -> "to"
    model.Cc -> "cc"
    model.Bcc -> "bcc"
    model.ReplyTo -> "reply_to"
  }
}

/// The message's bodies in `position` order, which is the model's order.
fn expected_body_rows(
  bodies: List(model.Body),
) -> List(#(String, String, String, Int, Option(String))) {
  bodies
  |> list.map(fn(body) {
    #(
      body.part_id,
      source_text(body.source),
      body.text,
      bool_int(body.is_truncated),
      truncated_by_text(body.truncated_by),
    )
  })
}

/// The message's addresses ordered by `field`, each field in the model's
/// order (the sort is stable, so `to` keeps the order the header had).
fn expected_address_rows(
  addresses: List(model.Address),
) -> List(#(String, Option(String), String)) {
  addresses
  |> list.map(fn(address) {
    #(address_field_text(address.field), address.name, address.email)
  })
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

/// The message's RFC 5322 identifiers ordered by `header`, each list in the
/// header's order.
fn expected_header_rows(ids: model.HeaderIds) -> List(#(String, String)) {
  [
    #("in_reply_to", ids.in_reply_to),
    #("message_id", ids.message_id),
    #("references", ids.references),
  ]
  |> list.flat_map(fn(entry) {
    let #(header, values) = entry
    values |> list.map(fn(value) { #(header, value) })
  })
}

/// The one message the round trip reads back: the fixture's first, which
/// carries every address field, every header-id kind and both body sources.
fn first_message(snapshot: model.Snapshot) -> model.Message {
  let assert [message, ..] = snapshot.messages
  message
}

/// Milliseconds first, then id: the store's ordering contract (design § 5.3).
fn message_order(a: model.Message, b: model.Message) -> Order {
  case int.compare(a.received_at.ms, b.received_at.ms) {
    Eq -> string.compare(a.id, b.id)
    other -> other
  }
}

fn sorted_message_ids(snapshot: model.Snapshot) -> List(String) {
  snapshot.messages
  |> list.sort(message_order)
  |> list.map(fn(message) { message.id })
}

/// The SQL of every explicit index on `table`, one per line.
fn index_sql(rows: List(#(String, String)), table: String) -> String {
  rows
  |> list.filter(fn(row) { row.0 == table })
  |> list.map(fn(row) { row.1 })
  |> string.join("\n")
}

// ---------------------------------------------------------------------------
// EX-3 / VT-1: migrations run inside the write transaction, nothing else
// ---------------------------------------------------------------------------

/// VT-1 (pending migration, then a write that fails before commit): a fresh
/// empty store with version 0 and a pending migration, written with an insert
/// that violates a primary key. The dump must be the one taken before
/// `open_writer` — no table created, `user_version` still 0. This fails an
/// implementation that migrates in `open_writer`, because the migration would
/// already be visible in the "after" dump.
pub fn pending_migration_write_failure_leaves_dump_and_user_version_unchanged_test() {
  let #(dir, path) = fresh_path("pending")
  create_empty_file(path)
  let before = store_dump.dump(path)

  let assert Ok(writer) = store.open_writer(path)
  let result = store.write_snapshot(writer, snapshot_fixture.broken())
  store.close_writer(writer)
  let after = store_dump.dump(path)
  temp.remove_dir(dir)

  result |> should.equal(Error(Store("write_failed")))
  after |> should.equal(before)
  after |> string.starts_with("user_version=0\n") |> should.be_true
}

/// VT-1 (failing migration): the second script of the injected chain is not
/// SQL, so the write fails after the first script already created a table.
/// The dump must be the one taken before the write: `ok_step` gone,
/// `user_version` still 0.
pub fn pending_migration_failing_migration_rolls_back_the_dump_test() {
  let #(dir, path) = fresh_path("bad-migration")
  create_empty_file(path)
  let before = store_dump.dump(path)
  let chain = ["CREATE TABLE ok_step (x TEXT)", "THIS IS NOT SQL"]

  let assert Ok(writer) = store.open_writer(path)
  let result =
    store.write_snapshot_with(writer, snapshot_fixture.full(account), chain)
  store.close_writer(writer)
  let after = store_dump.dump(path)
  temp.remove_dir(dir)

  result |> should.equal(Error(Store("write_failed")))
  after |> should.equal(before)
  after |> string.contains("ok_step") |> should.be_false
}

/// VT-1 (user_version): a first successful write takes the store from 0 to
/// the version this binary supports, which is the length of the chain.
pub fn user_version_after_a_first_write_is_the_supported_version_test() {
  let #(dir, path) = written(snapshot_fixture.full(account))
  let dump = store_dump.dump(path)
  temp.remove_dir(dir)

  dump
  |> string.starts_with(
    "user_version=" <> int.to_string(store.supported_version()) <> "\n",
  )
  |> should.be_true
}

// ---------------------------------------------------------------------------
// EX-4 / VT-2: a newer store is refused untouched
// ---------------------------------------------------------------------------

/// VT-2: a populated store taken to `supported_version() + 1` and given a
/// column this binary does not know. The write must fail with
/// `schema_mismatch` and change nothing, and a reader must refuse it too, so
/// a forward-only migration loop cannot pass this.
pub fn newer_schema_is_refused_with_schema_mismatch_and_left_untouched_test() {
  let #(dir, path) = written(snapshot_fixture.full(account))
  let newer = store.supported_version() + 1
  raw_exec(
    path,
    "ALTER TABLE message ADD COLUMN extra TEXT NOT NULL DEFAULT 'x'",
  )
  raw_exec(path, "PRAGMA user_version = " <> int.to_string(newer))
  let before = store_dump.dump(path)

  let assert Ok(writer) = store.open_writer(path)
  let write_result =
    store.write_snapshot(writer, snapshot_fixture.full("acct-b"))
  store.close_writer(writer)
  let after = store_dump.dump(path)
  let read_result = store.open_reader(path)
  temp.remove_dir(dir)

  write_result |> should.equal(Error(Store("schema_mismatch")))
  after |> should.equal(before)
  after
  |> string.contains("user_version=" <> int.to_string(newer) <> "\n")
  |> should.be_true
  // Still the first account's rows, and nothing of the second's.
  after |> string.contains("acct-a") |> should.be_true
  after |> string.contains("acct-b") |> should.be_false
  read_result |> should.equal(Error(Store("schema_mismatch")))
}

// ---------------------------------------------------------------------------
// EX-5 / VT-3: the read-only reader
// ---------------------------------------------------------------------------

/// VT-3: no store file at all is `no_snapshot`, and the reader never creates
/// one (it opens mode=ro, so a missing path stays missing).
pub fn open_reader_refuses_a_missing_store_with_no_snapshot_test() {
  let #(dir, path) = fresh_path("missing")
  let result = store.open_reader(path)
  let created = is_file(path)
  temp.remove_dir(dir)

  result |> should.equal(Error(Store("no_snapshot")))
  created |> should.be_false
}

@external(erlang, "filelib", "is_file")
fn is_file(path: String) -> Bool

/// VT-3: an existing but never-written store (version 0, no `sync` row) is
/// `no_snapshot`, not a migration prompt.
pub fn open_reader_refuses_an_empty_store_with_no_snapshot_test() {
  let #(dir, path) = fresh_path("empty")
  create_empty_file(path)
  let result = store.open_reader(path)
  temp.remove_dir(dir)

  result |> should.equal(Error(Store("no_snapshot")))
}

/// VT-3: after a write the reader succeeds and its read sees the fixture's
/// messages in the store's order: `received_at_ms`, then id.
pub fn open_reader_reads_the_fixture_message_ids_in_order_test() {
  let snapshot = snapshot_fixture.full(account)
  let #(dir, path) = written(snapshot)
  let result =
    read_from(path, fn(tx) {
      store.select(
        tx,
        "SELECT id FROM message ORDER BY received_at_ms, id",
        with: [],
        expecting: string_column(0),
      )
    })
  temp.remove_dir(dir)

  result |> should.equal(Ok(sorted_message_ids(snapshot)))
}

/// VT-3: the reader opens read-only, so a write inside its transaction fails
/// with `read_failed` and leaves the store as it was.
pub fn a_read_transaction_refuses_a_write_with_read_failed_test() {
  let #(dir, path) = written(snapshot_fixture.full(account))
  let before = store_dump.dump(path)
  let result =
    read_from(path, fn(tx) {
      store.select(
        tx,
        "INSERT INTO mailbox (account_id, id, name, sort_order, total_emails, unread_emails) VALUES ('acct-a', 'acct-a-new', 'New', 9, 0, 0)",
        with: [],
        expecting: decode.success(Nil),
      )
    })
  let after = store_dump.dump(path)
  temp.remove_dir(dir)

  result |> should.equal(Error(Store("read_failed")))
  after |> should.equal(before)
}

// ---------------------------------------------------------------------------
// EX-6 / VT-3: idempotence, replacement and rollback at store level
// ---------------------------------------------------------------------------

/// VT-3: writing the same snapshot twice gives the same dump, so a repeated
/// sync changes nothing (I3).
pub fn identical_writes_give_identical_dumps_test() {
  let #(dir, path) = written(snapshot_fixture.full(account))
  let first = store_dump.dump(path)

  let assert Ok(writer) = store.open_writer(path)
  let assert Ok(Nil) =
    store.write_snapshot(writer, snapshot_fixture.full(account))
  store.close_writer(writer)
  let second = store_dump.dump(path)
  temp.remove_dir(dir)

  second |> should.equal(first)
}

/// VT-3: a write for another account leaves nothing of the first, because the
/// transaction deletes every row before it inserts.
pub fn account_change_leaves_nothing_of_the_previous_account_test() {
  let #(dir, path) = written(snapshot_fixture.full(account))

  let assert Ok(writer) = store.open_writer(path)
  let assert Ok(Nil) =
    store.write_snapshot(writer, snapshot_fixture.full("acct-b"))
  store.close_writer(writer)
  let dump = store_dump.dump(path)
  temp.remove_dir(dir)

  dump |> string.contains("acct-a") |> should.be_false
  dump |> string.contains("acct-b") |> should.be_true
}

/// VT-3: an insert failure in the middle of a write rolls the whole
/// transaction back; the previous snapshot survives intact (I2).
pub fn insert_failure_rolls_back_the_dump_test() {
  let #(dir, path) = written(snapshot_fixture.full(account))
  let before = store_dump.dump(path)

  let assert Ok(writer) = store.open_writer(path)
  let result = store.write_snapshot(writer, snapshot_fixture.broken())
  store.close_writer(writer)
  let after = store_dump.dump(path)
  temp.remove_dir(dir)

  result |> should.equal(Error(Store("write_failed")))
  after |> should.equal(before)
}

/// EX-2 (rollback, not close): a failed write must roll its transaction back
/// itself, so the same writer can write again. A writer that left the
/// transaction open would fail the second `BEGIN IMMEDIATE`; closing the
/// connection would hide that, so this test keeps it open.
pub fn a_failed_write_leaves_the_writer_usable_test() {
  let #(dir, path) = fresh_path("reuse")
  let assert Ok(writer) = store.open_writer(path)
  let failed = store.write_snapshot(writer, snapshot_fixture.broken())
  let retried = store.write_snapshot(writer, snapshot_fixture.full(account))
  store.close_writer(writer)
  let dump = store_dump.dump(path)
  temp.remove_dir(dir)

  failed |> should.equal(Error(Store("write_failed")))
  retried |> should.equal(Ok(Nil))
  dump |> string.contains(account) |> should.be_true
}

/// EX-1 (foreign_keys on): a message filed in a mailbox the snapshot does not
/// hold breaks `message_mailbox`'s foreign key, so the write fails and rolls
/// back. With foreign keys off it would commit.
pub fn foreign_keys_refuse_a_dangling_mailbox_test() {
  let #(dir, path) = written(snapshot_fixture.full(account))
  let before = store_dump.dump(path)
  let dangling = model.Snapshot(..snapshot_fixture.full(account), mailboxes: [])

  let assert Ok(writer) = store.open_writer(path)
  let result = store.write_snapshot(writer, dangling)
  store.close_writer(writer)
  let after = store_dump.dump(path)
  temp.remove_dir(dir)

  result |> should.equal(Error(Store("write_failed")))
  after |> should.equal(before)
}

// ---------------------------------------------------------------------------
// EX-1 / VT-4: the schema of design § 5.3
// ---------------------------------------------------------------------------

/// VT-4: the eleven tables, and the three indexes the read verbs lean on:
/// `message(received_at_ms)`, `address(email)`, `message_mailbox(mailbox_id)`.
pub fn schema_carries_the_eleven_tables_and_three_indexes_test() {
  let #(dir, path) = written(snapshot_fixture.full(account))
  let names =
    read_from(path, fn(tx) {
      store.select(
        tx,
        "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name",
        with: [],
        expecting: string_column(0),
      )
    })
  let indexes =
    read_from(path, fn(tx) {
      store.select(
        tx,
        "SELECT tbl_name, sql FROM sqlite_schema WHERE type = 'index' AND sql IS NOT NULL",
        with: [],
        expecting: index_decoder(),
      )
    })
  temp.remove_dir(dir)

  let assert Ok(names) = names
  tables
  |> list.each(fn(table) { list.contains(names, table) |> should.be_true })

  let assert Ok(indexes) = indexes
  index_sql(indexes, "message")
  |> string.contains("received_at_ms")
  |> should.be_true
  index_sql(indexes, "address")
  |> string.contains("email")
  |> should.be_true
  index_sql(indexes, "message_mailbox")
  |> string.contains("mailbox_id")
  |> should.be_true
}

/// VT-4: the store runs in WAL, and `message` keeps the receipt time both raw
/// and as the integer sort key `received_at_ms` (RV-001 F-17).
pub fn schema_runs_with_journal_mode_wal_and_a_received_at_ms_column_test() {
  let #(dir, path) = written(snapshot_fixture.full(account))
  let journal_mode =
    read_from(path, fn(tx) {
      store.select(
        tx,
        "PRAGMA journal_mode",
        with: [],
        expecting: string_column(0),
      )
    })
  let columns =
    read_from(path, fn(tx) {
      store.select(
        tx,
        "SELECT name FROM pragma_table_info('message')",
        with: [],
        expecting: string_column(0),
      )
    })
  temp.remove_dir(dir)

  journal_mode |> should.equal(Ok(["wal"]))
  let assert Ok(columns) = columns
  columns |> list.contains("received_at_ms") |> should.be_true
}

// ---------------------------------------------------------------------------
// The row round trip: the fixture's model comes back as the stored rows
// ---------------------------------------------------------------------------

/// One fixture message read back row for row: its bodies by position, its
/// addresses by field then position, its header ids by header then position.
/// The expected rows are derived from the fixture model with the § 5.3
/// encodings (`0`/`1` for booleans, `text`/`html`, `server`/`message_limit`,
/// `from`/`sender`/`to`/`cc`/`bcc`/`reply_to`,
/// `message_id`/`in_reply_to`/`references`), so a renamed or re-encoded value
/// fails here rather than silently in a read verb.
pub fn round_trip_keeps_bodies_addresses_and_header_ids_test() {
  let snapshot = snapshot_fixture.full(account)
  let message = first_message(snapshot)
  let #(dir, path) = written(snapshot)

  let bodies =
    read_from(path, fn(tx) {
      store.select(
        tx,
        "SELECT part_id, source_type, text, is_truncated, truncated_by FROM body WHERE message_id = ? ORDER BY position",
        with: [sqlight.text(message.id)],
        expecting: body_decoder(),
      )
    })
  let addresses =
    read_from(path, fn(tx) {
      store.select(
        tx,
        "SELECT field, name, email FROM address WHERE message_id = ? ORDER BY field, position",
        with: [sqlight.text(message.id)],
        expecting: address_decoder(),
      )
    })
  let headers =
    read_from(path, fn(tx) {
      store.select(
        tx,
        "SELECT header, value FROM message_header_id WHERE message_id = ? ORDER BY header, position",
        with: [sqlight.text(message.id)],
        expecting: header_decoder(),
      )
    })
  temp.remove_dir(dir)

  bodies |> should.equal(Ok(expected_body_rows(message.bodies)))
  addresses |> should.equal(Ok(expected_address_rows(message.addresses)))
  headers |> should.equal(Ok(expected_header_rows(message.header_ids)))
}
