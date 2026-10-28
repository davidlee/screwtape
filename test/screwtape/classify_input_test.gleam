//// VT-3: the `read` line contract the classifier consumes (PHASE-12, T2).
////
//// The fixtures are the documents `render.read` printed, so decoding them is
//// the contract test: every `read-*.json` line must decode, `read-after-*`
//// holding several lines. A failure is a `Decode(path)` whose path names only
//// our own field names, question names, labels and list indices — never a key
//// or a value from the input.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/classify/input.{type Mail, MailBody}
import screwtape/error.{Decode}
import screwtape/file

pub fn main() -> Nil {
  gleeunit.main()
}

/// Every `read` fixture; the first six hold one line, the two `read-after`
/// files hold a page each.
const fixtures = [
  "read-StlqC78lBvpV.json",
  "read-StlqDajM7cCB.json",
  "read-StlqOgGOxrms.json",
  "read-StlqOs9L-c6V.json",
  "read-Stm7N6wH5vLs.json",
  "read-StmEQpYNhvr3.json",
  "read-after-1.json",
  "read-after-2.json",
]

/// One line of the read contract, every key `render.read` prints for the
/// fields the classifier reads.
const good_line =
  "{\"version\":1,\"kind\":\"read\",\"data\":{\"id\":\"M1\",\"cursor\":\"1:M1\",\"subject\":null,\"from\":[{\"name\":null,\"email\":\"a@b.example\"}],\"bodies\":[{\"part_id\":\"1\",\"source_type\":\"text\",\"text\":\"hi\",\"is_truncated\":false,\"truncated_by\":null,\"is_encoding_problem\":false,\"conversion_failed\":false}],\"attachments\":[{\"part_id\":\"2\",\"blob_id\":\"b\",\"name\":null,\"type\":\"text/plain\",\"size\":1,\"disposition\":null,\"cid\":null}],\"output_truncated\":false}}"

// ---------------------------------------------------------------------------
// The fixtures
// ---------------------------------------------------------------------------

pub fn every_read_fixture_decodes_test() {
  list.each(fixtures, fn(name) { should.be_true(decode_fixture(name) != []) })
}

pub fn output_truncated_fixture_test() {
  single("read-Stm7N6wH5vLs.json").output_truncated |> should.be_true
}

pub fn senders_come_from_from_test() {
  single("read-Stm7N6wH5vLs.json").senders
  |> should.equal(["b69e1c@example.com"])
}

pub fn attachment_is_type_and_optional_name_test() {
  single("read-StmEQpYNhvr3.json").attachments
  |> list.first
  |> should.equal(Ok(#("application/pdf", Some("Invoice-DCL6VRBU-8889.pdf"))))
}

pub fn bodies_carry_their_flags_test() {
  let assert [body, ..] = single("read-Stm7N6wH5vLs.json").bodies
  should.be_true(string.byte_size(body.text) > 0)
  body.is_truncated |> should.equal(False)
  body.conversion_failed |> should.equal(False)
}

// ---------------------------------------------------------------------------
// One line
// ---------------------------------------------------------------------------

pub fn line_decodes_the_read_contract_test() {
  let assert Ok(mail) = input.line(good_line)
  mail.id |> should.equal("M1")
  mail.cursor |> should.equal("1:M1")
  mail.subject |> should.equal(None)
  mail.senders |> should.equal(["a@b.example"])
  mail.bodies |> should.equal([MailBody("hi", False, False)])
  mail.attachments |> should.equal([#("text/plain", None)])
  mail.output_truncated |> should.be_false
}

pub fn not_json_is_the_root_path_test() {
  input.line("not json") |> should.equal(Error(Decode("$")))
}

pub fn wrong_version_test() {
  good_line
  |> string.replace("\"version\":1", "\"version\":2")
  |> input.line
  |> should.equal(Error(Decode("version")))
}

pub fn missing_version_test() {
  good_line
  |> string.replace("\"version\":1,", "")
  |> input.line
  |> should.equal(Error(Decode("version")))
}

/// Version is checked before kind: both wrong names the version path.
pub fn version_is_checked_before_kind_test() {
  good_line
  |> string.replace("\"version\":1", "\"version\":2")
  |> string.replace("\"kind\":\"read\"", "\"kind\":\"list\"")
  |> input.line
  |> should.equal(Error(Decode("version")))
}

pub fn wrong_kind_test() {
  good_line
  |> string.replace("\"kind\":\"read\"", "\"kind\":\"list\"")
  |> input.line
  |> should.equal(Error(Decode("kind")))
}

pub fn missing_field_test() {
  good_line
  |> string.replace("\"output_truncated\":false", "\"ignored\":false")
  |> input.line
  |> should.equal(Error(Decode("data.output_truncated")))
}

pub fn mistyped_nested_field_test() {
  good_line
  |> string.replace("\"text\":\"hi\"", "\"text\":42")
  |> input.line
  |> should.equal(Error(Decode("data.bodies[0].text")))
}

pub fn missing_nested_field_test() {
  good_line
  |> string.replace("\"is_truncated\":false,", "")
  |> input.line
  |> should.equal(Error(Decode("data.bodies[0].is_truncated")))
}

/// The path never quotes the input: an unknown key, an unknown nested key and
/// the values around the failing field are all sentinels, and none appears in
/// the error.
pub fn path_never_quotes_the_input_test() {
  let text =
    good_line
    |> string.replace(
      "\"data\":{",
      "\"UNKNOWN_KEY_SENTINEL\":\"UNKNOWN_VALUE_SENTINEL\",\"data\":{",
    )
    |> string.replace("\"id\":\"M1\"", "\"id\":\"ID_VALUE_SENTINEL\"")
    |> string.replace(
      "\"text\":\"hi\"",
      "\"PART_SENTINEL\":\"PART_VALUE_SENTINEL\",\"text\":42",
    )
  let assert Error(error) = input.line(text)
  error |> should.equal(Decode("data.bodies[0].text"))
  let inspected = string.inspect(error)
  list.each(
    [
      "UNKNOWN_KEY_SENTINEL",
      "UNKNOWN_VALUE_SENTINEL",
      "ID_VALUE_SENTINEL",
      "PART_SENTINEL",
      "PART_VALUE_SENTINEL",
    ],
    fn(sentinel) { string.contains(inspected, sentinel) |> should.be_false },
  )
}

// ---------------------------------------------------------------------------
// `lines`
// ---------------------------------------------------------------------------

pub fn lines_skips_blank_lines_and_the_trailing_newline_test() {
  input.lines("a\n\n  \nb\n") |> should.equal(["a", "b"])
}

pub fn lines_of_an_empty_string_is_no_lines_test() {
  input.lines("") |> should.equal([])
}

pub fn lines_keeps_whitespace_around_content_test() {
  input.lines(" a \n\t\n") |> should.equal([" a "])
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn fixture_text(name: String) -> String {
  let assert Ok(text) = file.read_text("test/fixtures/mail/" <> name)
  text
}

fn decode_fixture(name: String) -> List(Mail) {
  name
  |> fixture_text
  |> input.lines
  |> list.map(fn(line) {
    case input.line(line) {
      Ok(mail) -> mail
      Error(error) -> panic as { name <> ": " <> string.inspect(error) }
    }
  })
}

fn single(name: String) -> Mail {
  let assert [mail] = decode_fixture(name)
  mail
}
