//// Tests for `screwtape/utf8` (PHASE-06, T1; invariant I5).
////
//// The cut is by UTF-8 byte size but always between codepoints, so the cases
//// that matter are the fits and the near-fits around a multibyte sequence.

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
