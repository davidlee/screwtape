# Research: SL-003 (read contract for M3 consumers)

## Header

- **Thread 1 (governance)** and **Thread 2 (code map)**: the orchestrator
  (Opus 5.5), read directly, 2026-10-27. No research agents were spawned: the
  surface is small (store, query, render, argv) and every row below is
  load-bearing, so it was cheaper to read than to delegate and re-verify.
  `raw/` is therefore empty.
- satan sources read: satan:RFC-020 (D1, D2, D5, D8, OQ-10, OQ-11) via
  `doctrine show` in `~/dev/satan` at e91d89f; the brief
  `~/dev/satan/docs/email-brief.local.md` §3.1, §3.2, §4.2, §4.4, §5, §8 M3.
- Baseline: `baseline.toml`, stamped by `doctrine slice research 3`.

## Verification legend

- ✓ means the orchestrator read the cited site in this round.
- **R** means recalled, not read (SQLite behaviour). Design must confirm an R
  row by a test or a doc read before relying on it.

## Thread 1: governance applicability

**Binding**

| Source | Constraint on SL-003 |
|---|---|
| POL-001 (required) | One implementation per behaviour. A contract must not become a second renderer or a second query layer beside `render` / `store/query`. |
| DEC-007 (accepted) | Tables are private; the `v<N>_` prefix is **reserved for versioned views** (OQ-11). `PRAGMA user_version` is the one migration ledger; migrations run only inside the snapshot write transaction. ✓ facet text |
| DEC-008 (accepted) | Every sync is one `BEGIN IMMEDIATE` transaction that deletes every data row and inserts the snapshot. WAL; each read verb runs in one read transaction. ✓ facet; ✓ `store.gleam:1-21` |
| DEC-011 (accepted) | CLI stdout is one JSON document in a `{"version":1,...}` envelope; stderr JSON-line diagnostics; exit 0/1/2. Rationale: "the version envelope keeps the CLI usable as a contract". ✓ facet |
| DEC-016, DEC-017 (accepted) | Store lives in `~/.local/state/screwtape` (0700, operator uid), inside the `$HOME` that jails shadow. Read verbs open the store read-only as the caller. "M3 consumers running as the operator read the store directly; OQ-11's two contract forms both remain possible." ✓ facets |
| DEC-015 (accepted) | A SPEC-002 entry for Screwtape is deferred to M3, "when Screwtape first connects to SATAN". satan governance changes are drafted here and committed by the operator. ✓ facet |

**Evidence (satan, not binding here)**

- satan:RFC-020 D2: the M3 tools consume "an explicit, versioned contract that
  Screwtape publishes and tests, never its internals"; it "carries the
  brief's bounds and provenance fields, and Screwtape's tests assert them".
- satan:RFC-020 D1: the consumer half of `changes` "is a cursor over the
  store, held by each consumer".
- satan:RFC-020 OQ-11: views or CLI JSON; "must be fixed before M3".
- satan:RFC-020 D5: the triage invocation's placement (runner job, timer,
  mode) is open (satan:RFC-020 OQ-6).
- Brief §4.4: bound result counts, messages per batch, body bytes per
  message, aggregate bytes per invocation, thread size, pagination depth;
  return explicit errors or truncation metadata.
- Brief §3.1: `read` takes "one or more" ids; `thread` is "subject to count
  and total-byte limits".

**Checked, not applicable**

- ADRs, standards, specs: none exist in this repo.
- DEC-001, DEC-012 (token custody/ingress), DEC-018 (CA trust): read side
  does not touch the credential or the network.
- DEC-024..026 (retention and M2 id sources): unchanged; consulted only for
  how `email_state` is stamped (Thread 2).
- IMP-001: out of scope by operator ruling, 2026-10-27.

**Revision candidates**

- satan:RFC-020 OQ-11 answer and the D1 cursor wording (draft amendment in
  `~/dev/satan`, operator commits; precedent DEC-015).
- DEC-015's deferred SPEC-002 entry: M3 is when it falls due; note for the
  satan amendment, not this slice.

## Thread 2: code map

**Hotspots**

| File | Role for SL-003 |
|---|---|
| `src/screwtape/render.gleam` (263 lines) | Sole writer of the `{"version":1,"kind","data"}` envelope ✓ `:21-28`. Shapes: `mailboxes`, `list`, `read` (with `provenance: {account_id, email_state}` and `output_truncated`) ✓ `:57-95`, `thread` ✓ `:98`. Shared `summary_fields` keeps list/thread/read summaries identical ✓ `:108-123`. |
| `test/screwtape/render_test.gleam` | Already pins every printed field and its order: `envelope_prints_version_kind_and_data_test`, `mailboxes_prints_every_field_in_order_test`, `read_prints_the_whole_message_with_provenance_test`, `read_omits_blob_id_and_max_body_value_bytes_test`, `thread_prints_…` ✓ `:390-726`. |
| `src/screwtape/store/query.gleam` (766) | `ListQuery{mailbox_ids, since_ms, from, unread, limit, offset}` ✓ `:27-37`; `messages` newest first by `received_at_ms` desc, `id` desc ✓ `:60-74`; `thread` returns every entry, **unbounded** ✓ `:90-114`. |
| `src/screwtape/argv.gleam` (319) | Verbs `sync`, `mailboxes`, `list`, `read`, `thread` ✓ `:79-94`; `list --since` is a date (midnight UTC), not an instant ✓ `:11,36-37`; `--limit` 1..500, default 50 (DEC-011). |
| `src/screwtape/store.gleam` (872) | Schema v1 is the only migration ✓ `:19-21,680-824`; `message.email_state` column ✓ `:749`; no change log, no per-row sequence. |
| `src/screwtape/normalise.gleam` | `refresh` sets a message's `email_state` to the state of the response that delivered the light refresh ✓ `:339-356`. |
| `src/screwtape/retain.gleam` | Pure merge; `add_fetched` replaces on id clash ✓ `:72-83`. |

**Cited facts**

- F1 ✓ The store has **no monotonic marker**. `sync.synced_at` is one row per
  account, overwritten each run (`store.gleam:695-703`). JMAP state strings
  are opaque (RFC 8620 §5.1) and not orderable.
- F2 ✓ `message.email_state` is not a "changed" marker: on the full path
  every stored id gets a light refresh (SL-002 scope §2, DEC-026), and
  `normalise.refresh` restamps `email_state` whether or not anything changed
  (`normalise.gleam:339-356`).
- F3 ✓ `(received_at_ms, id)` is a total order already used by `list` and
  `retain` (`query.gleam:60-63`; `retain.gleam:39`).
- F4 ✓ The JSON shapes are already exact and tested (render_test). The
  envelope is version 1, set in one place.
- F5 ✓ Bounds today: `list --limit ≤ 500`; `read --max-bytes` (shared body
  budget, `output_truncated`); stored bodies carry `is_truncated` and
  `truncated_by` (server|message_limit). **Unbounded:** `thread` entry count;
  aggregate bytes across calls (per-invocation, the consumer's job).
- F6 A read-only (`?mode=ro`) connection on the WAL store creates `-wal`
  and `-shm` beside it, so the store's directory must be writable to the
  reader (memory `mem.fact.sqlite.esqlite-readonly-uri`, probed 2026-10-26;
  not re-probed here). Matters if a jailed consumer gets a read-only bind of
  the store.

**Naming precedents**

- Envelope `kind` = verb name; fields snake_case; optional values print
  `null`, never omitted (`render.gleam:1-6`).
- Reserved `v<N>_` view prefix (DEC-007).

## Cross-thread findings

1. **CLI JSON is already a versioned, tested contract (F4, DEC-011).** Views
   would be a second read surface beside `store/query` + `render`, which
   POL-001 resists, and would freeze table semantics behind a stable
   interface every migration must keep. CLI JSON costs a BEAM start per call
   (satan:RFC-020 D2); a triage run makes tens of calls, not thousands.
2. **The cursor cannot be built from what is stored (F1, F2).** Options:
   - a. **Arrival cursor** over `(received_at_ms, id)` (F3): no schema change;
     `list` gains an exclusive `--after <received_at_ms>:<id>` (or similar)
     and ascending order. Misses: a message entering the window late with an
     older `received_at` (moved into Inbox, retention widened), and keyword
     or mailbox changes. For triage ("what new mail arrived") this may be
     enough.
   - b. **Store sequence**: schema v2 adds a run counter and a per-message
     `changed_seq`, carried across runs and bumped only when a message is
     new or its `mailbox_ids`/`keywords` change. Catches late arrivals and
     flag changes; costs a migration and a comparison in the merge.
   satan:RFC-020 D1 puts the cursor's state with the consumer either way;
   Screwtape only needs an orderable value to filter on.
3. **Jail reach is the same for both forms (DEC-016, F6).** The store sits in
   the shadowed `$HOME`. Whether the triage invocation is jailed is
   satan:RFC-020 OQ-6. A jailed consumer needs a bind of the store (and, for
   CLI JSON, the screwtape binary) either way; WAL makes a read-only bind
   awkward (F6 R). Not Screwtape's to solve, but the contract doc must state
   the reader's file-access needs.
4. **Bounds gaps vs brief §4.4 (F5).** `thread` has no count bound; `read`
   takes one id (brief: "one or more"). Per-invocation aggregate bytes belong
   to the consumer (the `mail_*` tools), not a one-shot CLI.

## Design-input deltas

- Lean confirmed: **CLI JSON** as the contract (finding 1). The contract is
  the documented set of envelope shapes at `version: 1`, pinned by the
  existing render tests plus a small contract test; no views.
- Decide the cursor between 2a and 2b; 2a is the rigorous-simplicity default
  if triage only needs arrivals.
- Decide whether to bound `thread` (a `--limit`) now; batching `read` is
  optional (one call per id is acceptable under finding 1).
- Define the compatibility rule: adding a field is compatible within a
  version; removing, renaming or retyping one bumps `version`.
- State the reader's access needs (store dir, WAL files) in the contract doc.
