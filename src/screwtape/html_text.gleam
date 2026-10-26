//// HTML to plain text: a fold over htmgrrrl's SAX events (PHASE-03; design
//// § 5.1, DEC-010, DEC-020).
////
//// Pure. This module imports only `gleam_stdlib` and `screwtape/html_sax`
//// (invariant I5, enforced by `just check-imports`); nothing here can fetch.
////
//// The output is a line-oriented rendering: whitespace collapses, block
//// elements separate lines, `br` always breaks, table cells share a line,
//// and the content of scripts, styles and document metadata is dropped.

import gleam/list
import gleam/result
import gleam/string
import screwtape/html_sax

/// The text of an HTML document, or `Error(Nil)` when it cannot be parsed
/// (stored as `conversion_failed`, design § 5.5).
pub fn convert(html: String) -> Result(String, Nil) {
  case html_sax.sax(trim_open_tag(html), empty(), step) {
    Ok(acc) -> Ok(finish(acc))
    Error(Nil) -> Error(Nil)
  }
}

/// The fold's accumulator. `chunks` is reversed output; `pending_space` is a
/// space waiting to be written only if text follows it on the current line.
type Acc {
  Acc(
    chunks: List(String),
    pending_space: Bool,
    skip_depth: Int,
    line_start: Bool,
  )
}

fn empty() -> Acc {
  Acc(chunks: [], pending_space: False, skip_depth: 0, line_start: True)
}

fn finish(acc: Acc) -> String {
  acc.chunks
  |> list.reverse
  |> string.concat
  |> string.trim
}

fn step(acc: Acc, _line: Int, event: html_sax.Event) -> Acc {
  case event {
    html_sax.Start(name, attributes) -> start(acc, name, attributes)
    html_sax.End(name) -> end(acc, name)
    html_sax.Text(text) ->
      case acc.skip_depth > 0 {
        True -> acc
        False -> write_text(acc, text)
      }
    html_sax.Other -> acc
  }
}

fn start(acc: Acc, name: String, attributes: List(#(String, String))) -> Acc {
  case acc.skip_depth > 0 {
    True -> skip_start(acc, name)
    False ->
      case skips_content(acc, name) {
        True -> Acc(..acc, skip_depth: 1)
        False -> start_tag(acc, name, attributes)
      }
  }
}

/// Whether this start tag begins content to drop. `head` normally does, but
/// htmerl sometimes inserts one after leading text and puts that text's
/// following nodes inside it; a head that opens after output has started is
/// such an insertion, and its remaining contents still belong to the text.
fn skips_content(acc: Acc, name: String) -> Bool {
  case name {
    "head" -> acc.chunks == []
    _ -> is_skipped(name)
  }
}

fn end(acc: Acc, name: String) -> Acc {
  case acc.skip_depth > 0 {
    True -> skip_end(acc, name)
    False -> end_tag(acc, name)
  }
}

fn skip_start(acc: Acc, name: String) -> Acc {
  case is_skipped(name) {
    True -> Acc(..acc, skip_depth: acc.skip_depth + 1)
    False -> acc
  }
}

fn skip_end(acc: Acc, name: String) -> Acc {
  case is_skipped(name) {
    True -> Acc(..acc, skip_depth: acc.skip_depth - 1)
    False -> acc
  }
}

fn start_tag(
  acc: Acc,
  name: String,
  attributes: List(#(String, String)),
) -> Acc {
  case name {
    "br" -> hard_break(acc)
    "img" -> image_alt(acc, attributes)
    "li" -> acc |> line_break |> write_literal("• ")
    _ ->
      case is_block(name) {
        True -> line_break(acc)
        False -> acc
      }
  }
}

fn end_tag(acc: Acc, name: String) -> Acc {
  case name {
    "br" -> acc
    "td" | "th" -> mark_space(acc)
    _ ->
      case is_block(name) {
        True -> line_break(acc)
        False -> acc
      }
  }
}

fn image_alt(acc: Acc, attributes: List(#(String, String))) -> Acc {
  case attribute(attributes, "alt") {
    Ok(alt) -> write_text(acc, alt)
    Error(Nil) -> acc
  }
}

fn attribute(
  attributes: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  attributes
  |> list.find(fn(attribute) { attribute.0 == name })
  |> result.map(fn(attribute) { attribute.1 })
}

/// A block boundary: one newline, unless the output is already at the start
/// of a line, so adjacent blocks never produce a blank line.
fn line_break(acc: Acc) -> Acc {
  case acc.line_start {
    True -> Acc(..acc, pending_space: False)
    False ->
      Acc(
        chunks: ["\n", ..acc.chunks],
        pending_space: False,
        skip_depth: acc.skip_depth,
        line_start: True,
      )
  }
}

/// `br`: always a newline, even directly after another break.
fn hard_break(acc: Acc) -> Acc {
  Acc(
    chunks: ["\n", ..acc.chunks],
    pending_space: False,
    skip_depth: acc.skip_depth,
    line_start: True,
  )
}

fn write_literal(acc: Acc, text: String) -> Acc {
  Acc(
    chunks: [text, ..acc.chunks],
    pending_space: False,
    skip_depth: acc.skip_depth,
    line_start: False,
  )
}

/// Write character data, collapsing each whitespace run to one space and
/// dropping spaces that would begin a line.
fn write_text(acc: Acc, text: String) -> Acc {
  text
  |> string.to_graphemes
  |> write_graphemes(acc)
}

fn write_graphemes(graphemes: List(String), acc: Acc) -> Acc {
  case graphemes {
    [] -> acc
    [grapheme, ..rest] ->
      case is_whitespace(grapheme) {
        True -> write_graphemes(rest, mark_space(acc))
        False -> write_graphemes(rest, write_grapheme(acc, grapheme))
      }
  }
}

fn write_grapheme(acc: Acc, grapheme: String) -> Acc {
  case acc.pending_space {
    True ->
      Acc(
        chunks: [grapheme, " ", ..acc.chunks],
        pending_space: False,
        skip_depth: acc.skip_depth,
        line_start: False,
      )
    False ->
      Acc(
        chunks: [grapheme, ..acc.chunks],
        pending_space: False,
        skip_depth: acc.skip_depth,
        line_start: False,
      )
  }
}

fn mark_space(acc: Acc) -> Acc {
  case acc.line_start {
    True -> acc
    False -> Acc(..acc, pending_space: True)
  }
}

fn is_whitespace(grapheme: String) -> Bool {
  string.trim(grapheme) == ""
}

fn is_block(name: String) -> Bool {
  list.contains(
    [
      "p",
      "div",
      "h1",
      "h2",
      "h3",
      "h4",
      "h5",
      "h6",
      "ul",
      "ol",
      "table",
      "tr",
      "blockquote",
      "pre",
      "hr",
      "section",
      "article",
      "header",
      "footer",
      "dl",
      "dt",
      "dd",
    ],
    name,
  )
}

fn is_skipped(name: String) -> Bool {
  list.contains(
    ["script", "style", "head", "title", "noscript", "template"],
    name,
  )
}

/// Drop an unterminated trailing tag, the shape a byte-truncated document often
/// has: if there is no `>` after the last `<`, remove from that `<` onwards,
/// but only when it begins a named tag or declaration. A bare `</` is text to
/// the parser, not an unfinished tag, and trimming it would hide the failure
/// `</</` should report.
fn trim_open_tag(html: String) -> String {
  case string.split(html, "<") {
    [single] -> single
    parts ->
      case list.last(parts) {
        Ok(tail) ->
          case string.contains(tail, ">") || !starts_tag(tail) {
            True -> html
            False ->
              parts
              |> list.reverse
              |> list.drop(1)
              |> list.reverse
              |> string.join("<")
          }
        Error(Nil) -> html
      }
  }
}

fn starts_tag(fragment: String) -> Bool {
  case string.to_graphemes(fragment) {
    ["/", next, ..] -> is_ascii_letter(next)
    [first, ..] -> is_ascii_letter(first) || first == "!" || first == "?"
    [] -> False
  }
}

fn is_ascii_letter(grapheme: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
    grapheme,
  )
}
