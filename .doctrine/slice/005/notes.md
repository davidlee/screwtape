# Notes SL-005: classify window: raw-byte bounds, every address list, seen, PII relaxed for malice signals

Durable per-slice scratchpad — tracked in git. The place to lift anything from a
disposable phase sheet (`.doctrine/state/.../phase-NN.md`) that must survive
`rm -rf` before the slice close-out audit harvests it.

## Harvest
<!-- single-copy: updated in place each harvest; ids only, never restated content -->
fresh-as-of: 2026-10-29 · closed (RV-020 done, REV-004 done) · 9fb3326

### Produced
- design.md locked (run rev 29); DEC-040..DEC-044; ASM-006; RV-019 — 50b633c
- plan.toml / plan.md, 3 phases — 9d379c4, c428e67
- PHASE-01 utf8.spend, strip relaxed — 25f1d0a; PHASE-02 window, mail-2 —
  a54c839; PHASE-03 seen on lines, README — 65879a9; VH-1 probe — ce0e899
- RV-020 audit: 8 findings; synthesis + reconciliation brief in review-020.md
- Gate green, 629 tests; verify-vt 12/12; conformance 18/0/1 (notes only)

### Learned
- Concurrent `gleam`/`just` builds race on `build/` (§ Implementation run).
- Live Jev calls run on the host, never in a pi worker →
  mem.fact.screwtape.jev-live-calls-on-host. Build race → existing
  mem_01a17f2e07f07e03bc8b89563a4325d5.

### Open
- RV-020 reconciled (REV-004 done): design § 5.1, § 10; DEC-034 superseded;
  DEC-040 amends relations; POL-002 REV; ASM-006 settle (validated)
- Follow-Ups in slice-005.md: malebolge DEC-077, IDE-002

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

## Implementation run

Seat: /super-orchestrator, 2026-10-29, main worktree, from a293122 (clean).

- Host gate: `nix develop -c just check` (green at a293122, 611 tests).
- quotient forms: `read` (root read-only) and `write` (root writable;
  `just check` green, 611 tests). Neither has network or `curl`. No form
  change needed.
- Known hazard, not a form gap: concurrent builds of `build/` (two
  `gleam`/`just` runs at once) race on the esqlite NIF and argv artefacts and
  fail spuriously. Run one build at a time: never run the host gate while a pi
  worker builds, and tell workers to run gate steps sequentially.
- Operator ruling (2026-10-29, the user: "call Jev whenever, it's like 1/3 of
  a cent"): live Jev calls are allowed unattended, including PHASE-03 VH-1.
  The call runs on the host (Claude Bash), never in a pi worker: the forms have
  no network, and the credential
  (`~/.config/credstore.encrypted/screwtape.jev`) stays out of pi context. The
  synthetic worst-case mail is hand-made outside the repo (POL-002), e.g. in
  the session scratchpad; only token counts / `jev_context` outcome are
  recorded here, not the mail.
- README Bounds figure: PHASE-03 EX-5's "about 1.6×" is an estimate; replace
  it with the ratio PHASE-02 EX-7's test pins.
- Other writers: none expected.

## Autonomy log
- PHASE-01 · added `linear_long_letter_run_needs_the_token_lookbehind_test` (64 KiB run, < 1 s) beside the EX-4 16 KiB tests · negative control: without the lookbehind a 16 KiB run strips in ~0.2 s, so the 16 KiB tests alone cannot catch its loss; 64 KiB fails (verified) · decided
- PHASE-01 · re-pointed `stripping_that_lengthens_stays_within_the_body_total_test` input from addresses to `http://h?q ` (query grows by 4 B) · it relied on the removed email rule (EX-3); PHASE-02 rewrites this area anyway · decided
- PHASE-02 · named the shared address type `input.Address(name, email)` (design § 5.1 says `Entry`) · reads better beside `Addresses(entries, omitted)`; scope and contract unchanged; flag for audit · decided
- PHASE-02 · oversize emails are dropped before the 10-slot take (a dropped entry takes no slot); the 254-byte check is on the control-stripped email · matches EX-4 wording and the old sender_domains rule · decided
- PHASE-02 · added `fields_are_encoded_in_contract_order_test` (byte-exact empty window) and made VT-1's mail carry a strippable email and name · negative controls: an email or name bypassing `text` passed VT-1 and failed only the worst-case pin; field order (EX-2) had no test · decided
- PHASE-02 · EX-7 pinned size: worst-case `seen` 47,588 B, `state` 72,373 B, ratio 1.52 (filler `http://? `, 9 B → 14 B). ASM-006: at SL-004's 3.35 B/token, about 21.6k tokens; token-dense adversarial text may exceed 32k (accepted residual, `jev_context`). Not untenable for ordinary text · PHASE-03 README Bounds figure "about 1.6×" → 1.52 · decided
- PHASE-03 · VH-1 run by the agent on the host (operator ruling: live Jev calls allowed); the repo's erlang-shipment ran under systemd-run with the stored credential, via a local logging proxy (records request size and reply `usage` only, never headers) · VH-1 stays human-verified: evidence below for the operator to confirm at audit · decided
- PHASE-03 · operator hold on pi (gateway switch) after the VA-1 review run started; no new pi runs; T1/T2 pi work was already done · hold · decided

## Review passes

- PHASE-01 · pi implement (T1 tests, $0.060): table re-pointed and verified in `re`; 3 reds + utf8.spend compile red. Missed the lengthening test in classify_state_test.
- PHASE-01 · pi implement (T2 code, $0.018): green first try, 617 tests.
- PHASE-01 · pi review (VA-2, $0.088): hit the 40-request ceiling without answering; one continuation answered. One low finding (lengthening test no longer lengthens), verified and fixed. No other findings.
- PHASE-02 · pi implement (T1 tests, $0.087): all VT tests + EX-6 renames, compile red. Missed: VT-1 had no strippable email or name; no field-order test (both added by me after negative controls).
- PHASE-02 · pi implement (T2 code, $0.044): green first try, 628 tests; pins filled. Helpers tidied by me (`field_text`).
- PHASE-02 · pi review (VA-2, $0.027, 9 requests): no src defects. F1 medium (oversize-email test could not tell filter-first from cap-first) verified by negative control and fixed; F2 comment off by one, fixed; F3 attachment type had no word-drop case, added. F4 PROVENANCE.md names `schema.mail_1()`: accepted, it records how the mail-1 fixture was made (EX-6 keeps provenance). F5 a control-only body is `is_truncated` false with budget left and true once the budget is spent: accepted, both are the design's wording (§ 5.3); flag for audit/PHASE-03 docs.
- PHASE-03 · pi implement (T1 tests, $0.036): VT-1..VT-3 red (arity). The remote VT-2 test's 3 lines include one where seen != state (negative control `seen: state` on the Remote path fails 1 test).
- PHASE-03 · pi implement (T2 code + README, $0.019): green first try, 629 tests. README wording tidied by me ("Controls removed" label, misses paragraph).
- PHASE-03 · pi review (VA-1, $0.049, 13 requests): no src or test defects; EX-1..EX-6 and VT-1..VT-3 checked. F1 medium: README called `seen` "raw mail" though it is the bounded window; fixed (un-stripped mail text). F2 medium: "names and addresses go to Jev unchanged" though rules 4–6 apply inside them (a 20+ mixed local part → `[token]`); fixed. F3 low: token rule is ASCII-only; fixed. All three verified against `pii.gleam`/`state.gleam`.

## VH-1 live probe (PHASE-03, 2026-10-29, agent-run; operator confirmed 2026-10-29: "VH-1 confirmed")

Synthetic worst-case mail, generated by script from invented garden-committee prose (no real mail), kept in the session scratchpad, not committed (POL-002). Every field at or past its bound: subject 560 B, 6 lists × 11 entries (names 140 B, emails ~252 B), 11 bodies of ~2 KB with a `?query` URL each, 21 attachments (type and name 140 B).
- `classify --state` (repo build at the PHASE-03 diff): `seen` 47,231 B, `state` 47,159 B (ratio 1.00: ordinary text has few placeholders); lists 10 each, `_omitted` 1 each; bodies 10, texts 16,384 B, `bodies_omitted` 1; attachments 20, omitted 1; subject 504 B; line 94,524 B.
- `classify` against Jev (`typesafe/jev-1.14.0` via the gateway): HTTP 200; request 51,130 B → **12,269 input tokens** (4.17 B/token), 202 output tokens. Verdict line: `{version:1, kind:"classify", data:{id, cursor, schema:"mail-2", model:"jev-1.14.0", seen, answers{8 mail-2 questions}}}`. No `jev_context`.
- ASM-006 evidence: the worst-case ordinary-text window uses ~38% of the 32k-token limit. Token-dense adversarial text remains the accepted residual.
