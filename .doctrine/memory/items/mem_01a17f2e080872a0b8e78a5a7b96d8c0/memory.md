The solo binding writes a phase's `code_start_oid..code_end_oid` into
`.doctrine/state/slice/NNN/boundaries.toml` when the phase is flipped
`completed`. A code commit landed after that flip (SL-003: 25f96fa, a PHASE-04
review-verdict test made after PHASE-04 completed) sits in no range, and if it
becomes the next phase's `code_start_oid` its own patch is excluded from that
phase too. `slice conformance` then silently omits its paths.

Fix: `doctrine slice record-delta <id> PHASE-NN --start <old start> --end <new tip>`.
Prevention: land the post-review fix before flipping the phase completed, or
record the delta immediately after. Audit check: compare `git log` of the
slice against the boundary ranges (RV-015 F-3).
