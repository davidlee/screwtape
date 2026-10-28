//// POL-002 guard (PHASE-14, EX-4; VT-2): real mail stays in
//// `PII_hidden_fixtures.local/`.
////
//// A fixed location plus an untested promise is not a boundary, so the policy
//// is pinned by mechanism: `.gitignore` ignores the folder's contents and
//// re-includes only the two agent notes, so nothing in there can be committed
//// by accident. These tests read that stanza as text (the pattern is present,
//// and the only negations naming the folder are the two notes) and then ask
//// git itself, through `support/subprocess`, whether a probe path inside the
//// folder is ignored and whether the notes are not. The probe need not exist:
//// `git check-ignore` answers from the patterns alone.
////
//// The rule sits below the doctrine-managed block, because `doctrine install`
//// rewrites everything between its markers.

import gleam/int
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/file
import support/subprocess

pub fn main() -> Nil {
  gleeunit.main()
}

/// The folder, its ignore rule and the two re-included notes (design § 9, § 10).
const folder = "PII_hidden_fixtures.local"

const stanza = "/PII_hidden_fixtures.local/*"

const note_agents = "!/PII_hidden_fixtures.local/AGENTS.md"

const note_claude = "!/PII_hidden_fixtures.local/CLAUDE.md"

/// The folder's contents are ignored: the rule the policy rests on.
pub fn gitignore_ignores_the_folder_test() {
  gitignore_lines() |> list.contains(stanza) |> should.be_true
}

/// Only the two notes come back. A third negation would re-include a fixture;
/// a missing one would hide the note that tells an agent the rules.
pub fn gitignore_negates_only_the_two_notes_test() {
  let negations =
    gitignore_lines()
    |> list.filter(fn(line) { string.starts_with(line, "!") })
    |> list.filter(fn(line) { string.contains(line, folder) })

  negations |> list.length |> should.equal(2)
  negations |> list.contains(note_agents) |> should.be_true
  negations |> list.contains(note_claude) |> should.be_true
}

/// git agrees with that text: probes inside the folder are ignored whatever
/// their extension or depth (so a broad negation such as `!*.md` is caught), so
/// only a `git add -f` could commit one, which POL-002 forbids.
pub fn probes_inside_the_folder_are_ignored_test() {
  ["probe.eml", "probe.json", "probe.md", "sub/probe.eml"]
  |> list.each(fn(name) {
    check_ignore(folder <> "/" <> name) |> should.equal(0)
  })
}

/// The notes are not ignored: exit 1 is "no rule matched".
pub fn agent_notes_are_not_ignored_test() {
  check_ignore(folder <> "/CLAUDE.md") |> should.equal(1)
  check_ignore(folder <> "/AGENTS.md") |> should.equal(1)
}

/// `git check-ignore -q`: 0 when the path is ignored, 1 when it is not. Any
/// other status is git refusing to answer (128 is fatal, 127 means no `git`),
/// and must never read as "not ignored".
fn check_ignore(path: String) -> Int {
  let record = unwrap(subprocess.run("git", ["check-ignore", "-q", path]))

  case record.exit_code {
    0 -> 0
    1 -> 1
    code -> {
      let reason = "git check-ignore exited " <> int.to_string(code)
      let detail = path <> ": " <> record.stderr
      panic as { reason <> " for " <> detail }
    }
  }
}

/// `.gitignore` as trimmed lines; a missing or unreadable file fails here,
/// never silently.
fn gitignore_lines() -> List(String) {
  let assert Ok(text) = file.read_text(".gitignore")
  text
  |> string.split("\n")
  |> list.map(string.trim)
}

fn unwrap(result: Result(a, subprocess.Failure)) -> a {
  case result {
    Ok(value) -> value
    Error(failure) -> {
      let message = subprocess.failure_message(failure)
      panic as message
    }
  }
}
