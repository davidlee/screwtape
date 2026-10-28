# POL-002: Real mail stays in PII_hidden_fixtures.local/

## Statement

Real, unscrubbed mail content lives only in `PII_hidden_fixtures.local/`.
This means message text, subjects, addresses, names, and anything else
copied from the operator's mailbox, including its PII-stripped `classify
--state` form.

- **Never committed.** The folder is gitignored, and a test fails if it is
  not. Never `git add -f` anything under it.
- **Never quoted out.** Agents and humans do not copy its contents into
  commits, doctrine records (slices, notes, reviews, memories, knowledge),
  code comments, test fixtures, or chat and summary output. Refer to an item
  by its file name, its message id or an aggregate (counts, agreement
  rates), never by its content.
- **Never sent elsewhere** except where the operator directed it: the Jev
  call in `classify`, and the LLM tagging pass the operator runs for the
  evaluation (IMP-003).
- **Scrubbed fixtures are different.** Hand-made fixtures, and scrubbed
  fixtures with recorded provenance (e.g. those copied from malebolge's
  `test/mail/fixtures/real/`), belong in `test/` as usual.

## Rationale

The classifier's evaluation needs real mail, because scrubbed fixtures
destroy the sender-domain and URL-host signals it relies on (SL-004
research). Agents handle fixture files as ordinary data: they quote them in
findings, copy them into tests and summarise them in memories. Each of those
moves private mail into git or into durable records. A fixed location and a
tested ignore rule make the boundary mechanical rather than a matter of
care.

## Scope

This policy covers every contributor to this repository: the operator, the
orchestrator and delegated workers. Worker briefs that touch the evaluation
must cite it. `PII_hidden_fixtures.local/CLAUDE.md` and `AGENTS.md` repeat
the statement for any agent that starts inside the folder.
