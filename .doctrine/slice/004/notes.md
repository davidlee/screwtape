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

### PHASE-01 passes (2026-10-28)
- pi implement (deepseek-flash, $0.050, 35 req): pure move done, red then green (482 passed). Miss: touched check_imports_test outside allowlist (needed); otherwise clean.
- pi review (deepseek-flash max, $0.031): pure move confirmed; F1 minor no test pins "401/429 body not read" (fixed, negative control red 2 failures); F2 minor http_test bound unpinned (fixed); F3 nit 3xx/boundaries (fixed); F4 nit alias inconsistency (accepted); F5 nit design § 5.1 `failure/1` (deferred audit).

### PHASE-12 passes (2026-10-28)
- T1 pi implement (deepseek-flash, $0.131, 50 req, wall-clock timeout during its final `just check`; work complete). Miss: gave slashed dates and times "loose" boundaries (only a touching digit spoils them) and a rule-5 lookbehind that also blocked `/`; together `12/12/2026 12345678` and `14:00 12345678` leaked the 8-digit run. URL authority class allowed `?#`, so `https://host?token=x` kept its query. Orchestrator fixed both (whole-token boundaries for every shape per design § 5.2; authority excludes `?#`) and added 6 table rows. One spec row (`12/12/2026 1.2.26 …`, space-joined) contradicted the whole-token rule; corrected to comma-separated.
- T2 pi implement ($0.050, 44 req; wall-clock timeout in its final `just check`, work complete): `error.decode_failure` + classify/input; host gate 507 passed. No misses found on read. Briefs now tell pi to stop at `gleam test` and leave `just check` to the orchestrator (15-min run cap).
- T3 pi implement ($0.062, 28 req, final): classify/state, 16 tests, 523 passed. Resolved: bodies past 10 do not spend the budget; duplicate domains are not counted as omitted. Read: correct; word drop treats only ASCII whitespace as a word break (drops more, never less).
- T4 pi implement ($0.057, 27 req, final): jev + schema + jev fixtures, 551 passed. jev builds paths by hand (decode.at truncates missing segments), root object check via `dynamic.classify`. Red was a test syntax error, not the missing module (weak red; tests assert exact paths). Schema text checked against the spec verbatim by script.
- VA-1 pi review (deepseek-flash max, $0.101, 42 req): 10 findings. F1 major attachment `type` not stripped, contradicts I3 (accept: strip it; design § 5.2 strip bullet vs I3 drift for audit). F2 minor sender domain unstripped, `a@` gives "" (accept: strip, empty → omitted). F3 minor last-with-text judged pre-strip (reject: `render.read` prints every body after its cut as "", so a whitespace-only trailing body cannot follow a cut body). F4 minor tolerances never tested at the boundary (accept). F5 minor bracketed-host port kept (accept). F6 minor no y/m/d+time or ISO frac/offset rows (accept). F7 minor 253-byte domain kept-side untested (accept). F8 minor FFI exports unchecked (accept). F9 nit schema assertions duplicated in jev_test (accept). F10 nit strip runs on bodies past the budget (accept the remaining=0 shortcut).
- VA-2 Codex review (gpt-6.1-sol, effort high, read-only, erl probes): 9 findings + coverage notes. F1 blocker quoted, decomposed and atom-punctuation local parts survived (accept, fixed: quoted local part, \p{M}, RFC 5322 atext minus `/`). F2 blocker plain times took unbounded fractional seconds, protecting a joined digit run (accept, fixed: fraction only in ISO datetimes, ≤ 9 digits). F3 major the "extra key with mass fails the sum" ruling is false (`{"a":0.8,"b":0.2,"c":0.2}` passes) (accept the evidence; extras are ignored, test and doc corrected; the EX-12 "exactly our keys" vs "never decode.dict" conflict flagged to the seat). F4 major a huge JSON integer crashes `int.to_float` (accept, fix R4). F5 major quadratic email matching on long near-addresses, 3.4 s at 64k (accept, fixed: token-start lookbehind; regression test). F6 major `https://alice@bob@host` kept `bob@` (accept, fixed: userinfo to the last `@`). F7 minor IEEE slack at the tolerance boundary (accept, R5). F8 minor bracketed host kept its port (accept, fixed). F9 minor good-reply test discarded values (accept, R7). Non-ASCII digits and separators (fullwidth, U+00A0, U+2011) survive rule 5: the design's rules are ASCII; deferred to backlog. Duplicate JSON keys (first wins): no action.
- Orchestrator pii fixes: 12 rows added (quoted/decomposed/apostrophe emails, fractional-second runs, double-`@` userinfo, IPv6 ports, y/m/d + time, ISO fraction/offset) plus the 64k near-address test; 564 passed. Two of my expectations were wrong (a time without seconds before `:` is a whole token, so `12.12.2026 14:00:[number]`), corrected.
- T6 pi implement ($0.065, 35 req, final): R1-R9 review fixes; 577 passed on the host gate. Honest about weak reds: R3, R4, R6, R7 were green before their fixes (contract-preserving).

### PHASE-13 passes (2026-10-28)
- W1 pi implement ($0.062, 50 req; wall-clock timeout, one short continuation): T1 config jev block, T2 argv Classify, T3 render classify/classify_state; byte-exact contract strings transcribed from the spec; 588 passed. Made `jev.question_name` public (reuse).
- W2 pi implement ($0.065, 33 req, final): T4 run_piped/run_with, dispatch → Outcome, classify loop, `error.to_json_line_at`, cli_fixture jev helpers, 9 cli cases; 597 passed. No misses on read.
- W3 pi implement ($0.085, two runs, both wall-clock timeouts): T5 edge reader + `subprocess.run_stdin`. Miss: setting `{encoding, latin1}` on standard_io and leaving it escaped every codepoint >255 in stdout as `\x{…}`; orchestrator fixed (restore the device encoding). Design's `{encoding, unicode}` does not work (observed `no_translation` on valid UTF-8, `\xff` passed through).
- W4 Sonnet capsule-worker (reason: security negative control; pi failed twice next door): token_leak classify case, reflected lowercase sentinel in `model`; bearer header asserted at the server; planted-leak controls fired; 601 passed. Shared `local_tls_ffi` responder now receives the request head.
- VA-1 pi review (deepseek-flash max, $0.100, 52 req): 10 findings, no blocker/major. F1 I5 unpinned (accept: panicking opener/send fakes). F2 k=0 cursor unasserted (accept). F3 one state per line unproved (accept). F4 printed model is the reply's (configured or its last-`/` part) not the configured string (reject for this phase: § 5.2 rule, I2 drift already deferred to audit). F5 EX-7 "Some(lines)" vs empty-stdin None (accept: one `joined` rule shared with read --after, documented; EX-7 wording drift deferred to audit). F6 unparsable https base_url passes config, fails `Config("jev_url")` at the first ask (accept: test added; stricter validation would need a sixth reason, not in EX-2). F7 set-vs-order assertion (accept: comment). F8 duplication (accept: `joined`, `broken`, `jev_reply`; token-leak helper fold rejected, nit). F9 temp dirs leaked (accept). F10 VT-3 keyword (accept: tests renamed `read_stdin_*`).
- Fix pi implement ($0.046, 36 req, final): R1-R8; bite probes reverted (I5 opener panics; constant state and dropped cursor both fail); host gate 602 passed.

### PHASE-14 passes, pre-live (2026-10-29)
- N1 Sonnet capsule-worker (reason: nix/systemd steps the pi forms lack, plus byte-exact key-ingress scripts): jev options, wrapper branch, generalised provision, one `crashDump` definition, module-eval withJev cases and a bad-arguments battery; red (option missing) and a `--collect` negative control shown. Two resumes for review fixes.
- P1 pi implement ($0.047, 39 req): POL-002 stanza, folder notes, pol002_test. Miss: none in code; it flagged that the nix gleam-test sandbox has no `.gitignore`/`git` (orchestrator: package.nix ships `.gitignore` and README.md under doCheck, gitMinimal, `git init` with isolated config).
- P2 pi implement ($0.051, 28 req): README contract and docs_test (red: no `### mail-1` section). 607 passed.
- VA-3 Codex gpt-6.1-sol (high, read-only; rendered wrapper/provision): 6 findings, all accepted and fixed, verified in round 2 with no new defect. F1 major `--from-file` aliasing the stored/staged path (realpath compare; per-run staging). F2 major symlink source leaves plaintext target (refuse `-L`; hard links: known limit). F3 major concurrent runs share `.new` (private `mktemp -d` staging beside the store). F4 major `mv` into a directory (`mv -fT`). F5 minor `--from-file -`/leading dash (resolved absolute path). F6 minor unquoted credential property (escapeShellArg). Round-2 nit: SIGKILL can leave a staging dir holding ciphertext only (no action).
- VA-2 pi review ($~0.1, deepseek-flash max): 20 findings, no blocker. Accepted and fixed: README stdout-on-failure contradiction, score tolerance/argmax, "never sent" scoping, stdin bound, no_jev/no_stdin, clear-file wording and a `--from-file` deletion caution, PII detail; exact branch-test literal in module-eval (red by inverted condition); gitMinimal and isolated git config; pol002 probes four names (red by `!/PII_hidden_fixtures.local/*.md`: 2 failures); `wrapper != null` guard; rm-failure-after-store message. Declined: EX-2 single definition untestable by eval (parity pinned, structure reviewed); docs_test checks names only (EX-6 scope); naming nits; `classify --state extra` routes through systemd-run (fails argv either way; the guarded path is the safer default); separate docs check derivation. EX-3 "staging unchanged" vs private staging: see autonomy log.
- Gates: `nix develop -c just check` 607 passed; `nix flake check` rc=0.

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
- PHASE-01 · pi worker also edited test/screwtape/check_imports_test.gleam (fixture entry for the new governed path; required, else MissingFile) · fixture-only, outside brief allowlist · decided
- PHASE-01 · added test/screwtape/http_test.gleam and two client_test status rows (problem document under 401/429 never read) · review F1/F2, test-only, negative control confirmed red · decided
- PHASE-01 · design § 5.1 table says `failure/1` (§ 5.2, EX-1 and code say `failure/2`) · drift, code right · deferred (audit)
- PHASE-01 · `gleam/http` aliased `method` in client/client_test/transport_test, `gleam_http` in fixture_send · nit, no behaviour; accepted · decided
- PHASE-12 · schema per-question instruction text and choice-label descriptions authored by the orchestrator (DEC-035 fixes only the preamble, names, labels and level texts) · DEC-035 has no per-question text · decided, flag for audit
- PHASE-12 · "probabilities with exactly our keys" enforced as: each of our keys present and in [0,1], ours sum to 1 ± tol; an extra key is never read, so one with mass fails the sum and one with zero mass is ignored · design forbids decode.dict · decided, flag for audit
- PHASE-12 · max_tokens_exceeded compared at `detail` (string) or `detail.code` (OpenAPI HTTPBadRequestError.detail is string or object) · location unconfirmed until A1 (PHASE-14) · decided
- PHASE-12 · `input.lines` added beside `input.line`; shared `error.decode_failure` helper · keeps § 5.2 contracts, POL-001 · decided
- PHASE-12 · mail PROVENANCE.md cites malebolge 707b444 SCRUB.md by path, file not copied · operator ruling over EX-10 wording · decided
- PHASE-12 · check_imports: `FfiOnly(module)` and a per-wrapper beam allowlist (html, pii) · needed for a second FFI module · decided
- PHASE-12 · attachment `type` and sender domains now pass pii.strip (I3) although § 5.2's strip bullet names only subject, texts and names · drift, code follows I3 · deferred (audit)
- PHASE-12 · EX-12 "probabilities with exactly our keys" cannot hold alongside "never decode.dict"; extra keys are ignored (VA-2 F3 disproved the earlier sum argument) · design contradiction · flagged to seat; deferred (audit)
- PHASE-12 · non-ASCII digits/separators survive rule 5 · outside the design's ASCII rules · deferred (RSK-001)
- PHASE-12 · VT-1 table: one spec row contradicted the whole-token rule (space-joined shapes), corrected; 6 rows added after a boundary leak · strengthens the contract · decided
- PHASE-13 · cli tests reach `fixture_send` through an injected `send_for` in `@internal run_with` (production passes `production_send`) · design names only `production_send`; keeps § 5.2 · decided
- PHASE-13 · the edge reads stdin as raw bytes (`{encoding, latin1}`), validates UTF-8 with `unicode:characters_to_binary/1`, then restores the device encoding · design § 5.2 says `{encoding, unicode}`: observed `file:read` then fails `no_translation` on valid UTF-8 and lets `\xff` through, and leaving latin1 escapes output codepoints >255; contract unchanged · decided, flag for audit
- PHASE-13 · `jev.question_name` made public for render (POL-001) · decided
- seat · EX-12 count-only decode.dict for probabilities · operator ruling 2026-10-29 · decided
- PHASE-13 · review F4: printed `model` is the reply's accepted form, not the configured string · § 5.2 rule; same I2 drift · deferred (audit)
- PHASE-13 · review F5: EX-7 says success is `Some(lines)`; empty stdin is `None` per § 5.5 edge case, shared `joined` rule · EX-7 wording drift · deferred (audit)
- PHASE-14 · appended EN-3 superseding EN-2 (gateway key via llm-gateway issue → screwtape-provision jev --from-file; gateway config) and a plan.md note; EN-2 kept, ids unchanged · operator ruling 2026-10-28 · decided
- PHASE-14 · `nix/package.nix` check ships `.gitignore` and README.md, adds gitMinimal and `git init` (isolated config) so pol002_test and docs_test run in checks.gleam-test · outside § 10's path list; test-only inputs · decided
- PHASE-14 · provision staging is a per-run `mktemp -d` beside the store and `mv -fT`, not the fixed `.new` file; symlink and stored-path sources refused · Codex VA-3 F1-F4; EX-3 and design § 5.4 say "staging unchanged"; still staged + atomic, contract kept · decided, flag for audit
- PHASE-14 · wrapper routes every `classify` invocation except exactly `classify --state` through systemd-run · the safer default; malformed args fail argv inside the unit · decided
