# Review RV-008 — code-review of SL-002

Adversarial-review ledger. Structured findings live in the sister
ledger toml; this prose companion carries the reviewer's framing.

## Brief

<!-- Pre-reading + lines of attack: what this review is probing, the invariants
     it must hold the subject to, and where the bodies are likely buried. Seeded
     at `review new`; the reviewer fills it before raising findings. -->

## Synthesis

- **Overall**: solid
- **Synopsis**: PHASE-07 wires the Prior into `cli.sync` through the one shared
  reader helper (`read_store`, POL-001), loaded before credential, session and
  writer, so the reader is closed long before the writer opens (EX-1). The
  summary carries `mode` and `fallback_reason` (EX-2). The README's new sync
  section was checked against `sync.choose`, `retain.merge` and DEC-026: the
  paths, the upgrade's one-off `window_changed` with bodies kept, the retention
  scope and rules, and the bounded overspend are accurate (EX-3). Four findings
  (2 minor, 2 nit), all fixed: the load order is now pinned against
  credential-first, the sync scripts share their replies and name the committed
  state, a pass-through is folded, a spelling aligned. Standing: "no Email/get
  of ids" is proved by request count, not by method name (local_jmap records
  no bodies) — adequate, since an exhausted script fails any extra call.
  VH-1 (live) remains the operator's.
- **Haiku**:
  Read once, then let go —
  the writer finds the door shut;
  nothing new: four calls.
