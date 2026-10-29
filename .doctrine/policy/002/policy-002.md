# POL-002: Real mail stays outside the repository

## Statement

Real, unscrubbed mail content lives only outside the repository, by
default in `~/.local/state/screwtape/eval/` (the operator may choose
another location outside the repository).
This means message text, subjects, addresses, names, and anything else
copied from the operator's mailbox, including its PII-stripped `classify
--state` form.

- **Never in the repository.** Never copy real mail into the repository
  tree, not even under an ignored path.
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
moves private mail into git or into durable records. A folder inside the
repository is also visible to delegated workers (the repository root is
their working directory) and to any agent's glob or grep, which can send
its contents to an external model; a gitignore rule protects git, not
agents. Keeping real mail outside the tree makes the boundary mechanical
rather than a matter of care.

## Scope

This policy covers every contributor to this repository: the operator, the
orchestrator and delegated workers. Worker briefs that touch the evaluation
must cite it.
