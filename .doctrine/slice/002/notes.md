# Notes SL-002: Screwtape M2: minimal incremental sync

Durable per-slice scratchpad — tracked in git. The place to lift anything from a
disposable phase sheet (`.doctrine/state/.../phase-NN.md`) that must survive
`rm -rf` before the slice close-out audit harvests it.

## Harvest
<!-- single-copy: updated in place each harvest; ids only, never restated content -->
fresh-as-of: 2026-10-27 · PHASE-09 (01-06, 08, 09 completed; 07 next) · 50ed117

### Produced
- RV-005 hostile pass (Codex) disposed, integrated; design run locked rev 37 (8173079)
- DEC-024 accepted; DEC-024/025/026 amended per RV-005 (8173079, 176932c)
- plan.toml/plan.md: 9 phases, order 01-02-03-04-05-08-06-09-07 (68f52ce..5b4e7e7)
- POL-001 · EVD-001 · DEC-025 · DEC-026 · CHR-004 · design.md (sec-1..sec-10)
- code: PHASE-01 90c37b1 · 02 2b6f47b · 03 108994b · 04 54885c7 · 05 d15afc9 · 08 fc0d1b3 · 06 3db888e..9564d91 · 09 59be0ae..50ed117
- RV-006 (PHASE-06, Codex) done; RV-007 (PHASE-09, fresh Opus) done
- CHR-004 opening_entries guard recorded done (108994b)
- per-phase passes + review dispositions: § Execution passes (below)

### Learned
- mem.fact.jmap.fastmail-email-changes — EVD-001's Fastmail Email/changes behaviour
- mem.fact.doctrine.design-section-order — design section ordering
- mem.pattern.testing.sync-mutant-killing-fixtures — paging/budget tests that kill mutants
- pi form: no nix/curl/perl — `nix flake check` is the orchestrator's (§ Execution passes)
- sync fixture gotchas (expect_unchanged probe commit; spec bounds) — § PHASE-06 notes

### Open
- PHASE-07 done (VH-1 passed live); next `/audit`
- Thread/get ids now sorted, not first-seen (M1 A8 superseded) — reconcile at audit (§ PHASE-08 decisions)
- PHASE-02 phase delta tightened past foreign commit 0103779 (DEC-013) — check at audit
- unpinned by design: method-name guard; cannotCalculateChanges on a later page — § PHASE-09 notes
- RV-005 — optional raiser verify/contest round not run
- api_url as server identity — a Fastmail apiUrl change costs one full refetch
- satan:RFC-020 D8 amendment draft — at close
- research/ untracked and drifted (`doctrine slice research 2`) — operator to decide
- CHR-004 — remaining items stay open

## Design triage (2026-10-27, exploring)

**Constraining governance:**
- POL-001 (DRY, required).
- DEC-007: the schema is M2-ready.
- DEC-008: one atomic write per run.
- ISS-001: the Email and Thread states are taken by the opening request.
- satan:RFC-020 D7 and D8, and OQ-10 and OQ-11. These are evidence, not
  binding.

**Shaping decisions already made (operator, 2026-10-27):**
- Option B: incremental sync through `Email/changes`, with no `queryChanges`
  and no `Mailbox/changes`.
- `retain_messages` is separate from the fetch `max_messages`.
- The full path fetches the `Email/query` ids together with the stored ids.
- One pure merge serves both paths, and every commit goes through the
  unchanged `write_snapshot`.
- The fallback triggers are: no stored state, `cannotCalculateChanges`, a
  `window_json` mismatch, and `hasMoreChanges` still true at the page cap.
- Phases stay small, each phase is reviewed, and test discipline is strict.

**Open questions:** these are the run's inquiries, listed under the design
run (`doctrine design show --format prompt 2`).

**Risks:**
- The `Email/changes` semantics (research J1–J7) are recalled from the RFCs,
  not probed. The biggest is J5: a mailbox move must be reported as an Email
  update.
- `receivedAt` ties at the retention boundary.
- A write, load and rewrite round trip must leave the store unchanged.

**Assumptions:**
- Rewriting the whole retained set on every run is cheap: about 12 KB per
  message, all local.
- Fastmail keeps its change log long enough that `cannotCalculateChanges` is
  rare.

## GPT design review (2026-10-27, inquiring)

Informal critical review by Codex (gpt-6.1-sol, high effort) of DEC-022..024,
EVD-001, the inquiry notes, the scope, the research and the sync/store/config
code. Eight findings, each verified against the code and adjudicated
(`/feedback`); the operator accepted the dispositions.

- **Blocker (integrated):** local window selection never backfilled after a
  deletion (store `[A,B]`, server `[A,B,C]`, delete A → incremental `[B]`,
  full `[B,C]`). Retention only postpones it. With `retain_messages` set,
  "newest `max_messages`" also included messages past `max_age_days`. The
  research refresh's "count-capped divergence no longer applies" was wrong;
  the research file is left as is (untracked, operator to decide).
- **Redesign:** `Email/query` decides window membership and `Email/changes`
  decides which stored ids get a light refresh. A run with no changes skips
  the query. DEC-025 supersedes DEC-022 (invariant over the window filter);
  DEC-026 supersedes DEC-023. This also removes body fetches for changed
  messages outside the window, and sets a finite `maxChanges`.
- **Integrated (minor):** the `Prior` is discarded when the account or
  `max_body_bytes` differs; resolved mailbox ids join `window_json` as a
  fallback trigger; a no-change run carries the previous query record.
- **Contested prescription:** the `cannotCalculateChanges` bytes are dropped
  from the budget (verified: `client.gleam:103-114`, `decode.gleam:711`).
  Accepted as a documented bounded overspend (≤ about 2× `max_total_bytes`)
  instead of changing the client API.
- **Tests (inq-8 revised):** explicit expectations beside the comparison
  tests; generalise `expect_unchanged` (`sync_fixture.gleam:372`).
- Codex's full output: the session scratchpad `codex-out.json` (not kept).
- Next: sufficiency-accepted is again the operator's act, then drafting.

## Further review passes (2026-10-27, reviewing, after RV-005)

RV-005 (hostile pass, Codex as raiser on a fresh thread) is concluded and every
finding is disposed on the ledger; dispositions and repairs live there
(`doctrine review show RV-005`), not here. DEC-024/025/026 were amended to
match.

What a further pass would probe, if the operator wants one:

- the raiser's verify/contest round on RV-005 (resume the same Codex thread),
  chiefly the partly contested F-6 and the declined tests in F-2/F-3;
- whether `api_url` is a stable enough server identity (Fastmail could change
  its `apiUrl` without a server change; the cost would be one full refetch).

Otherwise none is needed: the remaining uncertainty is runtime behaviour
(concurrent changes, budget arithmetic), which the § 9 tests and the live check
settle better than another reading.

## Execution passes (orchestrated; /pi-orchestrate)

Form probe (2026-10-27): the pi `write` form has gleam, erl, just, git, sqlite3,
rg; **no nix, no curl, no perl**. `nix flake check` is always the orchestrator's.

| phase | step | who / profile | cost USD | outcome |
|---|---|---|---|---|
| 01 | phase-plan | pi `implement` | 0.016 | sound sheet; missed that `nix/module-eval.nix:296,307` compare the whole `.window` object (orchestrator amended scope) |
| 01 | implement | pi `implement` | 0.018 | green first pass; red evidence given; no deviations |
| 01 | review (VA-1) | pi `review` | 0.021 | 5 findings: 1 accepted, 1 kept as is, 3 rejected (below) |
| 02 | phase-plan | pi `implement` | 0.025 | thorough sheet; proposed copying a Message builder (POL-001) and stopping on a needed check_imports_test fixture row; both overridden by amendments at the sheet's top |
| 02 | implement | pi `implement` | 0.043 | green first pass; read the top-of-sheet amendments correctly; sensible deviations reported |
| 02 | review (VA-1) | Opus (orchestrator) | — | 4 findings, all fixed (below); negative controls: `>=`→`>` and filter-before-refresh each fail one test |
| 03 | phase-plan | pi `implement` | 0.031 | good sheet; "scope surprises" at the top worked; S1 misread EN-1; proposed a hand length check where `list.strict_zip` exists |
| 03 | implement | pi `implement` | 0.044 | green first pass; shared `get_page_decoder` (POL-001) as briefed |
| 03 | review (VA-1) | pi `review` | 0.028 | 7 findings, all accepted; caught the false doc the orchestrator also saw |
| 03 | fixes | pi `implement` (same session) | 0.017 | 9 items (7 review + 2 orchestrator) applied, green |
| 04 | phase-plan | pi `implement` | 0.024 | 5 scope surprises, all useful; orchestrator settled them in amendments |
| 04 | implement | pi `implement` | 0.029 | green first pass; followed amendments |
| 04 | review (VA-1) | pi `review` | 0.021 | 5 findings: 4 fixed by orchestrator, 1 noted; negative control (swap bool columns) fails one test |
| 05 | plan + implement + review | Opus | — | behaviour-preserving; sync_test diff is 3 lines (summary fields only, VA-1); `get_threads` deliberately not on `get_chunked` (no `notFound` contract; would add `all_answered`) |
| 08 | plan + implement | Opus | — | code before tests (TDD order not kept); compensated by 7 negative controls, each killed |
| 08 | review (VA-1) | Codex gpt-6.1-sol, high, read-only | — | 3 minor findings, all accepted and fixed red-first; Codex's 2 named surviving mutants now killed |
| 06 | plan + implement | Opus | — | red-first (9 tests red for the right reason); green at 421; 7 negative controls each killed |
| 06 | review (VA-1) | Codex gpt-6.1-sol, high, ledger RV-006 | — | 1 minor (F-1), fix-now; 2 tests added, 3 fold mutants killed; green at 423; RV-006 done |
| 09 | plan + implement | Opus | — | red-first (3 red at the Email/changes stop; EX-3 test green by construction); green at 427; 6 negative controls each killed |
| 09 | review (VA-1) | Opus subagent (fresh context), ledger RV-007 | — | 1 minor + 2 nits, all fix-now; pages-uncharged mutant (survived since PHASE-06) now killed; green at 428 |
| 07 | phase-plan | Opus | — | sheet with amendments A1-A5 at the top (load order, shared `read_store`, named `prior_or_none`, README and nix are the orchestrator's) |
| 07 | implement (cli + tests) | pi `implement` | 0.045 | green first pass (430); red evidence for T1-T3 correct; followed A1-A3; no negative controls (not briefed) |
| 07 | README + nix doc | Opus | — | sync section; `maxPages` now also bounds `Email/changes` (README table + module description) |
| 07 | negative controls | Opus | — | 4 mutants (Prior dropped, all errors→None, mode names swapped, reason always null), each killed by exactly one test |

PHASE-01 review dispositions:
- F1 "out-of-scope edit to module-eval.nix" (major) — rejected: the reviewer
  missed the sheet's orchestrator amendment.
- F2 no explicit-`null` decode test (minor) — accepted; assertion added to
  `retain_messages_decoded_test`.
- F3 "invalid relation fails only at timer run" — rejected: the module parses
  the generated config at build time (`nix/module-eval.nix:131`).
- F4 `///` vs `//` — rejected: the file uses `///` for doc comments.
- F5 `case` vs boolean `check` — kept as is (legible).
- Orchestrator nit: `window_json_changes_with_retain_messages_test` used an
  invalid retain (7 < max 10); changed to 20.

What pi got wrong: scope inference from a whole-object jq comparison (planner);
reading a sheet's late amendment (reviewer). Brief fix: put amendments at the
top of the sheet, or quote them in the brief.

PHASE-02 review dispositions (Opus):
- O1 `retain.refresh_all` / `add_fetched` were O(stored × refreshes) via
  `list.find`/`list.any`; the full path refreshes every stored id — fixed with a
  `dict` of refreshes and a `set` of fetched ids.
- O2 refresh test asserted 11 fields one by one — replaced by one record
  equality against `Message(..before, <mutable fields>)`, which pins every
  field.
- O3 empty-input merge test was TDD scaffolding — pruned (design § 9).
- O4 `refresh` doc cited § 5.1 — corrected to § 5.2.
- Design note (not a defect): ties at equal `received_at.ms` order by id
  descending (compare_received, reversed), as the design states.
- Improvement noted, not done: `snapshot_fixture.listing_message` could build
  on the new `bare_message`.

PHASE-03 review dispositions (all fixed):
- false doc on `decode.light_decoder` (claimed a full body cannot decode as
  light; decoders ignore extra keys) — corrected (major);
- `changes_response` lacked `oldState` (RFC 8620 § 5.2) — added;
- `opening_pairs` order test used identical argument sets — now distinct;
- `email_changes` key set unpinned — pinned;
- `changes_bent` tuple arg, a shared doc over two tests, a duplicated
  false-flags test — fixed / dropped;
- orchestrator: `opening_pairs` via `result.map`; one `get_arguments`
  envelope for full and light `Email/get` fixtures (POL-001).
- VA-2: CHR-004 records its opening_entries guard as done here.

PHASE-04 review dispositions:
- the round-trip could not tell `collapse_threads` from
  `can_calculate_changes` (both True in `full`) — the test now bends
  `collapse_threads` to False locally (shared fixture untouched) (major, fixed);
- false docs on `query.prior` (write order; "every part is an existing read")
  — corrected;
- no-snapshot test exercised only the `sync` path — now one test over three
  deletions (sync row, Email type_state, query_state);
- `account_id` now reuses `no_snapshot_when_empty`; shadowing locals renamed;
- EX-2 wording: `message_ids` is a fourth new reader, mandated by design
  § 5.2 ("every message id") — noted, no change.
- Accepted by design, not a defect: `prior` rebuilds each message with
  `query.message` (several selects per message). § 8 Risks: revisit only if
  measured.

PHASE-08 decisions and deviations:
- Thread ids for `Thread/get` are now **sorted** (canonical), not first-seen
  (M1 A8). The merge returns newest-first with id-descending ties, and every
  fixture email shares one `receivedAt`, so first-seen order would have tied
  `Thread/get` chunking to merge internals. `sync_fixture.fetch_chunked`
  chunks threads in the same sorted order; `summary_values_test`'s thread-id
  expectation changed accordingly (it pins counts, not order).
- Interim until PHASE-06: a usable Prior with an unchanged window runs full
  with the Prior, `fallback_reason: None` (unreachable in production: cli
  passes no Prior until PHASE-07).
- Light-refresh ids follow the Prior's message order, not `set.to_list`
  (unspecified order).
- EX-5 partly deferred to first use (write less code): `string_argument` and a
  public `type_state` land in PHASE-06, whose tests read `sinceState` and the
  stored Email state. Added here: `lights` step, `prior_of`,
  `run_with_prior`; `expect_unchanged` now accepts any seeded store
  (asserts one `sync` row instead of the seed account).

PHASE-08 review dispositions (Codex):
- `notFound` ids now delete stored messages but were unchecked — `get_chunked`
  now requires them to be requested (`Decode("notFound")`);
  `not_found_outside_the_chunk_fails_test` (red first).
- light request properties were unasserted (fixture matches by method) —
  `window_json_change_is_window_changed_test` now pins `properties` and no
  `maxBodyValueBytes`.
- no test showed light results reaching the store — the same test now has a
  flag change under a new state, a `notFound` and a move out of the window.

PHASE-06 notes:
- `sync.Start` gains `Changes(prior)`; a `Scope` (stored, refresh, gone,
  email_state, carried query record, mode) settles what a run refreshes;
  `changes` folds pages into a `Delta` (destroyed wins after the fold).
- Paging cap: `hasMoreChanges` after `max_pages` pages is
  `LimitExceeded("max_pages")` until PHASE-09 turns it into the
  `too_many_changes` fallback. No test pins the interim error (PHASE-09 does).
- EX-4 `run_twice` is realised as `sync_test.seed` + `sync_fixture.run_with_prior`
  (no separate two-run harness). `string_argument`, `changes`/`no_changes`
  steps and a public `type_states` landed here (deferred from PHASE-08 EX-5).
- Gotcha: `expect_unchanged` commits a probe snapshot (`acct-probe`) to prove
  the writer still commits — a test that runs again afterwards must assert
  the failure and the unchanged dump directly (`failure_then_retry_test`).
- Gotcha: `spec(script)` bounds are `bounds(Some(100))`; seeding under other
  bounds makes the next run `window_changed`, not incremental.

PHASE-06 review dispositions (RV-006, Codex raiser, Opus responder):
- F-1 "delta-fold tests pass when created ids or earlier pages are discarded"
  (minor) — fix-now. Codex showed by execution that dropping `page.created`,
  restarting `changed` per page, or keeping only the last page's `destroyed`
  all passed 421 tests. Added `changes_on_an_earlier_page_count_test` (page 1
  updates e1 and destroys e2, page 2 empty) and
  `created_only_runs_the_query_test`; each mutant now fails one of them
  (both parties re-ran them). Lesson: a paging test needs the decisive
  change on a non-final page, and an arrival that only `created` can reveal.

PHASE-09 notes:
- `Start.Reuse` carries its reason and `choose` returns a `Start` only;
  `Scope.mode` became `fallback_reason`, and `summary` derives `mode` from it
  (one source for "a run with a fallback reason is full").
- `changes` answers `Counted(delta) | Uncounted(reason)`. A fallback is
  `reuse(prior, reason, opening_state)`, the same pure constructor the
  `window_changed` start uses: no second full-path builder (POL-001).
- Page cap: `too_many_changes` continues with the client after the pages
  (their bytes stay spent: the cap bounds them). `cannotCalculateChanges`
  continues with the client held before the call, so its error bytes are
  never charged. That is structural: `client.call` returns no client on an
  error.
- VT-2 arithmetic: the budget is the session plus `bytes` of the fallback's
  full-path steps, plus 1. The run completes. One byte under that fails
  `LimitExceeded("max_total_bytes")`, so the test is exact, not loose.
  `fixture_send` honours the per-call cap (`TooLarge`), as the real `Send`
  does.
- Negative controls killed: catch every Email/changes method error; page cap
  → `LimitExceeded`; cannotCalculateChanges → error; swapped reasons; mode
  from the reason inverted; page cap off by one.
- Not pinned: the method-name guard (`failed == method`), since only
  Email/changes is in flight there. I6 / check_imports keeps the literal out.
  A cannotCalculateChanges on a later page also falls back, keeping the
  earlier pages' spend. Consistent with the design, not tested separately.

PHASE-09 review dispositions (RV-007, fresh Opus raiser, Opus responder):
- F-1 "no test pins that Email/changes pages are charged" (minor) — fix-now.
  Continuing on the pre-call client for every page survived the suite
  (also at 9564d91). Fix: `too_many_changes_pages_are_charged_test`, the
  counterpart of the VT-2 test: exact budget completes, one byte under fails.
  Shared `too_many_changes()`, `on_budget`, `cost` helpers serve both.
- F-2 module header claimed every call is charged (nit) — fix-now; names the
  DEC-026 exception.
- F-3 "changes" named four things; Counted/Uncounted misnamed (nit) — fix-now:
  `ChangeSet { Known | Unknown }`, binding `change_set`.

PHASE-07 notes:
- `cli.sync` order: config → Prior (`load_prior` over the shared `read_store`,
  reader closed) → credential → session → writer (sheet A1). A store read
  error therefore fails with zero requests and no credential read; pinned by
  `sync_fails_on_a_store_read_error_with_zero_requests_test` (run with no
  credentials directory).
- `read_store` is the one open/read/close helper; `read_verb` and
  `load_prior` both use it (POL-001). `sync` now receives the injected
  `open_reader` from `dispatch` like the read verbs.
- `data` gains `mode` and `fallback_reason` (null when incremental).
- README: new `## How sync works` (paths diagram, upgrade's one-off
  `window_changed`, retention scope and `retainMessages` rules, the
  cannotCalculateChanges overspend), `window.retainMessages` option row;
  `maxPages` described as bounding `Email/changes` too (README and
  `nix/module.nix` description).
- The second-sync test proves "no Email/get of ids" by request count (9 =
  5 + 4) with an exhausted script; local_jmap records no bodies.
- Negative controls killed: Prior dropped; every read error → None; mode
  names swapped; reason always null; credential read before the Prior.
- Gates: `gleam format --check`, `just check` (430), `nix flake check`.
- VH-1 (2026-10-27, operator ran the syncs; orchestrator read the journal,
  `journalctl --user -u screwtape`): runs at 17:44:58, 17:45:04, 17:45:48,
  17:45:52, 17:48:19 and 17:48:23 +11:00 each report `"mode":"incremental"`,
  `"fallback_reason":null`, 432 messages, 410 threads, unchanged states
  (`J365174`); about 4.1 s wall each, against about 8.1 s for the earlier
  full runs (17:15, 17:30, a pre-PHASE-07 build with no `mode` field).
  Observed: incremental on consecutive real syncs. Inferred, not observed
  (no request logging): no `Email/get` with ids — it is the no-change path
  (states unchanged), which sends none (design § 5.4; pinned by
  `second_sync_is_incremental_test`). The first post-PHASE-07 run was already
  incremental, not `window_changed`: the 17:30 build (post-PHASE-01, passing
  no Prior) had already committed the four-key `window_json`. The README's
  upgrade claim concerns an M1 store and stands.

PHASE-07 review dispositions (RV-008, fresh Opus raiser, Opus responder):
- F-1 read-error test did not pin Prior-before-credential (minor) — fix-now:
  test runs with `no_env`; negative control fails it.
- F-2 `incremental_sync_script` copied three replies and hid `es-0` (minor) —
  fix-now: shared `session_reply` / `opening_reply` / `threads_reply`, `pub
  const full_sync_email_state`.
- F-3 `load_prior` pass-through over undocumented `prior_or_none` (nit) —
  fix-now: folded.
- F-4 README diagram spelled `max_body_bytes` (nit) — fix-now.
