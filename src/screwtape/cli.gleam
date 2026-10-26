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
//// `sync` is the token path end to end: config file, credential from
//// `$CREDENTIALS_DIRECTORY`, a byte budget, the production `Send`, the session,
//// then `Mailbox/get` for the envelope (PHASE-05 extends it).
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
import screwtape/config
import screwtape/credential
import screwtape/error.{type Error}
import screwtape/file
import screwtape/jmap/client
import screwtape/jmap/decode
import screwtape/jmap/request as jmap_request

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
        Ok(document) -> Outcome(Some(document), [], 0)
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
/// the session and one `Mailbox/get`, and render the envelope. Any failure ends
/// the run (EX-2) with that `Error`.
fn sync(
  path: String,
  env: fn(String) -> Result(String, Nil),
) -> Result(String, Error) {
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
  let session = client.session_of(client_)
  use #(_, responses) <- result.try(
    client.call(client_, [
      jmap_request.mailbox_get(session.account_id, "c0"),
    ]),
  )
  use response <- result.try(only_response(responses))
  use #(mailboxes, _state) <- result.try(decode.mailboxes(response))
  Ok(envelope(session, mailboxes))
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

/// The one response this run asked for. `decode.method_responses` answers a
/// list; a run that got none has nothing to decode, and the path names the
/// missing entry, never the document.
fn only_response(
  responses: List(decode.MethodResponse),
) -> Result(decode.MethodResponse, Error) {
  case responses {
    [response] -> Ok(response)
    _ -> Error(error.Decode("methodResponses"))
  }
}

/// The `sync` document: the versioned envelope with this run's account, the
/// number of mailboxes the server listed and whether the account is read-only
/// (PHASE-05 widens the `data`).
fn envelope(
  session: decode.Session,
  mailboxes: List(decode.MailboxSummary),
) -> String {
  json.object([
    #("version", json.int(1)),
    #("kind", json.string("sync")),
    #(
      "data",
      json.object([
        #("account_id", json.string(session.account_id)),
        #("mailboxes", json.int(list.length(mailboxes))),
        #("is_read_only", json.bool(session.is_read_only)),
      ]),
    ),
  ])
  |> json.to_string
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
