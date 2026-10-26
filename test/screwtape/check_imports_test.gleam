//// Tests for the structural purity checker (PHASE-03, EX-6/VT-4).
////
//// Fixtures are inline values, never files: a .gleam fixture under `test/`
//// would be compiled as a module (`normalise` would collide with the real one),
//// and the checker only wants text. The Erlang wrapper is represented by the
//// import list of a compiled beam — `Ok(imports)` or `Error(Nil)` for a beam
//// that is missing — because that is what the checker reads. A fixed resolver
//// table stands in for the build/packages tree, so the tests never depend on
//// what has been downloaded.

import check_imports.{type Origin, Local, Package, check, describe}
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

const model_path = "src/screwtape/model.gleam"

const html_text_path = "src/screwtape/html_text.gleam"

const normalise_path = "src/screwtape/normalise.gleam"

const html_sax_path = "src/screwtape/html_sax.gleam"

const request_path = "src/screwtape/jmap/request.gleam"

const model_source =
  "import gleam/option.{type Option}

pub type Message {
  Message(id: String, at: Option(Int))
}
"

const html_text_source =
  "import gleam/string
import screwtape/html_sax

pub fn convert(html: String) -> Result(String, Nil) {
  let _ = html
  Ok(\"\")
}
"

const normalise_source =
  "import gleam/list
import screwtape/html_text
import screwtape/model

pub fn normalise(x: String) -> String {
  x
}
"

const html_sax_source =
  "import htmgrrrl

@external(erlang, \"screwtape_html_ffi\", \"sax\")
fn sax(html: String) -> Nil
"

const ffi_imports = [
  #("erlang", "get_module_info", 1),
  #("erlang", "get_module_info", 2),
  #("htmgrrrl_ffi", "sax", 3),
]

/// The package each fixture module resolves to: `gleam/erlang/process` is
/// gleam_erlang even though it starts with `gleam/` (RV-001 F-24).
fn resolve(module: String) -> Result(Origin, Nil) {
  case module {
    "gleam/option" | "gleam/string" | "gleam/list" ->
      Ok(Package("gleam_stdlib"))
    "gleam/erlang/process" -> Ok(Package("gleam_erlang"))
    "htmgrrrl" -> Ok(Package("htmgrrrl"))
    "screwtape/model"
    | "screwtape/html_text"
    | "screwtape/html_sax"
    | "screwtape/error" -> Ok(Local)
    _ -> Error(Nil)
  }
}

fn sources() -> List(#(String, String)) {
  [
    #(model_path, model_source),
    #(html_text_path, html_text_source),
    #(normalise_path, normalise_source),
    #(html_sax_path, html_sax_source),
  ]
}

fn erlang() -> Result(List(#(String, String, Int)), Nil) {
  Ok(ffi_imports)
}

fn with_source(
  sources: List(#(String, String)),
  path: String,
  text: String,
) -> List(#(String, String)) {
  list.map(sources, fn(source) {
    case source.0 == path {
      True -> #(path, text)
      False -> source
    }
  })
}

fn descriptions(
  gleam_sources: List(#(String, String)),
  erlang_imports: Result(List(#(String, String, Int)), Nil),
) -> List(String) {
  check(gleam_sources, erlang_imports, resolve)
  |> list.map(describe)
}

pub fn conforming_sources_have_no_violations_test() {
  check(sources(), erlang(), resolve)
  |> should.equal([])
}

pub fn conforming_ffi_imports_have_no_violations_test() {
  descriptions(sources(), erlang())
  |> should.equal([])
}

pub fn gleam_erlang_import_in_normalise_is_a_violation_test() {
  let normalise =
    "import gleam/erlang/process
import screwtape/model

pub fn normalise(x: String) -> String {
  process.sleep(0)
  x
}
"
  descriptions(with_source(sources(), normalise_path, normalise), erlang())
  |> should.equal([
    "src/screwtape/normalise.gleam: import gleam/erlang/process (package gleam_erlang) is not allowed here",
  ])
}

pub fn external_in_html_text_is_a_violation_test() {
  let html_text =
    "import screwtape/html_sax

@external(erlang, \"file\", \"read_file\")
fn read(path: String) -> Nil
"
  descriptions(with_source(sources(), html_text_path, html_text), erlang())
  |> should.equal([
    "src/screwtape/html_text.gleam: declares @external, but this module must be pure",
  ])
}

pub fn model_importing_error_is_a_violation_test() {
  let model =
    "import screwtape/error

pub type Message {
  Message
}
"
  descriptions(with_source(sources(), model_path, model), erlang())
  |> should.equal([
    "src/screwtape/model.gleam: local import screwtape/error is not allowed here",
  ])
}

pub fn html_text_importing_htmgrrrl_is_a_violation_test() {
  let html_text =
    "import htmgrrrl

pub fn convert(html: String) -> Result(String, Nil) {
  let _ = html
  Ok(\"\")
}
"
  descriptions(with_source(sources(), html_text_path, html_text), erlang())
  |> should.equal([
    "src/screwtape/html_text.gleam: import htmgrrrl (package htmgrrrl) is not allowed here",
  ])
}

pub fn method_name_literal_outside_request_is_a_violation_test() {
  let config =
    "const method = \"Email/get\"
const calls = \"methodCalls\"
"
  descriptions([#("src/screwtape/config.gleam", config), ..sources()], erlang())
  |> should.equal([
    "src/screwtape/config.gleam: string literal \"Email/get\" names a JMAP method",
    "src/screwtape/config.gleam: string literal \"methodCalls\" names a JMAP method",
  ])
}

pub fn method_name_literal_in_request_is_allowed_test() {
  let request =
    "const method = \"Email/get\"
const calls = \"methodCalls\"
// \"Email/set\" in a comment is not a literal
"
  check([#(request_path, request), ..sources()], erlang(), resolve)
  |> should.equal([])
}

pub fn ffi_imports_of_file_read_file_is_a_violation_test() {
  let imports = [
    #("erlang", "get_module_info", 1),
    #("erlang", "get_module_info", 2),
    #("file", "read_file", 1),
    #("htmgrrrl_ffi", "sax", 3),
  ]
  descriptions(sources(), Ok(imports))
  |> should.equal([
    "src/screwtape_html_ffi.erl: remote call file:read_file/1 is not htmgrrrl_ffi:sax/3",
  ])
}

pub fn ffi_imports_of_erlang_apply_is_a_violation_test() {
  // `apply(file, read_file, [X])` compiles to an import of `erlang:apply/3`,
  // which no text scan of the call site would show.
  let imports = [
    #("erlang", "get_module_info", 1),
    #("erlang", "get_module_info", 2),
    #("erlang", "apply", 3),
    #("htmgrrrl_ffi", "sax", 3),
  ]
  descriptions(sources(), Ok(imports))
  |> should.equal([
    "src/screwtape_html_ffi.erl: remote call erlang:apply/3 is not htmgrrrl_ffi:sax/3",
  ])
}

pub fn missing_ffi_beam_is_a_violation_test() {
  descriptions(sources(), Error(Nil))
  |> should.equal([
    "src/screwtape_html_ffi.erl: governed file is missing",
  ])
}

pub fn missing_governed_module_is_a_violation_test() {
  sources()
  |> list.filter(fn(source) { source.0 != html_sax_path })
  |> descriptions(erlang())
  |> should.equal(["src/screwtape/html_sax.gleam: governed file is missing"])
}

pub fn multi_line_import_is_parsed_test() {
  let model =
    "import gleam/option.{
  type Option,
}

pub type Message {
  Message(at: Option(Int))
}
"
  check(with_source(sources(), model_path, model), erlang(), resolve)
  |> should.equal([])
}
