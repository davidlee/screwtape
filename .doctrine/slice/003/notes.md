# Notes SL-003: Screwtape read contract for M3 consumers

Durable per-slice scratchpad — tracked in git. The place to lift anything from a
disposable phase sheet (`.doctrine/state/.../phase-NN.md`) that must survive
`rm -rf` before the slice close-out audit harvests it.

## Harvest
<!-- single-copy: updated in place each harvest; ids only, never restated content -->
fresh-as-of: 2026-10-28 · close (reconciled c09d4dc)

### Produced
- slice-003.md · research/research.md · design.md · plan.toml / plan.md
- DEC-027 · DEC-028 · DEC-029 · DEC-030 · DEC-031 · DEC-032
- PHASE-01..06 (b031ad8..90e9808); code reviews RV-011 · RV-012 · RV-013 · RV-014
- RV-010 (design review) · RV-015 (audit; brief → /reconcile)
- satan:RFC-020 amendment — satan commit 79c6b7b (operator, VH-1)
- IDE-001 (classifier, separate, pipe-composed)

### Learned
- mem.fact.build.gleam-build-lock — `doctrine check gate` and `just check` must run serially
- mem.fact.doctrine.boundary-after-completed — a commit after the completed flip is unattributed (RV-015 F-3)
- store has no change marker (design § 2) → arrival cursor
- Erlang `binary_to_integer` accepts `+05`/`007` (RV-010 F-5) → canonical-only parse
- SQLite breaks ORDER BY ties by scan order: tie tests insert both orders (RV-012 F-1)
- plan criterion corrections: append, don't edit in place (RV-015 F-10)
- mem.pattern.doctrine.nested-review-handback — nested reviewers: ledger first, SendMessage fallback

### Open
- none from SL-003. RV-015 brief reconciled in c09d4dc (design § 3/4/5.2/9/10, selectors, PHASE-04 delta, DEC-028)
- IMP-001 declined for now (operator); no open QUE/ASM

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

### PHASE-04 (charter 3) — completed (1c2af41)

- argv: `ListArgs` → `Filters(mailbox, since_ms, from, unread)` + `Page =
  Offset(limit, offset) | After(limit, after: Cursor)`; `Verb.List(filters,
  page)`. `ListFlags.after: Option(Cursor)`. One flag parser,
  `parse_value_flag(rest, taken, parse, store, flags)`, now serves every
  `list` flag but `--unread` (`--mailbox`/`--since` with `Ok`, `--from` with
  `from_value`, `--limit`, `--offset`, `--after` with `cursor_value`);
  `parse_text_flag`/`parse_from_flag`/`parse_int_flag` deleted (POL-001).
  `parse_list` = `filters_of(flags)` then `page_of(flags)`: every value error
  (cursor, `--since`) beats `offset_with_after`, which beats nothing else
  (RV-013 F-1 pins the `--since` case).
- render: `summary_fields` appends `cursor`; `list_after(after:, limit:,
  items:)` beside `list`, both through private `list_body(position, limit,
  items)` (decision D-a: no render-side Page type, render cannot import argv
  or query, and `render.list`'s callers and test stay as they were).
- cli: `list_document(filters, page)` = `list_page(page)` (pure: argv page →
  `#(query.Page, document fn)`) + `list_query(tx, filters, query_page)`
  (resolves `--mailbox`, builds `ListQuery`). **For PHASE-05:** `read
  --after` should reuse `list_query(tx, filters, query.Oldest(after,
  Some(limit)))` and argv's `ListFlags`/`filters_of`; `page_of` is list's
  (it defaults the page), so the selection needs its own precedence step
  (missing_after → offset_with_after → missing_max_bytes) over the same flags.
- Test support (POL-001): store_test's walk lifted to
  `test/support/paging.walk(from:, page:, next:, bound:)`, used by store_test
  and cli_test; `snapshot_fixture.listing_ascending_ids()`;
  `cli_fixture.item_strings(document, key)` (`item_ids` calls it).
- C6 audit: changed existing expectations are render_test's `summary_json`
  field-order helper and the read literal (`cursor`), cli_test
  `summary_keys`/`read_keys`. Through `summary_keys`,
  `thread_marks_in_store_entries_test` also now expects `cursor` on in-store
  items — EX-1 requires it, and it rides the `summary_keys` constant EX-4
  names. render_test's list test was restructured onto shared
  `list_summaries()`/`list_items_json()` with byte-identical expectations.
  Note: render_test's `date()` sets `ms: 0`, so render tests pin the cursor's
  position and id but not its ms; cli_test's
  `list_items_carry_their_arrival_cursor_test` pins real ms.
- Negative controls (orchestrator, each restored): drop `id ASC` from the
  limited Oldest order → CLI and store walks fail; `--after` + `--offset`
  allowed → usage test fails; `Oldest(limit: None)` in cli → document-shape
  test fails (the walks alone would not catch it); `filters_of`/`page_of`
  swapped → usage test fails (after F-1's fix).
- Research advisory drift: same benign plan-file drift; not refreshed.
- Passes: pi `implement` test support + cli red tests (34 req, $0.049;
  correct; orchestrator replaced a hard-coded walk bound); pi `implement`
  render red tests (15 req, $0.013; correct; orchestrator deduped the two list
  tests' fixtures); pi `implement` green (21 req, $0.029; correct first time;
  orchestrator refactored cli's two query arms into `list_page` +
  `list_query` and collapsed the text/from flag parsers). Review RV-013 (Opus
  adversarial subagent, ~105k tokens): 2 nits, both fix-now; verdict solid;
  handback failed again, findings read off the ledger, report arrived late
  by message.
- Post-review (RV-012 adversary's late notes): SQLite treats a negative
  LIMIT as none, so `Oldest(limit: Some(n))` relies on argv's 1..500;
  `list --after "" --limit 0/-1/501` → `invalid_integer` now pinned. The `id`
  column has no COLLATE (byte order), so the cursor predicate and ORDER BY
  agree; no Gleam code orders ids (checked: no sort over ids in
  query/cli/render/argv).
- **For PHASE-05** (adversary's open questions): `--max-bytes` must join
  the closed `ListFlags` table and `list` must then reject it; pull the
  `offset_with_after` check out of `page_of` to share it; the pre-existing
  `parse_sole_int_flag` (read `--max-bytes`, thread `--limit`) repeats
  `parse_value_flag`'s steps — fold it in there.
- Gotcha: one `just check` run failed 30 token_leak tests with
  "erlang-shipment not found" right after `gleam export erlang-shipment`; an
  immediate rerun was green. Likely a concurrent build in the same tree.

### PHASE-05 (charter 4) — completed (d616d8f, 01e622a)

- argv: `Verb.ReadAfter(filters, after, limit, max_bytes)`; `read` with a
  first argument matching `"--" <> _` is the selection. `parse_selection` =
  `parse_list_flags` → `filters_of` → `required(after, "missing_after")` →
  `no_offset_with_after` (pulled out of `page_of`, shared) →
  `required(max_bytes, "missing_max_bytes")`; `--limit` defaults to 50.
  `ListFlags` gains `max_bytes` and `takes_max_bytes` (which grammar is
  reading); the `--max-bytes` arm is guarded by it, so `list` refuses the
  token as `unknown_argument` (RV-014 F-1 replaced a post-hoc check).
  `flag_value(args, taken, parse)` is now the one once-only value reader,
  used by `parse_value_flag` and `parse_sole_int_flag`; `value_flag` deleted.
- cli: `dispatch` → `Result(#(Option(String), List(String)), Error)`;
  single-document verbs go through a local `run_document` (wraps `Some`),
  `sync` returns `Some` itself. `read_stream` in one `read_store`:
  `account_id`, `list_query(tx, filters, Oldest(after, Some(limit)))`,
  `message_ids`, `messages_of`, `render.read(.., Some(max_bytes))` joined by
  `\n`; `[]` → `None`. `main`'s `write` needed no change.
- C6 audit: no existing expectation changed. The PHASE-04 walk test became
  `after_walks_the_whole_listing_in_ascending_order_test` (list and read
  pagers, both insert orders, same expectations); the I8 helper's third
  argument is now the B rewrite fn (existing callers pass `rewritten`).
- Tests: C1 is pinned as line-for-line equality with `read <id>
  --max-bytes 7`; filters as equality with `list --after`'s ids; C4 by two
  new I8 callers (B deletes / re-dates `-m1`).
- Negative control (orchestrator): a two-`read_store` stream fails both C4
  callers (deletion → `read_failed`; re-dating → changed cursor).
- Passes: pi `implement` red tests (21 req, $0.041; correct; mislabelled two
  test docs as C4, orchestrator fixed). Orchestrator wrote src (cheaper than
  a brief: the design was already the code). Review RV-014 (Opus
  adversarial subagent, ~94k tokens): 1 minor + 2 nits, all fix-now and
  verified; handback failed again, findings read off the ledger; verify acts
  and synthesis recorded by the orchestrator, noted on the ledger.
- Gotcha (orchestrator cost): calling `pi_agent_wait` several times in one
  turn returns the full result each time once the run settles — wait once.

### PHASE-06 (charter 4) — completed (90e9808); VH-1 satisfied

- README: CLI table (`list --after`, `read --after … --max-bytes`, `thread
  --limit`), stdout wording (one document, or `read --after`'s lines), the
  new usage codes, and § Contract (envelope, DEC-029 rule, six field tables,
  cursor and paging rule incl. the drop-after-reading case, line-delimited
  `read --after` with a paging pipe, bounds, DEC-028's four limits, DEC-031
  reader needs).
- VA-1: README tables checked mechanically against cli_test `summary_keys`,
  `read_keys`, the mailbox and thread key lists, and render's body,
  attachment and provenance keys: all match.
- VA-2: live, host store, freshly built erlang-shipment (the installed
  binary predates SL-003): `list --after '' --limit 5` → after/items/limit,
  5 items with `cursor`; continuation from the last cursor echoes it, 5
  more; `read --after '' --limit 3 --max-bytes 200` → 3 lines, each `read`
  v1 with 26 data keys and a cursor; `thread <id> --limit 1` →
  id/items/total/truncated, 1 item. Only shapes printed.
- satan:RFC-020 amendment drafted, uncommitted (`rfc-020.md`,
  `rfc-020.toml`): D1 consumer cursor (DEC-028) with known limits; D2 OQ-11
  answered (CLI JSON, reasons, DEC-029/030/032 bounds, DEC-031 reader needs,
  IDE-001 composing by pipe); D8 M3 names SL-003; Outcome: OQ-11 settled,
  open OQ-11 entry removed; toml `updated`. **VH-1 satisfied:** the operator
  committed it in satan as 79c6b7b and stated "VH-1 done" in session
  (2026-10-28, relayed by the team lead); the audit read satan only.
- Decision: README calls the cursor opaque except the DEC-028 future-date
  check (the ms before the first `:`) — "do not parse" would contradict it.
  **For /reconcile:** design § 5.2's "opaque" and DEC-028's consumer check
  pull the same way; say so in the design.
- Passes: pi `implement` README draft (19 req, $0.032; fields all correct;
  four prose corrections by the orchestrator).

## Audit (RV-015)

- 2026-10-28, conformance self-audit (`auditor`/`author`), primary checkout
  at 12a0202. Evidence: `just check` serial (477 pass), `doctrine check gate`
  exit 0, `verify-vt 3` all pass, conformance 0 undelivered. 11 findings, no
  blocker or major; all verified. Brief in review-015.md.
- F-11 fixed in the audit commit (README thread table row order).
- Gotcha: running `doctrine check gate` while `just check` ran in the
  background broke the build (argv_ffi.erl missing); a serial rerun was green.
- Phase-sheet harvest: the durable decisions and assumptions in
  `.doctrine/state/slice/003/phases/phase-0{1..6}.md` are already lifted into
  § Execution above: PHASE-02's parser shape, PHASE-03 D1, PHASE-04 D-a,
  PHASE-05 A1/D1 (superseded by RV-014 F-1) and PHASE-06 D1. Nothing further
  needs to survive the sheets.
