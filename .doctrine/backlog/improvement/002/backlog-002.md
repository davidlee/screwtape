# IMP-002: Bound list fields per envelope in the CLI contract (references, attachments, address lists)

<!-- Backlog item body — context, detail, links. The structured, queried fields
     live in the sister `backlog-NNN.toml`; this prose is free-form and is never
     structurally parsed (the storage rule). -->

## Context

Contract v1 bounds only bodies (`--max-bytes`). List fields in an envelope
(`references`, `in_reply_to`, `message_id`, attachments, address lists,
`keywords`) are unbounded, so a hostile sender can make one `read` envelope
arbitrarily large (e.g. ~20,000 MIME parts, or a very long `References`
chain).

malebolge SL-005 (mail read tools) caps these fields only after the bytes
cross the pipe, under a 4 MiB stdout ceiling. A `read --after` envelope over
the ceiling fails the call at every limit; malebolge passes such a message
by falling back to `list --after <c> --limit 1` and marking it unreadable
(malebolge RV-015 F-41). The residual is a summary over 4 MiB.

## Proposal

Bound list fields per envelope in the contract: a maximum entry count per
list (and a per-entry byte cap where entries are header text), with the
total count and a truncation flag published, as `thread` already reports
`total`/`truncated`. A contract version bump if the shape changes.
