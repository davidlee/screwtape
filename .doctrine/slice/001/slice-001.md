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
- SQLite, in Screwtape's own state directory.
- The token's source is 1Password, with no cleartext token file.

**Amended in design (2026-10-26, DEC-001, DEC-004, DEC-016, DEC-017).** The research showed that
resolving `op://` when the unit starts prompts on every run. So instead:

- The operator provisions the token once per rotation into a user-scoped
  encrypted systemd credential (`op read | systemd-creds encrypt --user`,
  the llm-gateway pattern at user scope).
- A Home Manager `systemd --user` unit, running as the operator, loads it
  with `LoadCredentialEncrypted=`.
- The store sits in that unit's 0700 `StateDirectory`, under the `$HOME`
  that the operator's jails shadow.
- Humans read it directly; the wrapper only supplies `--config`.
  (DEC-016 and DEC-017 superseded an earlier dedicated-uid and `sudo -u`
  design: the operator's uid already reaches the same mail, and the jail is
  the boundary.)
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
     - `Email/get` with `fetchTextBodyValues` and `maxBodyValueBytes`. An
       HTML-only message presents its HTML in `textBody` (RFC 8621 §4.1.4),
       so `fetchHTMLBodyValues` is not needed (design § 5.2);
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
   - **The token** reaches the process only as a file in
     `$CREDENTIALS_DIRECTORY` (DEC-001, DEC-012). It never appears in argv,
     logs, errors or the store, and tests assert this.
   - **The flake package output** (CHR-001 provides the devshell, checks and
     forms).
   - **A Home Manager module** (`homeManagerModules.default`, DEC-004)
     providing:
     - the options: `op://` ref, window and bounds, timer;
     - the `systemd --user` oneshot service plus timer with hardening
       (DEC-016);
     - the JSON config file (DEC-009);
     - the provisioning command (`op read | systemd-creds encrypt --user`);
     - a `screwtape` wrapper that adds `--config` (DEC-011, DEC-017).
2. **Deployment in `~/flakes`:**
   - the `screwtape` input;
   - a feature whose `homeManager` key imports the module and sets the ref
     and window;
   - optionally, lingering for the operator, so the timer runs while logged
     out;
   - host facts in `SATAN.md`.
3. **satan:**
   - a `check-jails` assertion (satan's `justfile` and `flake.nix` checks,
     where `check-jails` lives) that the `op` wrapper and the 1Password app's
     sockets, or a directory above one, are bound into no jail that holds
     model output (DEC-013). It is a regression guard for known paths, not
     proof of NF-004. The abstract socket rests on 1Password's GID check
     (ASM-003, unvalidated; satan RSK-021 owns the negative probe).
   - drafts of RFC-020 revisions (D3, OQ-4, D7 row 10, the OQ-7 drift) for the
     operator to commit (DEC-015);
   - the SPEC-002 entry is deferred to M3 (DEC-015).

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

- This repo: `gleam.toml`, `manifest.toml`, `src/**`, `test/**`, `flake.nix`
  (package, checks, `homeManagerModules`), `nix/**`, `README.md`.
- `~/flakes`: the `screwtape` input, a feature with a `homeManager` key,
  `SATAN.md`.
- `~/dev/satan`: `justfile` and `flake.nix` (the `check-jails` assertion), and
  `.doctrine/rfc/020/` (drafts only).

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
- **1Password in a timer (RFC-020 OQ-4).** This was settled in design: `op`
  leaves the run-time path (DEC-001).
- **Packaging risk:** the esqlite NIF must build offline (ASM-001), so plan
  phase 1 is a spike (DEC-005).
- **Risk:** mail is plaintext on disk, readable by the operator's uid and
  root, as the operator's existing Gnus and Thunderbird copies are; jails
  don't see it (DEC-016). The README must state this.
- **Live run:** one read-only sync against the real account. It needs:
  - a read-only token, created by the operator in Fastmail;
  - its `op://` ref;
  - one provisioning run.

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
Fastmail mail into SQLite. It uses a read-only token, provisioned from
1Password into an encrypted systemd credential. It has a human JSON CLI, and
runs as a hardened `systemd --user` timer under the operator's uid. The module ships
from this repo, and `~/flakes` enables it.

## Follow-Ups

- M2 incremental sync (RFC-020 D8).
- RFC-020 OQ-11: the contract form, before M3.
- RFC-020 OQ-2: the ledger row.
