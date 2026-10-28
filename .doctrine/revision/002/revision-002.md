# REV REV-002 — reconcile SL-004

Revision — a pending revise-intent against authored governance/spec
truth. The structured `[[change]]` payload lives in the sister `revision-NNN.toml`;
this prose companion carries the rationale and the free-text before/after excerpts
for prose-body section edits.

## Rationale

<!-- Why this revision: what authored truth needs to change and why, the scope of
     the staged delta, and (for ADR/POL/STD/prose rows) the before/after excerpts
     the structured payload only labels. Seeded at `revision new`. -->

## Reconcile narrative

RV-018 reconciliation brief, governance half. Rows that REV cannot carry
(DEC-035 and DEC-016 are decisions, outside REV's target kinds) are amended
with `doctrine knowledge edit decision`, on the operator's reply of 2026-10-29.

- [RV-018 F-16] POL-002 § Statement, the Jev-call exception: "the evaluation
  (SL-004)" → "(IMP-003)". The evaluation was split out of SL-004 on
  2026-10-28; the operator confirmed. Before: `...the LLM tagging pass the
  operator runs for the evaluation (SL-004).` After: `... (IMP-003).`
- [RV-018 F-12] DEC-035 (not a REV row): the per-question instructions and
  choice-label descriptions are those in `classify/schema.gleam` under
  `mail-1`, accepted by the operator, who expects to refine them; mail-1 is
  unreleased, so refinement does not bump the schema id.
- [RV-018 F-17] DEC-016 (not a REV row): a consequence for the `jev`
  credential and PII-stripped mail leaving the host (DEC-038).
