# Notes SL-003: Screwtape read contract for M3 consumers

Durable per-slice scratchpad — tracked in git. The place to lift anything from a
disposable phase sheet (`.doctrine/state/.../phase-NN.md`) that must survive
`rm -rf` before the slice close-out audit harvests it.

## Harvest
<!-- single-copy: updated in place each harvest; ids only, never restated content -->
fresh-as-of: 2026-10-28 · ready (plan committed, phases materialised) · f03c758

### Produced
- slice-003.md · research/research.md · design.md (sec-1..sec-10, incl. § 5.2 Published shape v1)
- DEC-027 · DEC-028 · DEC-029 · DEC-030 · DEC-031 · DEC-032 (accepted)
- RV-010 (design review, Opus adversarial): F-1..F-14 verified, concluded
- plan.toml / plan.md: PHASE-01..06; phase sheets materialised
- IDE-001 (classifier, separate, pipe-composed)

### Learned
- store has no change marker (design § 2; research F1/F2) → arrival cursor
- `query.prior` already owns the ids→messages loop (RV-010 F-1)
- Erlang `binary_to_integer` accepts `+05`/`007` (RV-010 F-5)
- render's check_imports allowlist must admit `screwtape/cursor` (plan PHASE-01 EX-4)
- `--max-bytes` caps body text only, per message; headers uncapped (PHASE-06 EX-1)

### Open
- satan:RFC-020 amendment draft — PHASE-06 EX-2; operator commits in satan (VH-1)
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

## Plan

- 2026-10-28: plan authored (234bef0), revised after a critical pass
  (13ab93f: store_test helper rename, C4 via the shared I8 helper, live
  check), status ready (86f70da). PHASE-06 EX-1 sharpened twice in session:
  what `--max-bytes` bounds (9f94ac7) and the raw-page rule for consumers
  that filter (f03c758).
- Client-design question (satan `mail_*`, operator agreed 2026-10-28):
  `mail_new` takes no exclude-id list. The late-arrival re-read and its
  dedup belong to the cursor holder, paging on Screwtape's raw page; a
  Screwtape `--exclude` waits for evidence (DEC-032).

## Execution posture (operator, 2026-10-28)

- Sub-orchestrator pattern: the main thread spawns one Opus orchestrator per
  1–2 phases, each kept under 250k context; it spawns quotient pi agents
  (`/pi-orchestrate`) or Anthropic subagents as needed.
- Opus or Sonnet workers only where earned; pi (deepseek-flash) is the
  default for bounded work.
- Operator questions only for significant, real decisions, and only through
  the main thread; otherwise use discretion and report afterwards.

## Execution

### PHASE-01 Cursor module — completed (b031ad8)

- `src/screwtape/cursor.gleam`: `parse` uses `string.split_once` at the first
  `:`, `int.parse`, then one guard: non-empty id, within int64, and the round
  trip `to_string(c) == text` (canonicality). Bounds are cursor-private
  consts; argv's `max_offset` untouched (EX-3).
- Purity: cursor rule added to `test/check_imports.gleam`; render allowlist
  gains `screwtape/cursor`. `check_imports_test`'s conforming-sources fixture
  needed a cursor entry (every governed path must be present, else
  `MissingFile`), plus one violation test for cursor.
- Passes: pi `implement` wrote `cursor_test.gleam` (red, 6 requests,
  $0.003, correct first time). Orchestrator wrote the module and the
  check_imports changes (cheaper than a brief).
- Gotcha: `doctrine slice verify-vt` reports UNATTRIBUTABLE until the phase is
  flipped `completed` — attribution reads the phase boundary
  (`code_start_oid`..`code_end_oid`) written at completion.

### PHASE-02 Bounded thread — completed

- `model.ThreadPage(total, entries)`; `query.thread(tx, id, limit)` reads all
  ids, `list.drop(ids, total - limit)` (stdlib `drop` treats n ≤ 0 as no-op),
  summaries only for kept ids; `render.thread(id, page)` adds `total`,
  `truncated`.
- argv: `limit_value` / `in_limit_range` hold the 1..500 range once;
  `parse_int_flag` now takes a value parser (`limit_value`, `offset_value`),
  not a predicate; `parse_max_bytes` generalised to `parse_sole_int_flag`,
  shared by `read --max-bytes` and `thread --limit`. `Verb.Thread(id, limit)`.
- Decision (orchestrator): `thread <id> extra` now reports
  `unknown_argument` (was `unexpected_argument`) — a consequence of sharing
  read's parser; still a usage error, never pinned (RV-011 F-2).
- Added beyond the VTs: `thread_defaults_to_the_last_fifty_entries_test`
  (51-id thread built inline from `listing()`; C6's default) and
  `thread_limit_usage_matches_list_limit_test` (EX-2 reason parity, RV-011
  F-3).
- C6 audit: changed existing expectations are render_test's thread test,
  cli_test:646 (removed from usage cases), `thread_marks_in_store_entries_test`
  data keys (+ total, truncated) and store_test's thread tests (signature).
  The last two were missing from EX-5; EX-5 amended in place (RV-011 F-1).
- **For /reconcile:** design § 9's C6 row has the same enumeration gap
  (RV-011 F-1, design-wrong); correct it there.
- Passes: pi `implement` red tests (15 req, $0.016; correct, slightly
  repetitive — orchestrator deduped store_test via `th1_page`/`th1_entries`);
  pi `implement` green (14 req, $0.017; correct first time; one redundant
  `int.max` and a shadowed `value` binding, both removed in refactor).
- Review RV-011 (Opus adversarial subagent, ~97k tokens): acceptable, 5
  findings (3 minor, 2 nit), all terminal; see the ledger. Gotcha: the
  subagent could not hand back directly (SubagentHandback failed); its report
  came via the main thread.

### PHASE-03 (charter 2)

- `query.Page = Newest(limit, offset) | Oldest(after: Cursor, limit:
  Option(Int))`; `ListQuery.page` replaces `limit`/`offset`. One builder:
  `list_sql(select, query)` = select <> `list_where` (the cursor is one more
  ANDed filter, `after_filter`) <> `page_sql` (order + bounds). `messages`
  and `pub message_ids` differ only in the select (POL-001);
  `select_message_ids_sql` deleted. `pub messages_of(tx, ids)` extracted
  from `prior`; `prior` = `message_ids(tx, whole_store_ascending())` +
  `messages_of`. `cli.list_document` maps argv to `Newest`.
- C6 audit: no existing expectation changed. store_test's construction
  syntax moved to `page: query.Newest(..)` (values byte-identical); local
  helper `messages_of` → `listed` (EX-6). `list`, `prior` suites unchanged.
- Fixture fact: `listing()`'s shared millisecond is **m4/m5**, not m5/m6.
  plan.toml VT-1 (PHASE-03 and PHASE-04) amended in place.
  **For /reconcile:** design § 9 C2 row says `m5`/`m6` and cites
  `snapshot_fixture.gleam:421`; correct it. handover.md:61 has the same slip.
- Negative controls (orchestrator, each fails ≥ 1 test): `>=` on ms; no tie
  arm; `id >=`; `id DESC` in the limited arm; a LIMIT on `None`; swapped bind
  order. The walk helper stops once it has more ids than the store holds, so
  a cursor that never advances fails rather than hangs.
- RV-012 F-1 (minor, fix-now): dropping `id ASC` from the Oldest order was
  masked by insertion order (SQLite breaks ORDER BY ties by scan order). The
  walk test now writes `listing()` in both message orders. Gotcha for
  PHASE-04's CLI walk: a tie test passes by accident unless the higher id is
  inserted first in one run.
- Research advisory drift (plan.md/plan.toml added after the stamp) judged
  benign; not refreshed.
- Passes: pi `implement` red tests (16 req, $0.020; correct; orchestrator
  added the walk's overrun guard); pi `implement` green (13 req, $0.015;
  correct first time, matched the brief exactly). Review RV-012 (Opus
  adversarial subagent, ~96k tokens): 1 finding; handback failed again,
  findings read off the ledger.
