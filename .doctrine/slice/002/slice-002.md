# Screwtape M2: minimal incremental sync

## Context

SL-001 (M1) mirrors a bounded window of one Fastmail account into SQLite. Each
run does a full sync: it fetches the whole window and, in one transaction,
replaces the account's rows (DEC-008). The schema already stores the JMAP state
string for each type (DEC-007; ISS-001 fixed which state is recorded), so
incremental sync can be added without a schema break.

satan:RFC-020 (`~/dev/satan`) D8 defines M2 as "state tokens, `queryChanges`,
invalidation and resync, no duplicate fetches". satan:RFC-020 D1 splits `changes` in
two:

- **upstream:** the mirror asks JMAP what changed;
- **consumer:** a per-consumer cursor over the store.

This slice builds only the upstream half, and only its simplest form.

**Posture: rigorous simplicity** (operator, 2026-10-27). Build the simplest
thing that delivers the function. Read-side security was settled in SL-001 and
is not reopened here.

## Scope & Objectives

1. **Retention separate from the fetch window** (operator, 2026-10-27; partly
   answers satan:RFC-020 OQ-10, which asks how much mail the store keeps).
   - The fetch window (`mailboxes`, `max_age_days`, `max_messages`) decides
     which ids a full sync asks `Email/query` for.
   - A new optional `retain_messages`, at least `max_messages`, decides what
     the store keeps. When it is absent, retention equals the fetch window,
     as in M1.
   - Byte-budget validation isn't needed. A fallback refreshes stored ids
     with the light `Email/get` (about 1 MB for the retained tail), not their
     bodies (DEC-026, DEC-024).
2. **One window selection, two refresh scopes, one merge** (DEC-026).
   `Email/query` decides which messages are in the window; `Email/changes`
   decides which stored messages need refreshing.
   - **incremental**, when the `Prior` has an Email state, the same
     `window_json` and the same resolved mailbox ids: `Email/changes` from
     that state with a finite `maxChanges`, paging while `hasMoreChanges` is
     true, within the existing page and byte bounds. With no changes the run
     skips `Email/query` and every `Email/get`. With changes it runs the
     existing bounded `Email/query`, and only the changed stored ids get a
     light refresh;
   - **full**: the existing `Email/query`, and every stored id gets a light
     refresh. This refreshes the retained tail.

   The `Prior` is discarded, and everything refetched, when the account or
   `max_body_bytes` differs. After the id sources, the run:
   1. fetches the ids. Query ids not yet stored go through the existing full
      `Email/get` path, with bodies. Stored ids to refresh get a light
      `Email/get` of only `mailboxIds` and `keywords`, since JMAP content is
      immutable. `destroyed` or `notFound` means gone. A changed id that is
      neither stored nor in the query is ignored;
   2. refetches with `Mailbox/get`, which is cheap and needs no
      `Mailbox/changes`;
   3. merges the stored messages (the CLI loads them as a `Prior`) in one
      pure function shared by both paths, `screwtape/retain` (DEC-025):
      - drop destroyed and `notFound` ids;
      - apply the light refreshes;
      - add the newly fetched messages;
      - keep only messages that are in a configured mailbox;
      - trim to the newest `retain_messages`;
   4. fetches the merged set's threads with `Thread/get`, every run;
   5. commits through the unchanged `store.write_snapshot`, with no new
      store write code, so DEC-008's atomicity holds.
3. **Fallback to the full path,** in these cases:
   - no stored state (a first run, or a store wiped by a migration);
   - `cannotCalculateChanges`;
   - the stored `window_json` or the resolved window mailbox ids differ from
     the current ones;
   - `hasMoreChanges` is still true at the page cap.

   The sync summary reports `mode` (`incremental` or `full`) and
   `fallback_reason`. The unit's stdout already goes to the journal, so that
   is the log (DEC-026). Any other error fails the run, as in M1, and the
   next run retries. The bytes of a `cannotCalculateChanges` response are not
   charged to the budget, so a run may spend up to about twice
   `max_total_bytes`; still bounded, documented, client API unchanged.
4. **No duplicate body fetches.** An unchanged account costs three small
   requests (the opening request, `Email/changes` and `Thread/get`) and no
   `Email/get`. A seen, flag or move change costs one ids-only `Email/query`
   and a light refresh. Bodies are fetched only for new messages in the top
   `max_messages`.
5. **Test-suite survey (research and design input).** Before designing,
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
  to M3 and the Screwtape↔SATAN contract (satan:RFC-020 OQ-11).
- Any new security mechanism. Credential handling, the error allowlists and
  the crash containment from SL-001 are reused unchanged.
- A schema change. `window_json` is already stored (research, Thread 2b).
- Retention by age, or bodies ageing out before their metadata (the rest of
  satan:RFC-020 OQ-10).
- A daemon, push (EventSource), or anything in M3 or M4.
- IMP-001 (fail closed when the account is writable): a separate item.

## Affected surface

- `src/screwtape/sync.gleam`: choose between the incremental and full paths,
  and add the incremental path.
- `src/screwtape/jmap/request.gleam`, `jmap/decode.gleam`: `Email/changes`
  and the light `Email/get` (`mailboxIds`, `keywords`).
- `src/screwtape/retain.gleam` (new, pure): the shared merge (DEC-025).
- `src/screwtape/normalise.gleam`: the light refresh, sharing the keyword
  flag derivation.
- `src/screwtape/cli.gleam`: load the `Prior`; the summary gains `mode` and
  `fallback_reason`.
- `src/screwtape/store/query.gleam`: load the `Prior` (account id,
  messages, mailboxes, Email state, `window_json`, the query record, the
  stored body limit), reusing `query.account_id`, `query.mailboxes` and
  `query.message`.
- `src/screwtape/config.gleam`: `retain_messages` and its validation.
- `nix/module.nix`: the `retain_messages` option.
- `src/screwtape/model.gleam`: the `Prior` type.
- `test/check_imports.gleam`: the `retain` purity rule.
- `test/support/**`, `test/screwtape/sync_test.gleam`,
  `test/screwtape/jmap/*`, `test/screwtape/store_test.gleam`.
- `README.md`: the sync behaviour section.

## Risks, assumptions, open questions

- **Fastmail's single modseq.** Fastmail reports one modseq for every type, so
  Mailbox, Email and Thread states are equal (verified 2026-10-27,
  `mem.fact.jmap.query-get-response-semantics`). Nothing should depend on
  that.
- **Mailbox moves (assumed, to be probed).** Mail moving into or out of a
  configured mailbox is assumed to arrive as an `updated` id, because
  `mailboxIds` changes and RFC 8621 counts that as an Email update. This is
  recalled from the RFC, not checked. An early live probe of `Email/changes`
  against Fastmail must confirm it.
- **Invariant (DEC-025):** after either path, the store's newest
  `max_messages` messages that pass the window filter (mailboxes and
  `max_age_days`) equal what a full sync would fetch. Ties on `receivedAt`
  at the boundary are ordered by the server, which is unspecified; locally
  `id` breaks them (accepted, documented).
- **Retention covers configured mailboxes only.** Archiving a message out of
  a configured mailbox drops it from the store. To keep archived mail, add
  the archive mailbox to the window.
- **The write cost is accepted.** Every run rewrites the whole retained set
  through `write_snapshot`. That is bounded by `retain_messages` and is local
  (about 12 KB per message today). A test must show that writing, loading
  and rewriting leaves the dump unchanged.

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
- Consumer cursor: M3 and the satan:RFC-020 OQ-11 contract.
