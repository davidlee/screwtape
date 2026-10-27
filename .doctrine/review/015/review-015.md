# Review RV-015 — reconciliation of SL-003

Adversarial-review ledger. Structured findings live in the sister
ledger toml; this prose companion carries the reviewer's framing.

## Brief

<!-- Pre-reading + lines of attack: what this review is probing, the invariants
     it must hold the subject to, and where the bodies are likely buried. Seeded
     at `review new`; the reviewer fills it before raising findings. -->

Mode: **conformance** (post-implementation, self-audit; `auditor` raises,
`author` responds, both driven by the audit seat). Surface: primary checkout,
`main` at 12a0202; whole delta 23ea700..12a0202 (six phases, solo-bound). Not a
dispatched slice, so there is no candidate branch.

Lines of attack:

- **Mechanical evidence.** `doctrine slice conformance 3` (16 undeclared, 0
  undelivered, 12 conformant at open) and the boundary registry behind it,
  `doctrine slice verify-vt 3`, `doctrine check gate`, `just check` (serial).
- **Design § 5.2 incl. Published shape v1.** cursor encoding and canonical
  parse (C3); argv grammar and precedence (`missing_after` →
  `offset_with_after` → `missing_max_bytes`; list refuses `--max-bytes`); query
  `Page`, the cursor predicate and ascending order, shared `message_ids` /
  `messages_of` with `prior` (POL-001); render `cursor`, `list` `after` form,
  `thread` `total`/`truncated`; `dispatch` → `Option(String)`.
- **Invariants C1–C6** against the § 9 evidence rows; C6 by diffing every
  existing test expectation 23ea700..HEAD over `test/`.
- **§ 10 Code Impact** against what git touched.
- **DEC-027…DEC-032** as recorded (`doctrine show DEC-NNN`) against design
  and code.
- **README § Contract** against render/argv output (field tables, bounds,
  cursor, usage codes).
- **Execution-time choices**: the charters' discretionary decisions (phase
  sheets, notes.md § Execution) and the in-place plan.toml criterion
  amendments (PHASE-02 EX-5, PHASE-03 VT-1, PHASE-04 VT-1).
- **VH-1** (operator commits the satan:RFC-020 amendment): operator reply in
  session 2026-10-28 "VH-1 done"; satan commit 79c6b7b read, not written.

## Synthesis

**Closure story.** SL-003 delivers what the design specifies. The contract is
the CLI JSON at envelope version 1 (DEC-027, DEC-029). The arrival cursor
over `(received_at_ms, id)` is held by the consumer and encoded only by
`screwtape/cursor`, which accepts canonical text only (DEC-028, C3). The pipe
surface is `list --after`, `read --after … --max-bytes` and `thread --limit`
(DEC-032). README § Contract documents it (DEC-030, DEC-031). The code
matches § 5.2 point by point:

- argv: the `Filters`/`Page` split; selection precedence
  `missing_after` → `offset_with_after` → `missing_max_bytes`; `list` refuses
  `--max-bytes`; one `limit_value`.
- query: one `list_sql` builder serves both `messages` and `message_ids`; the
  cursor predicate is ANDed with the filters, in ascending order; `prior` and
  `read --after` share `messages_of` (POL-001).
- render: `cursor` comes last among the summary fields; `list_after` prints
  the `after` form; `thread` prints `total` and `truncated`.
- cli: `dispatch` returns `Option(String)`, and `read_stream` runs inside
  one `read_store` (C4, I8).

Mechanical evidence:

- `just check`, run serially: 477 passed, no failures.
- `doctrine check gate`: exit 0.
- `doctrine slice verify-vt 3`: every VT passes for PHASE-01..06.
- `doctrine slice conformance 3`: 0 undelivered.

C6 holds semantically. Every removed line in `test/` from 23ea700 to HEAD is
either a listed change, an added-field change, or a refactor with
byte-identical expectations (F-4). The four phase code reviews (RV-011..014)
are concluded, and each carried negative controls.

VH-1 is satisfied. The operator stated "VH-1 done" in session on 2026-10-28,
relayed by the team lead. satan commit 79c6b7b ("RFC-020") changes
`.doctrine/rfc/020/rfc-020.{md,toml}`. It was read only; nothing was written
in satan. VA-1 (README tables) was re-checked independently here: every table
matches render apart from the thread row order (F-11, fixed).

**Findings.** No blocker and no major. All findings except two are text
drift in the design: an enumeration short (F-4), a fact wrong (F-5), a
statement superseded by RV-010 and never updated (F-7, F-8), or the design
contradicting itself (F-6). One is a decision record narrower than the
contract that cites it (F-9). The other two are bookkeeping:

- the selector registry misses six in-scope paths (F-1);
- the boundary registry misses one PHASE-04 commit (F-3).

**Standing risks** (accepted in design and documented in README, not new):

- the arrival cursor's four known limits: late arrival with an older
  `received_at`, filters not reopening passed positions, a future-dated
  message, and no account scope;
- `thread`'s new default limit of 50;
- `Oldest(limit: Some(n))` relies on argv's 1..500, since SQLite treats a
  negative LIMIT as none. It is pinned through the CLI (`invalid_integer`),
  not in query.

**Tradeoffs consciously accepted.**

- F-2: `.doctrine/**` lifecycle paths stay undeclared in conformance, as for
  SL-002.
- F-10: plan criterion texts were corrected in place with their ids kept,
  rather than appended. Next time, append.
- `thread <id> extra` now reports `unknown_argument`, not
  `unexpected_argument` (RV-011 F-2). Usage reasons outside the four new ones
  are not part of the published stdout contract.

**Route for a human reader.** argv (`parse_selection`) → cli (`read_stream`
inside one `read_store`) → query (`list_sql` = `list_where` + `after_filter` +
`page_sql`; `message_ids`, `messages_of`) → render (`read` per line). Tests:

- the C2 walk is `after_walks_the_whole_listing_in_ascending_order_test`,
  run with both insert orders;
- C4 is the two `cli_read_after_stream_serves_one_snapshot_*` tests;
- C1 checks line-for-line equality with `read <id> --max-bytes 7`.

Sources worth opening:

- `doctrine show DEC-028`: the cursor and its limits (F-9).
- `doctrine show DEC-032`: the pipe surface.
- `doctrine review show RV-011 -f F-1`: the C6 enumeration origin.

## Reconciliation Brief

### Per-slice (direct edit)
- **F-1 (selector registry; load-bearing).** `doctrine slice selector add 3
  --intent design-target src/screwtape.gleam test/check_imports.gleam
  test/screwtape/check_imports_test.gleam test/screwtape/store_test.gleam
  test/support/cli_fixture.gleam test/support/paging.gleam`. Mirror: design
  § 10 Code Impact gains rows (or extends the test row) for `src/screwtape.gleam`
  (stdout prose), `test/check_imports.gleam` +
  `test/screwtape/check_imports_test.gleam` (cursor purity rule),
  `test/screwtape/store_test.gleam`, `test/support/{cli_fixture,paging}.gleam`.
  Expected after: conformance undeclared = `.doctrine/**` only (F-2).
- **F-3 (boundary registry).** `doctrine slice record-delta 3 PHASE-04 --start
  3bd4f40 --end 25f96fa`, so 25f96fa's cli_test change is attributed to
  PHASE-04.
- **F-4.** design § 9 C6 row: add `cli_test`
  `thread_marks_in_store_entries_test` (data keys gain `total`, `truncated`;
  in-store items gain `cursor` via `summary_keys`) and store_test's thread
  tests (adapted to `query.thread(tx, id, limit)` / `ThreadPage`, values
  unchanged).
- **F-5.** design § 9 C2 row: "`m4`/`m5` sharing a millisecond,
  `snapshot_fixture.gleam:421`" (was `m5`/`m6`).
- **F-6.** design § 4 first bullet and § 5.2 (`"cursor": str /* opaque */`
  and the README-contract Cursor bullet): opaque, except that a consumer may
  read the integer before the first `:` for DEC-028's future-date guard;
  nothing else.
- **F-7.** design § 3 sqlight badarg bullet: the cursor module owns its int64
  bounds; argv's `--offset` keeps `max_offset` (RV-010 N-3).
- **F-8 (nit).** design § 5.2 "One limit parser": replace "through
  `parse_int_flag`, which already takes a validator" with "through
  `flag_value` (via `parse_value_flag`; `thread` via `parse_sole_int_flag`)".
  Optionally name the C1/C4 tests in § 9's rows (see Synthesis).

### Governance/spec (REV)
- **F-9.** DEC-028 (decision record): consequences gain the three RV-010
  limits — filters do not reopen passed positions; a future-dated
  `received_at` moves a cursor past later arrivals, consumers must not store
  a cursor whose ms part exceeds now + skew (the one sanctioned read of the
  cursor); the cursor is not scoped to an account. Elaboration, choice
  unchanged. Write it as `doctrine knowledge edit DEC-028` if reconcile's
  REV surface does not take knowledge records.
- No ADR, policy, standard or spec is contradicted. POL-001 holds: one
  selection path, one ids→messages loop, one limit range, one renderer.

### Off-surface (no reconcile write)
- F-10: plan.toml criteria; tolerated, ids immutable.
- F-11: README fixed in the audit commit.
- handover.md:61 (`m5/m6`): gitignored packet; ignore.
