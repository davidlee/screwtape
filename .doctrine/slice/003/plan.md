# Implementation Plan SL-003: Screwtape read contract for M3 consumers

Prose companion to `plan.toml`. Narrative only — no queried data lives here
(the storage rule); the phase list, criteria, verification, and links are
authored in the TOML. Use this for the plan's rationale and sequencing.
<!-- Reference forms: `lib:reference/glossary.md` § reference forms. -->

## Overview

Six serial phases, leaves first, each ending green. The code phases follow
the data path from the inside out; the contract is written last, over output
that exists.

```
PHASE-01 cursor (pure)
   │
PHASE-02 thread --limit ── independent of the cursor; lands limit_value first
   │
PHASE-03 query: Page, cursor predicate, message_ids/messages_of   (no CLI change)
   │
PHASE-04 cursor field + list --after   (argv Filters/Page; C2 through the CLI)
   │
PHASE-05 read --after stream           (dispatch → Option(String); C1, C4)
   │
PHASE-06 README § Contract + satan:RFC-020 amendment draft
```

## Sequencing & Rationale

- **Cursor first.** `screwtape/cursor` is pure and has no dependants yet, so
  C3 is pinned by unit tests alone. Its purity rule lands with it; `render`'s
  allowlist (today `model`, `utf8`) widens to `cursor` in the same phase,
  since PHASE-04 needs it.
- **Thread before selection.** `thread --limit` is a vertical slice that does
  not touch the cursor. It goes early because it introduces `limit_value`,
  which PHASE-04 and PHASE-05 reuse, and because its C6 change is isolated
  from the cursor's.
- **Query without behaviour change.** PHASE-03 restructures `ListQuery` and
  extracts `messages_of` from `prior` while `cli` maps today's flags to
  `Newest`, so the existing `list` and `prior` suites judge the refactor and
  the new `Oldest` tests judge the predicate. This is the phase the review
  lane probes hardest (C2).
- **Field and `list --after` together.** The cursor a page continues from is
  the last item's `cursor` field, so the C2 walk through the CLI needs both.
  The argv `Filters`/`Page` split lands here; `ReadAfter` reuses `Filters`.
- **Stream last among the code.** `read --after` composes everything before
  it (`Filters`, `limit_value`, `message_ids`, `messages_of`, `render.read`);
  the only new machinery is `dispatch`'s `Option(String)` and the selection
  argv.
- **Contract after code.** The README and the RFC amendment describe output
  that exists and is pinned by tests, not output as designed.

## Notes

- **Reviews.** Per notes § Review passes: a code review (Opus subagent; Codex
  unavailable) on each query or argv phase — PHASE-02 to PHASE-05 — with the
  design § 9 tests as the oracle. PHASE-01 is pure and fully pinned by C3
  units; its diff rides PHASE-02's review.
- **Tests.** Extend `store_test`, `cli_test`, `render_test`,
  `read_snapshot_test` over `snapshot_fixture.listing()`; no new harness
  (POL-001, CHR-004). C2 is tested at the query (PHASE-03) and through the
  CLI (PHASE-04, as design § 9 states): the first is the predicate's oracle,
  the second the wiring's.
- **satan.** `~/dev/satan` has unrelated uncommitted operator work. PHASE-06
  edits only `.doctrine/rfc/020/*` and commits nothing there.
- **Research.** The baseline drift was only this slice's scope and design,
  written after the research; restamped at plan time with no content change.
