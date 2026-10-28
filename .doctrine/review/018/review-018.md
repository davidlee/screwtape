# Review RV-018 — reconciliation of SL-004

Adversarial-review ledger. Structured findings live in the sister
ledger toml; this prose companion carries the reviewer's framing.

## Brief

<!-- Pre-reading + lines of attack: what this review is probing, the invariants
     it must hold the subject to, and where the bodies are likely buried. Seeded
     at `review new`; the reviewer fills it before raising findings. -->

Mode: conformance, self-audit (one agent drives raiser and responder via
`--as`). Surface reviewed: the primary tree at `d4d1c2f` (main; no dispatch,
no candidate branch). Phases: PHASE-01 (9c16862), PHASE-12 (dbf81a1,
ee93f74), PHASE-13 (8eb7d06, b07973c), PHASE-14 (2ba7251 … d4d1c2f).

Lines of attack:
- Mechanical path conformance: `doctrine slice conformance 4` against the
  `design-target` selectors; `doctrine slice verify-vt 4` for VT keywords.
- Gates: `nix develop -c just check` and `nix flake check` on the host.
- Design § 5.1–§ 5.5, § 9, § 10 against the code: a pi review sweep (every
  contract statement: constants, bounds, reasons, key order, headers, wrapper
  flags, provision, README contract), with my probes on its claims.
- Every drift the run deferred to audit (notes `## Autonomy log`, per-phase
  pass blocks, `## Harvest` § Open): each gets a finding and a write surface.
- Governance open items: POL-002 wording, inq-9 (DEC-016 exposure note,
  satan:RFC-020 draft), DEC-035 versus the authored schema text, DEC-039 in
  the design.

Invariants held: I1–I5 (design § 5.5); DEC-033–DEC-039; POL-001 (no
parallel implementation); POL-002 (real mail only in
`PII_hidden_fixtures.local/`). Plan criteria (`plan.toml` EN/EX/VT) are
immutable: a criterion whose wording drifted is recorded here, never edited.

## Synthesis

SL-004 conforms to its design in behaviour. Gates at audit start (host, tree
`d4d1c2f`): `nix develop -c just check` 615 passed, 0 failures;
`nix flake check` rc 0 (3 checks). `doctrine slice conformance 4`, after the
delta bootstrap (F-1): 63 conformant, 0 undelivered, 3 undeclared source
paths (F-2). `doctrine slice verify-vt 4`: 18 of 20 VT pass; the two misses
are keyword-literal artefacts with the behaviour tested (F-11).

No blocker, no code defect. Every finding is design drift: the code took a
stricter, ruled or observed path, and the locked design still states the
earlier contract. Three classes:

- **Ruled by the operator during execution** (design lags a recorded act):
  DEC-039's two-location `max_tokens_exceeded` match (F-9, the one major),
  count-only `decode.dict` (F-6), the gateway key for the live check (F-13).
- **Forced by observation**: the stdin edge's raw-byte read (F-7); the live
  check's evidence on A1, tolerances and state size (F-18).
- **Code stricter or more precise than the prose**: I3 strip coverage (F-5),
  provision hardening (F-10), the printed `model` form (F-3), `jev_url`
  (F-15), signatures (F-4), empty stdin (F-8), pii rule 1's shape (F-14).

Governance: POL-002 wording (F-16, operator's REV), DEC-016's exposure note
(F-17), and DEC-035 versus the agent-authored mail-1 text (F-12). F-12 needs
the operator: accepting the text makes it mail-1.

Standing risks, consciously carried:
- pii leaks names, postal addresses, short numbers (documented caveat),
  non-ASCII digit runs (RSK-001) and dotless email addresses (F-14).
- The gateway match couples to LiteLLM's message text until IMP-004.
- Jev replies are not deterministic (max Δ 0.13 between runs, one choice
  flip); calibration and `substance` are IMP-003's question.
- The `alias` echo behaviour stays untested: the gateway key is scoped to the
  pinned model, which also enforces the pin.

Route through the system, for a reader: stdin `read` lines →
`classify/input.line` → `classify/state.build` (control chars, `pii.strip`,
bounds) → `jev.request_body` → `jev/client.ask` (one POST, 64 KiB cap,
DEC-039 400 mapping) → `jev.reply` (per-path decode, tolerances, model
equality) → `render.classify`. The behaviour most worth a look is the
`jev_context` skip: `jev_client_test` (recorded gateway and derived direct
400s, negative controls) and `cli_test`'s error line carrying the cursor.
`doctrine show DEC-039` gives the ruling; `doctrine show DEC-035` the schema
decision F-12 concerns. `/walkthrough` is available for the pii rules if
wanted.

Not done here, by charter: a multi-phase Codex review (operator's call; not
requested). Close-time items outside reconcile's surfaces: the
satan:RFC-020 D1/D5 amendment draft (F-17).

## Reconciliation Brief

### Per-slice (direct edit)
- F-2 — `doctrine slice selector add 4` (design-target) for
  `src/screwtape/error.gleam`, `nix/package.nix`, `test/fixtures/jev/**`
  (load-bearing: conformance reads the registry). Mirror in design.md § 10:
  rows for `error.gleam` (`decode_failure`, `to_json_line_at`),
  `nix/package.nix` (check inputs for pol002/docs tests) and
  `test/fixtures/jev/` (recorded reply, gateway and direct 400s,
  PROVENANCE.md).
- F-3 — design.md § 5.5 I2: `model` is printed only if it equals the
  configured model or the configured model's text after its last `/`.
- F-4 — design.md § 5.1: table `failure/2`; diagram
  `render.classify(id, cursor, reply)`.
- F-5 — design.md § 5.2 classify/state: strip applies to the subject, each
  text, each attachment type and name, and each sender domain; a sender with
  an empty domain is dropped and counted.
- F-6 — design.md § 5.2 jev `reply`: values read by `decode.at` per known
  key; the probabilities object is read with `decode.dict` for its key count
  only (operator ruling 2026-10-29); a choice is keyed by its labels, a score
  by `"0"`…`"n-1"`.
- F-7 — design.md § 5.2 the edge: `{encoding, latin1}` raw read, UTF-8
  validated by `unicode:characters_to_binary/1`, device encoding restored;
  reasons unchanged.
- F-8 — design.md § 5.2 dispatch: empty stdin is `Outcome(None, [], 0)`.
- F-9 — design.md § 5.2 jev/client: a 400 maps to `jev_context` when
  `detail.error_type` is `max_tokens_exceeded` or the gateway's
  `error.message` holds `"error_type":"max_tokens_exceeded"` (DEC-039;
  IMP-004 removes the second); any 413 likewise; drop "confirmed with A1".
  § 5.5 edge case cites DEC-039; § 7 table gains a DEC-039 row.
- F-10 — design.md § 5.4 Provisioning: private per-run staging beside the
  store, `mv -fT`, symlink and stored-path `--from-file` sources refused;
  `jev` is offered only when `services.screwtape.jev` is set.
- F-13 — design.md § 5.3 credential sentence, § 5.4 Live check, § 9 Manual:
  the gateway client key (`llm-gateway issue` → `screwtape-provision jev
  --from-file`), not the interim key.
- F-14 — design.md § 5.2 pii rule 1: state the shape (dotted domain, last
  label 2+ letters; dotless addresses survive); state example `a@b.co`; note
  a URL with userinfo loses its host to rule 1.
- F-15 — design.md § 5.2 config: a `base_url` that validates but cannot form
  the request URL fails `Config("jev_url")` at the first ask.
- F-18 — design.md § 5.2 (tolerances confirmed live; worst-case paragraph:
  largest observed 19.7 KB → 5,884 tokens), § 5.5 A1 (confirmed; alias
  untestable through the pinned key), § 6 (A1 resolved; replies
  non-deterministic, IMP-003).
- F-12 (per-slice half) — design.md § 5.2 classify/schema: DEC-035 fixes the
  preamble, names, labels and levels; the instructions and label
  descriptions are fixed in `classify/schema.gleam` under `mail-1`. Apply
  together with the governance half, after the operator accepts the text.

### Governance/spec (REV)
- F-16 — POL-002 § Statement line 19: "(SL-004)" → "(IMP-003)"; line 27
  unchanged. Operator's call (their 2026-10-28 instruction).
- F-12 — DEC-035: add that the per-question instructions and choice-label
  descriptions are those in `classify/schema.gleam` under `mail-1`, accepted
  by the operator. Gated on the operator accepting the authored text.
- F-17 — DEC-016: add a consequence: the `jev` credential is decrypted only
  inside the transient classify unit, and PII-stripped mail leaves the host
  for Jev through the gateway (DEC-038). The satan:RFC-020 D1/D5 draft is a
  close-time, cross-repo act, not a reconcile write.

### Not edited (immutable plan criteria; recorded here)
- PHASE-12 EX-12 and EX-14, PHASE-13 EX-7, PHASE-14 EX-3 and VT-4 wording
  (F-6, F-12, F-8, F-10, F-11).

## Reconciliation Outcome

Operator replies 2026-10-29: "apply the diff"; F-12, F-16, F-17 "yes".

### Direct edits applied
- design.md (edited in place; the run is locked, so no `design adopt`): § 5.1
  (F-4), § 5.2 (F-5 F-6 F-7 F-8 F-9 F-12 F-14 F-15 F-18), § 5.3 and § 5.4
  and § 9 (F-10 F-13), § 5.5 (F-3 F-9 F-18), § 6 (F-18), § 7 DEC-039 row
  (F-9), § 10 rows (F-2). Drafted by a Sonnet agent, each claim checked
  against the code; the operator approved the diff.
- Selector registry (F-2): `doctrine slice selector add 4 --intent
  design-target` for `src/screwtape/error.gleam`, `nix/package.nix`,
  `test/fixtures/jev/**`. `slice conformance 4`: 70 conformant, 0
  undelivered; the 13 undeclared paths are `.doctrine/` bookkeeping.

### REVs completed
- REV-002 (`reconcile-sl-004`): done. POL-002 line 19 "(SL-004)" →
  "(IMP-003)" (F-16), landed by hand. Narrative in revision-002.md.

### Decisions amended (outside REV's target kinds)
- DEC-035 (F-12): the authored instructions and label descriptions are
  mail-1, accepted by the operator, refinable without an id bump while
  mail-1 is unreleased.
- DEC-016 (F-17): consequence for the `jev` credential and PII-stripped mail
  leaving the host (DEC-038).

### Not edited
- Plan criteria PHASE-12 EX-12 and EX-14, PHASE-13 EX-7, PHASE-14 EX-3 and
  VT-4 (immutable); drift recorded in the brief.

### Carried to close
- The satan:RFC-020 D1/D5 amendment draft (cross-repo, F-17).
