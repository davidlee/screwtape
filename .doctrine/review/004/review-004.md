# Review RV-004 — reconciliation of SL-001

Adversarial-review ledger. Structured findings live in the sister
ledger toml; this prose companion carries the reviewer's framing.

## Brief

<!-- Pre-reading + lines of attack: what this review is probing, the invariants
     it must hold the subject to, and where the bodies are likely buried. Seeded
     at `review new`; the reviewer fills it before raising findings. -->

Mode: conformance (self-audit, both roles via `--as`). Surface: the primary
checkout, `main` at a02225e (not dispatched; no candidate branch).

Holds SL-001 to its locked design (`design.md`, run dr-01a17546, relocked
rev 118 after ISS-001), invariants I1–I10 (§ 5.5 / § 9), and the plan's
VT criteria (`plan.toml`).

Lines of attack:

1. Mechanical evidence: `doctrine check gate` (377 passed), `nix flake check`
   (exit 0; accepted `homeManagerModules` warning), `doctrine slice
   verify-vt 1` (one FAIL: PHASE-10 VT-2 keyword), `doctrine slice
   conformance 1` (undeclared / undelivered leads).
2. Design prose vs the code as built: § 5.1 module graph and table, § 5.2
   signatures and crash rules, § 5.3 / 5.5 edge cases, § 6 open questions,
   § 9 I1 / I5 evidence rows, § 10 Code Impact.
3. The audit queue recorded during execution (notes `### Open`): each item
   verified against current `design.md` (rev 118) before raising.
4. Recorded decisions whose consequences name a design edit: DEC-019
   (crash premise), DEC-020 (html_sax catch boundary).

Out of scope (owned elsewhere): RFC-020 OQ-7 and Wormwood `op://`; host
hygiene; CHR-002, CHR-003, IMP-001; `~/flakes` IMP-043 / IMP-051; ASM-003
(satan RSK-021).

## Synthesis

SL-001 delivers what its design promises. Every invariant I1–I10 has
passing evidence: `doctrine check gate` reports 377 passed, `nix flake check`
is clean apart from the accepted `homeManagerModules` warning, and every VT
criterion passes. PHASE-10 VT-2 failed on a missing traceability keyword
only, and was fixed here (F-1). The live deployment (PHASE-08/09) confirmed
ASM-004 and ASM-005 and observed `isReadOnly: true`.

The divergences all run one way: the code is right and the design prose is
stale. Sixteen of the seventeen findings are `design-wrong`. They fall into
three groups:

- **Structure grew finer than drawn** (F-2, F-5, F-6). Execution split
  `argv`, `file`, `utf8`, `store/query`, `store/codec` and `html_sax` out of
  the modules § 5.1 names. The check-imports allowlist grew to govern six
  modules, not three. The purity boundary is enforced mechanically; only
  the prose lags.
- **Decisions taken in flight never reached the design** (F-7, F-8, F-9,
  F-11, F-13, F-14). DEC-019 falsified the httpc crash-report premise.
  DEC-020 added the catch boundary. The operator settled D1 response order,
  list order, OQ-A and lingering. Each is recorded in a DEC, an operator
  reply or notes; § 5 and § 6 just don't carry it.
- **Small contract details** (F-10, F-12, F-15, F-16, F-17): signatures and
  opaque types, four edge cases from PHASE-05, an over-claim about M2 reuse
  of `query_state`, and an unstated htmerl tokenising exception.

Conformance (F-2, F-3, F-4) is fixed in the selector registry, not prose.

**Standing risks** (owned outside this slice, unchanged):

- ASM-003 is unvalidated (satan RSK-021).
- IMP-001 (fail closed on a writable account) is future work.
- CHR-002: htmerl crashes were never reported upstream.
- CHR-003: the quotient pin is still not a published tag.
- I7's jail clause depends on the launch condition until `~/flakes` IMP-042
  lands.
- Live limit clamping and `total` were not exercised (419 messages, under
  every bound).

**Tradeoffs consciously accepted:**

- D1 is stricter than RFC 8620 (F-9).
- A13 leaves an empty v0 file after a failed first run (F-12).
- `Thread/get` notFound ids are not counted (F-12).
- I6's literal scan sees whole literals only (F-6).

RV-003 (the design pass left from the ISS-001 relock, zero findings) was
waived by the operator at relock. It is concluded on that basis.

## Reconciliation Brief

### Per-slice (direct edit / selector registry)

- **F-2** registry: `doctrine slice selector add 1 src/screwtape_html_ffi.erl`
  (design-target). § 10 mirror: a row "`src/screwtape_html_ffi.erl` | new
  (DEC-020): calls `htmgrrrl_ffi:sax/3` inside try/catch; any exception →
  `Error(Nil)`".
- **F-3** registry: `slice selector add 1 flake.lock .gitignore`
  (design-target). § 10 mirror: `flake.nix` row adds "and its `flake.lock`";
  new row "`.gitignore` | ignore `erl_crash.dump`".
- **F-4** registry: `slice selector rm 1 nix/package.nix nix/module.nix`
  (covered by `nix/**`). No prose change.
- **F-5** design § 5.1: redraw the module diagram from the actual imports
  (F-5 detail lists the edges). Add table rows for `argv`, `file`, `utf8`
  (pure), `store/query`, `store/codec`, `html_sax`, `screwtape_html_ffi.erl`.
  `html_text` folds `html_sax` events. Read queries live in `store/query`.
  `model` holds pure rules.
- **F-6** design § 9 I5 row: rewrite to the six governed modules and their
  allowances, the `gleam/io` denial, the html_sax `@external` →
  `screwtape_html_ffi` rule, and the beam import-table check on
  `screwtape_html_ffi` (`htmgrrrl_ffi:sax/3` only). § 9 I6 row: add the
  whole-literal residual.
- **F-7** design § 5.5: "Parse failure" covers a parser exception caught by
  `html_sax` (DEC-020). "Truncated HTML" notes the trim of an unterminated
  trailing `<…` before parsing.
- **F-8** design § 5.2: drop the "httpc worker crash logs a report" premise
  (false on OTP 28.5, DEC-019). Logger silencing stays as defence in depth
  against the remaining channels (`let assert`, `function_clause`). The
  guard rule names `spawn_monitor`, which contains linked exits. § 9 I1 row:
  the crash case runs in the shipment via `erl_eval`, raising with the
  revealed header under the real guard and logger edge (an error raise and
  a linked exit), with VA-1 as the unguarded control (DEC-019).
- **F-9** design § 5.2: `call` guarantees response i answers call i (count
  and call ids), else `Decode("methodResponses")`. This is stricter than
  RFC 8620, and sound for the four methods.
- **F-10** design § 5.2: `sync.run(client: Client, writer: Writer, bounds:
  Bounds, now: Timestamp)`, where `Bounds` holds the window and the limits.
  § 5.4 sequence: cli opens the session (`client.session`) before `run`.
- **F-11** design § 5.2 CLI: `list` returns newest first (`received_at_ms
  DESC, id DESC`). `read --max-bytes` caps the concatenated bodies (a
  prefix). An unknown message or thread id is a usage error (exit 2). Usage
  reason codes are documented in `argv`. § 5.3 ordering contract: the
  direction is descending, ties by id descending.
- **F-12** design § 5.5: the isReadOnly warning is emitted only on a
  committed run. A failed first run leaves an empty `user_version` 0 file,
  which reads as `no_snapshot` (qualify I2: "as it was, or an empty v0 file
  where none existed"). An email naming a mailbox outside `Mailbox/get` fails
  the commit as `Store("write_failed")`. `not_found` counts Email only;
  Thread notFound ids are not counted.
- **F-13** design § 5.2 Configuration: also assert `xdg.configHome`
  (`%E`, provision). Build-time validation of the generated config by the
  program's parser. The `services.screwtape.configFile` internal option.
  § 5.4 provisioning: the staged file is removed by an EXIT trap, and
  INT/TERM/HUP exit through it.
- **F-14** design § 6: OQ-A decided (observed `isReadOnly: true`; M1
  warns; fail-closed is IMP-001). Lingering: off for now (PHASE-09 EN-4).
  Library pins closed (`manifest.toml`, PHASE-01/EX-1). Rate limits: the
  default window synced within limits (PHASE-09); clamping is not
  exercised. Keep OQ-11, silent failures and ASM-003.
- **F-15** design § 5.3: the `query_state` "Serves" cell becomes "M2
  `queryChanges` (only while the filter is stable; see note)". Add a note:
  with `max_age_days`, `after` changes every run and keys the row, so M2
  must recompute or re-key it.

- **F-16** design § 5.2: `Client` and `Budget` are opaque (accessors
  `session_of`, `budget_of`; `Budget` a pure byte count). `credential.read`
  rejects control bytes (< 0x20, 0x7f) after trimming as
  `Credential("invalid")`; add this to § 9's credential cases. § 5.1
  `normalise` row: it owns the stdlib-only JMAP Email input records and
  `utc_date_ms`, which `jmap/decode` builds (DEC-021).
- **F-17** design § 5.5: add an "Uppercase raw-text elements" edge (htmerl
  0.2.1 mis-tokenises `<SCRIPT>`; script text may be stored, and the
  following text dropped; inert, and the upstream fix is CHR-002). § 9
  html_text: qualify "script, style and head are dropped" with it.

### Governance/spec (REV)

- None. No finding bears on an ADR, policy, standard or spec. RFC-020
  drafts live in satan and are out of scope.
