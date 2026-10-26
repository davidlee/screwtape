# ISS-001: Email/Thread type_state taken after phase 1 misses mail arriving mid-sync

<!-- Backlog item body — context, detail, links. The structured, queried fields
     live in the sister `backlog-NNN.toml`; this prose is free-form and is never
     structurally parsed (the storage rule). -->

Source: SL-001 PHASE-05 review F1 (`phases/phase-05.md` Findings). Operator
decision 2026-10-26: fix within SL-001, after PHASE-06, before `/audit`.

Defect: `sync.run` takes the Email and Thread `type_state` from the first
`Email/get` / `Thread/get`, which run after phase 1 (`Email/query` paging).
Mail arriving between the last query page and the first get advances the
state past a message the id list lacks; M2 `/changes` from that state never
reports it.

Fix: send `Email/get ids:[]` and `Thread/get ids:[]` before phase 1
(ideally in the `Mailbox/get` request, so no extra round trip) and record
their states. Subsumes PHASE-05 A9 (empty gets only on an empty window).
Overlap is harmless: mail arriving mid-run is reported again and re-stored.

Governance: contradicts locked PHASE-05/EX-4 and design § 5.2 ("Email, from
the first Email/get") → amend via REV before changing code. Update sync_test
VT-4 (`type_state_earliest`) to pin the pre-phase-1 state.

No data harm meanwhile: nothing reads `type_state` until M2, and every sync
rewrites the snapshot.
