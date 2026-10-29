# REV REV-004 — reconcile SL-005

Revision — a pending revise-intent against authored governance/spec
truth. The structured `[[change]]` payload lives in the sister `revision-NNN.toml`;
this prose companion carries the rationale and the free-text before/after excerpts
for prose-body section edits.

## Rationale

POL-002 § Statement understated what `classify` prints after SL-005: both
the `classify` and `classify_state` lines carry `seen`, the un-stripped
window (design § 5.6, DEC-041), and `state` keeps names, addresses and URL
paths (DEC-043). Scope of the policy is unchanged; the wording now matches.

Before:
> copied from the operator's mailbox, including its PII-stripped `classify
> --state` form.

After:
> copied from the operator's mailbox, including the `classify` and `classify
> --state` output, which carry it un-stripped in `seen` and partly stripped
> in `state`.

## Reconcile narrative

- [RV-020 finding F-2]: POL-002 wording updated as above. Operator approved
  2026-10-29 ("apply").
