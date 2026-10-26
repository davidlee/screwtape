//// Contract tests for `screwtape/credential` (PHASE-10, D3; VT-5).
////
//// A token is read from a real file under a temporary directory, because the
//// module must not offer a test-only constructor: the only way to a `Token` is
//// the same `file:read_file/1` the unit uses. The secret is asserted through
//// `bearer` and through `string.inspect`, which is all a debug print could show.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/credential
import screwtape/error
import support/temp

pub fn main() -> Nil {
  gleeunit.main()
}

const secret = "SENTINEL-0123456789abcdef"

/// A namespaced secret: a `Credential("missing")` reason must never carry it.
const namespaced_secret = "SENTINEL-credential-0123456789"

pub fn missing_file_test() {
  let dir = temp.dir("credential-missing")
  let result = credential.read(dir, "fastmail")
  temp.remove_dir(dir)

  result |> should.equal(Error(error.Credential("missing")))
}

pub fn missing_credentials_directory_test() {
  let dir = temp.dir("credential-nodir")
  temp.remove_dir(dir)

  credential.read(dir <> "/nested", "fastmail")
  |> should.equal(Error(error.Credential("missing")))
}

pub fn empty_file_test() {
  let dir = temp.dir("credential-empty")
  let _ = write(dir, "fastmail", <<>>)
  let result = credential.read(dir, "fastmail")
  temp.remove_dir(dir)

  result |> should.equal(Error(error.Credential("empty")))
}

pub fn whitespace_only_file_empty_test() {
  let dir = temp.dir("credential-space")
  let _ = write(dir, "fastmail", bit_array.from_string("\n \t\r\n"))
  let result = credential.read(dir, "fastmail")
  temp.remove_dir(dir)

  result |> should.equal(Error(error.Credential("empty")))
}

pub fn non_utf8_file_missing_test() {
  let dir = temp.dir("credential-bytes")
  let _ = write(dir, "fastmail", <<0xff, 0xfe, 0x00>>)
  let result = credential.read(dir, "fastmail")
  temp.remove_dir(dir)

  result |> should.equal(Error(error.Credential("missing")))
}

/// Control bytes left after the trim (CR/LF, NUL, DEL) would reach the HTTP
/// header; the token is refused before any request exists.
pub fn control_bytes_invalid_test() {
  let dir = temp.dir("credential-control")
  let cases = [
    #("lf", "SENTINEL\nX"),
    #("cr", "SENTINEL\rX"),
    #("nul", "SENTINEL\u{0000}X"),
    #("tab", "SENTINEL\tX"),
    #("del", "SENTINEL\u{007F}X"),
  ]
  let results =
    list.map(cases, fn(c) {
      let _ = write(dir, c.0, bit_array.from_string(c.1))
      credential.read(dir, c.0)
    })
  temp.remove_dir(dir)

  results
  |> list.each(should.equal(_, Error(error.Credential("invalid"))))
}

pub fn readable_file_trailing_newline_trimmed_test() {
  let dir = temp.dir("credential-read")
  let _ = write(dir, "fastmail", bit_array.from_string(secret <> "\n"))
  let result = credential.read(dir, "fastmail")
  temp.remove_dir(dir)

  let assert Ok(token) = result
  credential.bearer(token)
  |> should.equal(#("authorization", "Bearer " <> secret))
}

pub fn readable_file_surrounding_whitespace_trimmed_test() {
  let dir = temp.dir("credential-trim")
  let _ =
    write(dir, "fastmail", bit_array.from_string("  \t" <> secret <> "  \n\n"))
  let result = credential.read(dir, "fastmail")
  temp.remove_dir(dir)

  let assert Ok(token) = result
  credential.bearer(token)
  |> should.equal(#("authorization", "Bearer " <> secret))
}

pub fn inspect_hides_secret_test() {
  let dir = temp.dir("credential-inspect")
  let _ = write(dir, "fastmail", bit_array.from_string(secret <> "\n"))
  let result = credential.read(dir, "fastmail")
  temp.remove_dir(dir)

  let assert Ok(token) = result
  let rendered = string.inspect(token)
  rendered |> string.contains(secret) |> should.be_false
  rendered |> should.equal("Token(//fn() { ... })")
}

/// The secret is not carried by an `Error` either, on any path a bad file can
/// take: `Credential` reasons are fixed strings.
pub fn error_reasons_do_not_carry_the_secret_test() {
  let dir = temp.dir("credential-errors")
  let _ = write(dir, "empty", bit_array.from_string("   \n"))
  let _ =
    write(
      dir,
      "bytes",
      bit_array.concat([
        <<0xff>>,
        bit_array.from_string(namespaced_secret),
        <<0xfe>>,
      ]),
    )
  let empty = credential.read(dir, "empty")
  let bytes = credential.read(dir, "bytes")
  let absent = credential.read(dir, "absent")
  temp.remove_dir(dir)

  let reasons =
    [empty, bytes, absent]
    |> list.map(fn(result) {
      let assert Error(error.Credential(reason)) = result
      error.to_json_line(error.Credential(reason))
    })
  string.join(reasons, "\n")
  |> string.contains(namespaced_secret)
  |> should.be_false
}

/// Erlang's `file:write_file/2` answers the bare atom `ok`, which has no Gleam
/// `Result` shape; the call's outcome is asserted where it matters, by reading
/// the file back through the code under test.
fn write(dir: String, name: String, content: BitArray) -> Nil {
  let _ = write_file(dir <> "/" <> name, content)
  Nil
}

@external(erlang, "file", "write_file")
fn write_file(path: String, content: BitArray) -> Dynamic
