# Implementation Plan SL-004: Jev mail classifier verb over PII-stripped read output

Prose companion to `plan.toml`. Narrative only — no queried data lives here
(the storage rule); the phase list, criteria, verification, and links are
authored in the TOML. Use this for the plan's rationale and sequencing.
<!-- Reference forms: `lib:reference/glossary.md` § reference forms. -->

## Overview

Four phases, in the operator's order (2026-10-28). They deliver a deployed
`classify`. The evaluation on real mail is IMP-003, not this slice.

```
PHASE-01 http seam lift
   └─▶ PHASE-12 pure core: pii, classify/input, classify/state,
                 jev, jev/client, classify/schema  (spec-based Jev fixtures)
          └─▶ PHASE-13 classify verb: argv, config, run_piped, stdin edge,
                        render, loop, token-leak
                 └─▶ PHASE-14 nix ingress + POL-002 guard + README
                               ── operator: store key, deploy ──▶ live check (A1)
```

## Supersession

An 11-phase draft (PHASE-01..11) came first. Phase ids are never reused, so:

| draft | now |
|---|---|
| PHASE-01 | PHASE-01, unchanged but for its entry criterion and a review row |
| PHASE-03, -04, -05 | PHASE-12 |
| PHASE-06, -07 | PHASE-13 |
| PHASE-02, -08, -09 | PHASE-14 |
| PHASE-10, -11 | dropped: the eval is IMP-003 |

The draft's criteria are merged, not dropped: they carry the RV-016 repairs
and cite the findings they implement. Its per-phase Opus review rows are
replaced by the review posture below.

## Sequencing & Rationale

- **PHASE-01 first.** A pure move behind the existing JMAP tests (design
  § 8). Everything that talks to Jev depends on `screwtape/http`.
- **PHASE-12 holds every pure module.** None has effects, so all are tested
  against fixtures: synthetic strings for the strip, the copied scrubbed
  `read` envelopes for input and state, and Jev replies modelled on the
  OpenAPI spec. Building the codec against the spec rather than a live
  probe moves the A1 risk to the end. It is contained there: the reply
  tolerances are named constants, and every check is local to `jev.reply`.
  Suggested internal order: `pii` → `classify/input` → `classify/state` →
  `jev` + `classify/schema` → `jev/client`. This is the largest phase; a
  sub-orchestrator may split it across charters along that order.
- **PHASE-13 makes it a verb.** `classify --state` works without a
  credential first, then the Jev loop with the DEC-037 failure semantics,
  the cursor on the error line, and the token-leak suite.
- **PHASE-14 deploys and confirms.** Ingress and the POL-002 guard come
  before any real key is used. The README follows the verb it documents.
  The live check comes last because it needs two operator acts: storing the
  interim key and deploying. It confirms A1, the RV-016 F-9 tolerances and
  where a 400 carries `max_tokens_exceeded`, and replaces the spec-derived
  fixtures with recorded ones. A fix within § 5.2's contract lands in the
  phase; a contract change goes to `/consult` first.

## Review posture

- Every phase: a quotient pi reviewer (`code-review`), findings disposed
  before the next phase.
- Codex (gpt-6.1-sol), for the correctness-critical work only:
  - PHASE-12: the pii regexes (privacy boundary) and the reply decoder
    (DEC-012, DEC-014);
  - PHASE-14: the generated wrapper and provision (key ingress, I1).
- A multi-phase Codex review before audit is the operator's call.

## Notes

- Execution will be driven by `/super-orchestrator`. Commits happen only on
  the operator's request.
- `inq-9` (the satan:RFC-020 D1/D5 amendment draft and the DEC-016 exposure
  note) is due at close, not in a phase.
- Token usage is not measured here. llm-gateway accounting is expected to
  show it once the gateway route (flakes:IMP-054) lands (unverified).
- The worst-case state size (about 51 KB encoded) stays unmeasured; the
  `jev_context` error line and skip-by-cursor cover it.
- No RV-016 finding is instrument-routed. RV-017 (the eval scope-out pass)
  raised no design findings.
