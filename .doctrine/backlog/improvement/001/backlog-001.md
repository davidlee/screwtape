# IMP-001: Fail closed when the synced account reports isReadOnly false

<!-- Backlog item body — context, detail, links. The structured, queried fields
     live in the sister `backlog-NNN.toml`; this prose is free-form and is never
     structurally parsed (the storage rule). -->

Operator ruling on SL-001 design § 6 OQ-A (PHASE-09/EX-5, VH-2,
2026-10-27): fail closed, as a later change outside SL-001.

Observed: Fastmail reports `isReadOnly: true` on the session's account for
the "Read-only access" token (PHASE-09 probe, 2026-10-26T21:52Z). So the
flag is a usable check. Today `sync` records `is_read_only` and only warns
when it is `false`.

Done when:

1. `sync` refuses to sync an account whose session entry reports
   `isReadOnly: false`, before any phase-1 request, with its own error
   code and exit status, and leaves the store unchanged;
2. a test with a fixture session reporting `false` shows the refusal and an
   unchanged store, and the existing `true` path still commits;
3. design § 5.2/§ 6 and the README say the mirror needs a read-only token.
