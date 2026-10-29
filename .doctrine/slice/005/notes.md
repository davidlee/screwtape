# Notes SL-005: classify window: raw-byte bounds, every address list, seen, PII relaxed for malice signals

Durable per-slice scratchpad — tracked in git. The place to lift anything from a
disposable phase sheet (`.doctrine/state/.../phase-NN.md`) that must survive
`rm -rf` before the slice close-out audit harvests it.

## Harvest
<!-- single-copy: updated in place each harvest; ids only, never restated content -->
fresh-as-of: 2026-10-29 · design/reviewing (run rev 22) · d757768 (all SL-005 work uncommitted)

### Produced
- design.md (10 sections, materialised rev 20); DEC-040, DEC-041, DEC-042,
  DEC-043, DEC-044; ASM-006; RV-019 (design review pass, open)
- research/research.md; IMP-003 retargeted to mail-2

### Learned
- (none durable yet)

### Open
- ASM-006 — validate by VT-6 + VH-1 (design § 9)
- Follow-Ups in slice-005.md: malebolge DEC-077, POL-002 wording REV, IDE-002

## Design triage (2026-10-29, exploring)

Evidence: `research/research.md` (X-n = its cross-thread findings).

**Shaping direction (operator, 2026-10-29, "that all sounds good to me"):**
- X-1 state shape owned by the schema id; contract stays v1.
- X-2 `seen` covers every bounded text and list, so consumers need no
  mirrored bounds table.
- X-3 relax `pii.strip` in place, no flag.
- URL paths: partial, host intact.

**Open questions** (become design inquiries):
1. State ownership: exact amendment to DEC-036 / README wording.
2. `seen` shape and its definition of raw kept bytes (X-4).
3. Cut order per field, and the body budget spent on raw bytes.
4. Address lists: entry shape, per-list count bound, name/address byte caps,
   recipients full vs domain-only.
5. Strip rules: email rule fate, URL rule (path kept, query/fragment, token
   segments), what remains.
6. Schema id name and decision records (supersede DEC-034).
7. Token-limit measurement method (X-5).

**Risks:** more PII to typesafe.ai; Jev token limits; URL token leakage
(reset links); display names are attacker text (X-6).

**Assumptions:** malebolge refuses an unknown schema id (DEC-036 says
consumers do; malebolge's DEC-077 treats missing `seen` as a violation).

**Constraining governance:** POL-001, POL-002, DEC-029, DEC-030, DEC-034,
DEC-035, DEC-036, DEC-039; SL-004 design I3 (superseded by this slice).

## Pre-draft adversarial review (2026-10-29, inquiring)

pi (`review` profile, deepseek-flash) over DEC-040..DEC-044, ASM-006; raw
result in quotient run `run-20261029T064935323Z-5-3744c2659da0`.
Operator agreed the dispositions ("agreed in principle", then "yes").

| F | sev | disposition |
|---|---|---|
| F-1, F-2 | blocking | accepted: keep a whitespace-free cut prefix; is_truncated = seen shorter than input; budget charged for seen bytes → DEC-041 |
| F-3 | major | accepted: token rule `[A-Za-z0-9]{20,}`, no `-`/`_`, start-anchored; misses recorded → DEC-043 |
| F-4 | major | accepted: keep port, delete `[email]`-host pass, `?[…]` / `#[…]`, schemeless position → DEC-043 |
| F-5 | major | partial: residual recorded in ASM-006; no retry |
| F-6 | major | accepted: DEC-040 also amends DEC-029; README Compatibility |
| F-7 | major→minor | partial: `read` already prints raw mail; POL-002 wording "PII-stripped `--state` form" goes stale → REV at reconcile |
| F-8 | major | declined (operator: complexity for a silly case): oversize email still drops its entry and is counted |
| F-9 | major | declined for SL-005; routed to IMP-003 (evaluate mail-2) |
| F-10, F-13 | minor | accepted: define seen precisely; README states per-line output ceiling |
| F-11 | minor | accepted: one window builder; merge the two `spend` copies |
| F-12 | minor | partial: bidi overrides removed with controls; first-10 exposure noted; empty-email entries not special-cased (declined) |

## Draft adversarial review (2026-10-29, reviewing)

pi (`review` profile) over design.md; findings and dispositions on RV-019
(quotient run `run-20261029T071255625Z-85-8abc2c96cef5`). Concluded.

**Further passes:** none needed before lock. The pass found only wording
and test-plan defects; it confirmed the strip rules under OTP `re`, the
code citations, I1 being structural, and the 45 KB arithmetic. The open
risk is empirical, not design: ASM-006's token fit, settled by VT-6 and
the VH-1 live probe at execution. A further pass would only probe the
README rewrite, which `docs_test` and VT-5 pin.
