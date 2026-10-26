//// Test support: the config file, the credentials directory and the stderr
//// line that the CLI contract tests and the token-leak suite both build
//// (PHASE-10, EX-4/EX-5).
////
//// Moved here from `test/screwtape/cli_test.gleam` when the token-leak suite
//// needed the same shapes with overridable bounds, so neither suite keeps a
//// copy: `document` is the one writer, `config_text_with` and `config_text`
//// differ only in the bounds and the window they pass it, and
//// `full_sync_script` is the whole reply list a passing run reads. A config is
//// written with `gleam_json`, so no path needs escaping; a failure line is
//// decoded to its `error` field, so a case does not depend on the line's
//// layout.

import gleam/bit_array
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import screwtape/cli
import screwtape/credential
import screwtape/model
import screwtape/store
import support/jmap_fixture
import support/local_jmap
import support/temp

/// The byte budget a config carries unless a case tightens it: large enough
/// that no fixture body can reach it.
pub const default_max_total_bytes = 268_435_456

/// The request timeout a config carries unless a case shortens it.
pub const default_request_timeout_ms = 30_000

/// A valid configuration document (the shape `config_test` generates) with the
/// default bounds and the `inbox` window. `store_path` is the store the run
/// commits to, a path inside a directory the caller made (`temp.dir`).
pub fn config_text(
  session_url: String,
  store_path: String,
  ca_file: Option(String),
) -> String {
  config_text_with(
    session_url,
    store_path,
    ca_file,
    default_max_total_bytes,
    default_request_timeout_ms,
  )
}

/// The same document with the two bounds the token-leak cases tighten: a small
/// `max_total_bytes` (the session body breaches it) or a short
/// `request_timeout_ms` (a withheld reply times out).
pub fn config_text_with(
  session_url: String,
  store_path: String,
  ca_file ca_file: Option(String),
  max_total_bytes max_total_bytes: Int,
  request_timeout_ms request_timeout_ms: Int,
) -> String {
  document(
    session_url,
    store_path,
    ca_file,
    ["inbox"],
    max_total_bytes,
    request_timeout_ms,
  )
}

/// The same document over a given window, for the case that names a mailbox the
/// server does not have (the run reaches `Mailbox/get` and fails there).
pub fn config_text_window(
  session_url: String,
  store_path: String,
  ca_file: Option(String),
  mailboxes: List(String),
) -> String {
  document(
    session_url,
    store_path,
    ca_file,
    mailboxes,
    default_max_total_bytes,
    default_request_timeout_ms,
  )
}

fn document(
  session_url: String,
  store_path: String,
  ca_file: Option(String),
  mailboxes: List(String),
  max_total_bytes: Int,
  request_timeout_ms: Int,
) -> String {
  let fields = [
    #("session_url", json.string(session_url)),
    #("credential_name", json.string("fastmail")),
    #("store_path", json.string(store_path)),
    #(
      "window",
      json.object([
        #("mailboxes", json.array(mailboxes, json.string)),
        #("max_age_days", json.int(30)),
        #("max_messages", json.int(2000)),
      ]),
    ),
    #("max_body_bytes", json.int(262_144)),
    #("max_pages", json.int(20)),
    #("max_total_bytes", json.int(max_total_bytes)),
    #("request_timeout_ms", json.int(request_timeout_ms)),
  ]
  let fields = case ca_file {
    None -> fields
    Some(path) -> list.append(fields, [#("ca_file", json.string(path))])
  }
  json.object(fields) |> json.to_string
}

/// A fresh temp directory holding a config file with `text`, named
/// `<dir>/config.json`; returns the directory and the path.
pub fn config_dir(prefix: String, text: String) -> #(String, String) {
  let dir = temp.dir(prefix)
  let path = dir <> "/config.json"
  temp.write(path, bit_array.from_string(text))
  #(dir, path)
}

/// A fresh temp directory holding the credential file `fastmail`, whose trimmed
/// contents are `secret`.
pub fn credential_dir(secret: String) -> String {
  let dir = temp.dir("cli-credentials")
  temp.write(dir <> "/fastmail", bit_array.from_string(secret <> "\n"))
  dir
}

/// The only way to a `Token`: a real file, read by `credential.read`.
pub fn token(secret: String) -> credential.Token {
  let dir = credential_dir(secret)
  let result = credential.read(dir, "fastmail")
  temp.remove_dir(dir)
  let assert Ok(token) = result
  token
}

/// The replies one whole `sync` run reads, for the CLI cases that drive the
/// production path end to end: the session, the opening request's answer (an
/// `inbox`, Email and Thread states `es-0` and `ts-0`),
/// one `Email/query` page of two messages, their `Email/get`, and the
/// `Thread/get` of their two threads.
pub fn full_sync_script(base_url: String) -> List(local_jmap.Reply) {
  [
    local_jmap.reply(200, jmap_fixture.session(base_url <> "/api")),
    local_jmap.reply(
      200,
      jmap_fixture.opening_response([inbox()], "mb-state-1", "es-0", "ts-0"),
    ),
    local_jmap.reply(
      200,
      jmap_fixture.email_query_response(
        ["m1", "m2"],
        "qs-1",
        0,
        Some(2),
        None,
        True,
      ),
    ),
    local_jmap.reply(
      200,
      jmap_fixture.email_get_response(
        [jmap_fixture.email("m1"), jmap_fixture.email("m2")],
        "es-1",
        [],
      ),
    ),
    local_jmap.reply(
      200,
      jmap_fixture.thread_get_response(
        [#("t-m1", ["m1"]), #("t-m2", ["m2"])],
        "ts-1",
      ),
    ),
  ]
}

/// The `inbox` mailbox `jmap_fixture.email` files its messages in.
fn inbox() -> jmap_fixture.Mailbox {
  jmap_fixture.mailbox("mb-1", "Inbox", Some("inbox"))
}

/// The error line as a decoded document's `error` field, so a case does not
/// depend on the exact line layout.
pub fn error_kind(line: String) -> Result(String, Nil) {
  case json.parse(line, using: decode.dynamic) {
    Error(_) -> Error(Nil)
    Ok(document) ->
      decode.run(document, decode.at(["error"], decode.string))
      |> result.map_error(fn(_) { Nil })
  }
}

// ---------------------------------------------------------------- read verbs

/// A session URL the read verbs never contact: they need no network.
const unused_session_url = "https://api.example.test/session"

/// One temp directory holding a config file (`config_path`) whose store is
/// `store_path`, beside it. Removing `dir` removes both.
pub type ReadSetup {
  ReadSetup(dir: String, store_path: String, config_path: String)
}

/// A config naming a store that does not exist yet.
pub fn unseeded(prefix: String) -> ReadSetup {
  let dir = temp.dir(prefix)
  let store_path = dir <> "/mail.sqlite3"
  let config_path = dir <> "/config.json"
  temp.write(
    config_path,
    bit_array.from_string(config_text(unused_session_url, store_path, None)),
  )
  ReadSetup(dir, store_path, config_path)
}

/// A config naming a store that holds `snapshot`, committed by the real writer.
pub fn seeded(prefix: String, snapshot: model.Snapshot) -> ReadSetup {
  let setup = unseeded(prefix)
  let assert Ok(writer) = store.open_writer(setup.store_path)
  let assert Ok(Nil) = store.write_snapshot(writer, snapshot)
  store.close_writer(writer)
  setup
}

/// The outcome's stdout as a decoded JSON document. A failure, or a stdout that
/// is not JSON, crashes the test here with the outcome in the message.
pub fn stdout_json(outcome: cli.Outcome) -> Dynamic {
  let assert Some(text) = outcome.stdout as string.inspect(outcome)
  stdout_text_json(text)
}

/// `text` (one stdout document, any trailing newline ignored) decoded as JSON.
pub fn stdout_text_json(text: String) -> Dynamic {
  let assert Ok(document) =
    json.parse(string.trim_end(text), using: decode.dynamic)
    as text
  document
}

/// The value at `path` in `document`, decoded; `Error(Nil)` if it is absent or
/// another type.
pub fn field(
  document: Dynamic,
  path: List(String),
  decoder: decode.Decoder(a),
) -> Result(a, Nil) {
  decode.run(document, decode.at(path, decoder))
  |> result.replace_error(Nil)
}

/// The sorted keys of the object at `path`, so a case can pin a shape exactly.
pub fn keys(
  document: Dynamic,
  path: List(String),
) -> Result(List(String), Nil) {
  field(
    document,
    path,
    decode.dict(decode.string, decode.dynamic)
      |> decode.map(fn(object) {
        dict.keys(object) |> list.sort(string.compare)
      }),
  )
}

/// The `id` of every item in `data.items`, in order.
pub fn item_ids(document: Dynamic) -> Result(List(String), Nil) {
  field(
    document,
    ["data", "items"],
    decode.list(decode.at(["id"], decode.string)),
  )
}
