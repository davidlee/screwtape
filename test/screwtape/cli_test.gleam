//// Contract tests for `screwtape/cli`, the CLI edge (PHASE-10, D7; EX-4 /
//// VT-7).
////
//// `run` is pure of process effects — it returns the document, the stderr lines
//// and the exit code — so every case here is in-process except the two that
//// spawn the shipment's own `entrypoint.sh run`, which are VT-7's proof that the
//// argv, the exit code and the stderr line survive the real process edge.
////
//// The happy path drives one `local_jmap` over real TLS through the whole sync
//// — session, `Mailbox/get`, `Email/query`, `Email/get`, `Thread/get` — and
//// commits to a store under `temp`, with a config file and a credentials
//// directory written there too: no module is stubbed, so the run is the
//// production path end to end.
////
//// The config file, credentials directory and stderr-line helpers live in
//// `support/cli_fixture`, shared with the token-leak suite (PHASE-10, T5a).

import gleam/bit_array
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/cli
import screwtape/model
import screwtape/store
import support/cli_fixture
import support/jmap_fixture
import support/local_jmap
import support/snapshot_fixture
import support/store_dump
import support/subprocess
import support/temp

pub fn main() -> Nil {
  gleeunit.main()
}

/// The account `jmap_fixture` documents belong to.
const account_id = "acct-1"

/// The one warning a writable account earns, byte for byte.
const warning_line =
  "{\"level\":\"warning\",\"warning\":\"account_not_read_only\"}"

/// A session URL that parses as a config but is never contacted: these cases
/// fail before the first request.
const unused_session_url = "https://api.example.test/session"

// ---------------------------------------------------------------- helpers

/// An environment with nothing set, as a shell that is not the service has.
fn no_env(_name: String) -> Result(String, Nil) {
  Error(Nil)
}

/// An environment where `CREDENTIALS_DIRECTORY` is `dir` and nothing else is.
fn credentials_env(dir: String) {
  fn(name: String) -> Result(String, Nil) {
    case name == "CREDENTIALS_DIRECTORY" {
      True -> Ok(dir)
      False -> Error(Nil)
    }
  }
}

/// A fresh directory for the store a config names, and the path inside it.
fn store_dir(prefix: String) -> #(String, String) {
  let dir = temp.dir(prefix)
  #(dir, dir <> "/mail.sqlite3")
}

/// One failing outcome: nothing on stdout, exactly one stderr JSON line naming
/// `kind`, and the given exit code.
fn expect_failure(
  outcome: cli.Outcome,
  kind: String,
  exit_code: Int,
) -> String {
  outcome.exit_code |> should.equal(exit_code)
  outcome.stdout |> should.equal(None)
  outcome.stderr |> list.length |> should.equal(1)
  let assert [line] = outcome.stderr
  cli_fixture.error_kind(line) |> should.equal(Ok(kind))
  line
}

fn unwrap(result: Result(a, subprocess.Failure)) -> a {
  case result {
    Ok(value) -> value
    Error(failure) -> {
      let message = subprocess.failure_message(failure)
      panic as message
    }
  }
}

// ---------------------------------------------------------------- argv

/// D7: an argv that names no verb we serve is `Usage`, which exits 2 and says
/// nothing about the arguments it was given. (The read verbs' own argv rules
/// are pinned in `read_verb_usage_shapes_exit_two_test`.)
pub fn usage_shapes_exit_two_test() {
  let path = "/nonexistent/screwtape/config.json"
  let cases = [
    [],
    ["sync"],
    ["--config"],
    ["--config", path],
    ["--config", path, "frobnicate"],
    ["--config", path, "sync", "extra"],
    ["--bogus"],
  ]

  list.each(cases, fn(argv) {
    let line = expect_failure(cli.run(argv, no_env), "usage", 2)
    line |> string.contains(path) |> should.be_false
  })
}

// ---------------------------------------------------------------- config

pub fn unreadable_config_exits_two_test() {
  let missing = "/nonexistent/screwtape/config.json"
  let outcome = cli.run(["--config", missing, "sync"], no_env)

  let line = expect_failure(outcome, "config", 2)
  line |> string.contains("/nonexistent") |> should.be_false
  line
  |> string.contains("\"reason\":\"unreadable\"")
  |> should.be_true
}

pub fn invalid_config_exits_two_test() {
  let #(dir, path) =
    cli_fixture.config_dir("cli-bad-config", "{\"session_url\":")
  let outcome = cli.run(["--config", path, "sync"], no_env)
  temp.remove_dir(dir)

  let line = expect_failure(outcome, "config", 2)
  line |> string.contains("\"reason\":\"invalid_json\"") |> should.be_true
}

// ---------------------------------------------------------------- credential

/// VT-7 "CREDENTIALS_DIRECTORY": a valid config and no credentials directory
/// (a manual run from a shell) is a `Credential` failure, exit 1.
pub fn no_credentials_directory_exits_one_test() {
  let #(store, store_path) = store_dir("cli-no-cred-store")
  let #(dir, path) =
    cli_fixture.config_dir(
      "cli-no-cred-env",
      cli_fixture.config_text(unused_session_url, store_path, None),
    )
  let outcome = cli.run(["--config", path, "sync"], no_env)
  temp.remove_dir(dir)
  temp.remove_dir(store)

  let line = expect_failure(outcome, "credential", 1)
  line
  |> string.contains("\"reason\":\"no_credentials_directory\"")
  |> should.be_true
}

/// A credentials directory that does not hold the named file is the same
/// `Credential` failure, with the reason that names the file, not the path.
pub fn missing_credential_file_exits_one_test() {
  let credentials = temp.dir("cli-missing-credential")
  let #(store, store_path) = store_dir("cli-missing-cred-store")
  let #(dir, path) =
    cli_fixture.config_dir(
      "cli-missing-cred",
      cli_fixture.config_text(unused_session_url, store_path, None),
    )
  let outcome =
    cli.run(["--config", path, "sync"], credentials_env(credentials))
  temp.remove_dir(dir)
  temp.remove_dir(store)
  temp.remove_dir(credentials)

  let line = expect_failure(outcome, "credential", 1)
  line |> string.contains("\"reason\":\"missing\"") |> should.be_true
  line |> string.contains(credentials) |> should.be_false
}

// ---------------------------------------------------------------- sync

/// The whole sync in process: config → credential → budget → `Send` → session →
/// `Mailbox/get`, `Email/query`, `Email/get`, `Thread/get` → one committed
/// snapshot → one document on stdout, exit 0. A writable account earns exactly
/// one warning line; two messages in one mailbox across two threads are stored.
pub fn full_sync_test() {
  let server = local_jmap.start_with(cli_fixture.full_sync_script)
  let credentials = cli_fixture.credential_dir("SENTINEL-cli-0123456789")
  let #(store, store_path) = store_dir("cli-sync-store")
  let #(dir, path) =
    cli_fixture.config_dir(
      "cli-sync",
      cli_fixture.config_text(
        local_jmap.url(server, "/session"),
        store_path,
        Some(server.ca_path),
      ),
    )

  let outcome =
    cli.run(["--config", path, "sync"], credentials_env(credentials))
  let requests = local_jmap.request_count(server)
  local_jmap.stop(server)
  temp.remove_dir(dir)
  temp.remove_dir(credentials)

  outcome.exit_code |> should.equal(0)
  outcome.stderr |> should.equal([warning_line])
  let assert Some(document) = outcome.stdout
  let assert Ok(json_document) = json.parse(document, using: decode.dynamic)
  // The session, then one call of each of the four methods.
  requests |> should.equal(5)
  decode.run(json_document, decode.at(["version"], decode.int))
  |> should.equal(Ok(1))
  decode.run(json_document, decode.at(["kind"], decode.string))
  |> should.equal(Ok("sync"))
  decode.run(json_document, decode.at(["data", "account_id"], decode.string))
  |> should.equal(Ok(account_id))
  decode.run(json_document, decode.at(["data", "mailboxes"], decode.int))
  |> should.equal(Ok(1))
  decode.run(json_document, decode.at(["data", "messages"], decode.int))
  |> should.equal(Ok(2))
  decode.run(json_document, decode.at(["data", "threads"], decode.int))
  |> should.equal(Ok(2))
  decode.run(json_document, decode.at(["data", "not_found"], decode.int))
  |> should.equal(Ok(0))
  decode.run(json_document, decode.at(["data", "truncated_bodies"], decode.int))
  |> should.equal(Ok(0))
  decode.run(
    json_document,
    decode.at(["data", "conversion_failures"], decode.int),
  )
  |> should.equal(Ok(0))
  decode.run(json_document, decode.at(["data", "is_read_only"], decode.bool))
  |> should.equal(Ok(False))
  decode.run(
    json_document,
    decode.at(
      ["data", "states"],
      decode.map(decode.dict(decode.string, decode.string), dict.keys),
    ),
  )
  |> should.equal(Ok(["Email", "Mailbox", "Thread"]))
  decode.run(
    json_document,
    decode.at(["data", "states", "Mailbox"], decode.string),
  )
  |> should.equal(Ok("mb-state-1"))
  decode.run(
    json_document,
    decode.at(["data", "states", "Email"], decode.string),
  )
  |> should.equal(Ok("es-0"))
  decode.run(
    json_document,
    decode.at(["data", "states", "Thread"], decode.string),
  )
  |> should.equal(Ok("ts-0"))
  // A fresh store has no Prior, so the run is full and says why.
  decode.run(json_document, decode.at(["data", "mode"], decode.string))
  |> should.equal(Ok("full"))
  decode.run(
    json_document,
    decode.at(["data", "fallback_reason"], decode.optional(decode.string)),
  )
  |> should.equal(Ok(Some("no_state")))
  let assert Ok(synced_at) =
    decode.run(json_document, decode.at(["data", "synced_at"], decode.string))
  // A whole-second RFC 3339 instant, the run's own clock.
  synced_at |> string.ends_with("Z") |> should.be_true
  string.byte_size(synced_at) |> should.equal(20)
  document |> string.contains("SENTINEL-cli") |> should.be_false
  // The committed snapshot is the one the document reports.
  store_dump.dump(store_path) |> string.contains(account_id) |> should.be_true
  temp.remove_dir(store)
}

/// The same run over a read-only account: no warning at all, and the document
/// still says so.
pub fn read_only_account_has_no_warning_test() {
  let server =
    local_jmap.start_with(fn(base_url) {
      let assert [_, ..rest] = cli_fixture.full_sync_script(base_url)
      [
        local_jmap.reply(
          200,
          jmap_fixture.session_with(base_url <> "/api", 1000, True),
        ),
        ..rest
      ]
    })
  let credentials = cli_fixture.credential_dir("SENTINEL-cli-read-only")
  let #(store, store_path) = store_dir("cli-read-only-store")
  let #(dir, path) =
    cli_fixture.config_dir(
      "cli-read-only",
      cli_fixture.config_text(
        local_jmap.url(server, "/session"),
        store_path,
        Some(server.ca_path),
      ),
    )

  let outcome =
    cli.run(["--config", path, "sync"], credentials_env(credentials))
  local_jmap.stop(server)
  temp.remove_dir(dir)
  temp.remove_dir(credentials)
  temp.remove_dir(store)

  outcome.exit_code |> should.equal(0)
  outcome.stderr |> should.equal([])
  let assert Some(document) = outcome.stdout
  let assert Ok(json_document) = json.parse(document, using: decode.dynamic)
  decode.run(json_document, decode.at(["data", "is_read_only"], decode.bool))
  |> should.equal(Ok(True))
}

/// A window naming a mailbox the server does not have: the run reaches
/// `Mailbox/get`, then fails `Config("unknown_mailbox")` and exits 2.
pub fn unknown_mailbox_exits_two_test() {
  let server =
    local_jmap.start_with(fn(base_url) {
      let assert [session, mailbox, ..] = cli_fixture.full_sync_script(base_url)
      [session, mailbox]
    })
  let credentials = cli_fixture.credential_dir("SENTINEL-cli-unknown-mailbox")
  let #(store, store_path) = store_dir("cli-unknown-mailbox-store")
  let #(dir, path) =
    cli_fixture.config_dir(
      "cli-unknown-mailbox",
      cli_fixture.config_text_window(
        local_jmap.url(server, "/session"),
        store_path,
        Some(server.ca_path),
        ["Nope"],
      ),
    )

  let outcome =
    cli.run(["--config", path, "sync"], credentials_env(credentials))
  local_jmap.stop(server)
  temp.remove_dir(dir)
  temp.remove_dir(credentials)
  temp.remove_dir(store)

  let line = expect_failure(outcome, "config", 2)
  line
  |> string.contains("\"reason\":\"unknown_mailbox\"")
  |> should.be_true
}

/// I2 at the session: a run whose session fetch fails writes nothing, so the
/// seeded store — schema, rows and `user_version` — is byte-for-byte as it was.
pub fn failed_session_leaves_store_unchanged_test() {
  let #(store, store_path) = store_dir("cli-i2-store")
  let assert Ok(writer) = store.open_writer(store_path)
  let assert Ok(Nil) =
    store.write_snapshot(writer, snapshot_fixture.full("acct-old"))
  store.close_writer(writer)
  let before = store_dump.dump(store_path)

  let server =
    local_jmap.start_with(fn(_base_url) { [local_jmap.reply(500, "")] })
  let credentials = cli_fixture.credential_dir("SENTINEL-cli-i2")
  let #(dir, path) =
    cli_fixture.config_dir(
      "cli-i2",
      cli_fixture.config_text(
        local_jmap.url(server, "/session"),
        store_path,
        Some(server.ca_path),
      ),
    )

  let outcome =
    cli.run(["--config", path, "sync"], credentials_env(credentials))
  local_jmap.stop(server)
  temp.remove_dir(dir)
  temp.remove_dir(credentials)

  let line = expect_failure(outcome, "http", 1)
  line |> string.contains("\"reason\":\"status_500\"") |> should.be_true
  before |> string.contains("user_version=") |> should.be_true
  before |> string.contains("acct-old") |> should.be_true
  store_dump.dump(store_path) |> should.equal(before)
  temp.remove_dir(store)
}

// ---------------------------------------------------------------- sync, again

/// A second sync over the store the first committed: the Prior is read, so the
/// run goes incrementally — the opening request, `Email/changes` from the
/// stored state and `Thread/get` over the kept threads. With nothing changed
/// no `Email/query` and no `Email/get` of ids run, and the document says so.
pub fn second_sync_is_incremental_test() {
  let server =
    local_jmap.start_with(fn(base_url) {
      list.append(
        cli_fixture.full_sync_script(base_url),
        cli_fixture.incremental_sync_script(base_url),
      )
    })
  let credentials = cli_fixture.credential_dir("SENTINEL-cli-incremental")
  let #(store, store_path) = store_dir("cli-incremental-store")
  let #(dir, path) =
    cli_fixture.config_dir(
      "cli-incremental",
      cli_fixture.config_text(
        local_jmap.url(server, "/session"),
        store_path,
        Some(server.ca_path),
      ),
    )

  let first = cli.run(["--config", path, "sync"], credentials_env(credentials))
  let second = cli.run(["--config", path, "sync"], credentials_env(credentials))
  let requests = local_jmap.request_count(server)
  local_jmap.stop(server)
  temp.remove_dir(dir)
  temp.remove_dir(credentials)
  temp.remove_dir(store)

  first.exit_code |> should.equal(0)
  second.exit_code |> should.equal(0)
  second.stderr |> should.equal([warning_line])
  // The first run's five requests, then the second's four: session, opening,
  // `Email/changes` and the one `Thread/get`. A full second run would be five.
  requests |> should.equal(9)
  let document = cli_fixture.stdout_json(second)
  cli_fixture.field(document, ["data", "mode"], decode.string)
  |> should.equal(Ok("incremental"))
  cli_fixture.field(
    document,
    ["data", "fallback_reason"],
    decode.optional(decode.string),
  )
  |> should.equal(Ok(None))
  cli_fixture.field(document, ["data", "messages"], decode.int)
  |> should.equal(Ok(2))
}

/// EX-1 / A1: a store read error other than `no_snapshot` — here a store one
/// schema version newer — fails the run as the store error it is, before any
/// credential, session or writer. With no credentials directory either, a run
/// that read the credential first would fail as a credential error instead.
pub fn sync_fails_on_a_store_read_error_with_zero_requests_test() {
  let server = local_jmap.start_with(fn(_base_url) { [] })
  let #(store, store_path) = store_dir("cli-read-error-store")
  let assert Ok(writer) = store.open_writer(store_path)
  let assert Ok(Nil) =
    store.write_snapshot(writer, snapshot_fixture.full("acct-prior"))
  store.close_writer(writer)
  store_dump.set_user_version(store_path, store.supported_version() + 1)
  let #(dir, path) =
    cli_fixture.config_dir(
      "cli-read-error",
      cli_fixture.config_text(
        local_jmap.url(server, "/session"),
        store_path,
        Some(server.ca_path),
      ),
    )

  let outcome = cli.run(["--config", path, "sync"], no_env)
  let requests = local_jmap.request_count(server)
  local_jmap.stop(server)
  temp.remove_dir(dir)
  temp.remove_dir(store)

  let line = expect_failure(outcome, "store", 1)
  line
  |> string.contains("\"reason\":\"schema_mismatch\"")
  |> should.be_true
  requests |> should.equal(0)
}

// ---------------------------------------------------------------- shipment

/// VT-7 through the real process edge: a `sync` with no `CREDENTIALS_DIRECTORY`
/// exits 1 with exactly one JSON line, and nothing on stdout. The variable is
/// removed from the child's environment (`None` in `run_env`) even
/// though this suite may have it set.
pub fn shipment_sync_without_credentials_exits_one_test() {
  let shipment = unwrap(subprocess.shipment_dir())
  let #(store, store_path) = store_dir("cli-run-no-cred-store")
  let #(dir, path) =
    cli_fixture.config_dir(
      "cli-run-no-cred-env",
      cli_fixture.config_text(unused_session_url, store_path, None),
    )
  let record =
    unwrap(
      subprocess.run_env(
        subprocess.entrypoint(shipment),
        ["run", "--config", path, "sync"],
        [#("CREDENTIALS_DIRECTORY", None)],
      ),
    )
  temp.remove_dir(dir)
  temp.remove_dir(store)

  record.exit_code |> should.equal(1)
  record.stdout |> should.equal(<<>>)
  record.stderr
  |> should.equal(
    "{\"level\":\"error\",\"error\":\"credential\","
    <> "\"reason\":\"no_credentials_directory\"}\n",
  )
}

/// The same edge for the argv rule: a verb we do not serve is a usage error, so
/// the process exits 2 before it reads anything.
pub fn shipment_unknown_verb_exits_two_test() {
  let shipment = unwrap(subprocess.shipment_dir())
  let record =
    unwrap(subprocess.run(subprocess.entrypoint(shipment), ["run", "nonsense"]))

  record.exit_code |> should.equal(2)
  record.stdout |> should.equal(<<>>)
  record.stderr
  |> string.starts_with("{\"level\":\"error\",\"error\":\"usage\"")
  |> should.be_true
}

// ---------------------------------------------------------------- read verbs
//
// PHASE-06 EX-1 / EX-3 / VT-2: `mailboxes`, `list`, `read` and `thread` over a
// store seeded by the real writer. They need no credential and no network, so
// every case runs with `no_env`. Each document is decoded and its shape pinned
// (D7); `list` is newest first (D5), and an unknown message or thread id is a
// usage error (D6).

/// The `listing` messages, newest first (D5: `received_at_ms DESC, id DESC`).
const newest_first = [
  "acct-l-m6", "acct-l-m5", "acct-l-m4", "acct-l-m3", "acct-l-m1", "acct-l-m2",
]

/// The keys of a `list` item (design § 5.2's example item, field for field).
const summary_keys = [
  "from", "has_attachment", "id", "is_flagged", "is_seen", "mailbox_ids",
  "preview", "received_at", "subject", "thread_id",
]

/// Run a read verb against `setup`'s config, with no environment at all.
fn read_verb(setup: cli_fixture.ReadSetup, args: List(String)) -> cli.Outcome {
  cli.run(["--config", setup.config_path, ..args], no_env)
}

/// A successful outcome: exit 0, nothing on stderr, and a version-1 envelope of
/// `kind`; returns the decoded document.
fn expect_document(outcome: cli.Outcome, kind: String) -> dynamic.Dynamic {
  outcome.exit_code |> should.equal(0)
  outcome.stderr |> should.equal([])
  let document = cli_fixture.stdout_json(outcome)
  cli_fixture.keys(document, [])
  |> should.equal(Ok(["data", "kind", "version"]))
  cli_fixture.field(document, ["version"], decode.int) |> should.equal(Ok(1))
  cli_fixture.field(document, ["kind"], decode.string) |> should.equal(Ok(kind))
  document
}

/// `list` over the `listing` snapshot with `args`: the item ids, in order.
fn listed(args: List(String)) -> List(String) {
  let setup = cli_fixture.seeded("cli-list", snapshot_fixture.listing())
  let outcome = read_verb(setup, ["list", ..args])
  temp.remove_dir(setup.dir)
  let assert Ok(ids) = cli_fixture.item_ids(expect_document(outcome, "list"))
    as string.inspect(#(args, outcome))
  ids
}

fn listing_ids(suffixes: List(String)) -> List(String) {
  list.map(suffixes, fn(suffix) { "acct-l-" <> suffix })
}

/// The `{name, email}` objects of an address list at `path`.
fn addresses_at(
  document: dynamic.Dynamic,
  path: List(String),
) -> Result(List(#(option.Option(String), String)), Nil) {
  cli_fixture.field(
    document,
    path,
    decode.list({
      use name <- decode.field("name", decode.optional(decode.string))
      use email <- decode.field("email", decode.string)
      decode.success(#(name, email))
    }),
  )
}

// ---------------------------------------------------------------- read argv

/// A5, A2, A4, D6: every malformed read-verb argv is `Usage`, exit 2, one
/// stderr line, nothing on stdout. The config and store are valid, so no other
/// failure can stand in for the usage error. Reason codes are pinned only where
/// the phase sheet names them.
pub fn read_verb_usage_shapes_exit_two_test() {
  let setup = cli_fixture.seeded("cli-read-usage", snapshot_fixture.listing())
  let cases = [
    // --limit outside 1..500, or not a non-negative integer.
    ["list", "--limit", "0"],
    ["list", "--limit", "501"],
    ["list", "--limit", "-1"],
    ["list", "--limit", "ten"],
    ["list", "--limit", "1.5"],
    // --offset negative or not an integer.
    ["list", "--offset", "-1"],
    ["list", "--offset", "x"],
    ["list", "--offset", "2.0"],
    // A repeated flag, valued or not.
    ["list", "--limit", "5", "--limit", "6"],
    ["list", "--unread", "--unread"],
    ["list", "--since", "2026-10-25", "--since", "2026-10-26"],
    // An unknown flag, a missing value, an extra positional.
    ["list", "--bogus"],
    ["list", "--limit"],
    ["list", "--mailbox"],
    ["list", "--from"],
    ["list", "--since"],
    ["list", "--offset"],
    ["list", "extra"],
    ["mailboxes", "extra"],
    ["mailboxes", "--unread"],
    // `read`: a missing id, a bad or missing --max-bytes, an extra positional.
    ["read"],
    ["read", "acct-l-m1", "--max-bytes", "-1"],
    ["read", "acct-l-m1", "--max-bytes", "lots"],
    ["read", "acct-l-m1", "--max-bytes"],
    ["read", "acct-l-m1", "--max-bytes", "5", "--max-bytes", "6"],
    ["read", "acct-l-m1", "extra"],
    ["read", "acct-l-m1", "--unread"],
    // `thread`: a missing id, an extra positional, a bad, missing or repeated
    // --limit.
    ["thread"],
    ["thread", "acct-l-th1", "extra"],
    ["thread", "acct-l-th1", "--limit", "0"],
    ["thread", "acct-l-th1", "--limit", "501"],
    ["thread", "acct-l-th1", "--limit", "ten"],
    ["thread", "acct-l-th1", "--limit"],
    ["thread", "acct-l-th1", "--limit", "5", "--limit", "6"],
  ]

  let outcomes = list.map(cases, fn(args) { #(args, read_verb(setup, args)) })
  temp.remove_dir(setup.dir)

  list.each(outcomes, fn(pair) {
    let #(args, outcome) = pair
    // The argv in the assertion message names the failing case.
    #(args, outcome.exit_code) |> should.equal(#(args, 2))
    #(args, outcome.stdout) |> should.equal(#(args, None))
    let assert [line] = outcome.stderr as string.inspect(args)
    #(args, cli_fixture.error_kind(line)) |> should.equal(#(args, Ok("usage")))
  })
}

/// The usage reasons the phase sheet names: a malformed `--since` (A2), an
/// unknown `--mailbox` (A4), and an unknown message or thread id (D6).
pub fn read_verb_named_usage_reasons_test() {
  let setup = cli_fixture.seeded("cli-read-reasons", snapshot_fixture.listing())
  let cases = [
    #(["list", "--since", "2026-13-01"], "invalid_since"),
    #(["list", "--since", "2026/10/25"], "invalid_since"),
    #(["list", "--since", "2026-10-25T00:00:00Z"], "invalid_since"),
    #(["list", "--since", "yesterday"], "invalid_since"),
    #(["list", "--from", ""], "invalid_from"),
    #(["list", "--mailbox", "Nope"], "unknown_mailbox"),
    #(["read", "acct-l-nope"], "unknown_message"),
    #(["thread", "acct-l-nope"], "unknown_thread"),
  ]

  let outcomes =
    list.map(cases, fn(case_) { #(case_, read_verb(setup, case_.0)) })
  temp.remove_dir(setup.dir)

  list.each(outcomes, fn(pair) {
    let #(#(args, reason), outcome) = pair
    #(args, outcome.exit_code) |> should.equal(#(args, 2))
    #(args, outcome.stdout) |> should.equal(#(args, None))
    #(args, outcome.stderr)
    |> should.equal(
      #(args, [
        "{\"level\":\"error\",\"error\":\"usage\",\"reason\":\""
        <> reason
        <> "\"}",
      ]),
    )
  })
}

/// EX-2 (PHASE-02): a bad, missing or repeated `thread --limit` is the same
/// usage error, reason included, that `list --limit` gives.
pub fn thread_limit_usage_matches_list_limit_test() {
  let setup = cli_fixture.seeded("cli-limit-parity", snapshot_fixture.listing())
  let tails = [["0"], ["501"], ["ten"], [], ["5", "--limit", "6"]]
  let outcomes =
    list.map(tails, fn(tail) {
      #(
        tail,
        read_verb(setup, ["thread", "acct-l-th1", "--limit", ..tail]),
        read_verb(setup, ["list", "--limit", ..tail]),
      )
    })
  temp.remove_dir(setup.dir)

  list.each(outcomes, fn(triple) {
    let #(tail, thread, listed) = triple
    #(tail, thread.exit_code) |> should.equal(#(tail, 2))
    #(tail, thread.stderr) |> should.equal(#(tail, listed.stderr))
  })
}

// ---------------------------------------------------------------- mailboxes

/// A8 / D7: every mailbox, by `sort_order`, then `name`, then `id`, each with
/// exactly the seven fields, a `null` for an unset option.
pub fn mailboxes_lists_every_mailbox_in_store_order_test() {
  let setup =
    cli_fixture.seeded("cli-mailboxes", snapshot_fixture.full("acct-a"))
  let outcome = read_verb(setup, ["mailboxes"])
  temp.remove_dir(setup.dir)

  let document = expect_document(outcome, "mailboxes")
  cli_fixture.keys(document, ["data"]) |> should.equal(Ok(["items"]))
  cli_fixture.item_ids(document)
  |> should.equal(
    Ok(["acct-a-mb1", "acct-a-mb3", "acct-a-mb4", "acct-a-mb0", "acct-a-mb2"]),
  )
  let assert Ok([inbox, zeta, ..]) =
    cli_fixture.field(document, ["data", "items"], decode.list(decode.dynamic))
  cli_fixture.keys(inbox, [])
  |> should.equal(
    Ok([
      "id", "name", "parent_id", "role", "sort_order", "total_emails",
      "unread_emails",
    ]),
  )
  cli_fixture.field(inbox, ["name"], decode.string)
  |> should.equal(Ok("Inbox acct-a"))
  cli_fixture.field(inbox, ["parent_id"], decode.optional(decode.string))
  |> should.equal(Ok(Some("acct-a-mb-root")))
  cli_fixture.field(inbox, ["role"], decode.optional(decode.string))
  |> should.equal(Ok(Some("inbox")))
  cli_fixture.field(inbox, ["sort_order"], decode.int) |> should.equal(Ok(1))
  cli_fixture.field(inbox, ["total_emails"], decode.int) |> should.equal(Ok(11))
  cli_fixture.field(inbox, ["unread_emails"], decode.int) |> should.equal(Ok(1))
  cli_fixture.field(zeta, ["role"], decode.optional(decode.string))
  |> should.equal(Ok(None))
  cli_fixture.field(zeta, ["parent_id"], decode.optional(decode.string))
  |> should.equal(Ok(None))
}

// ---------------------------------------------------------------- list

/// D5 / D7: with no flags, `list` echoes `offset` 0 and `limit` 50 and prints
/// every message newest first, the id breaking a millisecond tie; each item has
/// exactly the summary's fields.
pub fn list_default_is_newest_first_with_default_paging_test() {
  let setup = cli_fixture.seeded("cli-list-default", snapshot_fixture.listing())
  let outcome = read_verb(setup, ["list"])
  temp.remove_dir(setup.dir)

  let document = expect_document(outcome, "list")
  cli_fixture.keys(document, ["data"])
  |> should.equal(Ok(["items", "limit", "offset"]))
  cli_fixture.field(document, ["data", "offset"], decode.int)
  |> should.equal(Ok(0))
  cli_fixture.field(document, ["data", "limit"], decode.int)
  |> should.equal(Ok(50))
  cli_fixture.item_ids(document) |> should.equal(Ok(newest_first))

  // `m1`, the fifth item: two `from` addresses, an attachment, unseen.
  let assert Ok([_, _, _, _, m1, _]) =
    cli_fixture.field(document, ["data", "items"], decode.list(decode.dynamic))
  cli_fixture.keys(m1, []) |> should.equal(Ok(summary_keys))
  cli_fixture.field(m1, ["thread_id"], decode.string)
  |> should.equal(Ok("acct-l-th1"))
  cli_fixture.field(m1, ["received_at"], decode.string)
  |> should.equal(Ok("2026-10-25T00:00:00Z"))
  cli_fixture.field(m1, ["subject"], decode.optional(decode.string))
  |> should.equal(Ok(Some("Subject m1")))
  cli_fixture.field(m1, ["preview"], decode.string)
  |> should.equal(Ok("Preview m1"))
  addresses_at(m1, ["from"])
  |> should.equal(
    Ok([
      #(Some("Acme Billing"), "billing@acme.test"),
      #(Some("ACME Support"), "support@acme.test"),
    ]),
  )
  cli_fixture.field(m1, ["is_seen"], decode.bool) |> should.equal(Ok(False))
  cli_fixture.field(m1, ["is_flagged"], decode.bool) |> should.equal(Ok(False))
  cli_fixture.field(m1, ["has_attachment"], decode.bool)
  |> should.equal(Ok(True))
  cli_fixture.field(m1, ["mailbox_ids"], decode.list(decode.string))
  |> should.equal(Ok(["acct-l-mb1"]))
}

/// A4: `--mailbox` matches an id, then a role, then an exact name.
pub fn list_mailbox_by_id_role_or_name_test() {
  listed(["--mailbox", "acct-l-mb1"])
  |> should.equal(listing_ids(["m5", "m3", "m1", "m2"]))
  listed(["--mailbox", "inbox"])
  |> should.equal(listing_ids(["m5", "m3", "m1", "m2"]))
  listed(["--mailbox", "sent"]) |> should.equal(listing_ids(["m6"]))
  listed(["--mailbox", "Archive acct-l"])
  |> should.equal(listing_ids(["m4", "m3"]))
}

/// A2: `--since` is midnight UTC, inclusive: the message received exactly at
/// midnight and the one half a second after it are in, the one a millisecond
/// before it is out.
pub fn list_since_includes_the_midnight_boundary_test() {
  listed(["--since", "2026-10-25"])
  |> should.equal(listing_ids(["m6", "m5", "m4", "m3", "m1"]))
  listed(["--since", "2026-10-24"]) |> should.equal(newest_first)
  listed(["--since", "2026-10-26"]) |> should.equal([])
}

/// A2: `--since` rejects a day the calendar does not have, including 29
/// February in a non-leap year, and accepts the real leap day.
pub fn list_since_validates_the_calendar_test() {
  let setup =
    cli_fixture.seeded("cli-list-calendar", snapshot_fixture.listing())
  let invalid =
    list.map(["2026-02-30", "2026-02-29"], fn(date) {
      #(date, read_verb(setup, ["list", "--since", date]))
    })
  let valid = read_verb(setup, ["list", "--since", "2024-02-29"])
  temp.remove_dir(setup.dir)

  list.each(invalid, fn(pair) {
    let #(date, outcome) = pair
    #(date, outcome.exit_code) |> should.equal(#(date, 2))
    #(date, outcome.stdout) |> should.equal(#(date, None))
    #(date, outcome.stderr)
    |> should.equal(
      #(date, [
        "{\"level\":\"error\",\"error\":\"usage\",\"reason\":\"invalid_since\"}",
      ]),
    )
  })

  let document = expect_document(valid, "list")
  cli_fixture.item_ids(document) |> should.equal(Ok(newest_first))
}

/// A3: `--from` is a case-insensitive substring of a `from` address's email or
/// name — never a `To` or `Cc` — and `%` and `_` are literal.
pub fn list_from_matches_from_addresses_only_test() {
  listed(["--from", "ACME"]) |> should.equal(listing_ids(["m1"]))
  listed(["--from", "tie break"]) |> should.equal(listing_ids(["m5"]))
  listed(["--from", "%"]) |> should.equal(listing_ids(["m6"]))
  listed(["--from", "_"]) |> should.equal(listing_ids(["m6"]))
  listed(["--from", "nobody-at-all"]) |> should.equal([])
}

/// `--unread` keeps only the messages not seen.
pub fn list_unread_keeps_unseen_messages_test() {
  listed(["--unread"]) |> should.equal(listing_ids(["m6", "m5", "m1", "m2"]))
}

/// A5: `--limit` 1 and 500 are accepted and echoed, `--offset` skips from the
/// newest, an offset past the end is an empty page, and the flags combine with
/// AND in any order.
pub fn list_limit_offset_and_flag_order_test() {
  let setup = cli_fixture.seeded("cli-list-paging", snapshot_fixture.listing())
  let one = read_verb(setup, ["list", "--limit", "1"])
  let all = read_verb(setup, ["list", "--limit", "500"])
  let page = read_verb(setup, ["list", "--offset", "1", "--limit", "2"])
  let past = read_verb(setup, ["list", "--offset", "6"])
  let combined =
    read_verb(setup, [
      "list", "--unread", "--since", "2026-10-25", "--mailbox", "inbox",
    ])
  let reordered =
    read_verb(setup, [
      "list", "--mailbox", "inbox", "--unread", "--since", "2026-10-25",
    ])
  temp.remove_dir(setup.dir)

  let one = expect_document(one, "list")
  cli_fixture.field(one, ["data", "limit"], decode.int) |> should.equal(Ok(1))
  cli_fixture.item_ids(one) |> should.equal(Ok(listing_ids(["m6"])))

  let all = expect_document(all, "list")
  cli_fixture.field(all, ["data", "limit"], decode.int) |> should.equal(Ok(500))
  cli_fixture.item_ids(all) |> should.equal(Ok(newest_first))

  let page = expect_document(page, "list")
  cli_fixture.field(page, ["data", "offset"], decode.int) |> should.equal(Ok(1))
  cli_fixture.field(page, ["data", "limit"], decode.int) |> should.equal(Ok(2))
  cli_fixture.item_ids(page) |> should.equal(Ok(listing_ids(["m5", "m4"])))

  let past = expect_document(past, "list")
  cli_fixture.field(past, ["data", "offset"], decode.int) |> should.equal(Ok(6))
  cli_fixture.item_ids(past) |> should.equal(Ok([]))

  let combined = expect_document(combined, "list")
  cli_fixture.item_ids(combined) |> should.equal(Ok(listing_ids(["m5", "m1"])))
  cli_fixture.item_ids(expect_document(reordered, "list"))
  |> should.equal(Ok(listing_ids(["m5", "m1"])))
}

/// P-1 / O-F1: the largest `i64` is a legal offset (past the end, so an empty
/// page); one more is not an integer this store can bind and is a `Usage`.
pub fn list_offset_bounds_test() {
  let setup = cli_fixture.seeded("cli-list-offset", snapshot_fixture.listing())
  let too_large = read_verb(setup, ["list", "--offset", "9223372036854775808"])
  let largest = read_verb(setup, ["list", "--offset", "9223372036854775807"])
  temp.remove_dir(setup.dir)

  expect_failure(too_large, "usage", 2)

  let document = expect_document(largest, "list")
  cli_fixture.field(document, ["data", "offset"], decode.int)
  |> should.equal(Ok(9_223_372_036_854_775_807))
  cli_fixture.item_ids(document) |> should.equal(Ok([]))
}

// ---------------------------------------------------------------- read

/// The keys of a `read` document's `data` (D7): the summary's, the rest of the
/// message, `provenance` and `output_truncated` — and not the message's
/// `blob_id` or any body's `max_body_value_bytes`.
const read_keys = [
  "attachments", "bcc", "bodies", "cc", "from", "has_attachment", "id",
  "in_reply_to", "is_flagged", "is_seen", "keywords", "mailbox_ids",
  "message_id", "output_truncated", "preview", "provenance", "received_at",
  "references", "reply_to", "sender", "sent_at", "size", "subject", "thread_id",
  "to",
]

/// One body's text, `source_type` and `truncated_by`, in body order.
fn bodies_of(
  document: dynamic.Dynamic,
) -> Result(List(#(String, String, String, option.Option(String))), Nil) {
  cli_fixture.field(
    document,
    ["data", "bodies"],
    decode.list({
      use part_id <- decode.field("part_id", decode.string)
      use source_type <- decode.field("source_type", decode.string)
      use text <- decode.field("text", decode.string)
      use truncated_by <- decode.field(
        "truncated_by",
        decode.optional(decode.string),
      )
      decode.success(#(part_id, source_type, text, truncated_by))
    }),
  )
}

/// EX-1 / D7: `read` of a known id prints the whole message: its summary
/// fields, headers in canonical order, header-id lists, bodies, attachments by
/// `part_id`, and provenance; without `--max-bytes` nothing is cut.
pub fn read_prints_the_whole_message_test() {
  let setup = cli_fixture.seeded("cli-read", snapshot_fixture.full("acct-a"))
  let outcome = read_verb(setup, ["read", "acct-a-m1"])
  temp.remove_dir(setup.dir)

  let document = expect_document(outcome, "read")
  cli_fixture.keys(document, ["data"]) |> should.equal(Ok(read_keys))
  cli_fixture.field(document, ["data", "id"], decode.string)
  |> should.equal(Ok("acct-a-m1"))
  cli_fixture.field(document, ["data", "received_at"], decode.string)
  |> should.equal(Ok("2026-10-26T10:15:30Z"))
  cli_fixture.field(
    document,
    ["data", "sent_at"],
    decode.optional(decode.string),
  )
  |> should.equal(Ok(Some("2026-10-26T10:15:00+00:00")))
  cli_fixture.field(document, ["data", "size"], decode.int)
  |> should.equal(Ok(4096))
  cli_fixture.field(document, ["data", "keywords"], decode.list(decode.string))
  |> should.equal(Ok(["$seen", "acct-a-kw1"]))
  cli_fixture.field(
    document,
    ["data", "mailbox_ids"],
    decode.list(decode.string),
  )
  |> should.equal(Ok(["acct-a-mb0", "acct-a-mb1", "acct-a-mb2"]))
  addresses_at(document, ["data", "from"])
  |> should.equal(Ok([#(Some("Sender acct-a"), "acct-a-from@example.test")]))
  addresses_at(document, ["data", "to"])
  |> should.equal(
    Ok([
      #(Some("To One acct-a"), "acct-a-to1@example.test"),
      #(None, "acct-a-to2@example.test"),
    ]),
  )
  addresses_at(document, ["data", "sender"]) |> should.equal(Ok([]))
  addresses_at(document, ["data", "bcc"])
  |> should.equal(Ok([#(None, "acct-a-bcc@example.test")]))
  cli_fixture.field(
    document,
    ["data", "references"],
    decode.list(decode.string),
  )
  |> should.equal(
    Ok(["acct-a-mid0@example.test", "acct-a-mid-root@example.test"]),
  )
  cli_fixture.field(
    document,
    ["data", "message_id"],
    decode.list(decode.string),
  )
  |> should.equal(Ok(["acct-a-mid1@example.test"]))
  bodies_of(document)
  |> should.equal(
    Ok([
      #("1", "text", "Plain body acct-a", Some("server")),
      #("2", "html", "<p>Html body acct-a</p>", None),
    ]),
  )
  let assert Ok([plain, _]) =
    cli_fixture.field(document, ["data", "bodies"], decode.list(decode.dynamic))
  cli_fixture.keys(plain, [])
  |> should.equal(
    Ok([
      "conversion_failed", "is_encoding_problem", "is_truncated", "part_id",
      "source_type", "text", "truncated_by",
    ]),
  )
  cli_fixture.field(
    document,
    ["data", "attachments"],
    decode.list(decode.at(["part_id"], decode.string)),
  )
  |> should.equal(Ok(["3", "5"]))
  let assert Ok([pdf, _]) =
    cli_fixture.field(
      document,
      ["data", "attachments"],
      decode.list(decode.dynamic),
    )
  cli_fixture.keys(pdf, [])
  |> should.equal(
    Ok(["blob_id", "cid", "disposition", "name", "part_id", "size", "type"]),
  )
  cli_fixture.field(pdf, ["type"], decode.string)
  |> should.equal(Ok("application/pdf"))
  cli_fixture.keys(document, ["data", "provenance"])
  |> should.equal(Ok(["account_id", "email_state"]))
  cli_fixture.field(
    document,
    ["data", "provenance", "account_id"],
    decode.string,
  )
  |> should.equal(Ok("acct-a"))
  cli_fixture.field(
    document,
    ["data", "provenance", "email_state"],
    decode.string,
  )
  |> should.equal(Ok("state-acct-a-email-1"))
  cli_fixture.field(document, ["data", "output_truncated"], decode.bool)
  |> should.equal(Ok(False))
}

/// D7: unset options print as `null`, not omitted.
pub fn read_prints_unset_options_as_null_test() {
  let setup =
    cli_fixture.seeded("cli-read-null", snapshot_fixture.full("acct-a"))
  let outcome = read_verb(setup, ["read", "acct-a-m2"])
  temp.remove_dir(setup.dir)

  let document = expect_document(outcome, "read")
  cli_fixture.keys(document, ["data"]) |> should.equal(Ok(read_keys))
  cli_fixture.field(
    document,
    ["data", "subject"],
    decode.optional(decode.string),
  )
  |> should.equal(Ok(None))
  cli_fixture.field(
    document,
    ["data", "sent_at"],
    decode.optional(decode.string),
  )
  |> should.equal(Ok(None))
  bodies_of(document)
  |> should.equal(
    Ok([#("1", "text", "Second body acct-a", Some("message_limit"))]),
  )
}

/// A6 / D7: `--max-bytes` is one budget over the bodies in order. Cutting any
/// text sets `output_truncated`; a budget that covers every body cuts nothing.
pub fn read_max_bytes_sets_output_truncated_test() {
  let setup =
    cli_fixture.seeded("cli-read-max", snapshot_fixture.full("acct-a"))
  let cut = read_verb(setup, ["read", "acct-a-m1", "--max-bytes", "10"])
  let none = read_verb(setup, ["read", "acct-a-m1", "--max-bytes", "0"])
  let ample = read_verb(setup, ["read", "acct-a-m1", "--max-bytes", "4096"])
  temp.remove_dir(setup.dir)

  let cut = expect_document(cut, "read")
  cli_fixture.field(cut, ["data", "output_truncated"], decode.bool)
  |> should.equal(Ok(True))
  // The stored flags are kept; `output_truncated` is the only mark of the cut.
  bodies_of(cut)
  |> should.equal(
    Ok([#("1", "text", "Plain body", Some("server")), #("2", "html", "", None)]),
  )

  let none = expect_document(none, "read")
  cli_fixture.field(none, ["data", "output_truncated"], decode.bool)
  |> should.equal(Ok(True))
  bodies_of(none)
  |> should.equal(
    Ok([#("1", "text", "", Some("server")), #("2", "html", "", None)]),
  )

  let ample = expect_document(ample, "read")
  cli_fixture.field(ample, ["data", "output_truncated"], decode.bool)
  |> should.equal(Ok(False))
  bodies_of(ample)
  |> should.equal(
    Ok([
      #("1", "text", "Plain body acct-a", Some("server")),
      #("2", "html", "<p>Html body acct-a</p>", None),
    ]),
  )
}

// ---------------------------------------------------------------- thread

/// A7 / D7: `thread` lists the thread's ids in position order: a message the
/// store holds is its summary with `in_store: true`; one outside the window is
/// only `{id, in_store: false}`.
pub fn thread_marks_in_store_entries_test() {
  let setup = cli_fixture.seeded("cli-thread", snapshot_fixture.listing())
  let outcome = read_verb(setup, ["thread", "acct-l-th1"])
  temp.remove_dir(setup.dir)

  let document = expect_document(outcome, "thread")
  cli_fixture.keys(document, ["data"])
  |> should.equal(Ok(["id", "items", "total", "truncated"]))
  cli_fixture.field(document, ["data", "id"], decode.string)
  |> should.equal(Ok("acct-l-th1"))
  cli_fixture.field(document, ["data", "total"], decode.int)
  |> should.equal(Ok(4))
  cli_fixture.field(document, ["data", "truncated"], decode.bool)
  |> should.equal(Ok(False))
  cli_fixture.item_ids(document)
  |> should.equal(Ok(listing_ids(["m5", "m3", "m0", "m1"])))
  cli_fixture.field(
    document,
    ["data", "items"],
    decode.list(decode.at(["in_store"], decode.bool)),
  )
  |> should.equal(Ok([True, True, False, True]))
  let assert Ok([m5, _, m0, _]) =
    cli_fixture.field(document, ["data", "items"], decode.list(decode.dynamic))
  cli_fixture.keys(m5, [])
  |> should.equal(Ok(list.sort(["in_store", ..summary_keys], string.compare)))
  cli_fixture.field(m5, ["subject"], decode.optional(decode.string))
  |> should.equal(Ok(Some("Subject m5")))
  cli_fixture.keys(m0, []) |> should.equal(Ok(["id", "in_store"]))
}

/// C5, C6: `--limit` keeps the thread's last entries in position order and
/// sets `truncated`; `total` still counts the whole thread.
pub fn thread_limit_prints_a_truncated_page_test() {
  let setup = cli_fixture.seeded("cli-thread-limit", snapshot_fixture.listing())
  let outcome = read_verb(setup, ["thread", "acct-l-th1", "--limit", "2"])
  temp.remove_dir(setup.dir)

  let document = expect_document(outcome, "thread")
  cli_fixture.item_ids(document)
  |> should.equal(Ok(listing_ids(["m0", "m1"])))
  cli_fixture.field(document, ["data", "total"], decode.int)
  |> should.equal(Ok(4))
  cli_fixture.field(document, ["data", "truncated"], decode.bool)
  |> should.equal(Ok(True))
}

/// C5: a `--limit` larger than the thread keeps every id, untruncated.
pub fn thread_limit_beyond_the_thread_prints_every_id_test() {
  let setup = cli_fixture.seeded("cli-thread-wide", snapshot_fixture.listing())
  let outcome = read_verb(setup, ["thread", "acct-l-th1", "--limit", "500"])
  temp.remove_dir(setup.dir)

  let document = expect_document(outcome, "thread")
  cli_fixture.item_ids(document)
  |> should.equal(Ok(listing_ids(["m5", "m3", "m0", "m1"])))
  cli_fixture.field(document, ["data", "total"], decode.int)
  |> should.equal(Ok(4))
  cli_fixture.field(document, ["data", "truncated"], decode.bool)
  |> should.equal(Ok(False))
}

/// C6: with no `--limit`, a thread longer than 50 prints its last 50 entries,
/// truncated. The thread's ids are outside the snapshot, so it needs no
/// messages.
pub fn thread_defaults_to_the_last_fifty_entries_test() {
  let listing = snapshot_fixture.listing()
  // long-1 .. long-51, built from the top down by prepending.
  let ids =
    int.range(from: 51, to: 0, with: [], run: fn(ids, n) {
      ["long-" <> int.to_string(n), ..ids]
    })
  let snapshot =
    model.Snapshot(..listing, threads: [
      model.Thread("acct-l-th-long", ids),
      ..listing.threads
    ])
  let setup = cli_fixture.seeded("cli-thread-default", snapshot)
  let outcome = read_verb(setup, ["thread", "acct-l-th-long"])
  temp.remove_dir(setup.dir)

  let document = expect_document(outcome, "thread")
  cli_fixture.item_ids(document) |> should.equal(Ok(list.drop(ids, 1)))
  cli_fixture.field(document, ["data", "total"], decode.int)
  |> should.equal(Ok(51))
  cli_fixture.field(document, ["data", "truncated"], decode.bool)
  |> should.equal(Ok(True))
}

// ---------------------------------------------------------------- EX-3

/// O-F3: a read verb leaves the store exactly as it found it: every row,
/// index, schema line and `user_version` identical in the logical dump.
pub fn read_verbs_leave_the_store_unchanged_test() {
  let setup =
    cli_fixture.seeded("cli-read-unchanged", snapshot_fixture.full("acct-a"))
  let before = store_dump.dump(setup.store_path)
  let outcomes =
    list.map(read_verbs, fn(args) { #(args, read_verb(setup, args)) })
  let after = store_dump.dump(setup.store_path)
  temp.remove_dir(setup.dir)

  list.each(outcomes, fn(pair) {
    let #(args, outcome) = pair
    #(args, outcome.exit_code) |> should.equal(#(args, 0))
  })
  after |> should.equal(before)
}

/// One argv per read verb, valid against `full("acct-a")`.
const read_verbs = [
  ["mailboxes"],
  ["list"],
  ["read", "acct-a-m1"],
  ["thread", "acct-a-th1"],
]

/// Every read verb over a store in one unreadable state fails exit 1 with one
/// `Store` line naming `reason`, and prints nothing on stdout.
fn expect_store_refusal(setup: cli_fixture.ReadSetup, reason: String) -> Nil {
  let outcomes =
    list.map(read_verbs, fn(args) { #(args, read_verb(setup, args)) })
  temp.remove_dir(setup.dir)

  list.each(outcomes, fn(pair) {
    let #(args, outcome) = pair
    #(args, outcome.exit_code) |> should.equal(#(args, 1))
    #(args, outcome.stdout) |> should.equal(#(args, None))
    #(args, outcome.stderr)
    |> should.equal(
      #(args, [
        "{\"level\":\"error\",\"error\":\"store\",\"reason\":\""
        <> reason
        <> "\"}",
      ]),
    )
  })
}

/// EX-3: no store file yet is `no_snapshot`.
pub fn read_verbs_refuse_a_missing_store_with_no_snapshot_test() {
  expect_store_refusal(cli_fixture.unseeded("cli-ex3-missing"), "no_snapshot")
}

/// EX-3 / A9: the only older schema is `user_version` 0 — a store with tables
/// but no committed snapshot — and it is `no_snapshot` too.
pub fn read_verbs_refuse_an_older_store_with_no_snapshot_test() {
  let setup =
    cli_fixture.seeded("cli-ex3-older", snapshot_fixture.full("acct-a"))
  store_dump.set_user_version(setup.store_path, 0)
  expect_store_refusal(setup, "no_snapshot")
}

/// EX-3: a store one version newer than this binary, with a column it does not
/// know, is `schema_mismatch`.
pub fn read_verbs_refuse_a_newer_store_with_schema_mismatch_test() {
  let setup =
    cli_fixture.seeded("cli-ex3-newer", snapshot_fixture.full("acct-a"))
  store_dump.exec_sql(
    setup.store_path,
    "ALTER TABLE message ADD COLUMN extra TEXT NOT NULL DEFAULT 'x'",
  )
  store_dump.set_user_version(setup.store_path, store.supported_version() + 1)
  expect_store_refusal(setup, "schema_mismatch")
}

// ---------------------------------------------------------------- shipment

/// VT-2 through the real process edge: `list` from the shipment, with no
/// `CREDENTIALS_DIRECTORY`, prints one `list` document and exits 0.
pub fn shipment_list_prints_one_document_test() {
  let shipment = unwrap(subprocess.shipment_dir())
  let setup = cli_fixture.seeded("cli-run-list", snapshot_fixture.listing())
  let record =
    unwrap(
      subprocess.run_env(
        subprocess.entrypoint(shipment),
        ["run", "--config", setup.config_path, "list", "--limit", "2"],
        [#("CREDENTIALS_DIRECTORY", None)],
      ),
    )
  temp.remove_dir(setup.dir)

  record.exit_code |> should.equal(0)
  record.stderr |> should.equal("")
  let assert Ok(stdout) = bit_array.to_string(record.stdout)
  let document = cli_fixture.stdout_text_json(stdout)
  cli_fixture.field(document, ["kind"], decode.string)
  |> should.equal(Ok("list"))
  cli_fixture.item_ids(document) |> should.equal(Ok(listing_ids(["m6", "m5"])))
}
