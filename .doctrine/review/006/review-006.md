# Review RV-006 — code-review of SL-002

Adversarial-review ledger. Structured findings live in the sister
ledger toml; this prose companion carries the reviewer's framing.

## Brief

<!-- Pre-reading + lines of attack: what this review is probing, the invariants
     it must hold the subject to, and where the bodies are likely buried. Seeded
     at `review new`; the reviewer fills it before raising findings. -->

Subject: SL-002 PHASE-06 (incremental path, DEC-026), diff `fc0d1b3..3db888e`.
Raiser: Codex gpt-6.1-sol (high, read-only). Responder: Opus (adjudicates per /feedback).

Pin the code to:
- design § 5.4 (Choosing the path, Accumulating changes, Ids per run, Failure
  and retry) and § 5.5 invariants I-M1..I-M4; plan.toml PHASE-06 EX-1..EX-5,
  VT-1, VT-2.

Lines of attack:
1. Delta fold: `changed = (created ∪ updated) − destroyed` after all pages;
   last `newState` kept; page cap counts pages correctly (off-by-one).
2. Nothing-changed path: no Email/query, no Email/get with ids, carried
   query record, age bound still applied; "only destroyed" must still query
   (backfill, I-M1 `deletion_backfills_test`).
3. I-M3: stored Email state is the last `newState` on incremental, the
   opening state on full; a mid-run change is replayed next run.
4. I-M4: any failure after Email/changes leaves the store untouched.
5. Tests: behaviour not implementation; do the § 9 tests actually kill the
   plausible mutants (e.g. destroyed-loses, refresh all stored, skip query
   on destroyed-only, store opening state on incremental)?
6. Cohesion/DRY (POL-001): `Scope`/`Delta`/`changes` in sync.gleam vs
   existing `get_chunked`/`query_ids` paging; fixture growth vs a sibling
   harness (EX-4).
Out of scope: PHASE-09 fallbacks (interim `LimitExceeded("max_pages")` is
expected), CLI wiring (PHASE-07).

## Synthesis

- **Overall**: solid
- **Synopsis**: PHASE-06 adds the incremental path: `Start.Changes`, a
  `Scope` that settles what a run refreshes, and a `changes` fold into a
  `Delta`. The reviewer found the production fold, the nothing-changed skip,
  the stored Email state rule (I-M3) and the failure path (I-M4) correct
  against design § 5.4/§ 5.5. One minor test-confidence gap (F-1): three fold
  mutants (drop created, forget earlier changed, forget earlier destroyed)
  survived the suite, shown by execution. Two tests were added, each mutant
  now fails one of them; verified independently by both parties. Standing,
  by design: `hasMoreChanges` at the page cap is `LimitExceeded("max_pages")`
  until PHASE-09 turns it into the `too_many_changes` fallback.
- **Haiku**:
  Pages fold to one set —
  the last page empty, yet still
  e2 is gone.
