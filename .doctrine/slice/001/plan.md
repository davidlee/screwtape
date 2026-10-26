# Implementation Plan SL-001: Screwtape M1: Gleam JMAP mirror, full bounded sync

Prose companion to `plan.toml`. Narrative only — no queried data lives here
(the storage rule); the phase list, criteria, verification, and links are
authored in the TOML. Use this for the plan's rationale and sequencing.
<!-- Reference forms: `lib:reference/glossary.md` § reference forms. -->

## Overview

Eleven phases. Eight build this repo bottom-up, from packaging to the
deployment module. PHASE-11 fixes ISS-001, a sync-state race found in
PHASE-05's review. One does the out-of-repo satan work. The last deploys
through `~/flakes` and runs the live acceptance.

```text
PHASE-01 packaging skeleton ─┐
                             ▼
PHASE-02 HTTP transport proof                  (RV-001 F-12, F-19, F-20)
                             ▼
PHASE-10 client + thin CLI + token-leak suite  (RV-001 F-1, F-20 client half)
                             ▼
PHASE-03 pure core + import check              (RV-001 F-9; ASM-002)
                             ▼
PHASE-04 store                                 (RV-001 F-14, F-22)
                             ▼
PHASE-05 sync orchestration                    (extends F-1; needs PHASE-02/10's proof)
                             ▼
PHASE-06 read verbs                            (RV-001 F-15)
                             ▼
PHASE-07 Home Manager module + package + README
                             ▼
PHASE-11 Email/Thread state before phase 1     (ISS-001; supersedes part of PHASE-05/EX-4)
                             ▼
PHASE-09 deployment + live acceptance          (ASM-004, ASM-005, OQ-A)

PHASE-08 satan op-unjailed + RFC-020 drafts    (independent; any time before PHASE-09 closes)
```

## Sequencing & Rationale

**Risk first.** The two technical risks are the esqlite NIF under an offline
Nix build (ASM-001) and httpc's byte cap (RV-001 F-12, F-19, F-20). The
F-12/F-19/F-20 claims rest on reading the inets source, not on running it.
PHASE-01 and PHASE-02 retire both before any domain code depends on them. A
failure in either changes the design, so it should surface while little is
built on top.

**The transport proof stands alone; the token path follows whole.** PHASE-02
proves httpc's behaviour on the raw `Send`, so the riskiest empirical claims
close before any client code exists (plan review, 2026-10-26). RV-001 F-1
places the I1 sentinel suite in the phase that introduces the client and
credential, and that suite runs the built code as a subprocess, so PHASE-10
carries the client, `main`, `cli`, `config` and `error` together. Phase ids
are immutable, so the split-off phase is PHASE-10, ordered after PHASE-02.
PHASE-10's `sync` stops after `Mailbox/get`, and PHASE-05 replaces that stub
with the orchestration. Nothing deploys before PHASE-09.

**TLS in tests** (DEC-018). Production accepts only https, so `local_jmap`
serves TLS from a CA generated per run, and tests set `ca_file` to it.
PHASE-01/EX-7 proves that works inside the Nix sandbox before PHASE-02 builds
on it.

**Pure core before store before sync.** `normalise` and `html_text` don't
depend on I/O, so they're quickest to test and they fix the model types that
the store mirrors. The store comes next because the sync writes through it.
PHASE-05 integrates the three and must see the transport proof pass first
(its EN-1), because its byte-ceiling behaviour depends on it.

**Read verbs after sync.** RV-001 F-15 places the I8 test with the read
verbs. A real snapshot written by `sync` makes the verb tests faithful to
production.

**Deployment last.** PHASE-07 is evaluation-only (`module-eval`, no VM).
PHASE-09 needs operator acts: the token, provisioning, the lingering choice
and the OQ-A ruling. ASM-005's remaining unknowns (the real BEAM under the
hardening, TPM binding) can only be settled on the host.

**Placement of RV-001's control-routed findings.** Each criterion cites its
finding inline.

| Finding | Host phase | Criterion |
|---|---|---|
| F-1 crash reports | PHASE-10 | EX-5, extended by PHASE-05/EX-7 |
| F-9 per-message body bound | PHASE-03 | EX-3 |
| F-12, F-19 oversized bodies | PHASE-02 | EX-3 |
| F-20 hidden retry | PHASE-02, PHASE-10 | PHASE-02/EX-4 (one request, capped), PHASE-10/EX-2 (surfaces as an error) |
| F-14 migrations in the transaction | PHASE-04 | EX-3 |
| F-22 newer schema refused | PHASE-04 | EX-4 |
| F-15 one snapshot per read | PHASE-06 | EX-2 |

Each control must also reject its named wrong implementation. PHASE-02/VA-1
and PHASE-10/VA-1 record that demonstration for the transport and crash
controls. For the
others, the test's design does that work (for example, migrate-on-open would
fail F-14's assertion directly).

**Open items and where they land.**

- ASM-001 → PHASE-01. ASM-002 → PHASE-03. ASM-004, ASM-005, OQ-A → PHASE-09.
- ASM-003 does not gate this slice. satan RSK-021 owns its probe. PHASE-08's
  scan guards only the known paths.
- Lingering → PHASE-09/EN-4, the operator's choice.
- Library pins (design § 6) → PHASE-01/EX-1.
- RFC-020 drafts (DEC-015) → PHASE-08.

## Risks for the phase plans

- **Forcing a crash inside the client** (PHASE-10/EX-5). The I1 suite needs
  a crash in a frame that holds the revealed header, triggered in the built
  code with no test hook in production. Candidate triggers are a sentinel
  token with header-illegal bytes, or a response that httpc fails on. This is
  the phase's first unknown. If only a production hook would work, stop and
  /consult.
- **Withholding a body end.** The transport proof needs exact control of
  framing and timing. PHASE-02/EX-2 states the capability, not the mechanism:
  inets httpd if it can withhold the end of a body, raw `ssl` sockets
  otherwise.
- **Where raw JMAP types live** (PHASE-03). The import allowlist confines
  `normalise` to stdlib, `model` and `html_text`. So the decoded JMAP email
  type belongs in `model` or `normalise`, and `jmap/decode` imports it from
  there.
- **F-20's "charged to the Budget".** `call` returns an error on a 503 and
  the run ends, so no later balance is observable. The criterion is read as:
  the 503 body is received under the remaining-budget cap (PHASE-02/EX-4's
  oversized 503), after exactly one request.

## Notes

- **PHASE-11 (added 2026-10-26).** PHASE-05's review found that the Email
  and Thread `type_state`, taken from the first phase-2 get, can postdate
  mail missing from the stored id list (ISS-001). The operator chose a new
  phase over reopening PHASE-05, so PHASE-05's evidence stays true for what
  it built. PHASE-11/EX-1 supersedes PHASE-05/EX-4's Email and Thread
  sources; PHASE-05's ids and text are unchanged. It runs before PHASE-09,
  so the deployed binary carries the fix.

- **Parallelism.** PHASE-08 is file-disjoint from this repo and can run
  alongside any phase. Every other phase is serial.
- **CHR-001.** It is recorded as the slice's `needs` relation. Its flake work
  is done; the open item is swapping the quotient pin to a published tag.
  That blocks only `~/flakes` consuming this flake on another host, so it
  becomes PHASE-09/EN-3, not a PHASE-01 gate.
- **Not in this plan.** Sync-failure notification (`OnFailure=`, RV-001 F-8,
  follow-up) and `~/flakes` IMP-042 (the jail launch guard behind I7's launch
  condition) are tracked outside this slice.
