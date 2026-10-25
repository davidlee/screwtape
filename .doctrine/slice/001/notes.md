# Notes SL-001: Screwtape M1: Gleam JMAP mirror, full bounded sync

Durable per-slice scratchpad — tracked in git. The place to lift anything from a
disposable phase sheet (`.doctrine/state/.../phase-NN.md`) that must survive
`rm -rf` before the slice close-out audit harvests it.

## Harvest
<!-- single-copy: updated in place each harvest; ids only, never restated content -->
fresh-as-of: 2026-10-26 · design (post-research, no run started) · 2fa0535

### Produced
- SL-001 scope; amended in the research round: `check-jails` assertion moved from `~/flakes` to satan (uncommitted)
- CHR-001: flake and quotient forms; quotient pin swap pending
- Research round 1: `.doctrine/slice/001/research/research.md` + `raw/`. Disposable; it should be gitignored, but the doctrine install misses it, and the operator is taking that upstream.
- satan RFC-020: D3 bullets, OQ-4, OQ-9 and References updated from the research, with the operator's assent. Uncommitted in `~/dev/satan` and left for the operator.

### Learned
- mem.pattern.host.op-secrets-for-units: `op://` at unit start prompts on every run; use the llm-gateway provision-once `systemd-creds` pattern
- Project quotient forms: CHR-001 § Done
- The host `quotient` on PATH may be the stale npm 0.2.0; use `~/.local/state/quotient/bin/quotient`

### Open
- RFC-020 OQ-4: token custody. The gateway pattern leads (research finding 7); a dedicated uid and store access are for the operator to decide.
- RFC-020 OQ-11: contract form. A dedicated-uid store makes the read path part of it.
- Packaging spike (research finding 3): nix-gleam plus the esqlite NIF, offline `gleam test` under `nix flake check`
- Research host checks 8 (which socket `op` uses) and 9 (how Fastmail scopes combine): not yet run
- RFC-020 OQ-2, OQ-5, OQ-6, OQ-10
- RFC-020 lists OQ-7 as open although its Outcome records it as settled: drift, raised with the operator, no answer yet
- CHR-001: swap the quotient pin to a published tag
