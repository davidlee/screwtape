# Review RV-014 — code-review of SL-003

Adversarial-review ledger. Structured findings live in the sister
ledger toml; this prose companion carries the reviewer's framing.

## Brief

<!-- Pre-reading + lines of attack: what this review is probing, the invariants
     it must hold the subject to, and where the bodies are likely buried. Seeded
     at `review new`; the reviewer fills it before raising findings. -->

Subject: commit d616d8f (PHASE-05, read --after stream) over 25f96fa.
Depth: full per-phase pass (executing model below the adherence bar for the
red tests; orchestrator-written src).

Oracle: design § 9 C1 (stdout lines each a read envelope; empty → None),
C3 argv rows (missing_after / offset_with_after / missing_max_bytes and their
precedence), C4 (one snapshot / one transaction via the shared I8 helper
`cli_read_verb_serves_one_snapshot`). plan.toml PHASE-05 EX-1..EX-5, VT-1,
VT-2.

Lines of attack:
- One transaction: can any path in `read_stream` / `dispatch` read outside
  the single `read_store`? Would VT-2 catch a split? (Orchestrator ran a
  two-read_store negative control: both C4 tests failed.)
- argv precedence: value errors → missing_after → offset_with_after →
  missing_max_bytes; `list` refusing `--max-bytes` (D1: after flags parse,
  so a malformed value names its own error); `read --<anything>` routing.
- `--limit` 1..500 under the selection (SQLite negative LIMIT = none).
- Output framing: `\n` join, main's trailing newline, None vs Some("").
- Tests: theatre? would they pass against a plausible wrong implementation
  (ignored filters, wrong max_bytes, list order instead of ascending)?
- POL-001: duplication between `read_document` and `read_stream`, between
  `parse_list` and `parse_selection`; the `flag_value` fold.
- C6: no existing expectation may change.

## Synthesis

Written by the orchestrator (sl003-charter4) from the ledger: the adversary
subagent (Opus) raised and concluded on the ledger, but its hand-back failed,
so its verdict prose did not arrive.

- **Overall**: solid.
- **Synopsis**: The stream is one `read_store` over `list_query` →
  `message_ids` → `messages_of` → `render.read`, and the C4 guard bites: a
  two-`read_store` negative control failed both new I8 callers. C1 is pinned
  by line-for-line equality with `read <id> --max-bytes n`; filters by
  equality with `list --after`; the walk runs both verbs in both insert
  orders. The one real defect (F-1, minor) was the post-hoc `--max-bytes`
  refusal leaking the selection's grammar into `list`'s diagnostics; fixed by
  a `takes_max_bytes` grammar flag on `ListFlags`. F-2/F-3 were stale or wrong
  prose. No existing expectation changed (C6).
- **Haiku**: one snapshot held — / six lines leave the store at once; / the
  seventh flag, refused.
