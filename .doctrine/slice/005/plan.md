# Implementation Plan SL-005: classify window: raw-byte bounds, every address list, seen, PII relaxed for malice signals

Prose companion to `plan.toml`. Narrative only — no queried data lives here
(the storage rule); the phase list, criteria, verification, and links are
authored in the TOML. Use this for the plan's rationale and sequencing.
<!-- Reference forms: `lib:reference/glossary.md` § reference forms. -->

## Overview

Three phases, each ending green under `just check`, in dependency order:

```
PHASE-01 strip + spend ──► PHASE-02 window (state, input, schema) ──► PHASE-03 seen on the line, README, live probe
   pii, utf8                  state is encode(window, pii.strip)           render, cli, README, docs_test
```

## Sequencing & Rationale

- **PHASE-01 first** because it is self-contained: `pii.strip` is a pure
  `String -> String` with its own table test, and `spend` is a move. Landing
  them first means PHASE-02's window tests assert against the final strip,
  so no state test is written twice.
- **PHASE-02 is the core change.** The window, the encoder, the address
  lists and the schema id move together: the state's shape changes here, so
  DEC-035 (any preprocessing change bumps the schema id) holds at every
  commit. The lines keep their current fields; only `state`'s content and
  `schema` change. VT-6's pinned size feeds PHASE-03's README Bounds figure.
- **PHASE-03 is the contract surface.** `seen` on both lines and the README
  land together, because DEC-030 requires the contract documented and pinned
  in the change that makes it. The live probe closes ASM-006 last, on the
  final bounds.

Between PHASE-02 and PHASE-03 the README describes `mail-1` while the code
emits `mail-2`; no release happens in between.

## Notes

- Reuse `classify_state_test`'s `base_mail`, `state_of` and decoder, and
  `pii_test`'s `#(input, expected)` table (design § 9).
- `jev_context` handling and cursor-bearing error lines are unchanged in
  every phase (DEC-039).
