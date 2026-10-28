# PII_hidden_fixtures.local/ — POL-002

Real, unscrubbed mail from the operator's mailbox lives **only here**.

- **Never committed.** This folder is gitignored, and a test fails if it is
  not. Never `git add -f` anything under it.
- **Never quoted out.** Do not copy its contents into commits, doctrine
  records (slices, notes, reviews, memories, knowledge), code comments,
  fixtures, or chat and summary output. Refer to an item by its file name, its
  message id or an aggregate (counts, rates) — never by its content.
- **Never sent elsewhere**, except where the operator directed it: the Jev call
  in `classify`, and the LLM tagging pass the operator runs for the evaluation.
- **Scrubbed fixtures are different.** Hand-made fixtures, and scrubbed
  fixtures with recorded provenance, belong in `test/` as usual.

Source: policy **POL-002** (real mail stays in `PII_hidden_fixtures.local/`).
IMP-003's evaluation owns what goes in this folder.
