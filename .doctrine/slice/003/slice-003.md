# Screwtape read contract for M3 consumers

## Context

SL-001 (M1) and SL-002 (M2) built the mirror: a bounded, incremental sync of
one Fastmail account into SQLite, with the JSON read verbs `mailboxes`,
`list`, `read` and `thread` for humans.

satan:RFC-020 D8 puts M3 next: SATAN triage through native `mail_*` tools in
pi-durable. Those tools are TypeScript and share no code with Screwtape
(satan:RFC-020 D2). They read through an **explicit, versioned contract that
Screwtape publishes and tests**, never its internals. satan:RFC-020 OQ-11
leaves the contract's form open and says it must be fixed before M3:

- **read schema:** versioned SQLite views over the store, read in-process;
  the tables behind them stay private;
- **CLI JSON:** a schema for each read verb's output; one BEAM start per call.

SL-002 also deferred the **consumer cursor** (satan:RFC-020 D1's consumer half
of `changes`) to this contract: how a consumer asks what changed since it last
looked.

**Posture: rigorous simplicity** (operator, 2026-10-27). Read-side security
was settled in SL-001 and is not reopened.

## Scope & Objectives

1. **Settle satan:RFC-020 OQ-11**: the contract is the CLI JSON envelopes
   (DEC-027), versioned by DEC-029.
2. **Define the contract**: its version, the fields it exposes (including the
   brief's bounds and provenance fields: truncation, ids, source mailbox,
   sync time), and its compatibility rule (what a version bump means).
3. **Consumer cursor**: an arrival cursor over `(received_at_ms, id)`, held by
   the consumer (DEC-028). Pipe surface: `list --after`, `read --after`,
   `thread --limit` (DEC-032). Further query operations are deferred until
   there is evidence of need (operator, 2026-10-27).
4. **Publish and test it** (DEC-030): render and CLI tests pin the output, so
   a change that breaks a consumer fails Screwtape's suite.
5. **Document it**: the README (or a contract doc it links) states the
   contract for consumers; satan:RFC-020 OQ-11 is answered by a draft
   amendment in `~/dev/satan` for the operator to commit.

**Not docs only.** satan:RFC-020 D2 requires Screwtape to publish *and test*
the contract. The code delta is the argv flags, the cursor field, `read
--after`'s line-per-message output, `thread --limit`, and their tests. No
schema change.

## Non-Goals

- The IDE-001 classifier (separate, composes by pipe).
- Multi-id `read`, plural `thread`, other batch or search queries (DEC-032).
- The `mail_*` tools, the restricted triage invocation, the digest and
  prompt-injection cases (M3, pi-durable / satan).
- Proposals and mutation (M4).
- IMP-001 (fail closed on `isReadOnly: false`): operator declined for now.
- Retention by age (rest of satan:RFC-020 OQ-10).
- Reopening sync, credential or read-side security design.

## Affected surface

- `src/screwtape/cursor.gleam` (new);
- `src/screwtape/store/query.gleam` (cursor selection, shared `message_ids`
  and `messages_of` with `prior`, thread limit);
- `src/screwtape/render.gleam`, `src/screwtape/cli.gleam`,
  `src/screwtape/argv.gleam`, `src/screwtape/model.gleam`;
- `test/**` contract tests;
- `README.md`.

## Risks, assumptions, open questions

- **ASM:** M3's consumer is one triage invocation on this host, reading the
  store from Screwtape's state dir with read access only.
- **Risk:** the arrival cursor's known limits (design § 5.2, RV-010): mail
  entering the window with an older `received_at`; filters do not reopen
  passed positions; a future-dated message moves a cursor past later mail;
  the cursor is not account-scoped. All documented in the README contract.
- Reader access needs are stated, jail binds are satan's (DEC-031).

## Verification / closure

- satan:RFC-020 OQ-11 answered in design, with the reasoning recorded.
- Contract tests pin the published form and version; they fail on a breaking
  store or renderer change.
- Cursor tests: a full `--after` walk over a store with `received_at_ms`
  ties returns every message exactly once, oldest first.
- README states the contract; the satan:RFC-020 amendment is drafted.

## Summary

## Follow-Ups
