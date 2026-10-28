//// Tests for the structural purity checker (PHASE-03, EX-6/VT-4).
////
//// Fixtures are inline values, never files: a .gleam fixture under `test/`
//// would be compiled as a module (`normalise` would collide with the real one),
//// and the checker only wants text. Each Erlang wrapper is represented by the
//// import list of its compiled beam — `Ok(imports)` or `Error(Nil)` for a beam
//// that is missing — because that is what the checker reads. A fixed resolver
//// table stands in for the build/packages tree, so the tests never depend on
//// what has been downloaded.

import check_imports.{
  type Beam, type Origin, Beam, Local, Package, check, describe,
}
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

const model_path = "src/screwtape/model.gleam"

const utf8_path = "src/screwtape/utf8.gleam"

const cursor_path = "src/screwtape/cursor.gleam"

const http_path = "src/screwtape/http.gleam"

const html_text_path = "src/screwtape/html_text.gleam"

const normalise_path = "src/screwtape/normalise.gleam"

const retain_path = "src/screwtape/retain.gleam"

const render_path = "src/screwtape/render.gleam"

const html_sax_path = "src/screwtape/html_sax.gleam"

const pii_path = "src/screwtape/pii.gleam"

const classify_input_path = "src/screwtape/classify/input.gleam"

const classify_state_path = "src/screwtape/classify/state.gleam"

const classify_schema_path = "src/screwtape/classify/schema.gleam"

const jev_path = "src/screwtape/jev.gleam"

const jev_client_path = "src/screwtape/jev/client.gleam"

const request_path = "src/screwtape/jmap/request.gleam"

const html_ffi_path = "src/screwtape_html_ffi.erl"

const pii_ffi_path = "src/screwtape_pii_ffi.erl"

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
import screwtape/utf8

pub fn normalise(x: String) -> String {
  x
}
"

const retain_source =
  "import screwtape/model
import screwtape/normalise

pub fn merge(x: String) -> String {
  x
}
"

const utf8_source =
  "import gleam/string

pub fn prefix(text: String, budget: Int) -> String {
  let _ = budget
  text
}
"

const cursor_source =
  "import gleam/string

pub fn to_string(id: String) -> String {
  string.append(\"\", id)
}
"

const http_source =
  "import screwtape/error

pub fn failure(reason: String) -> error.Error {
  error.Http(reason)
}
"

const render_source =
  "import gleam/json
import gleam/option.{type Option, None, Some}
import screwtape/cursor
import screwtape/model
import screwtape/utf8

pub fn envelope(kind: String, data: json.Json) -> String {
  let _ = kind
  let _ = data
  \"\"
}

pub fn subject_prefix(message: model.Message) -> Option(String) {
  case message.subject {
    Some(text) -> Some(utf8.prefix(text, 10))
    None -> None
  }
}
"

const html_sax_source =
  "import htmgrrrl

@external(erlang, \"screwtape_html_ffi\", \"sax\")
fn sax(html: String) -> Nil
"

const pii_source =
  "import gleam/string

@external(erlang, \"screwtape_pii_ffi\", \"replace\")
fn replace(text: String, pattern: String, replacement: String) -> String
"

const classify_input_source =
  "import screwtape/error

pub fn input(x: String) -> Result(String, error.Error) {
  Ok(x)
}
"

const classify_state_source =
  "import screwtape/classify/input
import screwtape/pii
import screwtape/utf8

pub fn build(x: String) -> String {
  let _ = input.input
  let _ = pii.replace
  utf8.prefix(x, 10)
}
"

const classify_schema_source =
  "import screwtape/jev

pub fn questions() -> List(jev.Question) {
  []
}
"

const jev_source =
  "import screwtape/error

pub fn reply(x: String) -> Result(String, error.Error) {
  Ok(x)
}
"

const jev_client_source =
  "import screwtape/credential
import screwtape/error
import screwtape/http
import screwtape/jev

pub fn ask(token: credential.Token) -> Result(String, error.Error) {
  let _ = token
  let _ = http.failure
  let _ = jev.reply
  Ok(\"\")
}
"

const html_ffi_imports = [
  #("erlang", "get_module_info", 1),
  #("erlang", "get_module_info", 2),
  #("htmgrrrl_ffi", "sax", 3),
]

const pii_ffi_imports = [
  #("erlang", "get_module_info", 1),
  #("erlang", "get_module_info", 2),
  #("re", "replace", 4),
]

/// The compiler's own exports, present in every beam.
const compiler_exports = [#("module_info", 0), #("module_info", 1)]

const html_ffi_exports = [#("sax", 3)]

const pii_ffi_exports = [#("replace", 3)]

type Beams =
  List(#(String, Result(Beam, Nil)))

/// The two wrapper entries the checker reads.
fn beams(html: Result(Beam, Nil), pii: Result(Beam, Nil)) -> Beams {
  [#(html_ffi_path, html), #(pii_ffi_path, pii)]
}

fn html_beam(imports: List(#(String, String, Int))) -> Beam {
  Beam(
    imports: imports,
    exports: list.append(html_ffi_exports, compiler_exports),
  )
}

fn pii_beam(imports: List(#(String, String, Int))) -> Beam {
  Beam(
    imports: imports,
    exports: list.append(pii_ffi_exports, compiler_exports),
  )
}

/// The package each fixture module resolves to: `gleam/erlang/process` is
/// gleam_erlang even though it starts with `gleam/` (RV-001 F-24).
fn resolve(module: String) -> Result(Origin, Nil) {
  case module {
    "gleam/option" | "gleam/string" | "gleam/list" | "gleam/io" ->
      Ok(Package("gleam_stdlib"))
    "gleam/json" -> Ok(Package("gleam_json"))
    "gleam/erlang/process" -> Ok(Package("gleam_erlang"))
    "htmgrrrl" -> Ok(Package("htmgrrrl"))
    "screwtape/model"
    | "screwtape/html_text"
    | "screwtape/html_sax"
    | "screwtape/utf8"
    | "screwtape/cursor"
    | "screwtape/normalise"
    | "screwtape/pii"
    | "screwtape/http"
    | "screwtape/credential"
    | "screwtape/classify/input"
    | "screwtape/classify/state"
    | "screwtape/classify/schema"
    | "screwtape/jev"
    | "screwtape/jev/client"
    | "screwtape/error" -> Ok(Local)
    _ -> Error(Nil)
  }
}

fn sources() -> List(#(String, String)) {
  [
    #(model_path, model_source),
    #(utf8_path, utf8_source),
    #(cursor_path, cursor_source),
    #(http_path, http_source),
    #(html_text_path, html_text_source),
    #(normalise_path, normalise_source),
    #(retain_path, retain_source),
    #(render_path, render_source),
    #(html_sax_path, html_sax_source),
    #(pii_path, pii_source),
    #(classify_input_path, classify_input_source),
    #(classify_state_path, classify_state_source),
    #(classify_schema_path, classify_schema_source),
    #(jev_path, jev_source),
    #(jev_client_path, jev_client_source),
  ]
}

fn erlang() -> Beams {
  beams(Ok(html_beam(html_ffi_imports)), Ok(pii_beam(pii_ffi_imports)))
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
  erlang_beams: Beams,
) -> List(String) {
  check(gleam_sources, erlang_beams, resolve)
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

pub fn utf8_importing_a_local_module_is_a_violation_test() {
  let utf8 =
    "import screwtape/model

pub fn prefix(text: String, budget: Int) -> String {
  let _ = budget
  text
}
"
  descriptions(with_source(sources(), utf8_path, utf8), erlang())
  |> should.equal([
    "src/screwtape/utf8.gleam: local import screwtape/model is not allowed here",
  ])
}

pub fn cursor_importing_a_local_module_is_a_violation_test() {
  let cursor =
    "import screwtape/model

pub fn to_string(id: String) -> String {
  id
}
"
  descriptions(with_source(sources(), cursor_path, cursor), erlang())
  |> should.equal([
    "src/screwtape/cursor.gleam: local import screwtape/model is not allowed here",
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

pub fn html_text_importing_gleam_io_is_a_violation_test() {
  let html_text =
    "import gleam/io
import screwtape/html_sax

pub fn convert(html: String) -> Result(String, Nil) {
  let _ = html
  Ok(\"\")
}
"
  descriptions(with_source(sources(), html_text_path, html_text), erlang())
  |> should.equal([
    "src/screwtape/html_text.gleam: import gleam/io (package gleam_stdlib) is not allowed here",
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
  descriptions(
    sources(),
    beams(Ok(html_beam(imports)), Ok(pii_beam(pii_ffi_imports))),
  )
  |> should.equal([
    "src/screwtape_html_ffi.erl: remote call file:read_file/1 is not allowed here",
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
  descriptions(
    sources(),
    beams(Ok(html_beam(imports)), Ok(pii_beam(pii_ffi_imports))),
  )
  |> should.equal([
    "src/screwtape_html_ffi.erl: remote call erlang:apply/3 is not allowed here",
  ])
}

pub fn pii_ffi_importing_anything_else_is_a_violation_test() {
  let imports = [
    #("erlang", "get_module_info", 1),
    #("erlang", "get_module_info", 2),
    #("re", "replace", 4),
    #("re", "split", 2),
  ]
  descriptions(
    sources(),
    beams(Ok(html_beam(html_ffi_imports)), Ok(pii_beam(imports))),
  )
  |> should.equal([
    "src/screwtape_pii_ffi.erl: remote call re:split/2 is not allowed here",
  ])
}

pub fn wrapper_exporting_more_than_it_may_is_a_violation_test() {
  let exports = list.append([#("sax", 3), #("leak", 0)], compiler_exports)
  descriptions(
    sources(),
    beams(
      Ok(Beam(imports: html_ffi_imports, exports: exports)),
      Ok(pii_beam(pii_ffi_imports)),
    ),
  )
  |> should.equal([
    "src/screwtape_html_ffi.erl: export leak/0 is not allowed here",
  ])
}

pub fn pii_wrapper_exporting_more_than_it_may_is_a_violation_test() {
  let exports = list.append([#("replace", 3), #("split", 2)], compiler_exports)
  descriptions(
    sources(),
    beams(
      Ok(html_beam(html_ffi_imports)),
      Ok(Beam(imports: pii_ffi_imports, exports: exports)),
    ),
  )
  |> should.equal([
    "src/screwtape_pii_ffi.erl: export split/2 is not allowed here",
  ])
}

pub fn exports_with_the_compilers_module_info_are_allowed_test() {
  check(sources(), erlang(), resolve) |> should.equal([])
}

pub fn pii_importing_a_local_module_is_a_violation_test() {
  let pii =
    "import screwtape/model

@external(erlang, \"screwtape_pii_ffi\", \"replace\")
fn replace(text: String, pattern: String, replacement: String) -> String
"
  descriptions(with_source(sources(), pii_path, pii), erlang())
  |> should.equal([
    "src/screwtape/pii.gleam: local import screwtape/model is not allowed here",
  ])
}

pub fn pii_external_naming_another_module_is_a_violation_test() {
  let pii =
    "import gleam/string

@external(erlang, \"file\", \"read_file\")
fn replace(text: String, pattern: String, replacement: String) -> String
"
  descriptions(with_source(sources(), pii_path, pii), erlang())
  |> should.equal([
    "src/screwtape/pii.gleam: @external names \"file\", not \"screwtape_pii_ffi\"",
  ])
}

pub fn missing_ffi_beam_is_a_violation_test() {
  descriptions(sources(), beams(Error(Nil), Error(Nil)))
  |> should.equal([
    "src/screwtape_html_ffi.erl: governed file is missing",
    "src/screwtape_pii_ffi.erl: governed file is missing",
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
