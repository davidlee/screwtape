# Review RV-020 — reconciliation of SL-005

Adversarial-review ledger. Structured findings live in the sister
ledger toml; this prose companion carries the reviewer's framing.

## Brief

Mode: conformance. Surface: main worktree at ce0e899 (not dispatched).
Subject: SL-005 PHASE-01..03, commits 262925a..ce0e899.

Lines of attack:
- Design § 5.1–5.6 against `state.gleam`, `pii.gleam`, `utf8.gleam`,
  `cli.gleam` (`classify_mail`), `render.gleam` (`classify`, `classify_state`).
- Invariants I1 (state = strip of seen, one encoder), I2 (bounds on seen,
  nothing cut after stripping), I3 (state texts all stripped).
- Strip rule patterns byte-for-byte against § 5.4.
- README contract (Compatibility, field table, Bounds figure) against code.
- Governance: DEC-034 supersession, DEC-040 amendments, POL-002 wording,
  ASM-006 validation (VH-1).
- Mechanical: `slice conformance`, `slice verify-vt`, `doctrine check gate`,
  `nix develop -c just check`.

## Synthesis

SL-005 conforms to its locked design. The code under audit:

- `state.window` applies every § 5.3 bound once.
- `state.encode(w, text)` is the only encoder. `cli.classify_mail` calls it twice, once to make `seen` and once to make `state` (§ 5.5), so I1 holds by construction.
- `pii.strip`'s patterns match § 5.4 byte for byte.
- Both render lines carry `seen` in contract order.

Mechanical evidence:

- `slice conformance`: 18 conformant, 0 undelivered, 1 undeclared (the slice's own notes; F-8, tolerated).
- `slice verify-vt`: 12/12 pass.
- `doctrine check gate` and `nix develop -c just check`: green, 629 tests.

Findings and their routes:

- **Governance lags the code** (F-1, F-2). DEC-034 still reads as accepted, and POL-002 still calls the `--state` form PII-stripped. Both go to reconcile as REVs.
- **Design prose drift** (F-4, F-5). Both are direct edits.
- **Comment fixed in this audit** (F-6).
- **Settling ASM-006** (F-3) waits on the operator's confirmation of VH-1.

Standing risks, all accepted at design time and not reopened:

- More personal data now goes to typesafe.ai: names, local parts, all six lists, URL paths. README "What Jev sees" states this.
- Token-dense adversarial text can exceed Jev's 32k tokens. That message is skipped as `jev_context` and the consumer withholds it.
- The token rule misses short or hyphenated ids (§ 5.4).

Tradeoff accepted: a control-only body's `is_truncated` depends on whether body budget remains (F-7). This follows the design's literal rules and is documented.

## Reconciliation Brief

### Per-slice (direct edit)
- F-4 — design.md § 5.1: replace `Entry(name: Option(String), email: String)` / `List(Entry)` with the reused `input.Address(name, email)`.
- F-5 — design.md § 10: test row adds `jev_test.gleam` and `jev_client_test.gleam` (schema id rename).

### Governance/spec (REV)
- F-1 — DEC-034: superseded by DEC-044 (`doctrine supersede DEC-044 DEC-034`); DEC-036 and DEC-029: record DEC-040's amendment as a relation.
- F-2 — POL-002 Statement: REV modify. `classify` and `classify --state` output both carry the un-stripped `seen`; replace "its PII-stripped `classify --state` form" with wording that covers both lines.
- F-3 — ASM-006: settle as validated on VT-6 (worst case 72,373 B, ratio 1.52) and VH-1 (12,269 tokens, ~38% of 32k, no `jev_context`). Adversarial residual stays as stated. Operator confirmed VH-1 (2026-10-29).
