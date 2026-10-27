//// The CLI edge (PHASE-10, D7; design § 5.2): argv and the environment in, an
//// `Outcome` out.
////
//// `run` neither prints nor exits — it returns the stdout text, the stderr
//// lines and the exit code, and `main` writes them and halts — so the
//// whole command surface is a plain function the contract tests call in
//// process. Every failure is the one `Error` type: its JSON line is the only
//// thing an `Error` adds to stderr, and no variant carries server text, file
//// contents, a URL or the token.
////
//// The shape of argv is `screwtape/argv`'s: `parse` turns it into one
//// `Command` or the one `Usage`, and this module only runs what it accepted.
////
//// The read verbs need no credential and no network: the config, one
//// `open_reader`, one `store.read` holding every query of the verb, then
//// `close_reader`, then a document from `render` (I8). `read`'s selection is
//// the one verb whose stdout is other than one document: a line per selected
//// message, or nothing at all (C1, C4).
////
//// `sync` is the token path end to end: config file, the Prior from a
//// short-lived reader closed again, credential from `$CREDENTIALS_DIRECTORY`,
//// a byte budget, the production `Send`, the session, then one whole `sync.run`
//// — every JMAP call and the one committed snapshot — over a writer on the
//// config's store. The writer is closed on both paths, so a failed run leaves
//// the store as it was (I2); a successful one is reported as a single document,
//// and a writable account adds exactly one warning line.
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
import gleam/string
import gleam/time/timestamp
import screwtape/argv
import screwtape/config
import screwtape/credential
import screwtape/cursor
import screwtape/error.{type Error}
import screwtape/file
import screwtape/jmap/client
import screwtape/model
import screwtape/render
import screwtape/store
import screwtape/store/query
import screwtape/sync

/// What `main` writes and exits with: at most one stdout document, zero or more
/// stderr lines (each already a JSON line, without its newline), and the code.
pub type Outcome {
  Outcome(stdout: Option(String), stderr: List(String), exit_code: Int)
}

/// Run one invocation. Pure of process effects: no printing, no exit.
pub fn run(
  args: List(String),
  env: fn(String) -> Result(String, Nil),
) -> Outcome {
  run_with(args, env, store.open_reader)
}

/// `run` with the read verbs' reader opener injected. Exposed so the I8 tests
/// can hand every read verb a reader whose selects commit a new snapshot.
@internal
pub fn run_with(
  args: List(String),
  env: fn(String) -> Result(String, Nil),
  open_reader: fn(String) -> Result(store.Reader, Error),
) -> Outcome {
  case argv.parse(args) {
    Error(error) -> failure(error)
    Ok(argv.Command(path, verb)) ->
      case dispatch(path, verb, env, open_reader) {
        Ok(#(stdout, warnings)) -> Outcome(stdout, warnings, 0)
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

// ---------------------------------------------------------------- verbs

/// Run the parsed verb: `sync`, or one read verb over the config's store. The
/// stdout is `None` only for a selection that selected nothing.
fn dispatch(
  path: String,
  verb: argv.Verb,
  env: fn(String) -> Result(String, Nil),
  open_reader: fn(String) -> Result(store.Reader, Error),
) -> Result(#(Option(String), List(String)), Error) {
  let run_read = fn(query) { read_verb(path, open_reader, query) }
  let run_document = fn(document) {
    run_read(fn(tx) { document(tx) |> result.map(Some) })
  }
  case verb {
    argv.Sync -> sync(path, env, open_reader)
    argv.Mailboxes -> run_document(mailboxes_document)
    argv.List(filters, page) -> run_document(list_document(filters, page))
    argv.Read(id, max_bytes) -> run_document(read_document(id, max_bytes))
    argv.ReadAfter(filters, after, limit, max_bytes) ->
      run_read(read_stream(filters, after, limit, max_bytes))
    argv.Thread(id, limit) -> run_document(thread_document(id, limit))
  }
}

/// One read verb: the config, then `read_store`.
fn read_verb(
  path: String,
  open_reader: fn(String) -> Result(store.Reader, Error),
  query: fn(store.Tx) -> Result(Option(String), Error),
) -> Result(#(Option(String), List(String)), Error) {
  use settings <- result.try(read_config(path))
  let document = read_store(open_reader, settings.store_path, query)
  document |> result.map(fn(document) { #(document, []) })
}

/// One short-lived reader over `store_path`, every query of `query` in one
/// `store.read`, and the reader closed before the result is inspected (I8).
/// Shared by the read verbs and the `sync` run's Prior load.
fn read_store(
  open_reader: fn(String) -> Result(store.Reader, Error),
  store_path: String,
  query: fn(store.Tx) -> Result(a, Error),
) -> Result(a, Error) {
  use reader <- result.try(open_reader(store_path))
  let outcome = store.read(reader, query)
  store.close_reader(reader)
  outcome
}

fn mailboxes_document(tx: store.Tx) -> Result(String, Error) {
  use mailboxes <- result.try(query.mailboxes(tx))
  Ok(render.mailboxes(mailboxes))
}

/// One `list` page: the filters select, and the page chooses the query's order
/// and the document that echoes it (C2, design § 5.2).
fn list_document(
  filters: argv.Filters,
  page: argv.Page,
) -> fn(store.Tx) -> Result(String, Error) {
  let #(query_page, document) = list_page(page)
  fn(tx) {
    use list_query <- result.try(list_query(tx, filters, query_page))
    use items <- result.try(query.messages(tx, list_query))
    Ok(document(items))
  }
}

/// argv's page as the store's, with the document that echoes it: `--offset`
/// pages newest first, `--after` oldest first (C2).
fn list_page(
  page: argv.Page,
) -> #(query.Page, fn(List(model.MessageSummary)) -> String) {
  case page {
    argv.Offset(limit, offset) -> #(
      query.Newest(limit: limit, offset: offset),
      fn(items) { render.list(offset: offset, limit: limit, items: items) },
    )
    argv.After(limit, after) -> #(
      query.Oldest(after: after, limit: Some(limit)),
      fn(items) { render.list_after(after: after, limit: limit, items: items) },
    )
  }
}

/// The store query `filters` name, `--mailbox` resolved against `tx` (A4).
fn list_query(
  tx: store.Tx,
  filters: argv.Filters,
  page: query.Page,
) -> Result(query.ListQuery, Error) {
  use mailbox_ids <- result.try(resolve_mailbox(tx, filters.mailbox))
  Ok(query.ListQuery(
    mailbox_ids: mailbox_ids,
    since_ms: filters.since_ms,
    from: filters.from,
    unread: filters.unread,
    page: page,
  ))
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
      use all <- result.try(query.mailboxes(tx))
      let matched = list.filter(all, fn(mailbox) { mailbox.id == entry })
      let matched = case matched {
        [] -> model.mailboxes_matching(all, entry)
        _ -> matched
      }
      case matched {
        [] -> Error(error.Usage("unknown_mailbox"))
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
    use account_id <- result.try(query.account_id(tx))
    use message <- result.try(query.message(tx, id))
    case message {
      Some(message) ->
        Ok(render.read(
          account_id: account_id,
          message: message,
          max_bytes: max_bytes,
        ))
      None -> Error(error.Usage("unknown_message"))
    }
  }
}

/// `read`'s selection (C1, C4): `list --after`'s page, each message rendered
/// as `read <id> --max-bytes n` renders it, one line each, oldest first — all
/// inside the one transaction `read_store` holds. Nothing selected is `None`.
fn read_stream(
  filters: argv.Filters,
  after: cursor.Cursor,
  limit: Int,
  max_bytes: Int,
) -> fn(store.Tx) -> Result(Option(String), Error) {
  fn(tx) {
    use account_id <- result.try(query.account_id(tx))
    let page = query.Oldest(after: after, limit: Some(limit))
    use list_query <- result.try(list_query(tx, filters, page))
    use ids <- result.try(query.message_ids(tx, list_query))
    use messages <- result.try(query.messages_of(tx, ids))
    case messages {
      [] -> Ok(None)
      _ ->
        list.map(messages, fn(message) {
          render.read(
            account_id: account_id,
            message: message,
            max_bytes: Some(max_bytes),
          )
        })
        |> string.join("\n")
        |> Some
        |> Ok
    }
  }
}

fn thread_document(
  id: String,
  limit: Int,
) -> fn(store.Tx) -> Result(String, Error) {
  fn(tx) {
    use page <- result.try(query.thread(tx, id, limit))
    case page {
      Some(page) -> Ok(render.thread(id, page))
      None -> Error(error.Usage("unknown_thread"))
    }
  }
}

// ---------------------------------------------------------------- sync

/// The `sync` run: read the config, read the Prior in a reader closed before
/// any network or writer (EX-1), read the credential, spend a budget over the
/// session and the whole `sync.run`, and render the summary. Any failure ends
/// the run (EX-2) with that `Error`, and the writer is closed either way.
fn sync(
  path: String,
  env: fn(String) -> Result(String, Nil),
  open_reader: fn(String) -> Result(store.Reader, Error),
) -> Result(#(Option(String), List(String)), Error) {
  use settings <- result.try(read_config(path))
  use prior <- result.try(load_prior(open_reader, settings.store_path))
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
  let run = sync.run(client_, writer, bounds, prior, timestamp.system_time())
  // Closed before the run's own result is inspected, so a failed commit cannot
  // leave the writer (and its connection) behind.
  store.close_writer(writer)
  use summary <- result.try(run)
  Ok(#(Some(render.envelope("sync", data(summary))), warnings(summary)))
}

/// The store's Prior, or `None` when it holds no snapshot (design § 5.2
/// `sync.run`): any other read error ends the run unchanged.
fn load_prior(
  open_reader: fn(String) -> Result(store.Reader, Error),
  store_path: String,
) -> Result(Option(model.Prior), Error) {
  case read_store(open_reader, store_path, query.prior) {
    Ok(prior) -> Ok(Some(prior))
    Error(error.Store("no_snapshot")) -> Ok(None)
    Error(other) -> Error(other)
  }
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
    #("mode", json.string(mode_name(summary.mode))),
    #("fallback_reason", fallback_reason(summary.fallback_reason)),
    #("is_read_only", json.bool(summary.is_read_only)),
  ])
}

/// How the run chose the messages to refresh (design § 5.2 `sync.run`).
fn mode_name(mode: sync.Mode) -> String {
  case mode {
    sync.Incremental -> "incremental"
    sync.Full -> "full"
  }
}

/// Why a full run is full, `null` for an incremental one.
fn fallback_reason(reason: Option(String)) -> json.Json {
  case reason {
    None -> json.null()
    Some(reason) -> json.string(reason)
  }
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
