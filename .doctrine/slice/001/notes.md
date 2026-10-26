# Notes SL-001: Screwtape M1: Gleam JMAP mirror, full bounded sync

Durable per-slice scratchpad — tracked in git. The place to lift anything from a
disposable phase sheet (`.doctrine/state/.../phase-NN.md`) that must survive
`rm -rf` before the slice close-out audit harvests it.

## Harvest
<!-- single-copy: updated in place each harvest; ids only, never restated content -->
fresh-as-of: 2026-10-27 · 7bc38bc · all 11 phases completed (PHASE-08 landed in satan f0634c2, 1b82629; IMP-051 upstreaming); slice in audit; RV-004 opened (empty); next /audit

### Produced
- PHASE-09 (6c31cf9; ~/flakes a4c04414): quotient pinned by github at the same rev; ~/flakes screwtape input, features/satan/screwtape.nix, dev-checkouts entry, SATAN.md § Screwtape; ASM-004, ASM-005 validated; IMP-001 (OQ-A fail closed); CHR-003 updated
- PHASE-11 (418a09f): request.opening (Mailbox/get + Email/get ids:[] + Thread/get ids:[], c0/c1/c2); decode.state; decode.threads returns threads only; client.call D1 response-order guarantee; sync opening (`Opened`), phase 2 stateless, `in_chunks` over `list.sized_chunk` (no empty gets); test support RecordedCall.call_id, fixture_send.calls_of, sync_fixture Run.requests/opening_calls/opening/opening_with, jmap_fixture Entry/opening_entries/opening_response/responses/error_entry; tests VT-1..VT-3 (sync_test), opening wire shape, state_*, call_* D1
- PHASE-07 (95b04ee, 6b8d0bf): nix/module.nix `homeManagerModules.default` (options, hardened oneshot unit, timer, store config with a parser checkPhase, `--config`-only wrapper, screwtape-provision, stateHome/configHome assertions, internal `configFile`); nix/module-eval.nix `checks.module-eval` (VT-1, VT-2); flake home-manager input; README deployment sections
- PHASE-06 (93850f0, 5fa77da, 54ca590, 04f0f2f, 49d0d95): read verbs mailboxes/list/read/thread; modules argv (pure parse), render (one envelope writer, governed pure), utf8 (I5), store/query (read queries), store/codec (stored encodings both ways); model MessageSummary/ThreadEntry/mailboxes_matching; reader busy_timeout 5 s; `open_reader_with` + `cli.run_with` I8 seams; tests read_snapshot_test (4, VT-1), render_test, cli_test read contract (VT-2, EX-3), store_test read contract, utf8_test, model_test; memory mem.pattern.sqlite.snapshot-read-test, mem.fact.sqlite.esqlite-readonly-uri extended
- PHASE-05 (bfeb35f, b2cb3a5, 2498e04): sync (run, paging with sticky clamp, ≤2 restarts, chunked gets, earliest states, Email/get answer checks); jmap/request Email/query/get + Thread/get builders, `call_id`; decode QueryPage/EmailPage/threads/full Mailbox, `server_keyed_fields`, F8 name check; client.call_one; config.window_json; cli full sync + summary envelope + read-only warning; test support fixture_send `Expect`/recorded_calls, jmap_fixture builders, sync_fixture, cli_fixture token/full_sync_script; sync_test (36), I1 suite extended to the full path + store dump
- PHASE-04: store (schema v1 = migration chain `[schema_v1]`, write_snapshot/_with, open_reader/read/select, close_*); test support store_dump (in-process logical dump incl. user_version), snapshot_fixture (full/broken); store_test (16 tests)
- PHASE-03 (75dd306, f1d6289): model, html_sax + screwtape_html_ffi (catch boundary), html_text, normalise (utc_date, body bound, compare_received), decode.document + utc_date; test/check_imports (+ beam-import FFI rule) in `just check` and checks.gleam-test; DEC-020, DEC-021; ASM-002 validated; CHR-002
- PHASE-10 (a482012..54e028e): error, credential (control-byte rejection), config, file, jmap/request, jmap/decode, jmap/client (Budget), cli, main; test support fixture_send, jmap_fixture, cli_fixture, local_jmap.start_with/reply, temp.write, subprocess.run_env; I1 token_leak_test (VT-2); DEC-019; RV-002 concluded as waived (1fc3923)
- PHASE-02: screwtape_http.erl (production Send), jmap/client types, test/support local_jmap (+ local_tls_ffi serve/2), transport_test; memory mem.fact.erlang.httpc-reason-shapes
- PHASE-01 (1c76354, 8604d32, 40fbf74): gleam package + pins, screwtape_ffi, nix/package.nix + checks.gleam-test, test/support (subprocess, local_tls, temp); ASM-001 validated; memories mem.fact.gleam.shipment-compiles-test-erl, mem.pattern.gleam.guard-spawn-monitor
- SL-001 scope: research amendment (check-jails to satan) committed in 15914cd; design amendments (DEC-001, DEC-004, DEC-013, DEC-016, DEC-017, F11 body values, F-13 wording) uncommitted
- CHR-001: flake and quotient forms; resolved 2026-10-27 (pin → CHR-003, gateway export → flakes:IMP-043)
- Research round 1: `research/research.md` + `raw/`, restamped 2026-10-26 (gitignore gap is upstream doctrine, operator-owned)
- Design run: inq-1..inq-19 resolved; `design.md` materialised (14 sections); 11 design-target selectors
- Knowledge: DEC-001..DEC-017 (DEC-002, DEC-003 superseded by DEC-016, DEC-017), ASM-001..ASM-005; DEC-001/004/006/007/008/009/011/013/014/015 and ASM-003 revised after RV-001
- RV-001: pass 1 self-review F-1..F-8; pass 2 Codex F-9..F-18; pass 3 Codex verified 15, contested F-12/F-13/F-17, raised F-19..F-24, F-26; all re-disposed, awaiting the raiser
- satan RSK-021 (1Password abstract-socket probe; owns ASM-003's validation); ~/flakes IMP-042 (jail launcher refuses HOME-or-ancestor launch dirs; RV-001 F-27)
- RV-001 done: 31 findings (30 verified, 1 withdrawn), pass concluded; severe findings routed (control: F-1, F-9, F-12, F-14, F-15, F-19, F-20, F-22 — their criteria and host-phase constraints live on the ledger for /plan)
- Design locked 2026-10-26 on the operator's "agreed, lock it": all 14 sections attested, review-disposed (conducted RV-001), design-accepted
- satan RFC-020 edits from the research round: uncommitted in `~/dev/satan`, operator's
- plan.toml/plan.md: PHASE-01..PHASE-09; RV-001 control findings transcribed (placement table in plan.md); selectors `src/screwtape_http.erl`, `nix/**` added; research baseline restamped (drift was the design itself)

### Learned
- mem.pattern.host.op-secrets-for-units: `op://` at unit start prompts on every run; use the llm-gateway provision-once `systemd-creds` pattern
- Project quotient forms: CHR-001 § Done
- The host `quotient` on PATH may be the stale npm 0.2.0; use `~/.local/state/quotient/bin/quotient`
- Candidates for /record-memory at close: gleam_httpc buffers whole bodies (RV-001 F-12); httpc streams only 200/206 and autoretries 503 by default, but max_body_size bounds all statuses (F-19, F-20); the systemd user manager has no network-online.target; JMAP `#ids` back-references prevent client-side dedupe (F-10); WAL needs an explicit read transaction for multi-query consistency (F-15)

### Open
- Next: /audit
- ~/flakes a4c04414 (local, unpushed) also carries the operator's pre-staged files (7 ~/flakes .doctrine backlog entries incl. IMP-042, emacs/emacs.nix, modules/home/nushell.nix); operator: "one commit is fine"
- Reconcile at audit (PHASE-11 D1, operator 2026-10-27 "ok, b"): `client.call` guarantees response i answers call i (count + call ids in order) else `Decode("methodResponses")` — stricter than RFC 8620 in general (implicit extra responses), sound for the four scoped methods; design § 5.2 could name it next to F8. PHASE-11 A3's premise (F8 refuses a reorder) was false; recorded in the phase sheet
- Audit (pre-existing, found at PHASE-07 verify-vt): PHASE-10 VT-2 keyword `ca_file` is absent from `test/screwtape/token_leak_test.gleam` (never present; the test trusts a per-run CA via `server.ca_path`). Behaviour covered; the keyword/traceability needs a ruling at /audit
- Reconcile at audit (PHASE-07): design § 5.2/5.4 additions — module asserts xdg.configHome default too (the unit's %E; provision bakes `xdg.configHome`/credstore.encrypted/screwtape.fastmail); the config file is validated at build by the program's parser (writeTextFile checkPhase); `services.screwtape.configFile` internal option; provision traps EXIT/INT/TERM/HUP
- Reconcile at audit (PHASE-06): design § 5.1 module graph (new utf8, argv, store/query, store/codec; render imports utf8 not error; cli imports store/query; model gains pure rules); § 5.2/5.3 `list` order is newest first (D5); D7 output shapes and `--max-bytes` as a prefix of the concatenated bodies; usage reason codes (argv module doc); design § 5.2 says read verbs fail `no_snapshot` on v0 (A9 covers "older")
- PHASE-06 operator decisions, settled (2026-10-26): `list` newest first (received_at_ms DESC, id DESC; reconcile design § 5.2/5.3 wording); unknown message/thread id → Usage, exit 2
- ISS-001 RESOLVED (fixed, 418a09f, PHASE-11). History: (PHASE-05 review F1, type_state race): operator decided 2026-10-26 — fix within SL-001 after PHASE-06, before /audit; REV for design § 5.2 + PHASE-05/EX-4 first. REV-001 abandoned: `revision change add` refuses an SL target (SPEC/PRD/REQ/ADR/POL/STD only). Design amended through its run instead (reopened rev 112, adopted rev 113; §§ 5.2, 5.4, 9). Relocked rev 118 on the operator's "agreed" (human attestations att-24..26, RV-003 waived, design-accepted). Plan: operator chose a new PHASE-11 over reopening PHASE-05 (2026-10-26, "b)"); PHASE-05 ids and text unchanged, PHASE-11/EX-1 supersedes its EX-4 Email/Thread sources
- M2 note (PHASE-05 D3): with `max_age_days`, `after` (in `filter_json`, part of the `query_state` key) changes every run, so a stored `query_state` row is never reusable by `queryChanges` as-is
- Audit flags (PHASE-05): A9 retired by PHASE-11 (an empty window now sends no phase-2 gets; states come from the opening request); A10/D4 warning only on a committed run; A13/D5 a failed first run leaves an empty v0 file; A14 `sync.run(client, writer, bounds, now)` refines the design signature (session runs in cli, so EX-5's session injection is a cli_test); review F5 accepted (a mailbox id outside Mailbox/get fails the commit as `write_failed`); N1 thread notFound uncounted
- PHASE-09 live checks (PHASE-05 R5): `ids: []` gets and the three-call opening request accepted, and Email/get answered every id (not_found 0) — observed; `limit` clamping and `total` not exercised (419 messages, under every bound)
- PHASE-05/06 inherit (PHASE-04): sync writes through `store.write_snapshot` (I2 dump checks via `support/store_dump.dump`, also for the I1 sentinel); read verbs query via `store.read` + `store.select`; I8 test (PHASE-06/EX-2) needs a second connection committing mid-read — `store_dump` cannot see connection state
- PHASE-09 EN-2 (operator, 2026-10-26): the read-only Fastmail token's ref is `op://SLEIPNIR_CREDENTIALS/udcn7s4ervqa3mrvadczu6lqoy/credential` (a public module option per design § 5.3; the ref is not a secret, the token never leaves 1Password except via provisioning)
- PHASE-09 EN-3 (operator, 2026-10-26): accept the host-local `git+file` quotient pin for this host; superseded at PHASE-09 D4 (operator 2026-10-27): `~/flakes`' gate refuses a local source, so the same rev is pinned by github (6c31cf9). The tag swap stays CHR-003. CHR-001 resolved/done 2026-10-27 (operator "yes"): its last open item (gateway models from an internal agents file) moved to flakes:IMP-043, so SL-001's `needs` edge is satisfied
- PHASE-09 EN-4 (operator, 2026-10-26): no lingering for now. The timer runs only while the operator has a session
- Reconcile: design § 9 I5 row and § 5.1 module table per DEC-020 (html_text imports screwtape/html_sax, not htmgrrrl; html_sax + screwtape_html_ffi are the catch boundary); design § 5.5 'Parse failure' also covers a parser crash; § 9 I5 row: gleam/io denied within gleam_stdlib, FFI rule is the beam import table, I6 literal scan is whole-literal only; CHR-002 upstream htmerl report (operator)
- Later decoders: add field names to `decode.path_fields`; server-keyed maps go in `server_keyed_fields`
- Reconcile: design § 5.2 premise 'an httpc worker crash logs a report holding its request' is false on OTP 28.5 (DEC-019 consequences); EX-5 crash case reading per DEC-019
- Audit reconcile: design § 5.2 crash rules should name the linked-exit containment (guard under spawn_monitor; PHASE-01 review F2); PHASE-10/EX-5 inherits review F7 (forced crash through main)
- Design § 6: OQ-A decided (operator 2026-10-27, VH-2: fail closed, later change → IMP-001; observed `isReadOnly: true`); reconcile § 6 at audit; lingering (host choice); silent sync failures; library pins closed by PHASE-01/EX-1 (manifest.toml)
- ASM-003 (unvalidated; satan RSK-021); ASM-004, ASM-005 validated at PHASE-09
- I7 jail clause is conditional on launch directory (operator accepted, F-27)
- Host hygiene, outside SL-001 (operator to decide): `~/Mail`, `~/News` and `~/.var/app/com.fastmail.Fastmail` are 0755; whether the Fastmail flatpak's session is keyring-protected is unknown
- RFC-020 OQ-7: the draft takes the Outcome's "settled by the operator" at face value (operator not asked directly); Wormwood's future `op://` ref (rfc-020.md:296) unchanged
- nix-config IMP-051: upstream `jailScanCheck` + op preset into the agents lib after porting the last `useOpEnv` consumers to the gateway
- RFC-020 OQ-2, OQ-5, OQ-6, OQ-10, OQ-11
- Research host checks 8 and 9: not run
- CHR-001: swap the quotient pin to a published tag

## PHASE-08 evidence

All in `~/dev/satan`, uncommitted for the operator (DEC-013, DEC-015).

- EX-1: `checks.op-unjailed` built on a new shared `jailScanCheck`. From each `jailPkgs` bin it follows exec'd scripts (any depth: quotient forms are three deep), `{FD}</nix/store/…` args files (NUL-separated), and nested `-jailed-*` launchers on the jail PATH. It fails on literals `/run/wrappers/bin/op`, `onepassword-cli`, `.1password`, `1Password-BrowserSupport.sock`, `1PASSWORD_SDK_INTERGATIONS`, and on any bare argument equal to an ancestor: `/`, `/run`, `/run/wrappers`, `/run/wrappers/bin`, `/run/user`, `/run/user/<n>`, `$XDG_RUNTIME_DIR`. That is EX-1's three plus the rest of the chain (phase decision). It fails on 0 scripts scanned. `just check-jails` builds it.
- Refactor: `runner-socket-unjailed` moved onto `jailScanCheck` (same forbidden meaning; gained a control). It used to miss the quotient forms' bwrap launchers (one sed hop) and couldn't match inside NUL args files (space-bounded pattern).
- EX-2 positive control: built in, and runs every time. A synthetic launcher execs a script that binds `--ro-bind /run /run` through an args file, so it exercises the exec and args legs. Red (empty forbidden set): `op-unjailed: positive control passed: the scan misses '--ro-bind /run /run'`, exit 1. Demo with a synthetic `jailed-demo` (`exec bwrap --ro-bind /run /run true`) added to the scanned set: `…-jailed-demo/bin/jailed-demo has the argument '/run'`, exit 1; then removed.
- VA-1: `just check-jails` (satan HEAD dfa115e + diff), all six recipes exit 0; `op-unjailed: 27 scripts clean`, `runner-socket-unjailed: 27 scripts clean`. No hits, so no NF-004 backlog items. Dry run outside Nix: 13 injected forms caught; sub-path `/run/user/1000/satan/mcp` allowed. alejandra clean; satan `doctrine validate` clean.
- Earlier the lock didn't evaluate (`jailLib.gatewayFacts` missing). The operator fixed it mid-phase in `~/flakes` 73516b60 and satan 1af5868/dfa115e (IMP-043).
- Known limits (a guard, not proof of NF-004): indirection (`B=/run; --bind "$B"`), runtime-generated args (`elf-closure-binds`, `printf` process substitutions), helpers not named `-jailed-`, and a bare `/` in launcher text failing loudly.
- pi review (deepseek, $0.015): accepted F3 (exec line without args) and F5 (the control must exercise the args leg). Refuted F1 (claimed that args files never match; real launchers use `{RUNTIME_CLOSURE_BIND_ARGS_FD}</nix/store/…`). Declined F2, F4, F6, F7 and F8 as known limits or low value.
- VH-1 (operator, 2026-10-27: "file a backlog imp for merging these upstream, and then land 08"): landed in satan f0634c2 (check) and 1b82629 (RFC-020), not pushed; upstreaming → nix-config IMP-051 (dcf9f1ee). Operator: opEnv is superseded by the gateway; remaining users get ported.
- EX-3: RFC-020 revised in place: D1 diagram; D3 (provision-once `systemd-creds --user`, same uid per DEC-016/017, `op-unjailed`, the decrypted credential, provisioning prompt); D4 row; D7 row 10 "Enforced at"; D8 and OQ-7 (removed from the open list, matching the Outcome); brief table; Outcome; OQ-4 (settled, kept as record, residual → RSK-021).

## PHASE-09 evidence

Host Sleipnir, systemd 262, 2026-10-27 (local +11:00). Probe: a transient user unit (`systemd-run --user --pipe --wait -p LoadCredentialEncrypted=fastmail:…`) running a scratch `jmap-probe.sh`: token read by builtin, given to curl on stdin (`-K -`); session GET plus Mailbox/get, Email/get, Thread/get with `ids: []` and Email/query `limit: 0`.

- EX-1: ~/flakes a4c04414 — `screwtape = github:davidlee/screwtape` (follows nixpkgs-home, home-manager, agents, doctrine/agents), `features/satan/screwtape.nix`, `feature.satan.screwtape.enable`, dev-checkouts + its test, SATAN.md (Repos, Units, Storage, Known gaps, § Screwtape smoke). Lingering: none (EN-4). `just gate` exit 0 (after the operator's fleet bump b729033); `just home-switch` ok.
- EX-2 / ASM-005: provision ok ("credential stored; first sync succeeded"); unit exit 0 under every hardening key, none relaxed (7.8 s, 107 MB peak). Credential header GUID 2a1f877a-… = `CRED_AES256_GCM_BY_HOST_AND_TPM2_HMAC_SCOPED_PINNED_SRK` (systemd 262 `src/shared/creds-util.h`): TPM-bound.
- EX-3: `~/.local/state/screwtape` drwx------ david; `mail.sqlite3` 0600; `-wal`/`-shm` 0600 david, stat'ed while the unit held the store; both gone after it exited.
- EX-4: probe 21:52:32Z → sync 21:52:42–48Z (36 mailboxes, 188 messages, 185 threads, 0 truncated/not_found/conversion failures, `is_read_only: true`) → probe 21:53:00Z; Mailbox, Email, Thread all `J365090` before and after. Session capabilities core + mail; one account `u821e43a5` (isPersonal, isReadOnly true, mail only) = primaryAccounts mail (ASM-004); `canCalculateChanges: true`. Default window (30 d / 2000) then: 419 messages, 398 threads, 8.4 s, no rate-limit error.
- EX-5 / VH-2: OQ-A → fail closed later (IMP-001).
- VH-1: operator "Confirmed" (2026-10-27). VA-1: ASM-004, ASM-005 settled via `doctrine knowledge settle` with this evidence.
- Probe pitfall: `systemctl is-active` is false while a oneshot is `activating`; the first after-probe ran mid-sync and was discarded.

## PHASE-11 evidence

- EX-1 / VT-1 `type_state_earliest_first_request_test`: opening es-0/ts-0 stored, phase-2 es-1/es-2 per message, opening calls Mailbox/get ids null, Email/get [], Thread/get [] under c0/c1/c2 (`sync_fixture.opening_calls`). Negative control (run): mutant taking Email type_state from the first phase-2 chunk → 374/3, VT-1 red on Email es-1 ≠ es-0; restored.
- EX-2 / VT-2 `empty_window_first_request_test`: calls [MailboxGet, EmailQuery], commits, three opening states.
- EX-3 / VT-3 `inject_first_request_{email_error,thread_error,missing_thread_get,reordered_responses}_test`: JmapMethod("Email/get"|"Thread/get","serverFail"), Decode("methodResponses") ×2; dump and user_version unchanged on the seeded store.
- D1: client_test `call_*` (pass-through, reorder, missing, extra); red before T3 (reorder returned Ok).
- EX-4: token_leak_test passes over the opening request (cli_fixture); `nix develop -c doctrine check gate` exit 0 (format, warnings-as-errors, check-imports ok, 377 pass); `nix flake check` exit 0; `doctrine slice verify-vt 1`: PHASE-11 VT-1..VT-3 PASS (only PHASE-10 VT-2 `ca_file` fails, pre-existing audit item).
- A5 assessed: maxCallsInRequest < 3 → request-level limit problem → `JmapRequest("urn:ietf:params:jmap:error:limit")` (full URN) via the existing allowlist; no code, no sync_test (client/decode tests already cover the mapping).

## PHASE-07 evidence

- EN-1: PHASE-06 complete (13ea2e2), gate 364.
- Probe: a fresh `nix build .#screwtape` exits 1 (`store`/`no_snapshot`) on a valid config with no store, 2 on an invalid config; the repo-root `result` symlink is a stale early build (exits 0, no output).
- TDD: module-eval written by pi from EX-1..EX-3 + sheet D2-D8, red against the options-only stub (`Type: want oneshot`); module by orch; green. Review round: tests added first, red (`configFile` missing), then green.
- Negative controls (module copy backup, restored by copy), each red with its own message: LimitCORE removed; wrapper gains `--verbose`; `/home/` literal; stateHome assertion `true`; config credential_name changed (jq); ERL_CRASH_DUMP_SECONDS=10; configHome assertion `true`; parser exit 2 ignored (testBuildFailure: "builder did not fail"); provision opRef literal; `--name=other`; wrapper ignores `package`; `max_pages` literal.
- Gate (6b8d0bf tree): `doctrine check gate` 364 passed; `nix flake check` exit 0, only "unknown flake output 'homeManagerModules'" (EX-5); `doctrine slice verify-vt 1` PHASE-07 VT-1, VT-2 pass.
- VA-1 (orch): screwtape-provision against `~/flakes/features/agents/gateway/llm-gateway` `credentials` (l.326-360): same op read → encrypt pipe to `<stored>.new`, both statuses checked (PIPESTATUS), mv only on success, then one start of the unit with its result reported. The token is in no argv, variable or clear file; the op ref is the only argv. Differences: user scope (`--user`, no sudo, no `--with-key=host+tpm2`, per design § 5.4; key binding is ASM-005), and an EXIT trap (plus INT/TERM/HUP → exit) removes the staged file on every path. shellcheck runs in module-eval (it caught SC2174).
- VA-2 (orch): README checked against design § 5.4 and DEC-016 (`record-016.toml` context), `error.exit_code`, `cli.gleam` unknown-id → Usage; failures write nothing to stdout (probed).
- Review (pi `review`, max; 10 findings), dispositions: 1, 3 fixed (parser checkPhase; testBuildFailure cases for no window bound and http); 2 fixed (override case for every option; package and opRef reach wrapper/provision); 4 fixed (`credentialPath` shared; provision text checks); 5 fixed in part (home-relative negative value; a second value judged not worth it — the mutant `!= <literal>` is implausible); 6 fixed (traps); 7 fixed (configHome assertion, baked path; 10 follows); 8, 9 fixed (README).

## PHASE-05 evidence

- Plan review (opus, unanchored) folded in before execution: 10 findings (sheet Findings). Operator 2026-10-26 accepted A1/A2/A9/A10 ("design choices seem sound").
- TDD: T3 (23 contract tests) and T5 (29 sync tests) written red against stubs by agents that did not implement them; T4/T6 made them green. Orch TDD additions: sticky clamp (RFC 8620 § 5.5 echoes `limit` only when it differs), sorted flag keys.
- A11 probe: `to_rfc3339(from_unix_seconds(1793000000), seconds(0))` = `2026-10-26T07:33:20Z`, parsed by `normalise.utc_date`.
- Negative controls on sync.gleam (copy backup, restored by copy):
  - (a) queryState check off → 3 query_unstable tests red;
  - (b) write before Thread/get → inject_500_at_thread_get red;
  - (c) first chunk re-requested → 21 red, incl. exactly_once_chunks;
  - (d) latest Email state → type_state_earliest red;
  - (e) clamp ignored → 6 paging tests red.
- Gate 299 passed, check-imports ok; `nix flake check` exit 0, sandbox 299 passed.
- PHASE-05 review (opus, unanchored; no blockers, no reachable hang). F2/F3/F4/F6 fixed by a repair agent against orch-written red tests; F7 regression tests added; F5, N1, N2 accepted; F1 to the operator (Open).
- Orchestration: orch = Opus. pi (deepseek-flash) did T2, T3, T4 and T7a/b ($0.03–0.06 each, no fixes needed). Opus agents did the plan review, T5, T6, the T9 review and the repair. Briefs: fix the stubs' types before the contract-test brief; stub a signature change rather than let tests fail to compile.

## PHASE-04 evidence

- Probes (2026-10-26, orch erl against esqlite): `file:<p>?mode=ro` honoured (INSERT → 8 READONLY); missing file ro → 14 CANTOPEN; `PRAGMA user_version` inside a rolled-back `BEGIN IMMEDIATE` reverts. The nix check sandbox has no sqlite3 CLI (`nativeCheckInputs = [just]`), so `.dump` is the in-process `test/support/store_dump` (phase sheet D1).
- Gate 225 passed; `nix flake check` gleam-test: check-imports ok, 225 passed.
- Negative controls (orch, each reverted by copy, never git): (a) migrate-on-open → both `pending_migration` tests fail (EX-3); (b) forward-only loop (refusal removed) → `newer_schema…` fails (EX-4); (c) autocommit writes (no BEGIN/COMMIT) → 4 rollback tests fail (EX-2); (d) `foreign_keys=OFF` → `foreign_keys_refuse_a_dangling_mailbox` fails (EX-1); (e) write-path rollback removed → `a_failed_write_leaves_the_writer_usable` fails; (f) reader without `mode=ro` → missing-store and read-only tests fail (EX-5).
- VT-4 is lexical over `store.gleam` plus the schema tests; `busy_timeout` 5 s and `BEGIN IMMEDIATE` have no automated test (review F3/F4 accepted): the reviewer's probe saw a lock-blocked write fail `write_failed` after ≈5 s, dump unchanged, writer reusable.
- PHASE-04 review (pi `review`, deepseek-flash max, unanchored; timed out, continued with a request ceiling; $0.06). F1 accepted: `open_writer` sets WAL before the version check, so a non-WAL newer store flips to WAL — design § 5.2 puts WAL at open; I2/I10 are defined on dump + user_version; every store we meet is WAL. F2 fixed: rollback was hidden by close → reuse test. F3/F4 accepted (above). F5 fixed: `read` rolls back on a failed COMMIT. F6 accepted: a non-Latin-1 path is `open_failed` (esqlite Latin-1 filename), never a wrong write. F7 doc'd in store_dump. F8 fixed: missing-store test asserts no file is created.

## PHASE-03 evidence

- EX-1 / ASM-002 (2026-10-26, orch erl probes, htmgrrrl 1.0.1 / htmerl 0.2.1 = latest): events suffice; htmerl raises on input ending in a tag name (87/316 truncation offsets) and on an unclosed table cell → consulted → DEC-020 (operator: option A), DEC-021 (normalise owns inputs). ASM-002 validated; CHR-002 upstream report (operator files).
- EX-3 control (orch): per-part-only mutant fails message_limit plain/utf8/html. Not committed.
- EX-6 / VA-1 (orch, scratch tree, `just check-imports`): conforming ok exit 0; normalise importing gleam/erlang/process → exit 1; html_text with @external → exit 1. FFI rule checks the beam import table (quoted atoms, fun refs, literal apply caught); residual: variable-module call (apply opcode) — accepted, review-visible.
- Gate 209 passed; `nix flake check` gleam-test runs `just check-imports` then 209 tests (75dd306 + review fixes).
- PHASE-03 review (pi `review`, deepseek-flash max, unanchored, $0.11; orch reproduced F1 by probe). F1 fixed (leading style/script before bare text dropped it silently: synthetic-head skip removed). F2 fixed (non-digit fraction chars accepted). F3 split: leap second :60 now accepted; lowercase t/z rejection kept, contested by RFC 8620 § 1.4 (letters MUST be uppercase). F4 accepted: I6 literal scan misses concatenation; closed Method + opaque Invocation is the primary guard (doc'd in check_imports). F5 fixed: gleam/io denied in governed modules. F6 accepted + doc: design § 5.2 fetches with maxBodyValueBytes = max_body_bytes. Test notes: literal `<` survival pinned; real resolver exercised only via `main` (just check, nix) — accepted.

## PHASE-01 evidence

- EX-5 / VA-2 (2026-10-26, orch, devshell, network): OTP 28.5.0.8 (the shipment's erts) `public_key:cacerts_get/0` returns 118 certs on this NixOS host. httpc `verify_peer` + `cacerts_get()` + https hostname match_fun: `https://api.fastmail.com/.well-known/jmap` handshake succeeds (HTTP 401, unauthenticated); negative control `https://expired.badssl.com/` fails `Certificate Expired`. Decision: production trusts the system store; `ca_file` stays optional (DEC-018), not defaulted to the Nix cacert bundle.
- EX-2 / ASM-001 (2026-10-26, orch): `nix build .#screwtape` (sandbox = true) built the vendored esqlite 0.10.0 NIF via `rebar3WithPlugins [pc]`; no fallback. ASM-001 settled validated.
- EX-7 (2026-10-26, orch): `nix flake check` ran `checks.gleam-test` in the sandbox: loopback TLS from a pkix_test_data CA and subprocesses of the built shipment both work (12-13 passed).
- PHASE-01 review (pi `review`, deepseek-flash max, unanchored; 10 findings). Orch verified F2 and F3 by probe:
  - F2 (high): a process linked from inside `guard` that crashes kills `main`; gleam's `screwtape@@main` wrapper (trap_exit false) prints the exit reason to stderr (SENTINEL leaked). Fix: guard runs the body under `spawn_monitor`. Bears on design § 5.2's crash rules and PHASE-10's I1 suite: reconcile at audit.
  - F3: `gleam export erlang-shipment` compiles `test/**/*.erl` into the production app ebin. Fix: package src includes `test/` only when `doCheck`.
  - F4/F5/F6/F10 fixed (subprocess stderr/timeout, hostname-mismatch control, temp file modes). F7 deferred to PHASE-10 (forced crash through main). F8 accepted: `{flush,true}` is OTP's default since 26; kept explicit per design. F9 documented.

## PHASE-10 evidence

- T0 spike (2026-10-26, pi, $0.07): no client crash carrying the token is reachable on OTP 28.5. httpc concatenates header bytes unvalidated (CR/LF, NUL, 1 MB tokens all send); malformed responses return `{error,_}` with no log events; `httpc_handler` catches every exception into a `{shutdown,_}` stop (orch read lines 268-313). Only crash found: Cap = 0 `function_clause`, token-free. Consulted → DEC-019 (operator: "a) 1").
- Header injection: a token containing CR/LF is sent as-is. Operator ("b) yes", 2026-10-26): `credential.read` rejects control bytes → `Credential("invalid")`, tested.
- Test-helper gotcha (T0): `local_tls_ffi` request reading (`string:lowercase` on header lines) badargs on non-UTF-8 request header bytes; the I1 suite must use UTF-8 tokens or the helper be hardened.
- T1 (pi, $0.05) and T2 (pi, $0.07): TDD, 92 tests green, gate + `nix flake check` pass. `jmap/request.Invocation` is opaque: T3 needs an accessor (call ids → method names) for `decode.method_responses`'s `calls` argument.
- T1b (d64002a, orch): control bytes (< 0x20, 0x7f) after the trim → `Credential("invalid")`; red first.
- T3 (ce2c002): `Client` opaque (design § 5.2 shows a public record; opaque keeps the token unreachable; reconcile wording at audit). Budget is a pure value threaded through `Client`; a failed request ends the run (EX-2), so its charge has no reader. VT-1 control: removing the `cap <= 0` guard fails 3 tests (two fixture exhaustion cases; the real-transport case crashes httpc on cap 0).
- T4 (b94e3ad): T1's `screwtape_ffi:getenv/1` passed a binary to `os:getenv/1` (badarg → `internal` on every real sync); fixed, covered by the shipment sync case. EX-4/VT-7 green in process and through the shipment.
- T5a (a78b1de) EX-5/VT-2: eleven subprocess scenarios (401, 403, 429, 500, timeout, malformed JSON, method error, oversized; after review also server text carrying the sentinel in a problem type, a method-error type and a primaryAccounts key) plus the same scripts in process through jmap/client; DEC-019 crash cases (raise, linked exit) under real silence_logger + guard; happy-path control exit 0.
- VA-1 (orch, 2026-10-26, shipment ebin, OTP 28.5; not committed): (a) no guard, logger default, raise at boot → `Runtime terminating during boot ({{crash,<<"Bearer SENTINEL-i1-9f3c1d7a4b2e5068">>},…` (also wrote `erl_crash.dump`, deleted: set `ERL_CRASH_DUMP_SECONDS=0` for such probes); (b) crash in a spawned process → `=ERROR REPORT==== … {{crash,<<"Bearer SENTINEL-i1-…">>}, …}`; (c) with silence_logger + guard → `{"level":"error","error":"internal"}` only.
- T6 review (pi `review`, max, unanchored; 11 findings). Orch probed F1/F2 against the built modules: `problem` → `{ok,<<"SENTINEL-TYPE">>}`; method error → `{jmap_method,…,<<"SENTINEL-M">>}`; session `primaryAccounts {"SENTINEL-KEY":5}` → `{decode,<<"primaryAccounts.SENTINEL-KEY">>}` (stdlib `decode.dict` puts the failing key in the path). An I1 breach of D1/D6 the suite could not catch. Fixed (54e028e): RFC 8620 allowlists (§ 3.6.1 request, § 3.6.2/§ 5 method; else `Http("status_<n>")` / `"unknown"`); `decode.path` stops at the first segment outside `path_fields`; core limits > 0; request owns the URNs; main writes inside guard; byte-budget test on non-ASCII (regression guard, already green); three server-text cases in VT-2. Accepted F7 (inputs validated upstream), F10 (systemd owns the credentials dir), F11 (temp.write is already 0600; sandbox TMPDIR fixed). Deferred F8 to PHASE-05.
- T7 gates (orch): `doctrine check gate` 138 passed; `nix flake check` 0 failures, sandbox log 138 passed; no `let assert`/`panic`/`todo` in credential or jmap/client.

## PHASE-02 evidence

- EX-1..EX-4 / VT-1 / VT-2 (2026-10-26, orch): `test/screwtape/transport_test.gleam` (14 tests) against `local_jmap`: fixed-length and chunked 500 over the cap fail `TooLarge` while the server still withholds the body end; an oversized withheld 200 likewise; a 503 with `Retry-After: 0` is returned as a 503 after one request; an oversized 503 fails `TooLarge` after one request; a 301 is returned, not followed (one request); an untrusted CA, a missing `ca_file` and system CAs against the per-run CA each fail `TlsFailed`; closed port `ConnectFailed`; withheld under cap `Timeout` after one request; invalid UTF-8 `BadUtf8`; a non-ASCII body round-trips byte-exact. `doctrine check gate` 35 passed; `nix flake check` passes, sandbox ran 35 passed; shipment ebin holds no test FFI.
- VA-1 negative controls (2026-10-26, orch, witnessed, not committed; mutants of `src/screwtape_http.erl`):
  - (a) buffer-then-check stub (no `max_body_size`, OTP default autoretry, crude mapping): 10 fail, incl. both VT-1 500s (`Timeout`: it waited for the withheld end) and both VT-2 tests (request_count 2).
  - (b) `max_body_size` moved into HttpOptions: fixed-length 500, chunked 500, oversized 503, oversized 200 fail.
  - (c) `{autoretry, 0}` removed: `retry_after_503_one_request_test` fails (count 2). The oversized 503 stays at one request even under default autoretry: the cap fires before httpc's retry logic.
  - (d) `{autoredirect, false}` removed: `redirect_301_not_followed_test` fails.
  - (e) `{body_format, binary}` removed: four tests fail (charlist body → `BadUtf8` by the `is_binary` guard).
- Sandbox finding: `public_key:cacerts_get/0` raises when the host has no CA store (Nix build sandbox), so `ca_file = None` crashed `Send`. Now `TlsFailed` (red in `nix flake check`, green after). mem.fact.erlang.httpc-reason-shapes.
- Decisions D1-D4 (phase sheet), in scope: `HttpFailure`/`Send` live in `src/screwtape/jmap/client.gleam` now (types only; PHASE-10 adds session/call/Budget); Erlang entry `screwtape_http:send(Request, Cap, TimeoutMs, CaFile)`; the Gleam `@external` binding sits in transport_test until PHASE-10's cli owns the production one; `local_jmap` reuses `local_tls_ffi`'s listener and per-connection acceptor (`serve/2` with a responder fun).
- PHASE-02 review (pi `review`, max, unanchored; 12 findings). Fixed: 1 (body_format undiscriminated), 2 (`{options,_}` → TlsFailed), 3 (withholding registered after send: race), 4 (no 2xx cap test), 5 (autoredirect and system-CA branch untested), 6 (sleep as sync), 7, 8 (acceptor duplication vs D3), 10, 11 (badmatch on app start → `ConnectFailed`). Accepted 9 (servers leak only on an already-failed test). Rejected 11's per-request `cacerts_get` cost (OTP caches it in persistent_term) and 12 (unknown reason → `ConnectFailed` is deliberate and commented).
- For PHASE-10: a zero cap must never reach `Send` (F-29); unknown httpc reasons classify as `ConnectFailed`; `local_jmap` serves scripts in order (no method matching yet).

## Design triage (2026-10-26, run dr-01a17546)

Inquiry ids (`inq-N`) are the design run's; `doctrine design show 1`.

### Constraining governance (satan; screwtape has none)
- POL-001: Rust for SATAN-orbit daemons; Screwtape is a oneshot, so Gleam stands (RFC-020 D2). Disable switch = timer off.
- SPEC-002 NF-001 (REQ-013): Screwtape is sole schema owner of its store; M3 never migrates it.
- SPEC-002 NF-004 (REQ-016): model-output jails get no `op` wrapper or 1Password socket; asserted in satan `check-jails`.
- SPEC-002 NF-006 (REQ-018): store path from config/XDG, no host literals.
- Host facts (unit, uid, paths) live in `~/flakes/SATAN.md`, not specs.

### Shaping decisions — operator's (security boundary, state ownership)
- inq-1 token custody; inq-2 unit kind and uid; inq-3 store ownership and read path (couples RFC-020 OQ-11); inq-4 deployment shape.

### Technical open questions
- inq-5 packaging (nix-gleam + esqlite NIF, erlang-shipment, offline `gleam test`); spike timing.
- inq-6 module layout and JMAP client boundary.
- inq-7 store schema (state strings, queryState, provenance, queryable columns, view-ready).
- inq-8 sync atomicity and repeat-run replacement.
- inq-9 bounds and configuration (incl. aggregate bytes, concurrency, limits from session, store path).
- inq-10 HTML-to-text.
- inq-11 CLI surface and output contract; exit status.
- inq-12 token ingress and redaction tests.
- inq-13 satan `check-jails` assertion (abstract socket; host check 8).
- inq-14 error model.
- inq-15 governance follow-through (RFC-020 updates, SPEC-002 entry, SL-001 scope amendment).

### Risks
- esqlite NIF under offline Nix build (research finding 3) — highest technical risk.
- `op` at unit start prompts every run (P10 ✓); scope § 2 and RFC-020 D3 assume it. Scope amendment likely.
- Fastmail rate limits / caps undocumented; read from session.

### Assumptions
- One read-only Fastmail token, single account.
- Concurrency 1 suffices for a oneshot.

### Drift
- SL-001 scope says token "only through its environment" and `op run` user unit; the gateway pattern delivers a file in `$CREDENTIALS_DIRECTORY`. Resolve with inq-1/inq-12.
- RFC-020 lists OQ-7 open; its Outcome records it settled (raised, unanswered).

## Review passes

- Orchestration (2026-10-27, PHASE-11): orch = Opus; pi deepseek-flash. T2a sync/cli tests (`implement`) $0.044; T2b request/decode/client tests $0.027 (wall-clock timeout at its last check; work complete, verified by orch); T3 impl $0.041; T4 review (`review`, max) $0.058, 13 requests, answered within budget: ≈ $0.17. pi got wrong: T2a wrote a `first_post` helper re-running sync over its own fixture (parallel harness) instead of extending `sync_fixture` — orch added `Run.requests`/`RecordedCall.call_id`; T2b hand-built response entries duplicating `jmap_fixture` — orch rewrote over `opening_entries`; T3 returned an anonymous 4-tuple of states — orch named it `Opened`. Review: 10 findings, none high; fixed 1, 2 (doc), 4 (comment), 5 (`decode.threads` drops dead state), 6 (doc), 8 (dead `..fetch([])`), 10 (doc); declined 3 (call_one tests check its caller-visible contract), 7 (a 4th opening call fails D1 loudly), 9 (EX-1's null-vs-[] is asserted via `ids_argument`; helper unification out of scope). Brief tuning: tell test writers "extend test/support (name the type to extend) rather than writing a local harness"; the reviewer brief with "read only these files + ranges, answer by ~30" held (13 requests).

- Orchestration (2026-10-26, PHASE-07): orch = Opus; pi deepseek-flash. T2 module-eval contract (`implement`) $0.056; T5 README (`write`) $0.018; T6 review (`review`, max) $0.071 hit the 45-request ceiling probing (systemd docs, /nix/store greps) and answered on a 1-request continuation $0.022: ≈ $0.17. Module written by orch (pi has no `nix`; the eval loop is orch-only). pi got wrong: module-eval took the config path via `builtins.match` (drops string context → config missing in the sandbox; orch fixed, later replaced by an internal option); the brief's own half-abandoned sentence (orch's fault) left the config check shallow. pi got right where orch had not: review F1/F3 (configs the parser rejects evaluate fine), F2 (no override coverage), F7 (XDG_CONFIG_HOME vs %E split). Brief tuning: reviewers need "no probing of systemd/nix store; read only the listed files"; write briefs fully before sending.

- Orchestration (2026-10-26, PHASE-06): orch = Opus; pi deepseek-flash (`implement`) for T1, the T3/T5 tests and implementations, the T6 implementation, the T7 refactors and the review fixes; Opus subagents for the I8 test (T4), the cli contract tests (T6) and one review. pi costs: T1 $0.019, T3 tests $0.064 + impl $0.054, T5 tests $0.064 + impl $0.027, T6 impl $0.048, T7 $0.057 + $0.017, review (max) $0.129, fix tests $0.038 + fixes $0.020: ≈ $0.54. No pi run hit a ceiling (largest 54 requests, the reviewer). pi got wrong: nothing that reached a commit; the T5 test author settled `--max-bytes` as a prefix of the concatenated bodies (accepted, D7 updated) where the brief left it open. pi got right where Opus had not: the reader `busy_timeout` gap (P-2). Opus review found the bignum `--offset` crash (pi too), the I8-through-one-query gap and the missing read-only test. Brief tuning that worked: orch writes the stubs and the output-shape decision (D7) before any test brief; implementers are told which tests are fixed; split render and cli implementation into separate runs.

- Orchestration (2026-10-26, PHASE-03): orch = Opus; pi deepseek-flash. T3a html_text tests $0.01, T4a normalise tests $0.04 + continuation $0.003 (wall-clock timeout, build-lock waits), T5 check-imports $0.06, T3b html_sax/html_text $0.07 (timeout at final check; work complete), T4b normalise $0.05, FFI beam-import hardening $0.02. pi got wrong: T3a asserted hr → blank line against its own stated rule, and pinned unspecified mid-entity truncation; T4a missed MessageLimit-over-Server and scalar-field swap cases (orch added); T5's text scanner for the .erl was evadable (quoted atoms, fun refs) → orch had it replaced with a beam-import check; a worker erl probe left erl_crash.dump in the repo root. Brief tuning: three concurrent workers in one tree cost two wall-clock timeouts (gleam build lock) — max two concurrent, or stagger; give stubs with fixed types before contract-test briefs (worked well).

- Orchestration (2026-10-26, PHASE-01): orch = Opus; workers = quotient pi (deepseek-flash). Observed: planner, test and code workers reliable on bounded briefs ($0.01-0.07 each); two runs hit their request ceiling exploring (TLS test debug; reviewer cloning nixpkgs) and finished on a session continuation with a "stop probing, answer now" prompt; parallel workers in one tree serialise on gleam's `build/` lock; a worker-written test was vacuous (atom logger message raising function_clause) and caught only by orch running a control. Review at `max` found two real high/medium defects orch had missed.

- Orchestration (2026-10-26, PHASE-02): orch = Opus; pi deepseek-flash. Sheet written by orch (brief would have cost as much). T1 helper $0.04, T3 tests $0.02, T4 adapter $0.03, review (max) $0.07, two fix workers $0.02 each: total ≈ $0.20. pi got wrong: T1 served connections inline in the acceptor (a withheld reply would hide a retry; caught by orch reading) and registered withholding after sending (caught by review); T3 skipped BadUtf8 rather than flag the helper's String body; T4's atom-walk classifier missed `{options,_}` (review). Review again found real defects orch had not (5 contract gaps). Orch caught by sandbox only: `cacerts_get/0` raising without a CA store. Brief tuning: name the test-helper type constraints up front; ask contract-test writers for one mutant per option.

- Orchestration (2026-10-26, PHASE-10 T1b-T7): orch = Opus; pi deepseek-flash. T3a tests $0.07, T3b client $0.04, T4 cli $0.08 (ceiling at 60 req; finished on a continuation), helper refactor $0.04 (ceiling at 40; work complete, report lost), T5a suite $0.06 (wall-clock timeout at its final check; work complete), T6 review $0.05, review fixes $0.04: ≈ $0.38. pi got wrong: T3a's 503 test reused the pre-call client (demanding a charge survive an error); T3b "fixed" that with a hidden `counters` cell in an opaque value (rejected; orch had missed the test defect, the T3b worker flagged it); T3a used two servers + a CA bundle instead of the D9 helper; T4 used an empty string as "unset"; jmap_fixture's doc claimed no crash on a missing fixture. pi got right where orch had not: T4 found the getenv binary bug; T6 found the server-text I1 channel. Brief tuning: wide briefs (> ~6 deliverables) exceed 60 requests; split, or budget a continuation.

- Plan review (2026-10-26): pi `review` profile (deepseek-flash), read-only, unanchored brief over plan + design + RV-001. 12 findings, all integrated (F-5 as a two-way split to PHASE-02 + PHASE-10; F-6's prescription contested, observation integrated as the F-20 reading in plan.md). Finding 1 (https-only config vs loopback I1 suite) reopened the design: operator chose https + optional `ca_file` → DEC-018; design relocked rev 111 with RV-002 waived (operator: human review of the four amended sections).

- RV-001 pass 1 (2026-10-26): agent self-review; F-1..F-8 raised and disposed (7 fix-now, 1 follow-up).
- RV-001 pass 2 (2026-10-26): Codex (`gpt-6.1-sol`, high), unanchored brief; F-9..F-18 raised. All fix-now; F-13 accepted in part (whole-home binds left to ISS-028).
- RV-001 pass 3 (2026-10-26): Codex (`gpt-6.1-sol`, high), fresh thread. Verified 15; contested F-12 (non-2xx bodies buffered), F-13 (probe unowned), F-17 (sub-ms collapse); raised F-19..F-24, F-26 (F-25 withdrawn). Responder: transport moved to synchronous httpc with max_body_size + autoretry 0; probe owned by satan RSK-021; ms-then-id ordering contract; writer refuses newer schema; import allowlist.
- Operator rulings in the same session: run as the operator's uid under a Home Manager user unit, store under `$HOME` (DEC-016, DEC-017; reason: jails are the boundary and shadow `$HOME`, while the operator's uid already holds mail in Gnus, Thunderbird and the Fastmail flatpak; a separate uid was friction the operator would not keep). F-26 moot; the sudo half of module-vm and the VM itself dropped.
- Next pass: an Opus reviewer as raiser (operator's choice) verifies the round-3 dispositions and attacks the redesign (user-unit hardening and credentials, loss of network-online ordering, module-eval-only I7 evidence, F-4 and F-16 premises changed by the redesign).
- RV-001 pass 4 (2026-10-26): Opus subagent as raiser. Verified F-12, F-13, F-17, F-19..F-24, F-26 (reading inets source and running transient user units). Raised F-27 (I7 jail clause: same-uid jails launched from HOME see the store), F-28 (ProtectHome missing), F-29 (httpc option placement, zero budget), F-30 (@external), F-31 (leftovers). Operator ruled F-27: conditional I7 plus ~/flakes IMP-042, no gate. All five disposed fix-now.
- RV-001 route backfill (2026-10-26): the lock gate refused ten verified severe findings without a route; the Opus raiser reopened them, the responder re-disposed with routes (control F-1, F-9, F-14, F-15; review F-2, F-3, F-10, F-11, F-16; F-4 aligned), and the raiser re-verified. Then locked.
- Orchestration (2026-10-26, PHASE-04): orch = Opus; pi deepseek-flash. T2 test support $0.05, T3 contract tests $0.04, T4 store $0.07, review $0.05 + continuation $0.002 (wall-clock timeout). Operator: quotient execution is strictly sequential for now — the two T2/T3 runs queued, not parallel. pi got wrong: T3 claimed a ro open cannot read beside a live WAL writer (false; comment fixed) and could not express foreign_keys (orch added a behavioural FK test); T4 needed no fixes; the reviewer spent its budget on probes in a $TMPDIR copy and timed out before answering. Brief tuning: give reviewers a hard 'answer by' with a request ceiling; name the negative controls in the test brief.
