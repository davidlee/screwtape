//// The README's `mail-1` table against the schema (SL-004 PHASE-14, EX-6;
//// VT-3).
////
//// `mail_2()` owns the questions; the README says what a consumer will see.
//// This test is the seam: it reads `README.md`, takes the first cell of every
//// data row in the table under `### mail-1`, and requires those names to equal
//// `mail_2()`'s names in order. A missing section, a missing table or a
//// renamed, added, removed or reordered question fails here rather than in a
//// consumer. The README's table is the published shape, so the test parses it
//// as text and never trusts a hand-kept list.

import gleam/list
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/classify/schema
import screwtape/file
import screwtape/jev

pub fn main() -> Nil {
  gleeunit.main()
}

/// The table's question names, in the order the rows print.
pub fn mail_1_table_matches_schema_test() {
  let readme = readme()
  let expected = list.map(schema.mail_2(), jev.question_name)
  table_names(readme) |> should.equal(Ok(expected))
}

fn readme() -> String {
  let assert Ok(text) = file.read_text("README.md")
  text
}

/// The names in the `### mail-1` section's first table: header and separator
/// dropped, the first cell's backticks removed. The names are the schema's
/// exactly when the README and the code agree.
fn table_names(readme: String) -> Result(List(String), String) {
  use lines <- result.try(section_lines(string.split(readme, "\n")))
  let rows =
    list.filter(lines, fn(line) { string.starts_with(string.trim(line), "|") })
  case rows {
    [_, _, ..] as table -> Ok(list.drop(table, 2) |> list.map(name_cell))
    _ -> Error("has no table under ### mail-1")
  }
}

/// The lines after the `### mail-1` heading, up to the next heading.
fn section_lines(lines: List(String)) -> Result(List(String), String) {
  case lines {
    [] -> Error("has no ### mail-1 section")
    [line, ..rest] ->
      case string.trim(line) == "### mail-1" {
        True -> Ok(until_heading(rest))
        False -> section_lines(rest)
      }
  }
}

fn until_heading(lines: List(String)) -> List(String) {
  case lines {
    [] -> []
    [line, ..rest] ->
      case is_heading(string.trim(line)) {
        True -> []
        False -> [line, ..until_heading(rest)]
      }
  }
}

fn is_heading(line: String) -> Bool {
  string.starts_with(line, "## ") || string.starts_with(line, "### ")
}

/// The first cell of one table row, without its backticks. A cell that is not
/// backticked is kept as it is, so a malformed row cannot match a name.
fn name_cell(row: String) -> String {
  case string.split(row, "|") {
    [_, cell, ..] -> cell |> string.trim |> unquote
    _ -> ""
  }
}

fn unquote(cell: String) -> String {
  case string.starts_with(cell, "`") && string.ends_with(cell, "`") {
    True -> string.drop_start(cell, 1) |> string.drop_end(1)
    False -> cell
  }
}
