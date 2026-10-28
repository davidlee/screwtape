# Jev mail classifier verb over PII-stripped read output

## Context

IDE-001 proposed a classifier over Screwtape's CLI JSON contract (SL-003).
The README frames it as Screwtape giving consumers authenticated access to Jev
classifiers that compose with the read tools. Applying the results to mail is
left to consumers.

Jev is TypeSafe's decision model (https://docs.typesafe.ai). It is not an
LLM: the caller sends a `state` plus named, typed questions (choice, score,
noul, which is a 0–1 truth value), and Jev returns typed answers with
probabilities. Upstream: `POST https://api.typesafe.ai/v1/systemone` with a
bearer key.

**Endpoints (operator, 2026-10-28).**
- **Interim:** a direct TypeSafe API key.
- **Later:** the LLM gateway in `~/flakes`, which serves Jev natively at
  `POST /v1/systemone` behind per-client keys (flakes:IMP-054). It takes the
  same request body, so the swap is config plus re-provisioning (DEC-038).
  The gateway relay is `http://127.0.0.1:<port>`, admitted by DEC-033.

**Posture:** rigorous simplicity (SL-002 onward).

## Scope & Objectives

1. **Lift the HTTP seam.** `Send`, `HttpFailure` and the shared status and
   transport-failure mapping move from `jmap/client` to `screwtape/http`.
   JMAP keeps only its problem-document branch and budget (POL-001).
2. **`classify` verb.** It reads version-1 `read` envelopes on stdin
   (`screwtape read --after … | screwtape classify`) and makes one Jev
   request per message, holding every question. It writes one `classify`
   envelope per message (DEC-036). It is separate from `sync` and never
   touches the store.
3. **PII-stripped state (DEC-034).** The state is a fixed field set: the
   subject, the sender domains, the body texts with their truncation and
   conversion flags, and the attachments' `{type, name}`. Every field is
   bounded (body texts 16 KiB in total), so a single message is unlikely to
   block the stream; one that does is skipped by cursor. Erlang `re` rules, in a self-contained `pii` module, replace
   emails, URL paths and queries, IPv4 addresses and runs of 8 or more
   digits, with whole-token date shapes protected. Text is stripped, then
   cut to its bound.
   `classify --state` prints the state without calling Jev.
4. **Question schema `mail-1` (DEC-035).** It has a shared untrusted-content
   preamble and these questions:
   - `primary_purpose`, a choice;
   - nouls `security_related`, `recipient_action_requested`,
     `deadline_present`, `deception_cues` and `agent_directive`;
   - scores `claimed_time_pressure` and `substance`, where `substance` is an
     experiment.
5. **Validation and failure (DEC-037).**
   - Answers are decoded by known question names, never with `decode.dict`.
     Their ranges and internal consistency are checked, and the reported
     `model` must equal the configured one.
   - The first failure ends the run. The lines already classified are kept,
     one error line goes to stderr, and there is no retry.
   - Consumers resume with `--after`.
6. **Config and key ingress (DEC-038, DEC-033).**
   - The config gains an optional `jev {base_url, credential_name, model}`
     block.
   - The Home Manager wrapper runs `classify` under `systemd-run --user
     --pipe -p LoadCredentialEncrypted=jev:…`, with the same crash-dump
     suppression as `screwtape.service`.
   - `screwtape-provision` is generalised to a credential name plus an
     `op://` reference or a key-file source.
7. **Evaluation (POL-002).**
   - `PII_hidden_fixtures.local/` is gitignored, with a test asserting it,
     and holds CLAUDE.md and AGENTS.md notes.
   - Flow: one saved `read` sample → `classify --state` → an LLM tagging
     pass → operator confirmation → `classify` on the same sample → a
     `just eval` report of aggregate agreement, label coverage and Brier
     scores, run before consumers rely on `mail-1`.
   - Built after `classify` is deployed.
   - Scrubbed malebolge fixtures (`test/mail/fixtures/real/`) are copied
     into `test/` for the decode and state tests.
8. **Document it.** The README covers `classify`, `classify_state`, the
   `mail-1` schema and the PII caveat (names and postal addresses leak).

## Non-Goals

- The gateway route itself (flakes:IMP-054).
- Spam as a question. It depends on consent, which Jev cannot see, so it is a
  consumer rule (DEC-035).
- Personal interest, novelty and topic relevance. `substance` is the
  experiment; topic relevance is IDE-002.
- Persisting classifications (DEC-008), classifying inside `sync`, and
  SATAN-side triage (M3).
- Retries (DEC-037).

## Affected surface

- `src/screwtape/http.gleam` (new): the lifted seam.
  `src/screwtape/jmap/client.gleam`: the callers.
- `src/screwtape/cli.gleam`, `argv.gleam`, `src/screwtape.gleam`: the
  `classify` verb, `--state` and stdin injection.
- New modules for the Jev codec, question schema, state builder and PII
  strip (names are settled in design).
- `src/screwtape_ffi.erl`: the `re` wrapper. `test/check_imports.gleam`: its
  allowlist.
- `src/screwtape/config.gleam`: the `jev` block and the DEC-033 scheme rule.
- `nix/module.nix`, `nix/module-eval.nix`: jev options, the wrapper branch
  and the generalised provision.
- `test/`: support helpers, the copied fixtures and the gitignore test.
- `.gitignore`, `PII_hidden_fixtures.local/{CLAUDE,AGENTS}.md`, the
  `justfile` eval recipe, and `README.md`.

## Risks, assumptions, open questions

- `substance` may carry no signal; the eval decides whether it stays.
- The calibration of Jev's probabilities on this mail is unknown, so
  thresholds belong to consumers. The eval gives first evidence, not an
  established calibration.
- Token usage is not recorded by Screwtape; llm-gateway accounting is
  expected to show it (unverified).
- The regex strip is best-effort, and names and postal addresses leak.
  `--state` makes the strip auditable.
- Deferred (SL-004 inq-9): the satan:RFC-020 D1/D5 amendment, drafted in
  `~/dev/satan` for the operator to commit, and the DEC-016 exposure note.
  Both are due by close.

## Verification intent

- Codec, state and PII-strip tests: synthetic strings for the strip, and the
  copied scrubbed fixtures for decode and state.
- Hostile and malformed Jev responses fail closed, with error paths naming
  only our own question names.
- The token-leak sentinel suite covers `classify`. The gitignore test covers
  `PII_hidden_fixtures.local/`.
- Module evaluation checks for the wrapper and provision.
- A manual live run on the scrubbed fixtures, then the eval on real mail
  (aggregates only, POL-002).

## Summary

## Follow-Ups
