//// Contract tests for `screwtape/cli`, the CLI edge (PHASE-10, D7; EX-4 /
//// VT-7).
////
//// `run` is pure of process effects — it returns the document, the stderr lines
//// and the exit code — so every case here is in-process except the two that
//// spawn the shipment's own `entrypoint.sh run`, which are VT-7's proof that the
//// argv, the exit code and the stderr line survive the real process edge.
////
//// The happy path drives one `local_jmap` over real TLS to the session and the
//// `Mailbox/get`, with a config file and a credentials directory written under
//// `temp`: no module is stubbed, so the run is the production path end to end.
////
//// The config file, credentials directory and stderr-line helpers live in
//// `support/cli_fixture`, shared with the token-leak suite (PHASE-10, T5a).

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/cli
import support/cli_fixture
import support/jmap_fixture
import support/local_jmap
import support/subprocess
import support/temp

pub fn main() -> Nil {
  gleeunit.main()
}

/// The account and mailbox count `test/fixtures/jmap/mailbox_get.json` carries.
const account_id = "acct-1"

const mailbox_count = 3

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

/// D7: only `--config <path> sync` is accepted. Every other shape is `Usage`,
/// which exits 2 and says nothing about the arguments it was given.
pub fn usage_shapes_exit_two_test() {
  let path = "/nonexistent/screwtape/config.json"
  let cases = [
    [],
    ["sync"],
    ["--config"],
    ["--config", path],
    ["--config", path, "list"],
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
  let #(dir, path) =
    cli_fixture.config_dir(
      "cli-no-cred-env",
      cli_fixture.config_text(unused_session_url, None),
    )
  let outcome = cli.run(["--config", path, "sync"], no_env)
  temp.remove_dir(dir)

  let line = expect_failure(outcome, "credential", 1)
  line
  |> string.contains("\"reason\":\"no_credentials_directory\"")
  |> should.be_true
}

/// A credentials directory that does not hold the named file is the same
/// `Credential` failure, with the reason that names the file, not the path.
pub fn missing_credential_file_exits_one_test() {
  let credentials = temp.dir("cli-missing-credential")
  let #(dir, path) =
    cli_fixture.config_dir(
      "cli-missing-cred",
      cli_fixture.config_text(unused_session_url, None),
    )
  let outcome =
    cli.run(["--config", path, "sync"], credentials_env(credentials))
  temp.remove_dir(dir)
  temp.remove_dir(credentials)

  let line = expect_failure(outcome, "credential", 1)
  line |> string.contains("\"reason\":\"missing\"") |> should.be_true
  line |> string.contains(credentials) |> should.be_false
}

// ---------------------------------------------------------------- sync

/// The happy path: config → credential → budget → `Send` → session →
/// `Mailbox/get` → one envelope on stdout, exit 0.
pub fn sync_envelope_test() {
  let server =
    local_jmap.start_with(fn(base_url) {
      [
        local_jmap.reply(200, jmap_fixture.session(base_url <> "/api")),
        local_jmap.reply(200, jmap_fixture.text("mailbox_get.json")),
      ]
    })
  let credentials = cli_fixture.credential_dir("SENTINEL-cli-0123456789")
  let #(dir, path) =
    cli_fixture.config_dir(
      "cli-sync",
      cli_fixture.config_text(
        local_jmap.url(server, "/session"),
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
  outcome.stderr |> should.equal([])
  let assert Some(document) = outcome.stdout
  let assert Ok(json_document) = json.parse(document, using: decode.dynamic)
  requests |> should.equal(2)
  decode.run(json_document, decode.at(["version"], decode.int))
  |> should.equal(Ok(1))
  decode.run(json_document, decode.at(["kind"], decode.string))
  |> should.equal(Ok("sync"))
  decode.run(json_document, decode.at(["data", "account_id"], decode.string))
  |> should.equal(Ok(account_id))
  decode.run(json_document, decode.at(["data", "mailboxes"], decode.int))
  |> should.equal(Ok(mailbox_count))
  decode.run(json_document, decode.at(["data", "is_read_only"], decode.bool))
  |> should.equal(Ok(False))
  document
  |> string.contains("SENTINEL-cli")
  |> should.be_false
}

// ---------------------------------------------------------------- shipment

/// VT-7 through the real process edge: a `sync` with no `CREDENTIALS_DIRECTORY`
/// exits 1 with exactly one JSON line, and nothing on stdout. The variable is
/// removed from the child's environment (`None` in `run_env`) even
/// though this suite may have it set.
pub fn shipment_sync_without_credentials_exits_one_test() {
  let shipment = unwrap(subprocess.shipment_dir())
  let #(dir, path) =
    cli_fixture.config_dir(
      "cli-run-no-cred-env",
      cli_fixture.config_text(unused_session_url, None),
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
