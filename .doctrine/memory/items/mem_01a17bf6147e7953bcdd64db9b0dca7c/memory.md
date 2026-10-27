# Sync tests that kill paging and budget mutants (SL-002 RV-006 F-1, RV-007 F-1)

Two reviews found the suite passing against plausible wrong implementations,
shown by running mutants. Patterns that close those gaps:

- **Paging folds.** Put the decisive change on a *non-final* page, and end on
  an empty page with `hasMoreChanges: false`. A change only on the last page
  cannot tell "accumulate" from "keep the last page"
  (`changes_on_an_earlier_page_count_test`).
- **Something only `created` reveals.** An arrival that `Email/query` also
  returns hides a dropped `created`. Use a created-only delta, so the query
  runs only because of it (`created_only_runs_the_query_test`).
- **Budget charge, both sides.** `fixture_send` honours the per-call cap
  (`TooLarge`), as the real `Send` does, so budget tests can be byte-exact:
  `cost = byte_size(session_body(spec)) + sync_fixture.bytes(steps)`. Assert
  that `cost` completes and that `cost - 1` fails
  `LimitExceeded("max_total_bytes")`. Test the charged path
  (`too_many_changes_pages_are_charged_test`) as well as the uncharged one
  (the VT-2 `cannotCalculateChanges` test). Helpers `on_budget` and `cost`
  are in `sync_test`.
- **Mutate without git.** Copy `src/screwtape/sync.gleam` to the scratchpad,
  apply one exact-string replacement, run `gleam test`, and restore with
  `cp`, checking it with `cmp`. Never use `git checkout`/`stash` here.

## Fixture defaults that hide mutants (SL-002 audit, RV-009)

- **One shared `receivedAt`.** `jmap_fixture.email` gives every message the same `receivedAt`, so the merge orders by the id tie-break. A test whose claim depends on order (backfill, trim) can pass for the wrong reason. Build its emails with `sync_fixture.newest_first(ids)`, and make the decisive message win by date, not by id.
- **One shared Email state.** Openings answer `es-0` and seeded Priors hold `es-0`, so "stored the opening's state" and "stored the Prior's state" look the same. Give a fallback test's opening a distinct state (for example `sync_fixture.opening(..., "es-5", ...)`) and assert the stored `type_state`.
