# Screwtape M2: minimal incremental sync

## Context

SL-001 (M1) mirrors a bounded window of one Fastmail account into SQLite. Each
run does a full sync: it fetches the whole window and, in one transaction,
replaces the account's rows (DEC-008). The schema already stores the JMAP state
string for each type (DEC-007; ISS-001 fixed which state is recorded), so
incremental sync can be added without a schema break.

RFC-020 (in `~/dev/satan`) D8 defines M2 as "state tokens, `queryChanges`,
invalidation and resync, no duplicate fetches". RFC-020 D1 splits `changes` in
two:

- **upstream:** the mirror asks JMAP what changed;
- **consumer:** a per-consumer cursor over the store.

This slice builds only the upstream half, and only its simplest form.

**Posture: rigorous simplicity** (operator, 2026-10-27). Build the simplest
thing that delivers the function. Read-side security was settled in SL-001 and
is not reopened here.

## Scope & Objectives

1. **Incremental sync path.** When a stored Email state exists:
   1. `Email/changes` from the stored state, paging while `hasMoreChanges` is
      true, within the existing page and byte bounds.
   2. `Email/get` the `created` and `updated` ids, using the same properties
      and body bounds as the full sync. Keep only messages inside the
      configured window (mailboxes, max age); others count as removed.
   3. Refetch with `Mailbox/get`. There are few mailboxes, so this is cheap
      and needs no `Mailbox/changes`.
   4. `Thread/get` for the threads the changed messages touch.
   5. Write in one transaction:
      - upsert the fetched messages;
      - delete `destroyed` ids and messages that left the window;
      - trim locally to the window (max age, max count, keeping the newest);
      - store the new states.

      A failure leaves the store intact (DEC-008's atomicity rule).
2. **Fallback to the M1 full sync, unchanged,** in three cases:
   - no stored state (first run, or a store wiped by a migration);
   - `cannotCalculateChanges`;
   - a mismatch between the stored config window and the current one.

   Each fallback is logged to stderr with its reason. Any other error fails
   the run, as in M1, and the next run retries.
3. **No duplicate fetches.** An unchanged account costs one small request:
   `Email/changes` returns nothing, and `Mailbox/get` is refetched.
4. **Test-suite survey (research and design input).** Before designing,
   survey the existing test patterns:
   - fixtures (`jmap_fixture`, `sync_fixture`, `local_jmap`);
   - helpers and `store_dump`;
   - subprocess tests and their cost.

   Then decide which shared helpers, fixture extensions or mock facility the
   M2 tests need. Name the tests that are scaffolding rather than regression
   value. Prefer extending `test/support` to adding new harnesses.

## Non-Goals

- `Email/queryChanges` and `Mailbox/changes`. Membership is filtered locally;
  mailboxes are refetched.
- The consumer-side cursor (a store query such as "new since X"). That belongs
  to M3 and the Screwtape↔SATAN contract (RFC-020 OQ-11).
- Any new security mechanism. Credential handling, the error allowlists and
  the crash containment from SL-001 are reused unchanged.
- Changing the schema, beyond what a config-window fingerprint needs, if
  design keeps that fallback.
- A daemon, push (EventSource), or anything in M3 or M4.
- IMP-001 (fail closed when the account is writable): a separate item.

## Affected surface

- `src/screwtape/sync.gleam`: choose between the incremental and full paths,
  and add the incremental path.
- `src/screwtape/jmap/request.gleam`, `jmap/decode.gleam`: `Email/changes`.
- `src/screwtape/store.gleam`, `store/query.gleam`: upsert, delete, trim, and
  read the stored state.
- `src/screwtape/model.gleam`: only if the changes result needs a type.
- `test/support/**`, `test/screwtape/sync_test.gleam`,
  `test/screwtape/jmap/*`, `test/screwtape/store_test.gleam`.
- `README.md`: the sync behaviour section.

## Risks, assumptions, open questions

- **Fastmail's single modseq.** Fastmail reports one modseq for every type, so
  Mailbox, Email and Thread states are equal (verified 2026-10-27,
  `mem.fact.jmap.query-get-response-semantics`). Nothing should depend on
  that.
- **Window edges.** Max age moves forward with time, and max count can push
  older messages out when new ones arrive. A local trim handles both. Mail
  aged out of the window never returns via `/changes`, which is correct
  because it is out of the window. Design must confirm that mail moving into
  a configured mailbox arrives as an `updated` id: `mailboxIds` changes, and
  RFC 8621 counts that as an Email update.
- **Max-count trim versus the full sync.** The incremental path must select
  the same set as the full sync's query order (`receivedAt` descending), or
  the two paths diverge. Design should state this as an invariant, and one
  test should check it (incremental equals full over the same server state).
- **Thread state.** Thread membership can change with no Email of our window
  changing. Design decides whether threads are refetched for touched messages
  only, or for every stored thread (bounded by the window).
- **Open question:** does the config-window fingerprint earn its place, or
  should a config change simply fall back to a full sync because the first
  run after any config change is a full sync anyway? Design decides.

## Verification / closure intent

- Mocked tests that extend the existing JMAP fixtures:
  - incremental create, update, destroy;
  - mail moving into and out of the window;
  - `hasMoreChanges` paging;
  - `cannotCalculateChanges` falls back to a full sync;
  - a failure mid-run leaves the store intact;
  - incremental and full sync agree on the same server state.
- Test discipline:
  - no vacuous or duplicate tests;
  - expensive (subprocess, TLS) tests only where the boundary requires them;
  - TDD scaffolding pruned at phase end if it adds no regression value.
- Per-phase review kept.
- Live check: two consecutive syncs against the real account. The second
  takes the incremental path and fetches nothing new; the mailbox is
  unchanged.
- `gleam format --check`, `just check`, and `nix flake check` are clean.

## Summary

M2 adds an `Email/changes` incremental path to the existing sync. The window
is filtered and trimmed locally. The M1 full sync stays as the fallback and the
reference for correctness. There is no `queryChanges`, no `Mailbox/changes`,
and no new security mechanism. The test patterns are surveyed first so that
new tests extend shared support code rather than sprawl.

## Follow-Ups

- POL: DRY, no parallel implementation (operator request, 2026-10-27).
  Authored separately, ideally before design locks, so it governs this slice.
- Consumer cursor: M3 and the RFC-020 OQ-11 contract.
