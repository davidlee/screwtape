# Implementation Plan SL-004: Jev mail classifier verb over PII-stripped read output

Prose companion to `plan.toml`. Narrative only — no queried data lives here
(the storage rule); the phase list, criteria, verification, and links are
authored in the TOML. Use this for the plan's rationale and sequencing.
<!-- Reference forms: `lib:reference/glossary.md` § reference forms. -->

## Overview

Eleven phases in three runs. Phases 1–9 deliver a deployed `classify`. Phases
10–11 build and run the evaluation. The order follows the operator's
direction: deploy first, evaluate after.

```
01 seam lift ─▶ 02 A1 probe ─────────────────────▶ 05 codec/schema/client ─┐
      └──────▶ 03 pii ─▶ 04 input/state ─▶ 06 verb plumbing, --state ──────┴▶ 07 classify vs Jev
07 ─▶ 08 nix ingress + POL-002 ─▶ 09 README + live deploy ─▶ 10 eval harness ─▶ 11 first eval run
```

## Sequencing & Rationale

- **01 first.** The seam lift is a pure move behind the existing JMAP tests
  (design § 8). Everything that talks to Jev depends on `screwtape/http`.
- **02 before the codec.** Assumption A1 (Jev's reply shape) is the largest
  unknown under the codec, and so are the RV-016 F-9 tolerances and where the
  `max_tokens_exceeded` code sits. A live probe with synthetic state and the
  interim key turns those into recorded fixtures, so phase 05 is written
  against real replies, not the OpenAPI spec. If the probe contradicts design
  § 5.2, it goes to `/consult` before 05. The probe needs the operator only to
  encrypt the key.
- **03 → 04.** The state builder calls `pii.strip`. `pii` comes first on its
  own because it is self-contained and reusable, and its table tests are the
  densest.
- **05 and 06 can run in either order** after their inputs. 06 makes
  `classify --state` work end to end without a credential, which makes the
  state inspectable before any mail leaves the host.
- **07 joins them**: the Jev loop, the DEC-037 failure semantics with the
  cursor on the error line, and the token-leak suite.
- **08 then 09.** Ingress (wrapper, provision, shared crash-dump settings)
  must exist before the operator can run `classify` as deployed. The POL-002
  guard lands here, before any real mail is handled. 09 documents the
  contract and confirms the deployed path on the scrubbed fixtures.
- **10 → 11.** The eval is built after deploy, and only 11 touches real mail.

## Notes

- Commits happen only on the operator's request.
- `inq-9` (the satan:RFC-020 D1/D5 amendment draft and the DEC-016 exposure
  note) is due at close, not in a phase.
- Token usage is not measured here. llm-gateway accounting is expected to
  show it once the gateway route (flakes:IMP-054) lands.
- No RV-016 finding is instrument-routed. The repairs live in the design,
  and the phase criteria cite the findings they implement.
