//// Tests for `screwtape/cursor` (SL-003 PHASE-01; invariant C3).
////
//// One spelling per cursor: `parse` accepts only int64-canonical text, so
//// `+05:x`, `007:x` and `-0:x` are refused rather than read as 5, 7 and 0.

import gleam/list
import gleeunit
import gleeunit/should
import screwtape/cursor

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn of_builds_after_test() {
  cursor.of(5, "m1") |> should.equal(cursor.After(5, "m1"))
}

pub fn to_string_start_is_empty_test() {
  cursor.to_string(cursor.Start) |> should.equal("")
}

pub fn to_string_after_is_ms_colon_id_test() {
  cursor.of(1_700_000_000_000, "m1")
  |> cursor.to_string
  |> should.equal("1700000000000:m1")
}

pub fn round_trip_start_test() {
  cursor.Start
  |> cursor.to_string
  |> cursor.parse
  |> should.equal(Ok(cursor.Start))
}

pub fn round_trip_after_test() {
  [cursor.of(5, "m1"), cursor.of(-42, "x"), cursor.of(0, "-")]
  |> list.map(fn(c) { cursor.parse(cursor.to_string(c)) })
  |> should.equal([
    Ok(cursor.of(5, "m1")),
    Ok(cursor.of(-42, "x")),
    Ok(cursor.of(0, "-")),
  ])
}

pub fn round_trip_id_containing_colon_test() {
  cursor.of(5, "a:b")
  |> cursor.to_string
  |> cursor.parse
  |> should.equal(Ok(cursor.of(5, "a:b")))
}

pub fn parse_keeps_later_colon_in_id_test() {
  // Split at the first ':' only, so the rest belongs to the id.
  cursor.parse("5:a:b") |> should.equal(Ok(cursor.After(5, "a:b")))
}

pub fn parse_without_colon_is_refused_test() {
  cursor.parse("abc") |> should.equal(Error(Nil))
}

pub fn parse_empty_id_is_refused_test() {
  cursor.parse("5:") |> should.equal(Error(Nil))
}

pub fn parse_non_integer_is_refused_test() {
  cursor.parse("x:m1") |> should.equal(Error(Nil))
}

pub fn parse_empty_integer_is_refused_test() {
  cursor.parse(":m1") |> should.equal(Error(Nil))
}

pub fn parse_plus_sign_is_refused_test() {
  cursor.parse("+05:x") |> should.equal(Error(Nil))
}

pub fn parse_leading_zeros_is_refused_test() {
  cursor.parse("007:x") |> should.equal(Error(Nil))
}

pub fn parse_negative_zero_is_refused_test() {
  cursor.parse("-0:x") |> should.equal(Error(Nil))
}

pub fn parse_above_int64_max_is_refused_test() {
  cursor.parse("9223372036854775808:x") |> should.equal(Error(Nil))
}

pub fn parse_below_int64_min_is_refused_test() {
  cursor.parse("-9223372036854775809:x") |> should.equal(Error(Nil))
}

pub fn parse_int64_max_test() {
  cursor.parse("9223372036854775807:x")
  |> should.equal(Ok(cursor.After(9_223_372_036_854_775_807, "x")))
}

pub fn parse_int64_min_test() {
  cursor.parse("-9223372036854775808:x")
  |> should.equal(Ok(cursor.After(-9_223_372_036_854_775_808, "x")))
}
