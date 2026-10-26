//// Contract tests for `screwtape/html_text` (PHASE-03, T3a; EX-2, VT-1).
////
//// `convert` is pure and total: every input yields either the exact plain text
//// below or `Error(Nil)` (stored as `conversion_failed`). The truncation and
//// failure cases come from server-side truncation, which cuts bytes anywhere,
//// so the fold must never let a raw parser exception escape. Text-encoding
//// damage is deliberately not modelled: input arrives as a String already.

import gleam/string
import gleeunit
import gleeunit/should
import screwtape/html_text

pub fn main() -> Nil {
  gleeunit.main()
}

/// `convert` on input that must succeed; the exact text is the assertion.
fn text_of(html: String) -> String {
  let assert Ok(text) = html_text.convert(html)
  text
}

pub fn empty_input_test() {
  html_text.convert("") |> should.equal(Ok(""))
}

pub fn plain_text_passes_through_test() {
  text_of("Grüße ☃ 日本") |> should.equal("Grüße ☃ 日本")
}

pub fn whitespace_collapses_and_trims_test() {
  text_of("<p>  one \t two \n three  </p>\n") |> should.equal("one two three")
}

pub fn paragraph_blocks_test() {
  text_of("<p>a</p><p>b</p>") |> should.equal("a\nb")
}

pub fn adjacent_blocks_never_blank_line_test() {
  text_of("<div><p>a</p><h1>b</h1><section>c</section></div>")
  |> should.equal("a\nb\nc")
}

pub fn hr_is_its_own_line_test() {
  text_of("<p>a</p><hr><p>b</p>") |> should.equal("a\nb")
}

pub fn br_emits_line_break_test() {
  text_of("a<br>b") |> should.equal("a\nb")
}

pub fn br_twice_emits_blank_line_test() {
  text_of("a<br><br>b") |> should.equal("a\n\nb")
}

pub fn consecutive_br_are_not_merged_test() {
  text_of("a<br><br><br>b") |> should.equal("a\n\n\nb")
}

pub fn uppercase_tag_names_test() {
  text_of("<P>a</P><P>b</P>") |> should.equal("a\nb")
}

pub fn uppercase_br_test() {
  text_of("a<BR>b") |> should.equal("a\nb")
}

pub fn list_items_test() {
  text_of("<ul><li>one</li><li>two</li></ul>") |> should.equal("• one\n• two")
}

pub fn ordered_list_items_test() {
  text_of("<ol><li>one</li><li>two</li></ol>") |> should.equal("• one\n• two")
}

pub fn table_cells_share_a_line_test() {
  text_of("<table><tr><td>x</td><td>y</td></tr></table>") |> should.equal("x y")
}

pub fn table_header_cells_test() {
  text_of(
    "<table><tr><th>x</th><th>y</th></tr><tr><td>1</td><td>2</td></tr></table>",
  )
  |> should.equal("x y\n1 2")
}

pub fn image_alt_is_inline_text_test() {
  text_of("see <img src=\"x.png\" alt=\"pic\"> here")
  |> should.equal("see pic here")
}

pub fn image_without_alt_is_nothing_test() {
  text_of("see <img src=\"x.png\"> here") |> should.equal("see here")
}

pub fn link_text_kept_href_dropped_test() {
  let out = text_of("<p><a href=\"https://evil.example/x\">click</a></p>")
  out |> should.equal("click")
  string.contains(out, "evil.example") |> should.be_false
  string.contains(out, "http") |> should.be_false
}

pub fn entity_decoded_test() {
  text_of("a &amp; b &lt;c&gt; &#39;d&#39; &#x2014;")
  |> should.equal("a & b <c> 'd' —")
}

pub fn entity_named_quot_and_nbsp_test() {
  text_of("<p>&quot;hi&quot;</p>") |> should.equal("\"hi\"")
}

pub fn script_contents_dropped_test() {
  text_of("<p>a</p><script>var x = 1 < 2;</script><p>b</p>")
  |> should.equal("a\nb")
}

pub fn script_followed_by_text_test() {
  text_of("a<script>if (a < b) { evil() }</script>b") |> should.equal("ab")
}

pub fn style_and_head_contents_dropped_test() {
  text_of(
    "<head><title>T</title><style>p{ color: red }</style></head><body>hi</body>",
  )
  |> should.equal("hi")
}

pub fn leading_style_then_text_keeps_text_test() {
  text_of("<style>p{}</style>\nHello") |> should.equal("Hello")
}

pub fn leading_script_then_text_keeps_text_test() {
  text_of("<script>x</script>Hello") |> should.equal("Hello")
}

pub fn leading_style_then_text_with_br_test() {
  text_of("<style>p{}</style>Hello<br>world") |> should.equal("Hello\nworld")
}

pub fn literal_less_than_survives_test() {
  text_of("3 < 5 and 4 > 2") |> should.equal("3 < 5 and 4 > 2")
  text_of("x < y and more") |> should.equal("x < y and more")
}

pub fn template_and_noscript_dropped_test() {
  text_of("<p>a</p><template><p>t</p></template><noscript>n</noscript><p>b</p>")
  |> should.equal("a\nb")
}

pub fn truncated_inside_open_tag_test() {
  html_text.convert("<p>hello <a hre") |> should.equal(Ok("hello"))
}

pub fn truncated_inside_second_block_test() {
  html_text.convert("<p>one</p><p>two</a") |> should.equal(Ok("one\ntwo"))
}

pub fn truncated_after_entity_test() {
  // How a cut-off entity renders is unspecified; it must still yield text.
  text_of("a &am") |> string.starts_with("a") |> should.be_true
}

pub fn conversion_failed_on_junk_closers_test() {
  html_text.convert("</</") |> should.equal(Error(Nil))
}

pub fn conversion_failed_on_unclosed_table_cell_test() {
  html_text.convert("<table><tr><td>c") |> should.equal(Error(Nil))
}
