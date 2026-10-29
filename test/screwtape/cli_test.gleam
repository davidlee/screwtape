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
import gleam/http as method
import gleam/http/response.{Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/classify/input as classify_input
import screwtape/classify/state as classify_state
import screwtape/cli
import screwtape/error
import screwtape/http
import screwtape/model
import screwtape/pii
import screwtape/store
import support/cli_fixture
import support/fixture_send
import support/jmap_fixture
import support/local_jmap
import support/paging
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
  "cursor", "from", "has_attachment", "id", "is_flagged", "is_seen",
  "mailbox_ids", "preview", "received_at", "subject", "thread_id",
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

// ---------------------------------------------------------------- list --after
//
// PHASE-04 C2 / C3: `list --after <cursor>` walks the store oldest first from a
// position the consumer holds, and every item's `cursor` is what it holds
// between pages. The walk helper is `support/paging`, shared with the store
// suite, so a cursor that never advances fails rather than hangs.

/// The `(id, cursor)` pair of every item in `data.items`, in order: the two
/// strings `--after` paging reads from a page, zipped.
fn item_cursors(document: dynamic.Dynamic) -> List(#(String, String)) {
  let assert Ok(ids) = cli_fixture.item_strings(document, "id")
  let assert Ok(cursors) = cli_fixture.item_strings(document, "cursor")
  list.zip(ids, cursors)
}

/// `id`'s cursor text as `list` prints it, computed from `snapshot`'s own
/// message row, so no case keeps a second copy of an arrival instant.
fn expected_cursor(snapshot: model.Snapshot, id: String) -> String {
  let assert Ok(message) =
    list.find(snapshot.messages, fn(message) { message.id == id })
  int.to_string(message.received_at.ms) <> ":" <> message.id
}

/// One `list --after <after> --limit <limit>` page against `setup`: its items'
/// `(id, cursor)` pairs, oldest first.
fn after_page(
  setup: cli_fixture.ReadSetup,
  after: String,
  limit: Int,
) -> Result(List(#(String, String)), Nil) {
  let outcome =
    read_verb(setup, [
      "list",
      "--after",
      after,
      "--limit",
      int.to_string(limit),
    ])
  Ok(item_cursors(expect_document(outcome, "list")))
}

/// VT-1 (PHASE-04), C2: every item of a plain `list` carries `cursor`, its
/// `"<ms>:<id>"` arrival position — `-m1`'s is the fixture's own midnight — so
/// a consumer can ask for what follows any item it was shown.
pub fn list_items_carry_their_arrival_cursor_test() {
  let snapshot = snapshot_fixture.listing()
  let setup = cli_fixture.seeded("cli-list-cursor", snapshot)
  let outcome = read_verb(setup, ["list"])
  temp.remove_dir(setup.dir)

  let document = expect_document(outcome, "list")
  let pairs = item_cursors(document)
  list.map(pairs, fn(pair) { pair.0 }) |> should.equal(newest_first)
  list.map(pairs, fn(pair) { pair.1 })
  |> should.equal(
    list.map(newest_first, fn(id) { expected_cursor(snapshot, id) }),
  )
  list.find(pairs, fn(pair) { pair.0 == "acct-l-m1" })
  |> should.equal(
    Ok(#(
      "acct-l-m1",
      int.to_string(snapshot_fixture.listing_midnight_ms) <> ":acct-l-m1",
    )),
  )
}

/// VT-1 (PHASE-04/05), C2: `list --after` and `read --after` each walk the
/// whole listing once, oldest first, in `(received_at_ms, id)` order, for a page
/// of one, of two and the whole store. A read page is the lines its stream
/// printed, read for the same `(id, cursor)` pair a list page carries. Each
/// store is written in both message orders: SQLite breaks an `ORDER BY` tie by
/// scan order, and `-m4` and `-m5` share a millisecond, so an order without its
/// `id` column would still pass with one order (RV-012 F-1).
pub fn after_walks_the_whole_listing_in_ascending_order_test() {
  let listing = snapshot_fixture.listing()
  let reversed =
    model.Snapshot(..listing, messages: list.reverse(listing.messages))
  use snapshot <- list.each([listing, reversed])
  let setup = cli_fixture.seeded("cli-after-walk", snapshot)
  let pagers = [
    #("list", fn(after: String, limit: Int) { after_page(setup, after, limit) }),
    #("read", fn(after: String, limit: Int) {
      read_after_page(setup, after, limit)
    }),
  ]
  let walks =
    list.flat_map(pagers, fn(pager) {
      let #(verb, page) = pager
      list.map([1, 2, 500], fn(limit) {
        #(
          #(verb, limit),
          paging.walk(
            from: "",
            page: fn(after) { page(after, limit) },
            next: fn(pair) { pair.1 },
            bound: list.length(snapshot_fixture.listing_ascending_ids()),
          )
            |> result.map(list.map(_, fn(pair) { pair.0 })),
        )
      })
    })
  temp.remove_dir(setup.dir)

  list.each(walks, fn(walk) {
    #(walk.0, walk.1)
    |> should.equal(#(walk.0, Ok(snapshot_fixture.listing_ascending_ids())))
  })
}

/// C2 / D7 (PHASE-04): an `--after` document carries exactly `after`, `items`
/// and `limit` — no `offset` — echoes the cursor text it was given, defaults
/// `limit` to 50, and starts strictly after the cursor: past `-m4` come `-m5`
/// and `-m6`.
pub fn list_after_document_shape_test() {
  let setup =
    cli_fixture.seeded("cli-list-after-doc", snapshot_fixture.listing())
  let m4 =
    int.to_string(snapshot_fixture.listing_midnight_ms + 3_600_000)
    <> ":acct-l-m4"
  let start = read_verb(setup, ["list", "--after", ""])
  let from_m4 = read_verb(setup, ["list", "--after", m4])
  let limited = read_verb(setup, ["list", "--after", "", "--limit", "2"])
  temp.remove_dir(setup.dir)

  let start = expect_document(start, "list")
  cli_fixture.keys(start, ["data"])
  |> should.equal(Ok(["after", "items", "limit"]))
  cli_fixture.field(start, ["data", "after"], decode.string)
  |> should.equal(Ok(""))
  cli_fixture.field(start, ["data", "limit"], decode.int)
  |> should.equal(Ok(50))
  cli_fixture.item_ids(start)
  |> should.equal(Ok(snapshot_fixture.listing_ascending_ids()))

  let from_m4 = expect_document(from_m4, "list")
  cli_fixture.field(from_m4, ["data", "after"], decode.string)
  |> should.equal(Ok(m4))
  cli_fixture.item_ids(from_m4) |> should.equal(Ok(listing_ids(["m5", "m6"])))

  let limited = expect_document(limited, "list")
  cli_fixture.field(limited, ["data", "limit"], decode.int)
  |> should.equal(Ok(2))
  cli_fixture.item_ids(limited) |> should.equal(Ok(listing_ids(["m2", "m1"])))
}

/// C2 (PHASE-04): `--after ""` starts at the oldest message, so a filter's
/// `--after` page is its plain `list` page reversed — the listing is six
/// messages, so one page holds the whole of each filter's answer.
pub fn list_after_start_agrees_with_every_plain_list_filter_test() {
  let setup =
    cli_fixture.seeded("cli-list-after-filter", snapshot_fixture.listing())
  let filters = [
    ["--mailbox", "inbox"],
    ["--since", "2026-10-25"],
    ["--from", "acme"],
    ["--unread"],
  ]
  let outcomes =
    list.map(filters, fn(filter) {
      #(filter, read_verb(setup, ["list", "--after", "", ..filter]))
    })
  temp.remove_dir(setup.dir)

  list.each(outcomes, fn(pair) {
    let #(filter, outcome) = pair
    let assert Ok(ids) = cli_fixture.item_ids(expect_document(outcome, "list"))
      as string.inspect(#(filter, outcome))
    #(filter, ids)
    |> should.equal(#(filter, list.reverse(listed(filter))))
  })
}

/// C2 (PHASE-04): an `--after` page past the data is an empty page, not an
/// error — an empty store from `""`, and a store walked past `-m6`.
pub fn list_after_edges_are_empty_pages_test() {
  let empty = model.Snapshot(..snapshot_fixture.listing(), messages: [])
  let empty_setup = cli_fixture.seeded("cli-list-after-empty", empty)
  let empty_outcome = read_verb(empty_setup, ["list", "--after", ""])
  temp.remove_dir(empty_setup.dir)

  let setup =
    cli_fixture.seeded("cli-list-after-past", snapshot_fixture.listing())
  let past_cursor =
    int.to_string(snapshot_fixture.listing_midnight_ms + 7_200_000)
    <> ":acct-l-m6"
  let past = read_verb(setup, ["list", "--after", past_cursor])
  temp.remove_dir(setup.dir)

  let empty = expect_document(empty_outcome, "list")
  cli_fixture.field(empty, ["data", "after"], decode.string)
  |> should.equal(Ok(""))
  cli_fixture.item_ids(empty) |> should.equal(Ok([]))

  let past = expect_document(past, "list")
  cli_fixture.field(past, ["data", "after"], decode.string)
  |> should.equal(Ok(past_cursor))
  cli_fixture.item_ids(past) |> should.equal(Ok([]))
}

/// C3 (PHASE-04): the usage reasons `--after` adds. Only canonical cursor text
/// parses (no `+`, no leading zero, no empty id, no out-of-range instant);
/// `--after` with `--offset` is refused once every flag has parsed, so an
/// unknown flag still wins and a bad cursor or `--since` still names itself;
/// and a repeated or valueless `--after` is the same usage error a repeated
/// flag always is.
pub fn list_after_usage_reasons_test() {
  let setup =
    cli_fixture.seeded("cli-list-after-reasons", snapshot_fixture.listing())
  let invalid_cursors = [
    "x", ":", "5:", "abc:id", "+5:id", "007:id", "9223372036854775808:id",
  ]
  let bad_cursor_cases =
    list.map(invalid_cursors, fn(text) {
      #(["list", "--after", text], "invalid_cursor")
    })
  let cases =
    list.append(bad_cursor_cases, [
      #(["list", "--after", "", "--offset", "0"], "offset_with_after"),
      #(["list", "--offset", "0", "--after", ""], "offset_with_after"),
      #(["list", "--after", "", "--after", ""], "repeated_argument"),
      #(["list", "--after", "", "--offset", "1", "--bogus"], "unknown_argument"),
      #(["list", "--after", "x", "--offset", "1"], "invalid_cursor"),
      #(
        ["list", "--after", "", "--offset", "0", "--since", "2026-13-01"],
        "invalid_since",
      ),
      #(["list", "--after"], "missing_value"),
      // `--limit` keeps its 1..500 range under `--after`: SQLite reads a
      // negative LIMIT as no limit at all.
      #(["list", "--after", "", "--limit", "0"], "invalid_integer"),
      #(["list", "--after", "", "--limit", "-1"], "invalid_integer"),
      #(["list", "--after", "", "--limit", "501"], "invalid_integer"),
    ])

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

// ---------------------------------------------------------------- read --after
//
// PHASE-05 C1: `read --after` is `list --after`'s selection, printed as
// `read <id>` prints each message — one stdout line per selected message, oldest
// first — so a consumer can stream a whole listing from a cursor it holds.

/// The document each line of a `read --after` stream carries: one version-1
/// `read` envelope per selected message, oldest first. An empty selection is no
/// stdout at all (`None`), which is the empty page.
fn streamed_documents(
  outcome: cli.Outcome,
) -> Result(List(dynamic.Dynamic), Nil) {
  case outcome.stdout {
    None -> Ok([])
    Some(text) ->
      Ok(list.map(string.split(text, "\n"), cli_fixture.stdout_text_json))
  }
}

/// The `(id, cursor)` pair of every line of a `read --after` stream, in order:
/// the two strings a walk reads from a page, as `list --after` carries them.
fn streamed_cursors(
  outcome: cli.Outcome,
) -> Result(List(#(String, String)), Nil) {
  let assert Ok(documents) = streamed_documents(outcome)
  Ok(
    list.map(documents, fn(document) {
      let assert Ok(id) =
        cli_fixture.field(document, ["data", "id"], decode.string)
      let assert Ok(cursor) =
        cli_fixture.field(document, ["data", "cursor"], decode.string)
      #(id, cursor)
    }),
  )
}

/// One `read --after <after> --limit <limit> --max-bytes 0` page against
/// `setup`: its lines' `(id, cursor)` pairs, oldest first. `--max-bytes 0` keeps
/// every body empty, so a walk page stays small and is read only for the two
/// strings paging needs.
fn read_after_page(
  setup: cli_fixture.ReadSetup,
  after: String,
  limit: Int,
) -> Result(List(#(String, String)), Nil) {
  let outcome =
    read_verb(setup, [
      "read",
      "--after",
      after,
      "--limit",
      int.to_string(limit),
      "--max-bytes",
      "0",
    ])
  streamed_cursors(outcome)
}

/// C3 (PHASE-05): the usage reasons a `read` selection adds. A `read` whose
/// first argument starts with `--` is a selection, so it requires `--after` and
/// `--max-bytes`. Both are checked only once every flag has parsed, and in that
/// order: a value error, an unknown flag or an extra positional still names
/// itself first, `missing_after` beats `offset_with_after`, and
/// `offset_with_after` beats `missing_max_bytes`. `list` still refuses
/// `--max-bytes` as the unknown flag it is.
pub fn read_after_usage_reasons_test() {
  let setup =
    cli_fixture.seeded("cli-read-after-reasons", snapshot_fixture.listing())
  let cases = [
    // No --after at all: missing_after, even with --offset present.
    #(["read", "--max-bytes", "5"], "missing_after"),
    #(["read", "--limit", "2", "--max-bytes", "5"], "missing_after"),
    #(["read", "--offset", "0", "--max-bytes", "5"], "missing_after"),
    // --after with --offset: offset_with_after, with or without --max-bytes.
    #(
      ["read", "--after", "", "--offset", "0", "--max-bytes", "5"],
      "offset_with_after",
    ),
    #(["read", "--after", "", "--offset", "0"], "offset_with_after"),
    // --after without --max-bytes.
    #(["read", "--after", ""], "missing_max_bytes"),
    #(["read", "--after", "", "--limit", "2"], "missing_max_bytes"),
    // A value error still wins over missing_max_bytes.
    #(["read", "--after", "x"], "invalid_cursor"),
    #(["read", "--after", "", "--max-bytes", "-1"], "invalid_max_bytes"),
    // A repeated flag, an extra positional, an unknown flag.
    #(
      ["read", "--after", "", "--max-bytes", "5", "--max-bytes", "6"],
      "repeated_argument",
    ),
    #(
      ["read", "--after", "", "--after", "", "--max-bytes", "5"],
      "repeated_argument",
    ),
    #(["read", "--after", "", "--max-bytes", "5", "extra"], "unknown_argument"),
    #(
      ["read", "--after", "", "--max-bytes", "5", "--bogus"],
      "unknown_argument",
    ),
    // `list` does not select: --max-bytes stays an unknown flag there.
    #(["list", "--after", "", "--max-bytes", "5"], "unknown_argument"),
    #(["list", "--max-bytes", "-1"], "unknown_argument"),
    #(["list", "--max-bytes"], "unknown_argument"),
    // `--limit` keeps its 1..500 range under a selection too.
    #(
      ["read", "--after", "", "--max-bytes", "5", "--limit", "0"],
      "invalid_integer",
    ),
    #(
      ["read", "--after", "", "--max-bytes", "5", "--limit", "-1"],
      "invalid_integer",
    ),
    #(
      ["read", "--after", "", "--max-bytes", "5", "--limit", "501"],
      "invalid_integer",
    ),
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

/// C1 (PHASE-05): `read --after` over the whole listing prints exactly the
/// documents `read <id> --max-bytes 7` prints for the same ids, one line each,
/// oldest first: each line is a version-1 `read` envelope whose data keys are
/// `read_keys`, cursor included. Streaming a page and reading its ids one by
/// one therefore cannot disagree.
pub fn read_after_streams_the_listing_one_line_per_message_test() {
  let setup =
    cli_fixture.seeded("cli-read-after-stream", snapshot_fixture.listing())
  let streamed = read_verb(setup, ["read", "--after", "", "--max-bytes", "7"])
  let singles =
    list.map(snapshot_fixture.listing_ascending_ids(), fn(id) {
      read_verb(setup, ["read", id, "--max-bytes", "7"])
    })
  temp.remove_dir(setup.dir)

  streamed.exit_code |> should.equal(0)
  streamed.stderr |> should.equal([])
  let assert Some(text) = streamed.stdout as string.inspect(streamed)
  string.split(text, "\n")
  |> should.equal(
    list.map(singles, fn(outcome) {
      let assert Some(single) = outcome.stdout as string.inspect(outcome)
      single
    }),
  )

  let assert Ok(documents) = streamed_documents(streamed)
  list.each(documents, fn(document) {
    cli_fixture.keys(document, [])
    |> should.equal(Ok(["data", "kind", "version"]))
    cli_fixture.field(document, ["version"], decode.int) |> should.equal(Ok(1))
    cli_fixture.field(document, ["kind"], decode.string)
    |> should.equal(Ok("read"))
    cli_fixture.keys(document, ["data"]) |> should.equal(Ok(read_keys))
  })
}

/// C1 and § 5.5 Edge (PHASE-05): a selection that selects nothing prints nothing and exits 0
/// — no stdout, no stderr. Both edges are here: a cursor past the last message,
/// and a filter no message answers.
pub fn read_after_empty_selection_prints_nothing_test() {
  let snapshot = snapshot_fixture.listing()
  let setup = cli_fixture.seeded("cli-read-after-empty", snapshot)
  let assert Ok(last) = list.last(snapshot_fixture.listing_ascending_ids())
  let past =
    read_verb(setup, [
      "read",
      "--after",
      expected_cursor(snapshot, last),
      "--max-bytes",
      "0",
    ])
  let filtered =
    read_verb(setup, [
      "read", "--after", "", "--from", "nobody@nowhere.test", "--max-bytes", "0",
    ])
  temp.remove_dir(setup.dir)

  list.each([past, filtered], fn(outcome) {
    outcome.exit_code |> should.equal(0)
    outcome.stdout |> should.equal(None)
    outcome.stderr |> should.equal([])
  })
}

/// EX-4 (PHASE-05): a selection's filters select what `list --after` selects —
/// the same ids in the same oldest-first order — so streaming a filter is the
/// same answer as listing it. Every filter here narrows the listing, so a
/// selection that ignored it would not pass the equality by accident.
pub fn read_after_filter_selects_what_list_after_does_test() {
  let setup =
    cli_fixture.seeded("cli-read-after-filter", snapshot_fixture.listing())
  let filters = [
    ["--mailbox", "acct-l-mb1"],
    ["--since", "2026-10-25"],
    ["--from", "billing@acme.test"],
    ["--unread"],
  ]
  let outcomes =
    list.map(filters, fn(filter) {
      #(
        filter,
        read_verb(setup, ["list", "--after", "", ..filter]),
        read_verb(setup, ["read", "--after", "", "--max-bytes", "0", ..filter]),
      )
    })
  temp.remove_dir(setup.dir)

  list.each(outcomes, fn(pair) {
    let #(filter, listed, streamed) = pair
    let assert Ok(listed_ids) =
      cli_fixture.item_ids(expect_document(listed, "list"))
      as string.inspect(#(filter, listed))
    let assert Ok(streamed_pairs) = streamed_cursors(streamed)
      as string.inspect(#(filter, streamed))
    let streamed_ids = list.map(streamed_pairs, fn(pair) { pair.0 })
    #(filter, streamed_ids) |> should.equal(#(filter, listed_ids))
    listed_ids |> list.is_empty |> should.be_false
    let narrowed =
      list.length(listed_ids)
      < list.length(snapshot_fixture.listing_ascending_ids())
    narrowed |> should.be_true
  })
}

// ---------------------------------------------------------------- read

/// The keys of a `read` document's `data` (D7): the summary's, the rest of the
/// message, `provenance` and `output_truncated` — and not the message's
/// `blob_id` or any body's `max_body_value_bytes`.
const read_keys = [
  "attachments", "bcc", "bodies", "cc", "cursor", "from", "has_attachment", "id",
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

// ---------------------------------------------------------------- classify

/// The Jev deployment the classify cases name: a URL no transport reaches (the
/// scripted `Send` answers instead) and a config model the fixture reply's
/// bare `jev-1.14.0` is accepted for.
const jev_base_url = "https://jev.example.test"

/// The bearer secret the classify cases hand the scripted `Send`.
const jev_secret = "SENTINEL-cli-classify-0123456789abcdef"

/// The stdout document per line; a case's `flat_map` over it assumes the
/// separator is one newline, which `string.join` makes.
fn stdout_lines(outcome: cli.Outcome) -> List(String) {
  let assert Some(text) = outcome.stdout
  string.split(text, "\n")
}

/// One stdout line's `kind`.
fn kind_of(line: String) -> Result(String, Nil) {
  cli_fixture.field(cli_fixture.stdout_text_json(line), ["kind"], decode.string)
}

/// One stdout line's `data.id` and `data.cursor`, in order.
fn document_fields(line: String) -> #(String, String) {
  let document = cli_fixture.stdout_text_json(line)
  let assert Ok(id) = cli_fixture.field(document, ["data", "id"], decode.string)
  let assert Ok(cursor) =
    cli_fixture.field(document, ["data", "cursor"], decode.string)
  #(id, cursor)
}

/// One fixture line by index; a case names the line it fails at.
fn nth_line(lines: List(String), index: Int) -> String {
  let assert Ok(line) = list.drop(lines, index) |> list.first
  line
}

/// The input lines' ids and cursors, decoded the way the run decodes them.
fn input_ids_and_cursors(lines: List(String)) -> List(#(String, String)) {
  list.map(lines, fn(line) {
    let assert Ok(mail) = classify_input.line(line)
    #(mail.id, mail.cursor)
  })
}

/// One scripted Jev answer at a `Post` position.
fn jev_step(status: Int, body: String) -> fixture_send.Step {
  fixture_send.Step(
    method.Post,
    Ok(Response(status: status, headers: [], body: body)),
  )
}

/// The `send_for` a classify case injects: the fixture's `Send`, whatever
/// timeout and CA file the config named.
fn scripted_send(fixture: fixture_send.Fixture) {
  fn(_timeout_ms, _ca_file) { fixture_send.send(fixture) }
}

/// The two fakes a classify case pins I5 with: a store opener and a `Send`
/// factory that panic if called. Classify opens no store and, for `--state`,
/// builds no `Send`, so a call is a failure; both cases share these.
fn panicking_fakes() -> #(
  fn(String) -> Result(store.Reader, error.Error),
  fn(Int, Option(String)) -> http.Send,
) {
  #(fn(_path) { panic as "store opened by classify" }, fn(_, _) {
    panic as "send built for --state"
  })
}

/// Run one classify argv with `stdin` over the scripted `Send`.
fn run_classify(
  setup: cli_fixture.ReadSetup,
  args: List(String),
  env: fn(String) -> Result(String, Nil),
  stdin: String,
  fixture: fixture_send.Fixture,
) -> cli.Outcome {
  let #(never_opened, _) = panicking_fakes()
  cli.run_with(
    ["--config", setup.config_path, ..args],
    env,
    fn() { Ok(stdin) },
    never_opened,
    scripted_send(fixture),
  )
}

/// VT-1: `--state` needs no credential, no network and no `jev` block — the
/// five fixture lines each print one `classify_state` document, in order.
pub fn classify_state_over_the_read_fixture_test() {
  let setup = cli_fixture.unseeded("cli-classify-state")
  let lines = cli_fixture.read_after_lines()
  lines |> list.length |> should.equal(5)
  let #(never_opened, never_sent) = panicking_fakes()
  let outcome =
    cli.run_with(
      ["--config", setup.config_path, "classify", "--state"],
      no_env,
      fn() { Ok(cli_fixture.read_after_stdin()) },
      never_opened,
      never_sent,
    )
  temp.remove_dir(setup.dir)

  outcome.exit_code |> should.equal(0)
  outcome.stderr |> should.equal([])
  let printed = stdout_lines(outcome)
  printed |> list.length |> should.equal(5)
  printed
  |> list.map(kind_of)
  |> should.equal(list.repeat(Ok("classify_state"), 5))
  printed
  |> list.map(document_fields)
  |> should.equal(input_ids_and_cursors(lines))
}

/// No lines at all — empty stdin or only blank ones — is nothing on stdout and
/// exit 0, the shape a selection that selected nothing has (C4).
pub fn classify_with_no_lines_prints_nothing_test() {
  let setup = cli_fixture.unseeded("cli-classify-empty")
  ["", "\n\n"]
  |> list.each(fn(stdin) {
    cli.run_piped(
      ["--config", setup.config_path, "classify", "--state"],
      no_env,
      fn() { Ok(stdin) },
    )
    |> should.equal(cli.Outcome(None, [], 0))
  })
  temp.remove_dir(setup.dir)
}

/// EX-3: `run` has no stdin, so a classify run through it is `no_stdin`,
/// which exits 2.
pub fn classify_through_run_is_no_stdin_test() {
  let setup = cli_fixture.unseeded("cli-classify-no-stdin")
  let line =
    cli.run(["--config", setup.config_path, "classify", "--state"], no_env)
    |> expect_failure("usage", 2)
  temp.remove_dir(setup.dir)
  cli_fixture.error_reason(line) |> should.equal(Ok("no_stdin"))
}

/// EX-3: a remote classify without the `jev` block is `no_jev` before stdin is
/// read — the reader would crash the test if it ran.
pub fn classify_without_jev_block_is_no_jev_test() {
  let setup = cli_fixture.unseeded("cli-classify-no-jev")
  let line =
    cli.run_piped(["--config", setup.config_path, "classify"], no_env, fn() {
      panic as "stdin read without a jev block"
    })
    |> expect_failure("config", 2)
  temp.remove_dir(setup.dir)
  cli_fixture.error_reason(line) |> should.equal(Ok("no_jev"))
}

/// VT-2 through the cli: a bad `jev.base_url` is that config reason and exits
/// 2; a loopback base URL is accepted, and `--state` then runs without a
/// credential or a network.
pub fn classify_config_reasons_through_the_cli_test() {
  let bad =
    cli_fixture.jev_config("cli-classify-non-https", "http://jev.example.test")
  let line =
    cli.run_piped(["--config", bad.config_path, "classify"], no_env, fn() {
      Ok("")
    })
    |> expect_failure("config", 2)
  temp.remove_dir(bad.dir)
  cli_fixture.error_reason(line)
  |> should.equal(Ok("non_https:jev.base_url"))

  let loopback =
    cli_fixture.jev_config("cli-classify-loopback", "http://127.0.0.1:4000")
  let outcome =
    cli.run_piped(
      ["--config", loopback.config_path, "classify", "--state"],
      no_env,
      fn() { Ok("") },
    )
  temp.remove_dir(loopback.dir)
  outcome |> should.equal(cli.Outcome(None, [], 0))
}

/// VT-2 through the cli: a `jev.base_url` that passes config but is not a URL
/// `request.to` can parse is `Config("jev_url")`, exits 2, prints nothing, and
/// the scripted `Send` is never consulted.
pub fn classify_unparsable_jev_url_is_jev_url_test() {
  let setup = cli_fixture.jev_config("cli-classify-bad-url", "https://a b")
  let credentials = cli_fixture.jev_credential_dir(jev_secret)
  let line = cli_fixture.read_after_lines() |> nth_line(0)
  let fixture = fixture_send.start([])
  let outcome =
    run_classify(
      setup,
      ["classify"],
      credentials_env(credentials),
      line,
      fixture,
    )
  temp.remove_dir(setup.dir)
  temp.remove_dir(credentials)

  outcome.exit_code |> should.equal(2)
  outcome.stdout |> should.equal(None)
  let assert [error_line] = outcome.stderr
  cli_fixture.error_reason(error_line) |> should.equal(Ok("jev_url"))
  fixture_send.request_count(fixture) |> should.equal(0)
}

/// VT-1: one line, one Jev POST to `<base_url>/v1/systemone`, one `classify`
/// document; three lines are three of each and no warnings.
pub fn classify_posts_each_line_and_prints_a_document_test() {
  let setup = cli_fixture.jev_config("cli-classify-remote", jev_base_url)
  let credentials = cli_fixture.jev_credential_dir(jev_secret)
  let lines = list.take(cli_fixture.read_after_lines(), 3)
  let reply = cli_fixture.jev_reply("mail-1-reply.json")
  let fixture = fixture_send.start(list.repeat(jev_step(200, reply), 3))
  let outcome =
    run_classify(
      setup,
      ["classify"],
      credentials_env(credentials),
      string.join(lines, "\n"),
      fixture,
    )
  temp.remove_dir(setup.dir)
  temp.remove_dir(credentials)

  outcome.exit_code |> should.equal(0)
  outcome.stderr |> should.equal([])
  let printed = stdout_lines(outcome)
  printed |> list.length |> should.equal(3)
  printed
  |> list.map(kind_of)
  |> should.equal(list.repeat(Ok("classify"), 3))
  printed
  |> list.map(document_fields)
  |> should.equal(input_ids_and_cursors(lines))

  fixture_send.request_count(fixture) |> should.equal(3)
  fixture_send.recorded(fixture)
  |> list.map(fn(request) { request.url })
  |> should.equal(list.repeat(jev_base_url <> "/v1/systemone", 3))

  // Each request carries its own line's state: three copies of one state would
  // fail, and so would a body that is not the window's `pii.strip` encoding.
  let states =
    list.map(lines, fn(line) {
      let assert Ok(mail) = classify_input.line(line)
      json.to_string(classify_state.encode(
        classify_state.window(mail),
        pii.strip,
      ))
    })
  list.zip(
    fixture_send.recorded(fixture) |> list.map(fn(request) { request.body }),
    states,
  )
  |> list.each(fn(pair) {
    let #(body, state) = pair
    string.contains(body, state) |> should.be_true
  })
}

/// VT-4: a failure at the third line leaves exactly the first two documents on
/// stdout, and the one error line names the bound and the failing line's
/// cursor; exit 1.
pub fn classify_stops_at_the_failing_line_test() {
  let setup = cli_fixture.jev_config("cli-classify-k2", jev_base_url)
  let credentials = cli_fixture.jev_credential_dir(jev_secret)
  let lines = list.take(cli_fixture.read_after_lines(), 3)
  let reply = cli_fixture.jev_reply("mail-1-reply.json")
  let limit = cli_fixture.jev_reply("max-tokens-exceeded-400.gateway.json")
  let fixture =
    fixture_send.start([
      jev_step(200, reply),
      jev_step(200, reply),
      jev_step(400, limit),
    ])
  let outcome =
    run_classify(
      setup,
      ["classify"],
      credentials_env(credentials),
      string.join(lines, "\n"),
      fixture,
    )

  // The same first two lines through a passing run: its stdout is the exact
  // text the failing run must have printed before line three.
  let passing = fixture_send.start(list.repeat(jev_step(200, reply), 2))
  let ok =
    run_classify(
      setup,
      ["classify"],
      credentials_env(credentials),
      string.join(list.take(lines, 2), "\n"),
      passing,
    )
  temp.remove_dir(setup.dir)
  temp.remove_dir(credentials)

  ok.exit_code |> should.equal(0)
  outcome.exit_code |> should.equal(1)
  outcome.stdout |> should.equal(ok.stdout)
  let assert [line] = outcome.stderr
  cli_fixture.error_kind(line) |> should.equal(Ok("limit_exceeded"))
  cli_fixture.field(
    cli_fixture.stdout_text_json(line),
    ["bound"],
    decode.string,
  )
  |> should.equal(Ok("jev_context"))
  let assert Ok(mail) = classify_input.line(nth_line(lines, 2))
  cli_fixture.field(
    cli_fixture.stdout_text_json(line),
    ["cursor"],
    decode.string,
  )
  |> should.equal(Ok(mail.cursor))
}

/// VT-4: a failure at the first line prints nothing, one error line, exit 1.
pub fn classify_failure_at_the_first_line_prints_nothing_test() {
  let setup = cli_fixture.jev_config("cli-classify-k0", jev_base_url)
  let credentials = cli_fixture.jev_credential_dir(jev_secret)
  let line = cli_fixture.read_after_lines() |> nth_line(0)
  let limit = cli_fixture.jev_reply("max-tokens-exceeded-400.gateway.json")
  let fixture = fixture_send.start([jev_step(400, limit)])
  let outcome =
    run_classify(
      setup,
      ["classify"],
      credentials_env(credentials),
      line,
      fixture,
    )
  temp.remove_dir(setup.dir)
  temp.remove_dir(credentials)

  outcome.exit_code |> should.equal(1)
  outcome.stdout |> should.equal(None)
  let assert [error_line] = outcome.stderr
  cli_fixture.error_kind(error_line) |> should.equal(Ok("limit_exceeded"))
  let assert Ok(mail) = classify_input.line(line)
  cli_fixture.field(
    cli_fixture.stdout_text_json(error_line),
    ["cursor"],
    decode.string,
  )
  |> should.equal(Ok(mail.cursor))
}

/// EX-8: a line that does not decode is the plain `decode` line with no
/// `cursor`; the good line before it is already on stdout.
pub fn classify_non_decoding_line_has_no_cursor_test() {
  let setup = cli_fixture.jev_config("cli-classify-decode", jev_base_url)
  let credentials = cli_fixture.jev_credential_dir(jev_secret)
  let good = cli_fixture.read_after_lines() |> nth_line(0)
  let reply = cli_fixture.jev_reply("mail-1-reply.json")
  let fixture = fixture_send.start([jev_step(200, reply)])
  let outcome =
    run_classify(
      setup,
      ["classify"],
      credentials_env(credentials),
      good <> "\n{\"version\":2}",
      fixture,
    )
  temp.remove_dir(setup.dir)
  temp.remove_dir(credentials)

  outcome.exit_code |> should.equal(1)
  stdout_lines(outcome) |> list.length |> should.equal(1)
  let assert [error_line] = outcome.stderr
  cli_fixture.error_kind(error_line) |> should.equal(Ok("decode"))
  cli_fixture.field(
    cli_fixture.stdout_text_json(error_line),
    ["cursor"],
    decode.string,
  )
  |> should.equal(Error(Nil))
}
