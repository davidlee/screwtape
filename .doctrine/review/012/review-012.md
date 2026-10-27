# Review RV-012 — code-review of SL-003

Adversarial-review ledger. Structured findings live in the sister
ledger toml; this prose companion carries the reviewer's framing.

## Brief

<!-- Pre-reading + lines of attack: what this review is probing, the invariants
     it must hold the subject to, and where the bodies are likely buried. Seeded
     at `review new`; the reviewer fills it before raising findings. -->

Scope: PHASE-03, uncommitted working tree on `ed4e68e`: `src/screwtape/store/query.gleam`,
`src/screwtape/cli.gleam`, `test/screwtape/store_test.gleam`.

Oracle: design § 5.2 query and § 9 — C2 (a walk of oldest-first pages from
`Start` returns every message exactly once in `(received_at_ms, id)` order,
across a shared millisecond), C4 (`prior` through the shared `messages_of`),
C6 (no CLI behaviour change; no existing expectation changes).

Lines of attack:

- C2 predicate: `(received_at_ms > ? OR (received_at_ms = ? AND id > ?))`;
  argument binding order; SQLite text collation of `id` vs Gleam/order;
  NULL `received_at_ms`; LIMIT with filters.
- POL-001: one WHERE/ORDER builder for `messages` and `message_ids`.
- EX-1: query imports cursor, never argv; `Newest` unchanged.
- EX-4: `prior` order and behaviour unchanged.
- Tests: survive plausible wrong implementations? (orchestrator negative
  controls: `>=`, no tie arm, `id >=`, `id DESC`, LIMIT on `None`, swapped
  bind order: each fails ≥1 test.)
- Fixture tie is m4/m5 (design § 9 says m5/m6; plan VT text amended).

