//// Tests for `screwtape/utf8` (PHASE-06, T1; invariant I5).
////
//// The cut is by UTF-8 byte size but always between codepoints, so the cases
//// that matter are the fits and the near-fits around a multibyte sequence.
////
//// `utf8.spend` (SL-005 PHASE-01, VT-3) is the one shared budget helper:
//// `remaining` minus the text's UTF-8 byte size, floored at zero.

import gleeunit
import gleeunit/should
import screwtape/utf8

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn budget_larger_than_text_keeps_it_all_test() {
  utf8.prefix("hello", 100) |> should.equal("hello")
}

pub fn exact_fit_keeps_it_all_test() {
  utf8.prefix("hello", 5) |> should.equal("hello")
}

pub fn cut_before_a_multibyte_codepoint_test() {
  // "a" is one byte, "é" two: a budget of 2 cannot hold both.
  utf8.prefix("aé", 2) |> should.equal("a")
}

pub fn four_byte_emoji_fits_whole_test() {
  utf8.prefix("🙂", 4) |> should.equal("🙂")
}

pub fn four_byte_emoji_is_not_split_test() {
  utf8.prefix("🙂", 3) |> should.equal("")
}

pub fn budget_zero_yields_empty_test() {
  utf8.prefix("hello", 0) |> should.equal("")
}

/// A text smaller than the budget spends its own byte size.
pub fn spend_subtracts_a_smaller_text_test() {
  utf8.spend("hello", 10) |> should.equal(5)
}

/// An exact fit spends everything.
pub fn spend_exact_fit_leaves_nothing_test() {
  utf8.spend("hello", 5) |> should.equal(0)
}

/// A text larger than the budget floors at zero, never negative.
pub fn spend_a_larger_text_floors_at_zero_test() {
  utf8.spend("hello", 3) |> should.equal(0)
}

/// The spend is in UTF-8 bytes: "é" is two bytes, so it leaves eight of ten.
pub fn spend_counts_multibyte_text_in_bytes_test() {
  utf8.spend("é", 10) |> should.equal(8)
  utf8.spend("éé", 4) |> should.equal(0)
}

/// Nothing left stays nothing left.
pub fn spend_with_no_budget_left_test() {
  utf8.spend("hello", 0) |> should.equal(0)
  utf8.spend("", 0) |> should.equal(0)
}
