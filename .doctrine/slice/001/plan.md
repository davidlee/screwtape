# Implementation Plan SL-001: Screwtape M1: Gleam JMAP mirror, full bounded sync

Prose companion to `plan.toml`. Narrative only — no queried data lives here
(the storage rule); the phase list, criteria, verification, and links are
authored in the TOML. Use this for the plan's rationale and sequencing.
<!-- Reference forms: `lib:reference/glossary.md` § reference forms. -->

## Overview

Nine phases. Seven build this repo bottom-up, from packaging to the
deployment module. One does the out-of-repo satan work. The last deploys
through `~/flakes` and runs the live acceptance.

```text
PHASE-01 packaging skeleton ─┐
                             ▼
PHASE-02 transport proof + client + thin CLI   (RV-001 F-1, F-12, F-19, F-20)
                             ▼
PHASE-03 pure core + import check              (RV-001 F-9; ASM-002)
                             ▼
PHASE-04 store                                 (RV-001 F-14, F-22)
                             ▼
PHASE-05 sync orchestration                    (extends F-1; needs PHASE-02's proof)
                             ▼
PHASE-06 read verbs                            (RV-001 F-15)
                             ▼
PHASE-07 Home Manager module + package + README
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

**PHASE-02 is the token path, whole.** RV-001 F-1 places the I1 sentinel
suite in the phase that introduces the client and credential. That suite runs
the built code as a subprocess, so PHASE-02 also needs `main`, `cli`,
`config` and `error`. Its `sync` stops after `Mailbox/get`, and PHASE-05
replaces that stub with the orchestration. A stub `sync` lives only on an
undeployed branch of history; nothing deploys before PHASE-09.

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
| F-1 crash reports | PHASE-02 | EX-8, extended by PHASE-05/EX-7 |
| F-9 per-message body bound | PHASE-03 | EX-3 |
| F-12, F-19 oversized bodies | PHASE-02 | EX-3 |
| F-20 hidden retry | PHASE-02 | EX-4 |
| F-14 migrations in the transaction | PHASE-04 | EX-3 |
| F-22 newer schema refused | PHASE-04 | EX-4 |
| F-15 one snapshot per read | PHASE-06 | EX-2 |

Each control must also reject its named wrong implementation. PHASE-02/VA-1
records that demonstration for the transport and crash controls. For the
others, the test's design does that work (for example, migrate-on-open would
fail F-14's assertion directly).

**Open items and where they land.**

- ASM-001 → PHASE-01. ASM-002 → PHASE-03. ASM-004, ASM-005, OQ-A → PHASE-09.
- ASM-003 does not gate this slice. satan RSK-021 owns its probe. PHASE-08's
  scan guards only the known paths.
- Lingering → PHASE-09/EN-4, the operator's choice.
- Library pins (design § 6) → PHASE-01/EX-1.
- RFC-020 drafts (DEC-015) → PHASE-08.

## Notes

- **Parallelism.** PHASE-08 is file-disjoint from this repo and can run
  alongside any phase. Every other phase is serial.
- **CHR-001.** It is recorded as the slice's `needs` relation. Its flake work
  is done; the open item is swapping the quotient pin to a published tag.
  That blocks only `~/flakes` consuming this flake on another host, so it
  becomes PHASE-09/EN-3, not a PHASE-01 gate.
- **Not in this plan.** Sync-failure notification (`OnFailure=`, RV-001 F-8,
  follow-up) and `~/flakes` IMP-042 (the jail launch guard behind I7's launch
  condition) are tracked outside this slice.
