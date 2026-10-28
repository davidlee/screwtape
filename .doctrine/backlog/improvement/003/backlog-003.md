# IMP-003: Evaluate classify mail-1 on real mail (split from SL-004)

<!-- Backlog item body — context, detail, links. The structured, queried fields
     live in the sister `backlog-NNN.toml`; this prose is free-form and is never
     structurally parsed (the storage rule). -->

Split out of SL-004 on 2026-10-28 by the operator, to keep SL-004 to deploying
`classify` ("we'll do that, and split out the eval").

What carries over from SL-004:
- The eval design is SL-004 design § 5.3 (eval data) and § 5.4 (the
  evaluation run, steps 1–6). Read it there; do not restate it here.
- RV-016 F-6, F-7 and F-11 shaped that design: one saved sample, Brier score
  and label coverage, insufficient evidence below 5 positives, a join bound to
  the sample's ids and to one model. The same review added the synthetic
  adversarial fixtures.
- The open question behind it: SL-004 design § 6. Does `substance` carry a
  signal, and are Jev's probabilities calibrated on this mail?
- POL-002 governs all real-mail handling.

Scope here: `test/eval/tagging.md`, `gleam run -m eval`, `just eval`,
`test/fixtures/mail/adversarial/`, then the first run inside
`PII_hidden_fixtures.local/`, with aggregates only.
Depends on SL-004 being deployed.
