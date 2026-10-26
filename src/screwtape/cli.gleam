//// The CLI edge (PHASE-10, D7; design § 5.2): argv and the environment in, an
//// `Outcome` out.
////
//// `run` neither prints nor exits — it returns the one stdout document, the
//// stderr lines and the exit code, and `main` writes them and halts — so the
//// whole command surface is a plain function the contract tests call in
//// process. Every failure is the one `Error` type: its JSON line is the only
//// thing an `Error` adds to stderr, and no variant carries server text, file
//// contents, a URL or the token.
////
//// argv is `--config <path> sync` and nothing else (D7); `list` and the other
//// verbs arrive with PHASE-06, and until then every other shape is `Usage`.
////
//// `sync` is the token path end to end: config file, credential from
//// `$CREDENTIALS_DIRECTORY`, a byte budget, the production `Send`, the session,
//// then one whole `sync.run` — every JMAP call and the one committed snapshot —
//// over a writer on the config's store. The writer is closed on both paths, so
//// a failed run leaves the store as it was (I2); a successful one is reported
//// as a single document, and a writable account adds exactly one warning line.
////
//// The production `Send`'s Erlang binding lives here (D8), so the program has
//// exactly one: `production_send` closes it over the run's timeout and CA file,
//// and the transport tests import that instead of binding their own.

import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/timestamp
import screwtape/config
import screwtape/credential
import screwtape/error.{type Error}
import screwtape/file
import screwtape/jmap/client
import screwtape/model
import screwtape/store
import screwtape/sync

/// What `main` writes and exits with: at most one stdout document, zero or more
/// stderr lines (each already a JSON line, without its newline), and the code.
pub type Outcome {
  Outcome(stdout: Option(String), stderr: List(String), exit_code: Int)
}

/// Run one invocation. Pure of process effects: no printing, no exit.
pub fn run(
  argv: List(String),
  env: fn(String) -> Result(String, Nil),
) -> Outcome {
  case command(argv) {
    Error(error) -> failure(error)
    Ok(path) ->
      case sync(path, env) {
        Ok(#(document, warnings)) -> Outcome(Some(document), warnings, 0)
        Error(error) -> failure(error)
      }
  }
}

/// The one production `Send` (D8): the Erlang adapter's entry point bound with
/// this run's timeout and CA file, so the rest of the program only sees a
/// `Send`.
pub fn production_send(
  timeout_ms: Int,
  ca_file: Option(String),
) -> client.Send {
  fn(request, cap) { send(request, cap, timeout_ms, ca_file) }
}

// ---------------------------------------------------------------- argv

/// The accepted command line: `--config <path> sync`. Every other shape is a
/// `Usage` whose reason is a fixed code, never one of the arguments.
fn command(argv: List(String)) -> Result(String, Error) {
  case argv {
    ["--config", path, "sync"] -> Ok(path)
    [] -> usage("missing_command")
    ["--config"] -> usage("missing_config_path")
    ["--config", _] -> usage("missing_verb")
    ["--config", _, _] -> usage("unknown_verb")
    ["--config", _, "sync", _] -> usage("unexpected_argument")
    _ -> usage("unknown_argument")
  }
}

fn usage(reason: String) -> Result(String, Error) {
  Error(error.Usage(reason))
}

// ---------------------------------------------------------------- sync

/// The `sync` run: read the config, read the credential, spend a budget over
/// the session and the whole `sync.run`, and render the summary. Any failure
/// ends the run (EX-2) with that `Error`, and the writer is closed either way.
fn sync(
  path: String,
  env: fn(String) -> Result(String, Nil),
) -> Result(#(String, List(String)), Error) {
  use settings <- result.try(read_config(path))
  use dir <- result.try(credentials_directory(env))
  use token <- result.try(credential.read(dir, settings.credential_name))
  let send = production_send(settings.request_timeout_ms, settings.ca_file)
  use client_ <- result.try(client.session(
    send,
    token,
    settings.session_url,
    client.budget(settings.max_total_bytes),
  ))
  use writer <- result.try(store.open_writer(settings.store_path))
  let bounds =
    sync.Bounds(
      window: settings.window,
      max_pages: settings.max_pages,
      max_body_bytes: settings.max_body_bytes,
    )
  let run = sync.run(client_, writer, bounds, timestamp.system_time())
  // Closed before the run's own result is inspected, so a failed commit cannot
  // leave the writer (and its connection) behind.
  store.close_writer(writer)
  use summary <- result.try(run)
  Ok(#(document(summary), warnings(summary)))
}

/// An unreadable file — missing, unreadable or not UTF-8 — is `Config`
/// ("unreadable"), not a reason from the filesystem: the path and the contents
/// stay out of every line.
fn read_config(path: String) -> Result(config.Config, Error) {
  use text <- result.try(
    file.read_text(path)
    |> result.map_error(fn(_) { error.Config("unreadable") }),
  )
  config.parse(text)
}

/// systemd hands the unit a credentials directory; a shell does not. An unset
/// variable is the reason, never the path.
fn credentials_directory(
  env: fn(String) -> Result(String, Nil),
) -> Result(String, Error) {
  env("CREDENTIALS_DIRECTORY")
  |> result.map_error(fn(_) { error.Credential("no_credentials_directory") })
}

/// The one warning a run reports: a run that may write to the account says so,
/// on stderr, and still exits 0.
fn warnings(summary: sync.Summary) -> List(String) {
  case summary.is_read_only {
    True -> []
    False -> [warning("account_not_read_only")]
  }
}

fn warning(code: String) -> String {
  json.object([
    #("level", json.string("warning")),
    #("warning", json.string(code)),
  ])
  |> json.to_string
}

// ---------------------------------------------------------------- document

/// The `sync` document: the versioned envelope with the committed run's
/// summary (design § 5.2).
fn document(summary: sync.Summary) -> String {
  json.object([
    #("version", json.int(1)),
    #("kind", json.string("sync")),
    #("data", data(summary)),
  ])
  |> json.to_string
}

fn data(summary: sync.Summary) -> json.Json {
  json.object([
    #("account_id", json.string(summary.account_id)),
    #("synced_at", json.string(summary.synced_at.raw)),
    #("mailboxes", json.int(summary.mailboxes)),
    #("messages", json.int(summary.messages)),
    #("threads", json.int(summary.threads)),
    #("truncated_bodies", json.int(summary.truncated_bodies)),
    #("not_found", json.int(summary.not_found)),
    #("conversion_failures", json.int(summary.conversion_failures)),
    #("states", states(summary.states)),
    #("is_read_only", json.bool(summary.is_read_only)),
  ])
}

/// The run's type states as one object, `<type>: <state>`.
fn states(states: List(model.TypeState)) -> json.Json {
  json.object(
    list.map(states, fn(state) { #(state.type_, json.string(state.state)) }),
  )
}

// ---------------------------------------------------------------- outcome

fn failure(error: Error) -> Outcome {
  Outcome(None, [error.to_json_line(error)], error.exit_code(error))
}

// ---------------------------------------------------------------- FFI

@external(erlang, "screwtape_http", "send")
fn send(
  request: Request(String),
  cap: Int,
  timeout_ms: Int,
  ca_file: Option(String),
) -> Result(Response(String), client.HttpFailure)
