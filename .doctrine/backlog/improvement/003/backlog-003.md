# IMP-003: Evaluate classify mail-1 on real mail (split from SL-004)

<!-- Backlog item body — context, detail, links. The structured, queried fields
     live in the sister `backlog-NNN.toml`; this prose is free-form and is never
     structurally parsed (the storage rule). -->

Split out of SL-004 on 2026-10-28 by the operator, to keep SL-004 to deploying
`classify` ("we'll do that, and split out the eval").

What carries over from SL-004:
- The eval design below, moved verbatim in substance from SL-004 design
  § 5.3, § 5.4, § 6, § 8 and § 9 when SL-004's design was reopened to drop the eval
  (run revision 37). This body is now its home.
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
Depends on SL-004 being deployed. SL-004 delivers the folder, its notes and
the gitignore guard test (POL-002).

## Eval design (from SL-004)

**Eval data** lives in `PII_hidden_fixtures.local/` (gitignored, POL-002):
`sample.jsonl` (the `read` output, taken once), `states.jsonl`,
`labels.jsonl` (LLM-proposed, operator-confirmed) and `classify.jsonl`.
Only aggregate reports leave the folder.

**Evaluation run.** All files are in `PII_hidden_fixtures.local/`.
1. `screwtape read --after "" --limit 50 --max-bytes 16384 >
   sample.jsonl`. This is the sample. Every later step reads this file, so
   a sync in between cannot change what is tagged or classified.
2. `screwtape classify --state < sample.jsonl > states.jsonl`.
3. An LLM tagging pass, driven by `test/eval/tagging.md`, writes
   `labels.jsonl` from `states.jsonl`. The operator confirms or edits it.
4. `screwtape classify < sample.jsonl > classify.jsonl`.
5. `just eval` runs `gleam run -m eval`. The ids in `sample.jsonl` are the
   expected set. It fails if any of the three derived files misses,
   repeats or adds an id against that set, if they name different schemas,
   or if `classify.jsonl` names more than one model. A failed or partial
   classify run therefore cannot be scored as a complete one. It prints,
   for each question:
   - how many messages carry each label, level or noul positive;
   - the Brier score: the mean squared error of the probabilities (or
     `noul`) against the confirmed label;
   - `primary_purpose`: agreement and a confusion count;
   - each noul: hits and misses at 0.3/0.7, with an uncertain band;
   - each score: agreement of the rounded score.

   A question with fewer than 5 positive labels is reported as
   insufficient evidence, not scored. Aggregates only.
6. The live run also classifies `test/fixtures/mail/adversarial/`: a few
   synthetic mails, as v1 `read` envelopes (the only input `classify`
   takes), written to trigger `deception_cues` and
   `agent_directive`, including instructions aimed at the classifier.

**Test.** The join fails on a missing, repeated or extra id against
`sample.jsonl`, including when every derived file lacks the same suffix,
and on two models under one schema.

**Code impact.** `test/eval.gleam`, `test/eval/tagging.md` and a `justfile`
recipe (the eval report and the tagging brief);
`test/fixtures/mail/adversarial/` (synthetic mails).

About 50 messages can expose gross miscalibration; they cannot establish
calibration. Consumers set thresholds after this eval.
