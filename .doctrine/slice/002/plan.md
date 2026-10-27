# Implementation Plan SL-002: Screwtape M2: minimal incremental sync

Prose companion to `plan.toml`. Narrative only — no queried data lives here
(the storage rule); the phase list, criteria, verification, and links are
authored in the TOML. Use this for the plan's rationale and sequencing.
<!-- Reference forms: `lib:reference/glossary.md` § reference forms. -->

## Overview

Seven small phases build M2 from the leaves inward: config, the pure merge,
the wire surface and the store reader first; then `sync` in two steps (the full
path through the merge, then the incremental path); then the CLI, the README
and live acceptance. Each phase ends green and is reviewed before the next
starts (operator posture: small phases, a review after each).

```
PHASE-01 config ─┐
PHASE-02 merge ──┼─▶ PHASE-05 full path ─▶ PHASE-06 incremental ─▶ PHASE-07 cli/docs/live
PHASE-03 jmap  ──┤        (sync.run(prior), get_chunked)
PHASE-04 prior ──┘
```

## Sequencing & Rationale

- **Leaves first.** PHASE-01..04 each touch one module group and are testable
  without `sync`: config through `config_test`, the merge as pure units, the
  decoders against fixtures, `query.prior` against the existing fixture store.
  PHASE-02 precedes PHASE-03 because `decode.light_emails` returns
  `normalise.Light`.
- **Full path before incremental.** PHASE-05 changes `sync.run`'s signature
  and puts the full path through `retain.merge` with an optional `Prior`. With
  no `Prior` the run must still equal M1, so the existing sync suite is the
  regression net for the refactor (`get_chunked`) before any new behaviour
  lands. The `Prior`-validity fallbacks (`no_state`, `window_changed`) belong
  here because they choose between full runs.
- **Incremental last in `sync`.** PHASE-06 adds only `Email/changes` and its
  two fallbacks on top of a merge and a full path already proven, so its tests
  isolate the new decisions. It carries the invariant tests (I-M1..I-M4),
  including the RV-005 concurrent-move case.
- **CLI last.** Until PHASE-07 the CLI passes no `Prior`, so every
  intermediate phase ships M1 behaviour plus dormant code; the user-visible
  switch to incremental happens in one place, followed by the live check.

## Notes

- Tests extend `test/support` (`sync_fixture`, `jmap_fixture`) rather than
  adding a harness (POL-001). No new subprocess or TLS tests.
- PHASE-06 is the largest phase. If its tests outgrow one review, split it at
  the fallbacks (append a new phase id; never renumber).
- The research artefact under `research/` is untracked and has drifted
  (`doctrine slice research 2`); the operator decides its fate. The plan rests
  on the locked design, not on it.
