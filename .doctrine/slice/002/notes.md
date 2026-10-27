# Notes SL-002: Screwtape M2: minimal incremental sync

Durable per-slice scratchpad — tracked in git. The place to lift anything from a
disposable phase sheet (`.doctrine/state/.../phase-NN.md`) that must survive
`rm -rf` before the slice close-out audit harvests it.

## Harvest
<!-- single-copy: updated in place each harvest; ids only, never restated content -->
fresh-as-of: <yyyy-mm-dd> · <PHASE-NN | stage> · <head-commit>

### Produced

### Learned

### Open

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
