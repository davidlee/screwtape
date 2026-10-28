# Notes SL-004: Jev mail classifier verb over PII-stripped read output

Durable per-slice scratchpad — tracked in git. The place to lift anything from a
disposable phase sheet (`.doctrine/state/.../phase-NN.md`) that must survive
`rm -rf` before the slice close-out audit harvests it.

## Harvest
<!-- single-copy: updated in place each harvest; ids only, never restated content -->
fresh-as-of: 2026-10-28 · ready, but plan REWORK pending (11-phase draft superseded by operator direction below) · 90c3699 (all SL-004 work uncommitted)

### Produced
- SL-004 scoped, researched (`research/research.md`, raw/ threads), design run at reviewing; design.md materialised (14 sections) — uncommitted
- minted: DEC-033 — Jev base_url loopback-http exception; DEC-034 — PII-stripped state; DEC-035 — schema mail-1; DEC-036 — classify envelope + schema id; DEC-037 — stop at first failure; DEC-038 — jev config + systemd-run ingress
- minted: POL-002 — real mail only in PII_hidden_fixtures.local/
- minted: IDE-002 — topic relevance for mail-2
- cross-repo: flakes:IMP-054 — Jev behind the LLM gateway (created here; since revised by the flakes session, uncommitted there)
- Codex (gpt-6.1-sol) schema review shaped DEC-035; transcript in session scratchpad only
- RV-016 adversarial pass (Codex gpt-6.1-sol raiser, 6 rounds): 13 findings, all fix-now and verified; DEC-034 and DEC-037 amended on operator assent
- design locked 2026-10-28 on operator reply; F-4 kept 16 KiB bodies with a jev_context error line carrying the cursor (operator)
- minted: IMP-003 — the eval, split out of SL-004 (needs SL-004; governed_by POL-002)
- plan.toml/plan.md: 11-phase draft, sheets materialised — superseded, to be reworked
- process slip: run rev 31 logged a false user design-accepted from a top-level acceptance on adversarial attestations; staled at rev 34, superseded by the real one at rev 36; friction observation + mem.fact.doctrine.design-apply-acceptance-records-user-act

### Learned
- mem.fact.systemd.run-pipe-credentials — systemd-run --pipe carries stdin/stdout/exit and a loaded credential
- mem.fact.jev.reply-shape — Jev request/reply keys; decode by our names
- mem.fact.doctrine.governance-confirmed-invalidated-by-edges — new governing edges stale the governance act

### Open
- SL-004 inq-9 (deferred to close) — satan:RFC-020 D1/D5 amendment draft + DEC-016 exposure note
- design A1 — Jev reply shape unconfirmed live
- design § 6 — substance signal and calibration: now IMP-003's question
- design § 5.2 — worst-case state about 51 KB encoded vs Jev 32k tokens: unmeasured; jev_context error + skip-by-cursor covers it
- design § 5.2 — location of Jev's max_tokens_exceeded code in a 400 body: confirm with A1
- run shows `review_pass RV-016 STALE` after lock; cause not investigated
- design § 5.2 — F-9 reply tolerances (sum 1 ± 0.02, score ± 0.05) are estimates; A1 smoke test confirms
- design § 6 — token usage assumed visible in llm-gateway accounting (unverified)
- plan rework (operator, 2026-10-28): 4 phases. (1) http seam lift; (2) pure core: pii, classify/input, classify/state, jev, jev/client, classify/schema, with spec-based fixtures; (3) classify verb: argv, config, run_piped, stdin edge, render, loop, token-leak; (4) ingress and docs: nix wrapper/provision/shared crash-dump settings, POL-002 guard, README, then a live run confirming A1 and fixing the codec if needed. Keep the draft's criteria, merged per phase (they carry the RV-016 repairs).
- scope change (operator): the eval is out of SL-004 (IMP-003). The locked design § 1 boundary, § 5.3 eval data, § 5.4 evaluation run, § 9 eval tests and § 10 eval paths, plus slice scope objective 7 and the eval selectors, still include it. Reconcile through the proper verb, not by hand.
- review posture for execution (operator): a quotient pi reviewer per phase; Codex only for especially correctness-critical work or multi-phase review. Execution will be driven by /super-orchestrator.
- the live run (new phase 4) needs the operator to store the interim Jev key first: systemd-creds encrypt --user --name=jev - ~/.config/credstore.encrypted/screwtape.jev

## Further review passes
Written after RV-016 concluded (round 4). No further adversarial design pass is needed: four rounds converged, the last raised one minor edge case, and the remaining risks are empirical, not design defects. They are settled by instruments at execution, not by review: the A1 live smoke test (reply shape, F-9 tolerances), the token-leak subprocess test with a lowercase model-shaped sentinel (F-1), the pii near-date table (F-2), the render.read to state cut-on-arrival tests (F-3, F-12), and the first eval run (calibration, state size). A code review at audit should probe the pii regexes against the section 9 table and the systemd-run wrapper's generated properties.
Updated after rounds 5–6 (F-13, the jev_context error-line tag): the conclusion stands.
