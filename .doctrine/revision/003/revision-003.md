# REV REV-003 — POL-002: real mail stays outside the repository

Revision — a pending revise-intent against authored governance/spec
truth. The structured `[[change]]` payload lives in the sister `revision-NNN.toml`;
this prose companion carries the rationale and the free-text before/after excerpts
for prose-body section edits.

## Rationale

<!-- Why this revision: what authored truth needs to change and why, the scope of
     the staged delta, and (for ADR/POL/STD/prose rows) the before/after excerpts
     the structured payload only labels. Seeded at `revision new`. -->

Operator ruling, 2026-10-29 ("yeah do it"): real, unscrubbed mail moves out
of the repository tree. A folder inside the repo is visible to pi workers
(the repo root is their cwd) and to any agent glob or grep, which could send
its contents to an external model. A gitignore rule protects git, not
agents.

- POL-002 title: "Real mail stays in PII_hidden_fixtures.local/" → "Real
  mail stays outside the repository".
- § Statement: the location becomes "outside the repository, by default
  `~/.local/state/screwtape/eval/` (the operator may choose another
  location outside the repository)". "Never committed. The folder is
  gitignored, and a test fails if it is not. Never `git add -f` …" →
  "Never in the repository. Never copy real mail into the repository tree,
  not even an ignored path." "Never quoted out", "Never sent elsewhere"
  and the scrubbed-fixtures carve-out are kept.
- § Rationale: adds the agent-visibility argument; drops "a tested ignore
  rule".
- § Scope: drops the folder notes (`PII_hidden_fixtures.local/CLAUDE.md`,
  `AGENTS.md`), retired with the folder.

Consequent non-REV edits (same commit): `PII_hidden_fixtures.local/`, its
`.gitignore` stanza, `test/screwtape/pol002_test.gleam` and the nix check's
`.gitignore`/`gitMinimal` inputs are removed; IMP-003, PROVENANCE.md and
SL-004 notes re-pointed.

Approval: the operator, reply "yeah do it" (2026-10-29) to the proposal
above; recorded by the sub-orchestrator on their behalf.
