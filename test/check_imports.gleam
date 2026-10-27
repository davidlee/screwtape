//// Structural purity check (PHASE-03, EX-6/VT-4): prove that the pure modules
//// cannot do I/O — invariant I5 — and that no source outside the JMAP request
//// builder names a JMAP method — invariant I6.
////
//// Accepted residual for I6: the literal scan sees whole literals only, so a
//// concatenated method name is not caught; the closed `Method` type and opaque
//// `Invocation` are the primary guard.
////
//// Not shipped: this lives under `test/` and is run by `just check-imports`.
//// The rules are pure and take their sources and a resolver as arguments, so
//// the tests can feed fixtures without touching the tree; only `main` reads
//// files, lists directories and exits.
////
//// The Gleam sources are hand-parsed rather than regex-based: the pinned
//// stdlib has no `gleam/regex`, and the patterns the rules need (an import
//// token, a quoted literal) are small enough to scan directly.
////
//// The Erlang wrapper is not scanned as text: a text scan can be fooled
//// (`'file':'read_file'(X)`, `fun file:read_file/1`, `apply(file, read_file,
//// [X])`), so the check reads the `imports` chunk of the compiled beam instead.
//// Every call a module can make appears there, the last as `erlang:apply/3`.

import gleam/int
import gleam/io
import gleam/list
import gleam/string
import screwtape/file

const erl_path = "src/screwtape_html_ffi.erl"

const erl_beam_path = "build/dev/erlang/screwtape/ebin/screwtape_html_ffi.beam"

const request_path = "src/screwtape/jmap/request.gleam"

const ffi_module = "screwtape_html_ffi"

/// Denied even when the module's package is allowed: `gleam/io` writes to
/// stdout/stderr, so a governed module must not reach it.
const denied_modules = ["gleam/io"]

/// Where an import goes: a module of this project, or another package.
pub type Origin {
  Local
  Package(String)
}

/// One broken rule. `describe` is the only rendering; the constructors carry
/// just enough to name the file and the offending token.
pub type Violation {
  MissingFile(path: String)
  UnresolvedImport(path: String, module: String)
  ForbiddenImport(path: String, module: String, origin: Origin)
  ExternalInPureModule(path: String)
  ExternalWrongTarget(path: String, target: String)
  RemoteCallNotAllowed(path: String, call: String)
  MethodNameLiteral(path: String, literal: String)
}

/// What a governed module may reach: local modules by name, and packages.
/// `html_sax` is the one governed module allowed to declare `@external`.
type Rule {
  Rule(
    path: String,
    local: List(String),
    packages: List(String),
    external: External,
  )
}

type External {
  NoExternal
  FfiOnly
}

const rules = [
  Rule("src/screwtape/model.gleam", [], ["gleam_stdlib"], NoExternal),
  Rule("src/screwtape/utf8.gleam", [], ["gleam_stdlib"], NoExternal),
  Rule(
    "src/screwtape/html_text.gleam",
    ["screwtape/html_sax"],
    ["gleam_stdlib"],
    NoExternal,
  ),
  Rule(
    "src/screwtape/normalise.gleam",
    ["screwtape/model", "screwtape/html_text", "screwtape/utf8"],
    ["gleam_stdlib"],
    NoExternal,
  ),
  Rule(
    "src/screwtape/retain.gleam",
    ["screwtape/model", "screwtape/normalise"],
    ["gleam_stdlib"],
    NoExternal,
  ),
  Rule(
    "src/screwtape/render.gleam",
    ["screwtape/model", "screwtape/utf8"],
    ["gleam_stdlib", "gleam_json"],
    NoExternal,
  ),
  Rule(
    "src/screwtape/html_sax.gleam",
    [],
    ["gleam_stdlib", "htmgrrrl"],
    FfiOnly,
  ),
]

/// All violations, in a stable order: missing files first, then per file.
pub fn check(
  gleam_sources: List(#(String, String)),
  erlang_imports: Result(List(#(String, String, Int)), Nil),
  resolve: fn(String) -> Result(Origin, Nil),
) -> List(Violation) {
  let missing_governed =
    rules
    |> list.filter(fn(rule) { !has_source(gleam_sources, rule.path) })
    |> list.map(fn(rule) { MissingFile(rule.path) })

  let import_violations =
    list.flat_map(gleam_sources, fn(source) {
      case list.find(rules, fn(rule) { rule.path == source.0 }) {
        Ok(rule) -> check_imports(rule, source.1, resolve)
        Error(Nil) -> []
      }
    })

  let external_violations =
    list.flat_map(gleam_sources, fn(source) {
      check_externals(source.0, source.1)
    })

  let literal_violations =
    gleam_sources
    |> list.filter(fn(source) { source.0 != request_path })
    |> list.flat_map(fn(source) { check_method_literals(source.0, source.1) })

  let erlang_violations = check_erlang_imports(erlang_imports)

  list.flatten([
    missing_governed,
    import_violations,
    external_violations,
    literal_violations,
    erlang_violations,
  ])
}

/// The human line for one violation, printed as `check-imports: <line>`.
pub fn describe(violation: Violation) -> String {
  case violation {
    MissingFile(path) -> path <> ": governed file is missing"
    UnresolvedImport(path, module) ->
      path <> ": import " <> module <> " resolves to no local module or package"
    ForbiddenImport(path, module, Local) ->
      path <> ": local import " <> module <> " is not allowed here"
    ForbiddenImport(path, module, Package(package)) ->
      path
      <> ": import "
      <> module
      <> " (package "
      <> package
      <> ") is not allowed here"
    ExternalInPureModule(path) ->
      path <> ": declares @external, but this module must be pure"
    ExternalWrongTarget(path, "") ->
      path <> ": @external names no Erlang module"
    ExternalWrongTarget(path, target) ->
      path
      <> ": @external names \""
      <> target
      <> "\", not \""
      <> ffi_module
      <> "\""
    RemoteCallNotAllowed(path, call) ->
      path <> ": remote call " <> call <> " is not htmgrrrl_ffi:sax/3"
    MethodNameLiteral(path, literal) ->
      path <> ": string literal \"" <> literal <> "\" names a JMAP method"
  }
}

fn has_source(sources: List(#(String, String)), path: String) -> Bool {
  list.any(sources, fn(source) { source.0 == path })
}

fn check_imports(
  rule: Rule,
  text: String,
  resolve: fn(String) -> Result(Origin, Nil),
) -> List(Violation) {
  text
  |> string.split("\n")
  |> list.filter_map(import_module)
  |> list.filter_map(fn(module) {
    case resolve(module) {
      Error(Nil) -> Ok(UnresolvedImport(rule.path, module))
      Ok(Local) ->
        case list.contains(rule.local, module) {
          True -> Error(Nil)
          False -> Ok(ForbiddenImport(rule.path, module, Local))
        }
      Ok(Package(package)) ->
        case list.contains(denied_modules, module) {
          True -> Ok(ForbiddenImport(rule.path, module, Package(package)))
          False ->
            case list.contains(rule.packages, package) {
              True -> Error(Nil)
              False -> Ok(ForbiddenImport(rule.path, module, Package(package)))
            }
        }
    }
  })
}

/// The module named by an `import` line, or `Error(Nil)`. A multi-line
/// `.{ ... }` import keeps its module on the first line, so the line is enough.
fn import_module(line: String) -> Result(String, Nil) {
  case string.starts_with(line, "import ") {
    False -> Error(Nil)
    True ->
      line
      |> string.drop_start(string.length("import "))
      |> string.trim_start
      |> take_module
      |> non_empty
  }
}

fn take_module(text: String) -> String {
  text
  |> string.to_graphemes
  |> take_while(is_module_char)
  |> string.concat
}

fn is_module_char(grapheme: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_/",
    grapheme,
  )
}

fn check_externals(path: String, text: String) -> List(Violation) {
  case list.find(rules, fn(rule) { rule.path == path }) {
    Error(Nil) -> []
    Ok(rule) -> {
      let lines =
        text
        |> string.split("\n")
        |> list.filter(fn(line) {
          !is_comment(line) && string.contains(line, "@external")
        })
      case rule.external {
        NoExternal ->
          case lines {
            [] -> []
            _ -> [ExternalInPureModule(path)]
          }
        FfiOnly ->
          list.filter_map(lines, fn(line) {
            case external_module(line) {
              Ok(target) ->
                case target == ffi_module {
                  True -> Error(Nil)
                  False -> Ok(ExternalWrongTarget(path, target))
                }
              Error(Nil) -> Ok(ExternalWrongTarget(path, ""))
            }
          })
      }
    }
  }
}

/// The first quoted string on an `@external(erlang, "mod", "fun")` line: the
/// Erlang module. Gleam writes the module first, so the first literal is it.
fn external_module(line: String) -> Result(String, Nil) {
  case string.split(line, "\"") {
    [_, module, ..] -> non_empty(module)
    _ -> Error(Nil)
  }
}

fn check_method_literals(path: String, text: String) -> List(Violation) {
  text
  |> string.split("\n")
  |> list.filter(fn(line) { !is_comment(line) })
  |> list.flat_map(fn(line) {
    line
    |> quoted_literals
    |> list.filter(is_method_name)
    |> list.map(fn(literal) { MethodNameLiteral(path, literal) })
  })
}

fn is_comment(line: String) -> Bool {
  string.starts_with(string.trim(line), "//")
}

/// `"Email/get"` or `"methodCalls"` (I6).
fn is_method_name(literal: String) -> Bool {
  case literal == "methodCalls" {
    True -> True
    False ->
      case string.split(literal, "/") {
        [method, verb] ->
          is_named_part(method, is_upper) && is_named_part(verb, is_lower)
        _ -> False
      }
  }
}

fn is_named_part(part: String, accept_head: fn(String) -> Bool) -> Bool {
  case string.to_graphemes(part) {
    [] -> False
    [head, ..rest] -> accept_head(head) && list.all(rest, is_letter)
  }
}

fn quoted_literals(line: String) -> List(String) {
  quoted(string.split(line, "\""), False, [])
}

fn quoted(
  parts: List(String),
  inside: Bool,
  acc: List(String),
) -> List(String) {
  case parts {
    [] -> list.reverse(acc)
    [part, ..rest] ->
      case inside {
        True -> quoted(rest, False, [part, ..acc])
        False -> quoted(rest, True, acc)
      }
  }
}

/// The wrapper's beam imports. `Error(Nil)` means the beam is missing or
/// unreadable, which is the same failure as a missing governed source.
fn check_erlang_imports(
  imports: Result(List(#(String, String, Int)), Nil),
) -> List(Violation) {
  case imports {
    Error(Nil) -> [MissingFile(erl_path)]
    Ok(imports) ->
      imports
      |> list.filter(fn(call) { !is_allowed_erlang_import(call) })
      |> list.map(fn(call) {
        RemoteCallNotAllowed(erl_path, erlang_import(call))
      })
  }
}

fn erlang_import(call: #(String, String, Int)) -> String {
  call.0 <> ":" <> call.1 <> "/" <> int.to_string(call.2)
}

/// The one call the wrapper is allowed to make, plus the two `get_module_info`
/// imports the compiler emits itself.
fn is_allowed_erlang_import(call: #(String, String, Int)) -> Bool {
  case call {
    #("htmgrrrl_ffi", "sax", 3) -> True
    #("erlang", "get_module_info", 1) -> True
    #("erlang", "get_module_info", 2) -> True
    _ -> False
  }
}

fn take_while(items: List(String), accept: fn(String) -> Bool) -> List(String) {
  case items {
    [] -> []
    [first, ..rest] ->
      case accept(first) {
        True -> [first, ..take_while(rest, accept)]
        False -> []
      }
  }
}

fn is_letter(grapheme: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
    grapheme,
  )
}

fn is_lower(grapheme: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyz", grapheme)
}

fn is_upper(grapheme: String) -> Bool {
  string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", grapheme)
}

fn non_empty(value: String) -> Result(String, Nil) {
  case value == "" {
    True -> Error(Nil)
    False -> Ok(value)
  }
}

// ---------------------------------------------------------------------------
// I/O: the only part `main` needs, and the only part the tests do not call.
// ---------------------------------------------------------------------------

pub fn main() -> Nil {
  let gleam_sources =
    gleam_sources()
    |> list.filter_map(read_source)

  let violations =
    check(gleam_sources, beam_imports(erl_beam_path), resolver(package_names()))

  case violations {
    [] -> io.println("check-imports: ok")
    _ -> {
      list.each(violations, fn(violation) {
        io.println_error("check-imports: " <> describe(violation))
      })
      halt(1)
    }
  }
}

fn read_source(path: String) -> Result(#(String, String), Nil) {
  case file.read_text(path) {
    Ok(text) -> Ok(#(path, text))
    Error(Nil) -> Error(Nil)
  }
}

/// A module is local when `src/<module>.gleam` exists; otherwise it belongs to
/// the first package whose `build/packages/<package>/src/<module>.gleam` does
/// (`gleam/erlang/process` is gleam_erlang, not stdlib: RV-001 F-24).
fn resolver(packages: List(String)) -> fn(String) -> Result(Origin, Nil) {
  fn(module) {
    case exists("src/" <> module <> ".gleam") {
      True -> Ok(Local)
      False ->
        list.find_map(packages, fn(package) {
          let path =
            "build/packages/" <> package <> "/src/" <> module <> ".gleam"
          case exists(path) {
            True -> Ok(Package(package))
            False -> Error(Nil)
          }
        })
    }
  }
}

@external(erlang, "check_imports_ffi", "gleam_sources")
fn gleam_sources() -> List(String)

@external(erlang, "check_imports_ffi", "package_names")
fn package_names() -> List(String)

/// The `imports` chunk of a compiled module, or `Error(Nil)` when the beam is
/// missing or unreadable.
@external(erlang, "check_imports_ffi", "beam_imports")
fn beam_imports(path: String) -> Result(List(#(String, String, Int)), Nil)

@external(erlang, "check_imports_ffi", "exists")
fn exists(path: String) -> Bool

@external(erlang, "check_imports_ffi", "halt")
fn halt(status: Int) -> Nil
