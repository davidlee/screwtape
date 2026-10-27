# Review RV-011 — code-review of SL-003

Adversarial-review ledger. Structured findings live in the sister
ledger toml; this prose companion carries the reviewer's framing.

## Brief

<!-- Pre-reading + lines of attack: what this review is probing, the invariants
     it must hold the subject to, and where the bodies are likely buried. Seeded
     at `review new`; the reviewer fills it before raising findings. -->

Scope: PHASE-01 (`b031ad8`, pure `screwtape/cursor`) and PHASE-02 (working
tree: bounded `thread`), diff `23ea700..` plus uncommitted. PHASE-01 has no own
review; it rides this one (plan.md § Notes).

Oracle: design § 9 — C3 (cursor round trip, canonical-only, int64), C5 (last
`min(limit, total)` entries; `truncated` iff dropped), C6 (only the listed
expectations change; `thread` defaults to 50).

Lines of attack:

- C3: can `parse` accept any text whose `to_string` differs, or crash on any
  input (unicode digits, whitespace, `-`, huge integers)?
- int64 bounds: in cursor only; argv `max_offset` untouched (RV-010 N-3).
- Purity: cursor held to gleam_stdlib, no @external; render allowlist.
- argv: one 1..500 range (`limit_value`), list behaviour unchanged; the
  generalised sole-int-flag parser keeps `read` identical; usage codes for
  thread `--limit`.
- query.thread: summaries read only for kept ids; limit/total arithmetic.
- C6: audit every changed existing test expectation against EX-5's list.
- Tests: would each survive a plausible wrong implementation?

## Synthesis

- **Overall**: acceptable.
- **Synopsis**: `screwtape/cursor` meets C3 (canonical-only round trip, int64
  bounds private to cursor, pure); the bounded `thread` meets C5 and C6 with
  the default of 50 tested (51-id inline thread). The reviewer's mutants
  (first-N, wrong default, `truncated` against `limit`, `total` = page length)
  are all caught. Five findings, no blocker or major: two fixed (reason parity
  test, named `offset_value`), one plan enumeration gap fixed in plan.toml with
  design § 9 routed to /reconcile, one deliberate reason-code change accepted,
  one key-order check tolerated under the suite's sorted-keys policy.
  Accepted tradeoff: `thread <id> extra` reports `unknown_argument` (was
  `unexpected_argument`) because thread now shares read's flag parser.
- **Haiku**: The last fifty stay — / colons kept within the id, / zeros turned away.
