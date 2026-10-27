# Review RV-013 — code-review of SL-003

Adversarial-review ledger. Structured findings live in the sister
ledger toml; this prose companion carries the reviewer's framing.

## Brief

<!-- Pre-reading + lines of attack: what this review is probing, the invariants
     it must hold the subject to, and where the bodies are likely buried. Seeded
     at `review new`; the reviewer fills it before raising findings. -->

Subject: the PHASE-04 working-tree diff over 3bd4f40 — `cursor` in
`render.summary_fields`, `render.list_after`, argv `Filters` + `Page =
Offset | After` with `--after`, `cli.list_document` mapping, and the shared
`test/support/paging.walk`.

Lines of attack:
- C2 through the CLI as the oracle: does the CLI walk (both insertion orders,
  limit 1/2/500) actually fail when the order or the cursor is wrong?
  (Orchestrator negative controls: dropping `id ASC` fails 2 tests; dropping
  `offset_with_after` fails 1; `Oldest(limit: None)` fails 1.)
- argv precedence: `offset_with_after` only after every flag parses; bad
  cursor → `invalid_cursor` during the parse; repeated `--after`; reason codes
  carry no argument (DEC-011).
- Filters/Page split: no invalid state representable; fit for PHASE-05's
  `read --after` reuse (design § 5.2).
- C6: the only changed existing expectations are render_test field-order and
  cli_test summary_keys/read_keys (EX-4).
- POL-001: no parallel implementation (paging walker, flag parsers, list
  rendering, cli query construction).

## Synthesis

- **Overall**: solid (the adversary's verdict, from its late report).
- **Synopsis**: PHASE-04 publishes `cursor` on every summary and pages
  `list` by it. The argv split makes `--after` with `--offset` unrepresentable
  past the parse, and one value-flag parser now serves every `list` flag but
  `--unread`. C2 through the CLI is a real oracle: the walk runs in both
  insertion orders, and orchestrator negative controls (no `id ASC`, legal
  `--after`+`--offset`, unbounded `Oldest`) each fail a test. The two nits
  were fixed: the value-error-before-combination-error rule is now pinned by a
  `--since` case (F-1), and render's private builder no longer shares
  `cli.list_document`'s name (F-2). Standing note: render_test's dates carry
  `ms: 0`, so the cursor's ms is pinned only through cli_test. The adversary's
  handback failed; its verify and conclude acts were recorded by the
  orchestrator from the ledger. Adversary's discarded candidates: filter
  plus a mid-walk cursor untested through the CLI (store VT-1d covers the
  AND); render_test's `cursor_json` reusing `cursor.to_string` (cli_test's
  hand-built cursor and render's literal case are independent oracles).
  Post-review, from the RV-012 adversary: `--limit`'s 1..500 range under
  `--after` is now pinned in `list_after_usage_reasons_test` (SQLite reads a
  negative LIMIT as none).
- **Haiku**: past the last seen mail / one millisecond, two ids — / order
  breaks the tie.
