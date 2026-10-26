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
//// argv is `--config <path> <verb> [args]`: `sync`, or one of the read verbs
//// `mailboxes`, `list`, `read` and `thread` (PHASE-06, D7). `command` turns it
//// into one `Command`; every shape it does not accept is `Usage`, whose reason
//// is a fixed code and never one of the arguments.
////
//// The read verbs need no credential and no network: the config, one
//// `open_reader`, one `store.read` holding every query of the verb, then
//// `close_reader`, then a document from `render` (I8).
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
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some, is_some, unwrap}
import gleam/result
import gleam/string
import gleam/time/timestamp
import screwtape/config
import screwtape/credential
import screwtape/error.{type Error}
import screwtape/file
import screwtape/jmap/client
import screwtape/model
import screwtape/normalise
import screwtape/render
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
    Ok(Command(path, verb)) ->
      case dispatch(path, verb, env) {
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

/// One accepted invocation: the config file to read and the verb to run.
pub type Command {
  Command(config_path: String, verb: Verb)
}

/// The verbs the CLI serves.
pub type Verb {
  Sync
  Mailboxes
  List(ListArgs)
  Read(id: String, max_bytes: Option(Int))
  Thread(id: String)
}

/// `list`'s checked flags with their defaults applied; `since_ms` is the
/// midnight-UTC instant a `--since YYYY-MM-DD` names (A2).
pub type ListArgs {
  ListArgs(
    mailbox: Option(String),
    since_ms: Option(Int),
    from: Option(String),
    unread: Bool,
    limit: Int,
    offset: Int,
  )
}

/// The page size and start `list` uses when no flag names them, and the range
/// `--limit` and `--offset` accept (A5).
const default_limit = 50

const default_offset = 0

const min_limit = 1

const max_limit = 500

/// The accepted command line: `--config <path> <verb> [args]`. Every other
/// shape is a `Usage` whose reason is a fixed code, never an argument.
fn command(argv: List(String)) -> Result(Command, Error) {
  case argv {
    [] -> usage("missing_command")
    ["--config"] -> usage("missing_config_path")
    ["--config", _] -> usage("missing_verb")
    ["--config", path, verb, ..args] -> verb_command(path, verb, args)
    _ -> usage("unknown_argument")
  }
}

fn verb_command(
  path: String,
  verb: String,
  args: List(String),
) -> Result(Command, Error) {
  case verb, args {
    "sync", [] -> Ok(Command(path, Sync))
    "sync", _ -> usage("unexpected_argument")
    "mailboxes", [] -> Ok(Command(path, Mailboxes))
    "mailboxes", _ -> usage("unexpected_argument")
    "list", _ ->
      parse_list(args) |> result.map(fn(args) { Command(path, List(args)) })
    "read", _ ->
      parse_read(args)
      |> result.map(fn(parsed) {
        let #(id, max_bytes) = parsed
        Command(path, Read(id, max_bytes))
      })
    "thread", _ ->
      parse_thread(args) |> result.map(fn(id) { Command(path, Thread(id)) })
    _, _ -> usage("unknown_verb")
  }
}

fn usage(reason: String) -> Result(a, Error) {
  Error(error.Usage(reason))
}

/// A flag that may appear once: a second appearance is `Usage` (A5).
fn fresh(taken: Bool) -> Result(Nil, Error) {
  case taken {
    False -> Ok(Nil)
    True -> usage("repeated_argument")
  }
}

// ---------------------------------------------------------------- read argv

/// `read <id> [--max-bytes n]`.
fn parse_read(args: List(String)) -> Result(#(String, Option(Int)), Error) {
  case args {
    [] -> usage("missing_message_id")
    [id, ..rest] -> {
      use max_bytes <- result.try(parse_max_bytes(rest, None))
      Ok(#(id, max_bytes))
    }
  }
}

fn parse_max_bytes(
  args: List(String),
  found: Option(Int),
) -> Result(Option(Int), Error) {
  case args {
    [] -> Ok(found)
    ["--max-bytes", ..rest] -> {
      use _ <- result.try(fresh(is_some(found)))
      use pair <- result.try(value_flag(rest))
      let #(raw, rest) = pair
      use value <- result.try(max_bytes_value(raw))
      parse_max_bytes(rest, Some(value))
    }
    _ -> usage("unknown_argument")
  }
}

fn max_bytes_value(raw: String) -> Result(Int, Error) {
  case int.parse(raw) {
    Ok(value) if value >= 0 -> Ok(value)
    _ -> usage("invalid_max_bytes")
  }
}

/// `thread <id>`, with no other argument (A7).
fn parse_thread(args: List(String)) -> Result(String, Error) {
  case args {
    [id] -> Ok(id)
    [] -> usage("missing_thread_id")
    _ -> usage("unexpected_argument")
  }
}

/// `list`'s flags, in any order, each at most once (A5).
type ListFlags {
  ListFlags(
    mailbox: Option(String),
    since: Option(String),
    from: Option(String),
    unread: Bool,
    limit: Option(Int),
    offset: Option(Int),
  )
}

fn parse_list(args: List(String)) -> Result(ListArgs, Error) {
  use flags <- result.try(parse_list_flags(args, empty_flags()))
  use since_ms <- result.try(optional_since(flags.since))
  Ok(ListArgs(
    mailbox: flags.mailbox,
    since_ms: since_ms,
    from: flags.from,
    unread: flags.unread,
    limit: unwrap(flags.limit, default_limit),
    offset: unwrap(flags.offset, default_offset),
  ))
}

fn empty_flags() -> ListFlags {
  ListFlags(None, None, None, False, None, None)
}

fn parse_list_flags(
  args: List(String),
  flags: ListFlags,
) -> Result(ListFlags, Error) {
  case args {
    [] -> Ok(flags)
    [flag, ..rest] ->
      case flag {
        "--unread" -> {
          use _ <- result.try(fresh(flags.unread))
          parse_list_flags(rest, ListFlags(..flags, unread: True))
        }
        "--mailbox" ->
          parse_text_flag(
            rest,
            flags.mailbox,
            fn(flags, value) { ListFlags(..flags, mailbox: Some(value)) },
            flags,
          )
        "--since" ->
          parse_text_flag(
            rest,
            flags.since,
            fn(flags, value) { ListFlags(..flags, since: Some(value)) },
            flags,
          )
        "--from" ->
          parse_text_flag(
            rest,
            flags.from,
            fn(flags, value) { ListFlags(..flags, from: Some(value)) },
            flags,
          )
        "--limit" ->
          parse_int_flag(
            rest,
            flags.limit,
            fn(value) { value >= min_limit && value <= max_limit },
            fn(flags, value) { ListFlags(..flags, limit: Some(value)) },
            flags,
          )
        "--offset" ->
          parse_int_flag(
            rest,
            flags.offset,
            fn(value) { value >= 0 },
            fn(flags, value) { ListFlags(..flags, offset: Some(value)) },
            flags,
          )
        _ -> usage("unknown_argument")
      }
  }
}

/// A flag taking one text value, which it stores once.
fn parse_text_flag(
  args: List(String),
  found: Option(String),
  store: fn(ListFlags, String) -> ListFlags,
  flags: ListFlags,
) -> Result(ListFlags, Error) {
  use _ <- result.try(fresh(is_some(found)))
  use pair <- result.try(value_flag(args))
  let #(value, rest) = pair
  parse_list_flags(rest, store(flags, value))
}

/// A flag taking one integer value `allowed` accepts, stored once.
fn parse_int_flag(
  args: List(String),
  found: Option(Int),
  allowed: fn(Int) -> Bool,
  store: fn(ListFlags, Int) -> ListFlags,
  flags: ListFlags,
) -> Result(ListFlags, Error) {
  use _ <- result.try(fresh(is_some(found)))
  use pair <- result.try(value_flag(args))
  let #(raw, rest) = pair
  use value <- result.try(int_value(raw, allowed))
  parse_list_flags(rest, store(flags, value))
}

fn int_value(raw: String, allowed: fn(Int) -> Bool) -> Result(Int, Error) {
  case int.parse(raw) {
    Ok(value) ->
      case allowed(value) {
        True -> Ok(value)
        False -> usage("invalid_integer")
      }
    Error(Nil) -> usage("invalid_integer")
  }
}

/// The value after a flag; a flag with nothing after it is `Usage`.
fn value_flag(args: List(String)) -> Result(#(String, List(String)), Error) {
  case args {
    [value, ..rest] -> Ok(#(value, rest))
    [] -> usage("missing_value")
  }
}

/// `--since` must be exactly `YYYY-MM-DD`; `normalise.utc_date` then validates
/// the calendar date at midnight UTC (A2).
fn optional_since(raw: Option(String)) -> Result(Option(Int), Error) {
  case raw {
    None -> Ok(None)
    Some(raw) -> since_ms(raw) |> result.map(Some)
  }
}

fn since_ms(raw: String) -> Result(Int, Error) {
  case string.to_graphemes(raw) {
    [_, _, _, _, "-", _, _, "-", _, _] ->
      case normalise.utc_date(raw <> "T00:00:00Z") {
        Ok(date) -> Ok(date.ms)
        Error(Nil) -> usage("invalid_since")
      }
    _ -> usage("invalid_since")
  }
}

// ---------------------------------------------------------------- verbs

/// Run the parsed verb: `sync`, or one read verb over the config's store.
fn dispatch(
  path: String,
  verb: Verb,
  env: fn(String) -> Result(String, Nil),
) -> Result(#(String, List(String)), Error) {
  case verb {
    Sync -> sync(path, env)
    Mailboxes -> read_verb(path, mailboxes_document)
    List(args) -> read_verb(path, list_document(args))
    Read(id, max_bytes) -> read_verb(path, read_document(id, max_bytes))
    Thread(id) -> read_verb(path, thread_document(id))
  }
}

/// One read verb: the config, one reader, every query in one `store.read`, and
/// the reader closed before the result is inspected (I8).
fn read_verb(
  path: String,
  query: fn(store.Tx) -> Result(String, Error),
) -> Result(#(String, List(String)), Error) {
  use settings <- result.try(read_config(path))
  use reader <- result.try(store.open_reader(settings.store_path))
  let outcome = store.read(reader, query)
  store.close_reader(reader)
  outcome |> result.map(fn(document) { #(document, []) })
}

fn mailboxes_document(tx: store.Tx) -> Result(String, Error) {
  use mailboxes <- result.try(store.mailboxes(tx))
  Ok(render.mailboxes(mailboxes))
}

fn list_document(args: ListArgs) -> fn(store.Tx) -> Result(String, Error) {
  fn(tx) {
    use mailbox_ids <- result.try(resolve_mailbox(tx, args.mailbox))
    use items <- result.try(store.messages(
      tx,
      store.ListQuery(
        mailbox_ids: mailbox_ids,
        since_ms: args.since_ms,
        from: args.from,
        unread: args.unread,
        limit: args.limit,
        offset: args.offset,
      ),
    ))
    Ok(render.list(offset: args.offset, limit: args.limit, items: items))
  }
}

/// The mailboxes `--mailbox` selects: an id first, then the role-then-name rule
/// `sync` uses (A4). No match is `Usage("unknown_mailbox")`.
fn resolve_mailbox(
  tx: store.Tx,
  mailbox: Option(String),
) -> Result(Option(List(String)), Error) {
  case mailbox {
    None -> Ok(None)
    Some(entry) -> {
      use all <- result.try(store.mailboxes(tx))
      let matched = list.filter(all, fn(mailbox) { mailbox.id == entry })
      let matched = case matched {
        [] -> model.mailboxes_matching(all, entry)
        _ -> matched
      }
      case matched {
        [] -> usage("unknown_mailbox")
        _ -> Ok(Some(list.map(matched, fn(mailbox) { mailbox.id })))
      }
    }
  }
}

fn read_document(
  id: String,
  max_bytes: Option(Int),
) -> fn(store.Tx) -> Result(String, Error) {
  fn(tx) {
    use account_id <- result.try(store.account_id(tx))
    use message <- result.try(store.message(tx, id))
    case message {
      Some(message) ->
        Ok(render.read(
          account_id: account_id,
          message: message,
          max_bytes: max_bytes,
        ))
      None -> usage("unknown_message")
    }
  }
}

fn thread_document(id: String) -> fn(store.Tx) -> Result(String, Error) {
  fn(tx) {
    use entries <- result.try(store.thread(tx, id))
    case entries {
      Some(entries) -> Ok(render.thread(id, entries))
      None -> usage("unknown_thread")
    }
  }
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
  Ok(#(render.envelope("sync", data(summary)), warnings(summary)))
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

/// The `sync` document's `data`: the committed run's summary (design § 5.2).
/// The envelope around it comes from `render.envelope`, the one writer.
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
