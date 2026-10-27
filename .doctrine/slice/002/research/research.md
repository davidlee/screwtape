# Research: SL-002 (M2 minimal incremental sync)

## Header

- **Thread 1 (governance)** and the **JMAP facts** strand: the orchestrator
  (Opus 5.5), read directly, 2026-10-27.
- **Thread 2a (test-suite survey)**: a pi worker (deepseek-flash, `judgement`
  profile, $0.05, read-only). Verbatim output is in `raw/test-survey.md`.
- **Thread 2b (production code map)**: the orchestrator, from reading
  `sync.gleam`, `store.gleam`, `store/query.gleam`, `model.gleam`, `request.gleam`.
- Baseline: `baseline.toml`, stamped by `doctrine slice research 2`.

## Verification legend

- ✓ means the orchestrator re-read the cited site.
- Unmarked rows are researcher claims: cited, but not re-checked.
- **R** means recalled from RFC 8620 or RFC 8621 without re-reading the
  spec text. Design must confirm an R row by a live probe or a spec read
  before relying on it.

## Thread 1: governance applicability

**Binding**

| Source | Constraint on SL-002 |
|---|---|
| POL-001 (required) | One implementation per behaviour. The incremental path must reuse the full sync's fetch, normalise and store-write code. Tests extend `test/support`. |
| DEC-007 (accepted) | The schema stores JMAP states per type and is "M2-ready". ✓ `type_state` table, `store.gleam:705` |
| DEC-008 (accepted) | One transaction per run that replaces the account's rows; a failed run leaves the store intact. The incremental path keeps this atomicity. |
| ISS-001 (resolved) | The Email and Thread states are taken by the opening request, *before* phase 1. `sinceState` for the next run is therefore the opening state, so a message arriving mid-sync is reported again rather than lost. ✓ `sync.gleam:105-109` |

**Checked, not applicable**

- **ADRs, standards, specs:** none exist in this repo
  (`doctrine adr|standard list` is empty; there is no `.doctrine/spec`).
- **IMP-001** (fail closed on a writable account): a separate item that
  SL-002's scope excludes.
- **CHR-002 and CHR-003:** they concern htmerl and quotient; sync logic is
  untouched by them.
- **satan:RFC-020:** this is evidence, not a binding source. D8 lists
  `queryChanges` for M2. SL-002 drops it by operator decision (2026-10-27,
  option B). That divergence should reach satan:RFC-020 as a revision note at
  close (see *Revision candidates*).

**Memories relied on**

- `mem.fact.jmap.query-get-response-semantics` records these Fastmail facts
  (verified 2026-10-27):
  - every type shares one modseq;
  - `canCalculateChanges: true`;
  - `ids: []` gets return the type's state.
- `mem.fact.sqlite.esqlite-readonly-uri` covers the reader and writer
  connections and the `busy_timeout` default.

**Revision candidates**

- satan:RFC-020 D8 M2: a "no `queryChanges`; local window filter" amendment,
  drafted for the operator at close. This follows the SL-001 precedent of
  RFC drafts the operator commits.

## JMAP facts (for the incremental path)

| # | Fact | Basis |
|---|---|---|
| J1 | Request: `Email/changes {accountId, sinceState, maxChanges?}`. Response: `{accountId, oldState, newState, hasMoreChanges, created[], updated[], destroyed[]}`. | R (RFC 8620 § 5.2) |
| J2 | When `hasMoreChanges` is true, the client calls again with `sinceState = newState`. The server may return fewer than `maxChanges`. | R |
| J3 | Ids can repeat across pages: an id created in one page may appear as updated in a later one, and created-then-destroyed may appear only in `destroyed`. The client unions the pages: `fetch = (created ∪ updated) − destroyed`. A later `Email/get` `notFound` counts as destroyed. | R |
| J4 | When the server cannot compute changes from `sinceState`, it returns the method-level error `cannotCalculateChanges`. | R; ✓ the type is already in the problem allowlist, `decode.gleam:69` |
| J5 | `mailboxIds` and `keywords` are mutable Email properties. Changing either reports the Email in `updated`. So a move into or out of a configured mailbox, or a seen or flag change, appears as an update. | R (RFC 8621 § 4.1) |
| J6 | Mailbox counts (`totalEmails`, `unreadEmails`) change the Mailbox state. Refetching with `Mailbox/get` covers them. | R |
| J7 | Thread membership changes only when Emails are created, destroyed or re-threaded, and every one of those is also an Email change. | R |
| J8 | Fastmail: the read-only token has `canCalculateChanges: true`, and every type shares one modseq. | memory, verified live 2026-10-27 |

**Gap:** J1–J7 have not been exercised against Fastmail.
`probes.local.d/jmap/jmap-probe.sh` (untracked) can be extended to send
`Email/changes` from the stored state in a transient unit. It is cheap and
read-only, and design should schedule it early.

## Thread 2a: test-suite survey (summary; detail in `raw/test-survey.md`)

- **Size:** 377 tests. Most run in-process. 42 start a loopback TLS listener
  and 31 spawn an OS subprocess, mostly in `token_leak_test`, `ffi_test`,
  `transport_test` and the shipment cases of `cli_test`.
- **The sync tests are in-process and well supported.**
  - `sync_fixture.run` scripts `fixture_send.Step`s.
  - `Expect(method, reply)` matches the first call's method name, and an
    unexpected request is answered with 500 and recorded as unmatched.
  - `expect_calls` asserts the ordered call list. `store_dump` is taken
    before and after, and `expect_unchanged` proves the atomic rollback.
- Matching and assertion all use `request.method_name`
  (✓ `fixture_send.gleam:190-200`). Adding an `EmailChanges` variant to
  `request.Method` therefore needs no change to the harness.
- **Two runs against one store already work.** ✓ `sync_test.gleam:782`
  `repeated_run_identical_dump_test` and `:796`
  `window_leaver_rows_removed_test` call `run` twice on one writer.
- **Missing for M2:**
  - `jmap_fixture.changes_response` and a `changes_error`, built on the
    existing `error_entry`;
  - `sync_fixture.changes` step builders;
  - `string_argument`, alongside the existing `int_argument`, for asserting
    `sinceState`;
  - a public `type_state` accessor, which today is private at
    `sync_test.gleam:135`;
  - possibly a `run_twice` helper.
- **Sharp edge:** ✓ `jmap_fixture.opening_entries` (`:327-346`) zips
  `request.opening`'s call names against a hard-coded list of three argument
  sets. Adding an opening call would silently truncate every scripted
  opening. Keep `Email/changes` out of the opening request.
- **No mock library.** `fixture_send` and `jmap_fixture` already do what a
  mock library would. Adding one would be the very parallel abstraction
  POL-001 forbids.
- **Existing duplication (POL-001 debt; not in SL-002's scope unless it is
  touched):**
  - `cli_fixture.full_sync_script` re-scripts the full sync for `local_jmap`;
  - `client_test` and `jmap_fixture_test` duplicate wrappers;
  - `unwrap` is copied ×3;
  - hand-built `methodResponses` appear in `client_test` and
    `token_leak_test`.
- **Weak-test candidates:**
  - the five shape-only `jmap_fixture_test` cases;
  - `sync_test:629,638`, which duplicate `client_test:346,353`;
  - three near-identical `cli_test` refusal tests;
  - the 11 `token_leak_test` shipment scenarios, each re-asserted in
    process. Collapsing these is the largest wall-clock saving.

## Thread 2b: production code map

- ✓ **`sync.run`** (`sync.gleam:62-120`) runs these stages in order:
  - `opening` (Mailbox/get, plus Email/get and Thread/get with `ids: []` for
    the states);
  - `resolve_mailboxes`;
  - `query_ids` (phase 1, the Email/query pages);
  - `get_emails` (phase 2, chunked, with `only_requested` and
    `all_answered` checks);
  - `get_threads` over `distinct_thread_ids`;
  - building a `model.Snapshot`;
  - `store.write_snapshot`.

  Every stage after `query_ids` takes a plain id list. The incremental path
  can therefore swap phase 1 for `Email/changes` and reuse `get_emails`,
  `get_threads` and `in_chunks` unchanged.
- ✓ **`store.write_snapshot`** (`store.gleam:119-150`) does BEGIN IMMEDIATE,
  then migrate, delete all rows, insert the snapshot, and COMMIT. It is the
  one writer, and its input is a whole `model.Snapshot`.
- ✓ **`store/query.message(tx, id)`** (`query.gleam:79`) rebuilds a full
  `model.Message`, with relations in canonical order. So the stored window
  can be loaded back into `List(Message)` with existing code: list the ids,
  then call `message` for each.
- ✓ **The `sync` row stores `window_json`** (`store.gleam:699`, written
  from `config.window_json(window)`, `sync.gleam:395`). Detecting a changed
  config window is a string comparison with no schema change.
- ✓ **`model.Snapshot`** (`model.gleam:193`) holds account, states, query,
  mailboxes, messages and threads. `model.Message.email_state` records the
  state of the response that delivered the message.

## Cross-thread findings

1. **The simplest store path is no new store path.**
   - Load the stored window as `List(Message)` with `query.message`.
   - Merge the fetched messages in a pure function: replace by id, drop
     destroyed ids, filter to the window, trim to `max_messages` newest.
   - Commit through the unchanged `write_snapshot`.

   This needs no upsert or delete SQL, keeps DEC-008's atomicity for free,
   and makes the merge testable without SQLite. The cost is rewriting the
   whole window each run, which is bounded by the window and local.
   Precondition: a write → load → write round trip must leave the dump
   unchanged, and one test should assert that.
2. **Incremental and full sync can only diverge in the window filter.** The
   full sync's window is built server-side: `Email/query` with an `OR` of `inMailbox`
   (✓ `request.gleam:78-108`) and `after`, sorted by `receivedAt`
   descending, limited to `max_messages`. The incremental window is built
   locally. Two known divergences:
   - **Count-capped deletion:** when the window is at `max_messages` and a
     message leaves, the full sync pulls in the next-oldest message. The
     incremental path never saw it, so its window comes up short.
   - **Ties on `receivedAt`** at the count boundary are ordered by the
     server, which is unspecified. Locally the `id` tiebreak applies, as in
     `query.messages`.

   Simplest rule: fall back to a full sync when the stored window is at its
   count cap and a message leaves it. Otherwise accept "at most N". Design
   decides; the "incremental equals full" test pins whichever is chosen.
3. **Threads:** reuse `get_threads` over the merged window's distinct thread
   ids whenever there were Email changes. That is a few chunked requests,
   and it removes the thread-staleness question (J7).
4. **No-change run:** if `newState == sinceState` and there are no ids, skip
   every get. Either write the stored snapshot with a fresh `synced_at`, or
   write nothing. Design decides; the slice goal is one small request.
5. **Bounds:** paging `Email/changes` counts against `max_pages` and the
   byte budget, which the `Client` already threads through. If
   `hasMoreChanges` is still true at the page cap, fall back to a full sync,
   which is bounded by construction, rather than fail.

## Design-input deltas

- The scope's "trim locally, then upsert or delete in one transaction" becomes
  **load stored, merge purely, then `write_snapshot`**, with no new store
  write code.
- The window-change fallback costs nothing: compare against the stored
  `window_json`. This answers the scope's open question; keep it.
- New fallback triggers to decide:
  - the count-capped window loses a message (finding 2);
  - `hasMoreChanges` is still true at the page cap (finding 5).
- `Email/changes` is its own request, never part of the opening request (the
  `opening_entries` sharp edge).
- Test support to add, all in existing modules:
  - `request.Method.EmailChanges`;
  - `jmap_fixture.changes_response` and `changes_error`;
  - `sync_fixture.changes`, `string_argument` and a public `type_state`.

  Avoid a new harness; use no mock library.
- Run an early live probe of `Email/changes` against Fastmail to confirm
  J1–J5.
- Optional, operator's call: fold some weak or duplicate tests into SL-002
  as POL-001 debt reduction, or log a backlog chore.

## Refresh (2026-10-27, after the retention decision)

The slice scope changed after this round. The operator added
`retain_messages`, separate from the fetch `max_messages`, and made the full
path fetch the `Email/query` ids together with the ids already stored
(option a). Effect on the findings above:

- Cross-thread finding 2 (count-capped divergence) no longer applies. The
  store is no longer required to equal the fetch window, and the invariant
  becomes "the store's newest `max_messages` equal what a full sync would
  fetch".
- Finding 1 (load, merge, `write_snapshot`) now serves both paths.
- New surface: `src/screwtape/config.gleam` (`Window` at `:20-25`, ✓; the
  `validate` checks at `:102`, ✓) and `nix/module.nix`.
- Disk cost: the live store is 4.9 MB for 419 messages, about 12 KB per
  message (✓ `ls -la ~/.local/state/screwtape/`).
