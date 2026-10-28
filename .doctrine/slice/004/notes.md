# Notes SL-004: Jev mail classifier verb over PII-stripped read output

Durable per-slice scratchpad — tracked in git. The place to lift anything from a
disposable phase sheet (`.doctrine/state/.../phase-NN.md`) that must survive
`rm -rf` before the slice close-out audit harvests it.

## Harvest
<!-- single-copy: updated in place each harvest; ids only, never restated content -->
fresh-as-of: 2026-10-28 · ready; design re-locked without the eval (run rev 43); plan reworked to 4 phases; next: /super-orchestrator from PHASE-01 · 060d763 (pre-surgery baseline; rework uncommitted)

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
- plan.toml/plan.md: 11-phase draft superseded; reworked to PHASE-01, -12, -13, -14 (mapping table in plan.md); draft sheets pruned
- design reopened (rev 37 locked→reviewing), eval removed from sec-01/03/05-3/05-4/06/08/09/10 via `design adopt` (rev 38); eval design moved verbatim into IMP-003's body; slice scope objective 7 → real-mail guard; selectors test/eval.gleam, test/eval/**, justfile removed
- RV-017 — eval scope-out pass (quotient pi reviewer): no design findings, concluded; adversarial attestations att-adv3-* recorded (rev 39)
- design re-locked 2026-10-28 (rev 43) on operator reply "reviewed, ok, lock it": att-user3-* (rev 40), review-disposed conducted RV-017 (rev 41), design-accepted (rev 42)
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
- SETTLED `review_pass … STALE` after lock: seen at both locks (RV-016 rev 36, RV-017 rev 43); status shows 1 change since baseline right after the stage move, so the lock itself stales the pass. Inference: benign, not a review gap
- design § 5.2 — F-9 reply tolerances (sum 1 ± 0.02, score ± 0.05) are estimates; A1 smoke test confirms
- design § 6 — token usage assumed visible in llm-gateway accounting (unverified)
- FOR RECONCILE (operator, 2026-10-28): revise POL-002 § Statement, tagging-pass exemption "(SL-004)" → "(IMP-003)", through a REV (governance edit); source: RV-017 pass, pi review finding 3
- DONE plan rework (operator, 2026-10-28): 4 phases. (1) http seam lift; (2) pure core: pii, classify/input, classify/state, jev, jev/client, classify/schema, with spec-based fixtures; (3) classify verb: argv, config, run_piped, stdin edge, render, loop, token-leak; (4) ingress and docs: nix wrapper/provision/shared crash-dump settings, POL-002 guard, README, then a live run confirming A1 and fixing the codec if needed. Keep the draft's criteria, merged per phase (they carry the RV-016 repairs).
- DONE scope change (operator): the eval is out of SL-004 (IMP-003). The locked design § 1 boundary, § 5.3 eval data, § 5.4 evaluation run, § 9 eval tests and § 10 eval paths, plus slice scope objective 7 and the eval selectors, still include it. Reconcile through the proper verb, not by hand.
- review posture for execution (operator): a quotient pi reviewer per phase; Codex only for especially correctness-critical work or multi-phase review. Execution will be driven by /super-orchestrator.
- the live run (new phase 4) needs the operator to store the interim Jev key first: systemd-creds encrypt --user --name=jev - ~/.config/credstore.encrypted/screwtape.jev

## Further review passes
Written after RV-016 concluded (round 4). No further adversarial design pass is needed: four rounds converged, the last raised one minor edge case, and the remaining risks are empirical, not design defects. They are settled by instruments at execution, not by review: the A1 live smoke test (reply shape, F-9 tolerances), the token-leak subprocess test with a lowercase model-shaped sentinel (F-1), the pii near-date table (F-2), the render.read to state cut-on-arrival tests (F-3, F-12), and the first eval run (calibration, state size). A code review at audit should probe the pii regexes against the section 9 table and the systemd-run wrapper's generated properties.
Updated after rounds 5–6 (F-13, the jev_context error-line tag): the conclusion stands.

## Implementation run
Seat: /super-orchestrator, 2026-10-28. Phases in order PHASE-01, PHASE-12, PHASE-13, PHASE-14. Main worktree, no dispatch. Halt before audit.

### Gates
- Host gate: `nix develop -c just check` (green at preflight: 477 passed). PHASE-14 also runs `nix flake check` (checks.module-eval) on the host.
- quotient write form: `just check` green (477 passed); no sandbox-only failures. Form lacks `nix`, `systemd-run`, `systemd-creds`, `jq`, `curl`: nix/systemd steps are the sub-orchestrator's, on the host. No form change.
- Hazard (observed): two builds in `build/` at once break `gleam export erlang-shipment` (rebar3 esqlite NIF, "Waiting for build directory lock"). Serialise every build/test in this tree: one pi worker building at a time, never a host gate alongside a running worker.
- Bare `gleam test` without `build/erlang-shipment` gives ~30 false reds (shipment-dependent tests); use `just test` / `just check`.
- pi forms cannot read ~/dev/malebolge (outside the root): the seat or a Claude worker copies fixtures in.

### Operator rulings (2026-10-28)
- Commits: one planning commit before PHASE-01, then one commit per phase, naming only that phase's paths. Leave `.doctrine/backlog/improvement/002*` alone. Don't edit flakes:IMP-054 or anything in ~/flakes.
- Fixtures: copy the scrubbed malebolge fixtures (`~/dev/malebolge/test/mail/fixtures/real/`, committed there as malebolge 707b444) into screwtape's test fixtures as is, WITHOUT SCRUB.md. Provenance: malebolge 707b444 SCRUB.md.
- Live check endpoint: the gateway, not the interim TypeSafe key (flakes SL-019 is live). Config per design § 5.4 "Swapping to the gateway": `jev.baseUrl = "http://127.0.0.1:<relayPort>"`, `jev.model = "typesafe/jev-1.14.0"`. PHASE-14 EN-2's operator act becomes: `llm-gateway issue screwtape --models typesafe/jev-1.14.0 --budget <USD> --out <file>`, `screwtape-provision jev --from-file <file>`, deploy. Plan adaptation logged below; the halt before EX-7 stands. The agent never sees the key.
- Codex models listed at preflight: gpt-6.1-sol is current; no tier superseded.

### Evidence carried in (A1, partial)
- Observed (operator, flakes SL-019 VH-1, two live calls): request `model` "typesafe/jev-1.14.0" → reply `model` "jev-1.14.0" (plain and zstd). Reply shape seen: `{"model","answers":{name:{"type":"noul","noul":0.97}},"usage":{"input_tokens","output_tokens"}}`. Design § 5.2's rule (configured model, or the part after its last `/`) already accepts it; PHASE-12 reply fixtures include a prefix-stripped case.
- Inference, unverified: an alias (typesafe/jev-latest) may come back as the served version; design pins a version (§ 7). Check at the live run.
- Drift for audit: design invariant I2 says `model` printed "only if it equals the configured model" without the last-`/` exception of § 5.2.

## Autonomy log
<!-- one line per envelope decision: phase · what · why · tier (decided / deferred / escalated) -->
- seat · PHASE-14 EN-2 operator act changes from interim key to gateway key provisioning · operator ruling 2026-10-28 · decided
- seat · design I2 wording vs § 5.2 last-`/` rule · drift, not a defect · deferred (audit)
