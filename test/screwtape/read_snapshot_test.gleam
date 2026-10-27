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
//// BEGIN/COMMIT): `query.message` issues several selects (the message row,
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
////
//// PHASE-05 adds the same guard for `read --after`, whose stream selects a page
//// of message ids and then reads each message. B there either deletes a message
//// the page selected or re-dates it, so a stream split across two read
//// transactions would print A's selection with B's documents.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit/should
import screwtape/cli
import screwtape/model.{
  type Message, type Snapshot, Address, Attachment, Body, From, Message,
  PlainText, Snapshot, Thread, To, UtcDate,
}
import screwtape/store
import screwtape/store/query
import support/cli_fixture
import support/snapshot_fixture
import support/temp

const account = "acct-a"

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// O-F2: each read verb through the CLI still serves the old_snapshot when a
/// second_connection commits B during its read. These are regression guards:
/// they pass while each verb runs all its queries inside one `store.read`.
///
/// They would fail if a verb split its queries across two `store.read` calls:
/// the hook commits B after the first select of the first read, and the second
/// `store.read` begins a fresh transaction whose snapshot is B. The verb's
/// document would then mix A's first answer with B's later ones, differing
/// from `expected`. `list` issues several selects (`mailboxes` for --mailbox,
/// then `messages`), `read` assembles its relations from several selects, and
/// `thread` reads the entries then each summary, so a split is visible in all
/// three. `read --after` selects its page of ids and then reads each message:
/// split, it would print A's selection with B's documents, so a deletion or a
/// re-dating of a selected message shows.
pub fn cli_list_serves_one_snapshot_while_another_commits_test() {
  cli_read_verb_serves_one_snapshot(
    "cli-i8-list",
    ["list", "--mailbox", "acct-l-mb1"],
    rewritten(_, "acct-l-m1"),
  )
}

pub fn cli_read_serves_one_snapshot_while_another_commits_test() {
  cli_read_verb_serves_one_snapshot(
    "cli-i8-read",
    ["read", "acct-l-m1"],
    rewritten(_, "acct-l-m1"),
  )
}

pub fn cli_thread_serves_one_snapshot_while_another_commits_test() {
  cli_read_verb_serves_one_snapshot(
    "cli-i8-thread",
    ["thread", "acct-l-th1"],
    rewritten(_, "acct-l-m1"),
  )
}

/// C4 (PHASE-05): a `read --after` stream whose B deletes one of the messages
/// the page selected. A two-transaction stream selects `-m1` among the ids and
/// then reads it in a second `store.read`, which begins after B has committed:
/// `messages_of` would find `-m1` gone and fail `read_failed`, exiting non-zero
/// with no stdout. Inside one `store.read`, WAL serves A throughout and the stream
/// still prints all six lines.
pub fn cli_read_after_stream_serves_one_snapshot_when_a_message_is_deleted_test() {
  cli_read_verb_serves_one_snapshot(
    "cli-i8-read-after-deleted",
    ["read", "--after", "", "--max-bytes", "4096"],
    fn(snapshot) { without(snapshot, "acct-l-m1") },
  )
}

/// C4 (PHASE-05): the same walk with B re-dating a selected message instead.
/// A two-transaction stream selects `-m1`'s id at A's position and then reads
/// the message from B, so its line would carry B's `cursor` and `received_at`
/// (and B's place in the order), where A's line is what `read acct-l-m1` over A
/// prints.
pub fn cli_read_after_stream_serves_one_snapshot_when_a_message_is_redated_test() {
  cli_read_verb_serves_one_snapshot(
    "cli-i8-read-after-redated",
    ["read", "--after", "", "--max-bytes", "4096"],
    fn(snapshot) { redated(snapshot, "acct-l-m1") },
  )
}

/// Run `args` over snapshot A without a hook, then with one whose every select
/// commits B — `rewrite` of A — through a second_connection. The documented
/// answer is A's; a plain run after it proves B is now the store's committed
/// snapshot.
fn cli_read_verb_serves_one_snapshot(
  prefix: String,
  args: List(String),
  rewrite rewrite: fn(Snapshot) -> Snapshot,
) -> Nil {
  let old_snapshot = snapshot_fixture.listing()
  let new_snapshot = rewrite(old_snapshot)
  let setup = cli_fixture.seeded(prefix, old_snapshot)
  let argv = ["--config", setup.config_path, ..args]

  let expected = cli.run(argv, fn(_name) { Error(Nil) })
  let actual =
    cli.run_with(argv, fn(_name) { Error(Nil) }, fn(path) {
      store.open_reader_with(path, commit_hook(path, new_snapshot, None))
    })
  let afterwards = cli.run(argv, fn(_name) { Error(Nil) })
  temp.remove_dir(setup.dir)

  expected.exit_code |> should.equal(0)
  actual.exit_code |> should.equal(0)
  actual.stderr |> should.equal([])
  actual.stdout |> should.equal(expected.stdout)
  afterwards.exit_code |> should.equal(0)
  afterwards.stdout |> should.not_equal(expected.stdout)
}

pub fn read_serves_one_snapshot_while_another_commits_test() {
  let old_snapshot = snapshot_fixture.full(account)
  let message = first_message(old_snapshot)
  let new_snapshot = rewritten(old_snapshot, message.id)
  let #(dir, path) = written(old_snapshot)

  let assert Ok(reader) =
    store.open_reader_with(path, commit_hook(path, new_snapshot, None))
  let assert Ok(read) =
    store.read(reader, fn(tx) { query.message(tx, message.id) })
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
    store.read(reader, fn(tx) { query.message(tx, message.id) })
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
  let assert Ok(message) = store.read(reader, fn(tx) { query.message(tx, id) })
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

/// `snapshot` without message `id`. `write_snapshot` deletes every row of every
/// table before it inserts, so B's write drops the message row with its
/// addresses, bodies, attachments and mailbox memberships; its thread stops
/// naming it so B holds no reference the model would call dangling.
fn without(snapshot: Snapshot, id: String) -> Snapshot {
  Snapshot(
    ..snapshot,
    messages: list.filter(snapshot.messages, fn(message) { message.id != id }),
    threads: list.map(snapshot.threads, fn(thread) {
      Thread(thread.id, list.filter(thread.email_ids, fn(held) { held != id }))
    }),
  )
}

/// `snapshot` with message `id` re-dated a minute past the listing's newest
/// message, so its `(received_at_ms, id)` position — and so its cursor — is not
/// the one a stream over `snapshot` selected.
fn redated(snapshot: Snapshot, id: String) -> Snapshot {
  let received_at =
    UtcDate(
      raw: "2026-10-25T02:01:00Z",
      ms: snapshot_fixture.listing_midnight_ms + 7_260_000,
    )
  let messages =
    list.map(snapshot.messages, fn(message) {
      case message.id == id {
        True -> Message(..message, received_at: received_at)
        False -> message
      }
    })
  Snapshot(..snapshot, messages: messages)
}
