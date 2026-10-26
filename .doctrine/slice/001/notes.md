# Notes SL-001: Screwtape M1: Gleam JMAP mirror, full bounded sync

Durable per-slice scratchpad — tracked in git. The place to lift anything from a
disposable phase sheet (`.doctrine/state/.../phase-NN.md`) that must survive
`rm -rf` before the slice close-out audit harvests it.

## Harvest
<!-- single-copy: updated in place each harvest; ids only, never restated content -->
fresh-as-of: 2026-10-26 · design relocked rev 111 (DEC-018); plan 10 phases (PHASE-10 split from PHASE-02); slice status ready

### Produced
- SL-001 scope: research amendment (check-jails to satan) committed in 15914cd; design amendments (DEC-001, DEC-004, DEC-013, DEC-016, DEC-017, F11 body values, F-13 wording) uncommitted
- CHR-001: flake and quotient forms; quotient pin swap pending
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
- Next: /phase-plan PHASE-01 (packaging skeleton) → /execute; plan.md § Risks lists phase-plan unknowns (forced crash in client, body withholding, raw JMAP type home, F-20 'charged' reading)
- Design § 6: OQ-A (operator 2026-10-26: warn now, decide after the live run); lingering (host choice); silent sync failures; library pins
- ASM-001 (PHASE-01), ASM-002 (PHASE-03), ASM-003 (unvalidated; satan RSK-021), ASM-004 (PHASE-09), ASM-005 (PHASE-09) (partly checked by the Opus reviewer; real BEAM and TPM binding remain for the deployment phase)
- I7 jail clause is conditional on launch directory (operator accepted, F-27)
- Host hygiene, outside SL-001 (operator to decide): `~/Mail`, `~/News` and `~/.var/app/com.fastmail.Fastmail` are 0755; whether the Fastmail flatpak's session is keyring-protected is unknown
- RFC-020 drafts per DEC-015 (D3, OQ-4, D7 row 10, OQ-7 drift): not yet written
- RFC-020 OQ-2, OQ-5, OQ-6, OQ-10, OQ-11
- Research host checks 8 and 9: not run
- CHR-001: swap the quotient pin to a published tag

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

- Plan review (2026-10-26): pi `review` profile (deepseek-flash), read-only, unanchored brief over plan + design + RV-001. 12 findings, all integrated (F-5 as a two-way split to PHASE-02 + PHASE-10; F-6's prescription contested, observation integrated as the F-20 reading in plan.md). Finding 1 (https-only config vs loopback I1 suite) reopened the design: operator chose https + optional `ca_file` → DEC-018; design relocked rev 111 with RV-002 waived (operator: human review of the four amended sections).

- RV-001 pass 1 (2026-10-26): agent self-review; F-1..F-8 raised and disposed (7 fix-now, 1 follow-up).
- RV-001 pass 2 (2026-10-26): Codex (`gpt-6.1-sol`, high), unanchored brief; F-9..F-18 raised. All fix-now; F-13 accepted in part (whole-home binds left to ISS-028).
- RV-001 pass 3 (2026-10-26): Codex (`gpt-6.1-sol`, high), fresh thread. Verified 15; contested F-12 (non-2xx bodies buffered), F-13 (probe unowned), F-17 (sub-ms collapse); raised F-19..F-24, F-26 (F-25 withdrawn). Responder: transport moved to synchronous httpc with max_body_size + autoretry 0; probe owned by satan RSK-021; ms-then-id ordering contract; writer refuses newer schema; import allowlist.
- Operator rulings in the same session: run as the operator's uid under a Home Manager user unit, store under `$HOME` (DEC-016, DEC-017; reason: jails are the boundary and shadow `$HOME`, while the operator's uid already holds mail in Gnus, Thunderbird and the Fastmail flatpak; a separate uid was friction the operator would not keep). F-26 moot; the sudo half of module-vm and the VM itself dropped.
- Next pass: an Opus reviewer as raiser (operator's choice) verifies the round-3 dispositions and attacks the redesign (user-unit hardening and credentials, loss of network-online ordering, module-eval-only I7 evidence, F-4 and F-16 premises changed by the redesign).
- RV-001 pass 4 (2026-10-26): Opus subagent as raiser. Verified F-12, F-13, F-17, F-19..F-24, F-26 (reading inets source and running transient user units). Raised F-27 (I7 jail clause: same-uid jails launched from HOME see the store), F-28 (ProtectHome missing), F-29 (httpc option placement, zero budget), F-30 (@external), F-31 (leftovers). Operator ruled F-27: conditional I7 plus ~/flakes IMP-042, no gate. All five disposed fix-now.
- RV-001 route backfill (2026-10-26): the lock gate refused ten verified severe findings without a route; the Opus raiser reopened them, the responder re-disposed with routes (control F-1, F-9, F-14, F-15; review F-2, F-3, F-10, F-11, F-16; F-4 aligned), and the raiser re-verified. Then locked.
