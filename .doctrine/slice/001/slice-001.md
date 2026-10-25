# Screwtape M1: Gleam JMAP mirror, full bounded sync

## Context

Screwtape is the JMAP connector and sole credential holder of **Belphegor**,
the read-only mail subsystem for SATAN. Belphegor's architecture is
deliberated in satan's RFC-020: `~/dev/satan`, `doctrine show RFC-020` there.
In brief:

- A scheduled mirror outside the agent syncs Fastmail into a local store, and
  every consumer reads only the store.
- No agent-reachable process holds a mail credential.
- Wormwood, a future executor, will apply human-approved operations with a
  separate write token.

This slice is RFC-020's milestone 1 (D8). It builds a Gleam program on BEAM
that syncs a bounded window of mail over JMAP (Fastmail's JSON mail protocol:
RFC 8620 core, RFC 8621 mail) into SQLite. There is no LLM, no SATAN
integration and no Emacs.

Operator decisions this slice builds on, all from 2026-10-26 and recorded in
RFC-020:

- Gleam on BEAM.
- SQLite, under `~/.local/state/screwtape/`.
- The token is read from an `op://` reference when the unit starts. No token
  file exists.
- M1 and M2 (incremental sync) stay separate.
- Emacs has no part in it.
- SATAN will consume Screwtape through an explicit, versioned contract (form
  open, RFC-020 OQ-11), never its internals.

Prerequisite: CHR-001, the flake bootstrap (devshell, checks, quotient forms).

## Scope & Objectives

1. **This repo** (Gleam, BEAM target):
   - **JMAP client, restricted to what Screwtape needs:**
     - session discovery;
     - `Mailbox/get`;
     - `Email/query`;
     - `Email/get` with `fetchTextBodyValues` / `fetchHTMLBodyValues` and
       `maxBodyValueBytes`;
     - `Thread/get`.

     It is not a general-purpose client and offers no pass-through for
     arbitrary requests.
   - **Normalised model:** messages, addresses, mailboxes, attachment metadata
     and provenance (account id, JMAP id, thread id, `Message-ID` header kept
     separate from the JMAP id).
   - **Bounded full sync of a configured window:** mailboxes, date range or
     count, per-message body bytes, page depth and request timeouts.
     Truncation is recorded per message, never silent. Hitting a limit gives
     an explicit error or truncation metadata.
   - **HTML-only bodies** are reduced to text at sync time, with no external
     fetch.
   - **The SQLite store:**
     - The schema records JMAP state strings (`Email`, `Mailbox`, `Thread`)
       from the start, so M2 adds behaviour without a schema break.
     - Tables are laid out so versioned read views can be added later
       (RFC-020 OQ-11).
     - A failed sync leaves the previous store intact (one transaction per
       sync, or an equivalent swap).
   - **JSON CLI, data on stdout and diagnostics on stderr:**
     - `sync`, the verb the unit runs;
     - read verbs over the store for humans: `mailboxes`, `list`, `read`,
       `thread`.
   - **The token** reaches the process only through its environment. It never
     appears in argv, logs, errors or the store, and tests assert this.
   - **The flake package output** (CHR-001 provides the devshell, checks and
     forms).
2. **Deployment in `~/flakes`:**
   - the package input;
   - a oneshot user service plus timer that resolves the `op://` reference at
     start (`op run`, after the jailed-agents precedent in
     `~/flakes/agents/README.md`);
   - the state directory.
3. **satan:**
   - a `check-jails` assertion (satan's `justfile` and `flake.nix` checks,
     where `check-jails` lives) that the `op` wrapper and the 1Password app's
     sockets reach no jail that holds model output. The abstract socket is
     included (RFC-020 D3; research finding 2).
   - update RFC-020 with settled findings;
   - add Screwtape to SPEC-002 (satan's context spec) if design says it
     belongs there.

## Non-Goals

- Incremental sync, `Email/changes` and `queryChanges` (M2). The schema is
  ready for them but the behaviour is not built.
- Any SATAN integration: `mail_*` tools, triage, digests (M3); fixing the
  Screwtape↔SATAN contract form (before M3).
- Operation proposals (M4), Wormwood, and any mailbox write.
- Emacs or Gnus.
- Attachment download.
- Sending mail.
- Full-text indexing.
- A daemon.
- Authority-ledger rows (RFC-020 OQ-2, deferred).
- Retention beyond the configured window (OQ-10).

## Affected surface

- This repo: `gleam.toml`, `src/**`, `test/**`, `flake.nix`, `README.md`.
- `~/flakes`: package input, the `features/` unit and timer.
- `~/dev/satan`: `justfile` and `flake.nix` (the `check-jails` assertion), `.doctrine/rfc/020/`, and possibly
  `.doctrine/spec/tech/002/`.

## Risks, assumptions, open questions

- **Gleam ecosystem (unverified, needs research).** It is not yet known
  whether these exist and are maintained: a JMAP client; HTTP and JSON
  libraries; a SQLite binding for BEAM; HTML-to-text; Nix packaging of Gleam
  with its Erlang dependencies. A gap here could mean writing more than
  expected, or an Erlang FFI (calls into Erlang code).
- **Fastmail facts (unverified, needs research):**
  - the read-only token scope and its capability URIs;
  - the session URL;
  - request caps (`maxObjectsInGet`, `maxCallsInRequest`) and rate limits;
  - `Email/queryChanges` support, which matters for M2 but shapes the schema
    now.
- **1Password in a timer (RFC-020 OQ-4, unverified):**
  - Can a non-interactive user unit resolve a ref through the desktop
    integration?
  - What happens when the app is locked? The assumption is that the run fails
    loudly and the previous store stands.
  - Does the integration authorise each calling process?
- **Assumption:** the user unit runs as `david` (implied by `op://`, RFC-020
  D3).
- **Risk:** plaintext mail on disk is readable by unjailed processes running
  as `david` (RFC-020 D3). It is accepted for M1 and must be stated in the
  README.
- **Live run:** one read-only sync against the real account. It needs a
  read-only token created by the operator in Fastmail, with its `op://` ref
  supplied.

## Verification / closure intent

- **Mocked tests:** Gleam tests against recorded or synthetic JMAP fixtures,
  with no real credentials or mail in the repo. They cover:
  - auth and API errors;
  - pagination and limits;
  - malformed responses;
  - missing messages;
  - multipart and HTML-only bodies, and HTML with external resources (never
    fetched);
  - large bodies and truncation;
  - Unicode;
  - token absence from logs and errors;
  - store atomicity on failed sync.
- **Deployment check:** `check-jails` passes with the new assertion.
- **Live acceptance (RFC-020 M1):** a sync with the read-only token puts a
  bounded set of real messages in the store. The mailbox is unchanged
  (verified by mailbox state before and after; a read-only token makes
  mutation impossible).
- `gleam format --check` and `nix flake check` are clean.

## Summary

Screwtape M1 is a Gleam (BEAM) oneshot that mirrors a bounded window of
Fastmail mail into SQLite, using a read-only token resolved from 1Password at
start. It has a human JSON CLI and is deployed as a user timer from
`~/flakes`.

## Follow-Ups

- M2 incremental sync (RFC-020 D8).
- RFC-020 OQ-11: the contract form, before M3.
- RFC-020 OQ-2: the ledger row.
