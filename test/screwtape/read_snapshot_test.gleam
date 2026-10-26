//// Contract test for invariant I8 (PHASE-06, EX-2; VT-1; RV-001 F-15): each
//// read verb's output comes from one committed snapshot.
////
//// The reader is opened with `store.open_reader_with`, whose hook every
//// `select` calls once it has its rows. The hook opens a second_connection as
//// the writer and commits snapshot B, in which the message being read has a
//// different subject, preview, bodies, addresses, attachments and mailbox
//// membership. The read must still return the message as snapshot A stored it
//// (the old_snapshot).
////
//// Why this fails if `store.read` ran each select in autocommit (no
//// BEGIN/COMMIT): `store.message` issues several selects (the message row,
//// then its addresses, header ids, bodies, attachments and mailbox ids). The
//// hook commits B after the first of them. In autocommit every later select
//// starts a fresh implicit read transaction, so it sees B's rows: the result
//// would carry A's subject with B's addresses, bodies and so on, and differs
//// from A. Under one read transaction WAL keeps serving the snapshot taken at
//// its first read, so every select sees A. (If `message` were one single
//// select, autocommit could not be told apart; the test assumes the several
//// selects the design describes.)
////
//// The test does not depend on `read` reading `PRAGMA user_version` right
//// after BEGIN. SQLite's deferred BEGIN takes the snapshot at the first read,
//// and the hook first fires only after the first `select` has its rows, so the
//// snapshot is already pinned to A either way.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit/should
import screwtape/model.{
  type Message, type Snapshot, Address, Attachment, Body, From, Message,
  PlainText, Snapshot, To,
}
import screwtape/store
import support/snapshot_fixture
import support/temp

const account = "acct-a"

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub fn read_serves_one_snapshot_while_another_commits_test() {
  let old_snapshot = snapshot_fixture.full(account)
  let message = first_message(old_snapshot)
  let new_snapshot = rewritten(old_snapshot, message.id)
  let #(dir, path) = written(old_snapshot)

  let assert Ok(reader) =
    store.open_reader_with(path, commit_hook(path, new_snapshot, None))
  let assert Ok(read) =
    store.read(reader, fn(tx) { store.message(tx, message.id) })
  store.close_reader(reader)

  read |> should.equal(Some(snapshot_fixture.canonical(message)))

  // B really committed: a fresh reader sees it.
  read_message(path, message.id)
  |> should.equal(Some(snapshot_fixture.canonical(first_message(new_snapshot))))

  temp.remove_dir(dir)
}

/// The hook runs during the read, so the first test cannot pass vacuously.
pub fn hook_commits_during_the_read_test() {
  let old_snapshot = snapshot_fixture.full(account)
  let message = first_message(old_snapshot)
  let new_snapshot = rewritten(old_snapshot, message.id)
  let #(dir, path) = written(old_snapshot)
  let fired = process.new_subject()

  let assert Ok(reader) =
    store.open_reader_with(path, commit_hook(path, new_snapshot, Some(fired)))
  let assert Ok(_) =
    store.read(reader, fn(tx) { store.message(tx, message.id) })
  store.close_reader(reader)

  process.receive(fired, within: 0) |> should.equal(Ok(Nil))
  read_message(path, message.id)
  |> should.equal(Some(snapshot_fixture.canonical(first_message(new_snapshot))))

  temp.remove_dir(dir)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A hook that commits `snapshot` through a second_connection on every call,
/// asserting the write succeeds: WAL lets a writer commit while a reader holds
/// its snapshot. Rewriting the same snapshot is idempotent, so no counter is
/// needed. `fired`, if given, is told each time the hook runs.
fn commit_hook(
  path: String,
  snapshot: Snapshot,
  fired: Option(Subject(Nil)),
) -> fn() -> Nil {
  fn() {
    let assert Ok(second_connection) = store.open_writer(path)
    let assert Ok(Nil) = store.write_snapshot(second_connection, snapshot)
    store.close_writer(second_connection)
    case fired {
      Some(subject) -> process.send(subject, Nil)
      None -> Nil
    }
  }
}

/// A store holding `snapshot`, written through the real writer and closed.
fn written(snapshot: Snapshot) -> #(String, String) {
  let dir = temp.dir("screwtape-read-snapshot")
  let path = dir <> "/screwtape.db"
  let assert Ok(writer) = store.open_writer(path)
  let assert Ok(Nil) = store.write_snapshot(writer, snapshot)
  store.close_writer(writer)
  #(dir, path)
}

/// Message `id` as a plain reader returns it.
fn read_message(path: String, id: String) -> Option(Message) {
  let assert Ok(reader) = store.open_reader(path)
  let assert Ok(message) = store.read(reader, fn(tx) { store.message(tx, id) })
  store.close_reader(reader)
  message
}

fn first_message(snapshot: Snapshot) -> Message {
  let assert [message, ..] = snapshot.messages
  message
}

/// `snapshot` with message `id` changed in every part a read assembles from a
/// separate select. It keeps only mailboxes `snapshot` already holds, so the
/// foreign keys still hold.
fn rewritten(snapshot: Snapshot, id: String) -> Snapshot {
  let messages =
    list.map(snapshot.messages, fn(message) {
      case message.id == id {
        True -> changed(message)
        False -> message
      }
    })
  Snapshot(..snapshot, messages: messages)
}

fn changed(message: Message) -> Message {
  Message(
    ..message,
    subject: Some("Subject B"),
    preview: "Preview B",
    mailbox_ids: list.take(message.mailbox_ids, 1),
    addresses: [
      Address(From, Some("From B"), "from-b@example.test"),
      Address(To, None, "to-b@example.test"),
    ],
    bodies: [
      Body(
        part_id: "9",
        source: PlainText,
        text: "Body B",
        is_truncated: False,
        truncated_by: None,
        is_encoding_problem: False,
        conversion_failed: False,
        max_body_value_bytes: 1024,
      ),
    ],
    attachments: [
      Attachment(
        part_id: "8",
        blob_id: "blob-b",
        name: Some("b.txt"),
        type_: "text/plain",
        size: 3,
        disposition: None,
        cid: None,
      ),
    ],
  )
}
