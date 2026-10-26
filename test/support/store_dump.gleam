//// A logical dump of a store file, standing in for the sqlite3 CLI's `.dump`
//// (the nix check sandbox has no sqlite3; PHASE-04 phase sheet A1).
////
//// The dump holds `PRAGMA user_version` (which `.dump` omits), every
//// `sqlite_schema` row, and every table's rows in rowid order, so two dumps are
//// equal exactly when the schema, the data and the version are.
////
//// It does not see connection state: pragmas such as `journal_mode`, the
//// `-wal`/`-shm` files, or a transaction another connection left open. Tests
//// of those observe them directly.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sqlight

/// Dump the store at `path`. A path that cannot be read crashes the test here.
pub fn dump(path: String) -> String {
  // Read-only through the URI, so a dump can never create or modify a store.
  let assert Ok(connection) = sqlight.open("file:" <> path <> "?mode=ro")

  let lines = [
    "user_version=" <> int.to_string(user_version(connection)),
    ..list.append(schema_lines(connection), table_lines(connection))
  ]

  let assert Ok(Nil) = sqlight.close(connection)
  string.join(lines, "\n") <> "\n"
}

fn user_version(connection: sqlight.Connection) -> Int {
  let assert Ok([version]) =
    sqlight.query(
      "PRAGMA user_version",
      on: connection,
      with: [],
      expecting: decode.field(0, decode.int, decode.success),
    )
  version
}

fn schema_lines(connection: sqlight.Connection) -> List(String) {
  let assert Ok(lines) =
    sqlight.query(
      "SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY type, name",
      on: connection,
      with: [],
      expecting: schema_line_decoder(),
    )
  lines
}

/// One schema row as one line: the four columns tab-separated, a NULL `sql`
/// rendered empty. Embedded newlines become spaces so a row stays one line.
fn schema_line_decoder() -> decode.Decoder(String) {
  use type_ <- decode.field(0, decode.string)
  use name <- decode.field(1, decode.string)
  use tbl_name <- decode.field(2, decode.string)
  use sql <- decode.field(3, decode.optional(decode.string))
  let sql = sql |> option_unwrap_empty |> one_line
  let fields = [type_, name, tbl_name, sql] |> list.map(one_line)
  decode.success(string.join(fields, "\t"))
}

fn option_unwrap_empty(value: Option(String)) -> String {
  case value {
    Some(text) -> text
    None -> ""
  }
}

fn one_line(text: String) -> String {
  text
  |> string.replace("\r\n", " ")
  |> string.replace("\n", " ")
  |> string.replace("\r", " ")
}

/// The header line and rows of every non-internal table, by name.
fn table_lines(connection: sqlight.Connection) -> List(String) {
  connection
  |> table_names
  |> list.map(fn(table) { ["table " <> table, ..row_lines(connection, table)] })
  |> list.flatten
}

fn table_names(connection: sqlight.Connection) -> List(String) {
  let assert Ok(names) =
    sqlight.query(
      "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name",
      on: connection,
      with: [],
      expecting: decode.field(0, decode.string, decode.success),
    )
  names |> list.filter(fn(name) { !string.starts_with(name, "sqlite_") })
}

/// One JSON array per row, so a row is one line and every column value keeps
/// its type (NULL included).
fn row_lines(connection: sqlight.Connection, table: String) -> List(String) {
  let columns =
    column_names(connection, table)
    |> list.map(quote_identifier)
    |> string.join(", ")
  let assert Ok(rows) =
    sqlight.query(
      "SELECT json_array("
        <> columns
        <> ") FROM "
        <> quote_identifier(table)
        <> " ORDER BY rowid",
      on: connection,
      with: [],
      expecting: decode.field(0, decode.string, decode.success),
    )
  rows
}

fn column_names(connection: sqlight.Connection, table: String) -> List(String) {
  let assert Ok(names) =
    sqlight.query(
      "SELECT name FROM pragma_table_info(?) ORDER BY cid",
      on: connection,
      with: [sqlight.text(table)],
      expecting: decode.field(0, decode.string, decode.success),
    )
  names
}

fn quote_identifier(name: String) -> String {
  "\"" <> string.replace(name, "\"", "\"\"") <> "\""
}

/// Run one statement on the store outside `screwtape/store`, as an operator or
/// another binary would: how a test takes a store to an older or newer
/// `user_version`.
pub fn exec_sql(path: String, sql: String) -> Nil {
  let assert Ok(connection) = sqlight.open(path)
  let assert Ok(Nil) = sqlight.exec(sql, on: connection)
  let assert Ok(Nil) = sqlight.close(connection)
  Nil
}

/// Set the store's `PRAGMA user_version`, leaving its tables and rows.
pub fn set_user_version(path: String, version: Int) -> Nil {
  exec_sql(path, "PRAGMA user_version = " <> int.to_string(version))
}
