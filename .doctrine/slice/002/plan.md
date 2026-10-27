# Implementation Plan SL-002: Screwtape M2: minimal incremental sync

Prose companion to `plan.toml`. Narrative only — no queried data lives here
(the storage rule); the phase list, criteria, verification, and links are
authored in the TOML. Use this for the plan's rationale and sequencing.
<!-- Reference forms: `lib:reference/glossary.md` § reference forms. -->

## Overview

Nine small phases build M2 from the leaves inward, run serially with one
review each (operator posture: small phases, a review after each). Phase ids
are immutable, so the execution order (the array order in `plan.toml`) is
non-monotonic after the split.

```
leaves (no data dependency between them; serial for review)
  PHASE-01 config → PHASE-02 merge → PHASE-03 jmap → PHASE-04 prior
sync
  → PHASE-05 signature + get_chunked (still M1)
  → PHASE-08 full path through the merge
  → PHASE-06 incremental core
  → PHASE-09 incremental fallbacks
edge
  → PHASE-07 cli, README, live check
```

## Sequencing & Rationale

- **Leaves first.** PHASE-01..04 each touch one module group and are testable
  without `sync`. PHASE-02 must precede PHASE-03 (`decode.light_emails`
  returns `normalise.Light`); the rest are ordered only for review.
- **Behaviour-preserving step first in `sync`.** PHASE-05 changes `sync.run`'s
  signature and moves `get_emails` onto `get_chunked` with no behaviour change,
  so the existing sync suite alone judges it.
- **Full path, then incremental.** PHASE-08 puts the full path through
  `retain.merge` with the `Prior`, including `Thread/get` over the merged set.
  PHASE-06 adds `Email/changes` on top of a proven merge and full path, with
  the invariant tests (I-M1..I-M4). PHASE-09 adds the two fallbacks and the
  budget contract of `cannotCalculateChanges`. Tests land with the behaviour
  they pin (red/green), not in a later phase.
- **CLI last.** Until PHASE-07 the CLI passes no `Prior`, so every
  intermediate phase ships M1 behaviour plus dormant code; the switch to
  incremental happens in one place, followed by the live check.

## Notes

- Tests extend `test/support` (`sync_fixture`, `jmap_fixture`) rather than
  adding a harness (POL-001). No new subprocess or TLS tests.
- The split of the first draft's PHASE-05 and PHASE-06 (into 05/08 and 06/09)
  follows a pi plan review; findings and dispositions were reported to the
  operator in session.
- The research artefact under `research/` is untracked and has drifted
  (`doctrine slice research 2`); the operator decides its fate. The plan rests
  on the locked design, not on it.
