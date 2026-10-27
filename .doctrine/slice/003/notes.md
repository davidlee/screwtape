# Notes SL-003: Screwtape read contract for M3 consumers

Durable per-slice scratchpad — tracked in git. The place to lift anything from a
disposable phase sheet (`.doctrine/state/.../phase-NN.md`) that must survive
`rm -rf` before the slice close-out audit harvests it.

## Harvest
<!-- single-copy: updated in place each harvest; ids only, never restated content -->
fresh-as-of: 2026-10-27 · plan (design locked, run rev 43) · 611e6d5

### Produced
- slice-003.md · research/research.md · design.md (sec-1..sec-10, incl. § 5.2 Published shape v1)
- DEC-027 · DEC-028 · DEC-029 · DEC-030 · DEC-031 · DEC-032 (accepted)
- RV-010 (design review, Opus adversarial): F-1..F-14 verified, concluded
- IDE-001 (classifier, separate, pipe-composed)

### Learned
- store has no change marker (design § 2; research F1/F2) → arrival cursor
- `query.prior` already owns the ids→messages loop (RV-010 F-1)
- Erlang `binary_to_integer` accepts `+05`/`007` (RV-010 F-5)

### Open
- satan:RFC-020 amendment draft (OQ-11 answered, D1 cursor, IDE-001 note) — due in plan as a phase; operator commits in satan
- no open QUE/ASM; IMP-001 declined for now (operator)

## Design

- 2026-10-27: research round by the orchestrator (no agents; `research/`).
- Inquiry: DEC-027 (CLI JSON contract), DEC-028 (arrival cursor), DEC-029
  (compatibility), DEC-030 (README + tests), DEC-031 (reader access), DEC-032
  (pipe surface; further query operations deferred until evidence of need).
- Operator direction during design: the IDE-001 classifier is separate and
  composes by pipe; IMP-001 declined for now.
- Review policy: adversarial-then-human. Codex unavailable, so the
  adversarial lane is an Opus subagent.

## Review passes

- RV-010 (Opus, adversarial): 11 findings (2 major) + 3 from a recheck of the
  amendments; all fixed in design and verified. Main changes: shared
  `message_ids`/`messages_of` with `prior` (POL-001); query keeps its own
  `Page` with an optional limit; canonical-only cursor parse; argv
  `Filters`/`Page` split; documented cursor limits (future dates, filters,
  account scope).
- **Further pass:** none needed for design. The remaining risk is in the
  implementation, not the shape: the cursor SQL predicate and paging (C2), the
  one-transaction `read --after` (C4), and argv precedence. A per-phase code
  review of the query and argv phases should probe those, using the C2/C4
  tests in design § 9 as the oracle.
