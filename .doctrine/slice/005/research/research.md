# SL-005 research

**Producers.** Thread 1 (governance) and Thread 2 (code map): quotient pi,
profile `research` (deepseek-flash), read-only, 2026-10-29. Verbatim output in
`raw/governance.md`, `raw/code-map.md`. Synthesis and ✓ checks: Claude
(Opus 5.5). Baseline: `baseline.toml` (stamped by `doctrine slice research 5`).

**Verification legend.** ✓ = verified by the consuming agent by reading the
cited site. Unmarked = researcher claim, cited but not checked. Design may
load-bear only ✓ rows or rows it verifies at point of use. Note: Thread 2's
`pii.gleam` line numbers are offset (it cites `:251-260` for `strip`; actual
`pii.gleam:203-212`); its other citations checked out.

## Thread 1 — governance applicability

### Binding constraints

- ✓ **DEC-034** fixes the state shape (`sender_domains` only; "No display
  names, local parts, other address fields") and the order "stripped first and
  cut to their bounds after". SL-005 reverses both; it must supersede or amend
  DEC-034 by name.
- ✓ **DEC-035**: "Any change to … state preprocessing bumps the schema id".
  Goals 1, 2, 5 all do; `mail-1` is `schema.gleam:11`.
- ✓ **DEC-036**: classify line is `{id, cursor, schema, model, answers}`;
  `classify --state` is `{id, cursor, schema, state}`. Vocabulary is owned by
  `schema`, not contract enums; "consumers check schema and refuse an unknown
  one". `seen` is a new key in `data` — additive.
- ✓ **DEC-029 / README compatibility** (`README.md:119-125`): additions keep
  v1; removing, renaming, retyping or changing a field's meaning needs v2.
  `state.*` fields are documented individually (`README.md:236-260`), so they
  are contract surface.
- **DEC-030**: contract documented in README and pinned by render/CLI tests;
  `docs_test.gleam` pins the `mail-1` README table ✓ (`docs_test.gleam:25-30`),
  nothing pins the state table.
- **POL-001**: one implementation per behaviour. A policy parameter on
  `pii.strip` (or relaxing rules in place) complies; a second relaxed stripper
  or state builder beside the first does not.
- **POL-002**: keep/erase cases and README examples must be hand-made or
  provenance-recorded fixtures, never real mail or its `--state` form.
- **DEC-039** + slice text: `jev_context` handling is unchanged, but raw-before-
  strip and more address data make `max_tokens_exceeded` more reachable. The
  token-limit check is an obligation.
- **SL-004 locked design** I3 ("Every text in `state` has passed `pii.strip`.
  `state` holds no display name, local part …", `.doctrine/slice/004/design.md:541-542`)
  and the bounds/strip-then-cut bullets (`design.md:247-262`): binding for
  SL-004 only; SL-005 records that it supersedes them.

### Checked, not applicable

- `ASM-003`, `DEC-033`, `DEC-038` — credential/endpoint; untouched.
- `DEC-027`, `DEC-028`, `DEC-031`, `DEC-011`, `DEC-014` — contract form,
  cursor, envelopes, errors; no new verb, error class or cursor change.
- `IDE-003`, `IMP-003`, `IDE-002`, `IMP-004` — non-goals (reputation, eval,
  topics, gateway errors).
- `RSK-001` — non-goal unless the strip rewrite touches rule 5.
- `IMP-002` — non-goal; only number consistency is owed.
- `IMP-005`, `IMP-006` — origin items, tier-5 evidence, not binding. Their
  "all additive within v1" claim must be tested against DEC-029 (see below).

### Revision candidates

- **DEC-034** → supersede: state shape, "No display names, local parts, other
  address fields", "stripped first and cut … after", sender-domain bounds, the
  email/URL strip rules.
- **DEC-035** → consequences only: new schema id.
- **DEC-036** → possibly amend (see X-1): declare `state` shape owned by
  `schema`, as answers' vocabulary already is.
- **SL-004 design** → note superseded clauses (I3; bounds/strip order).
- **README** `### classify_state` (`:236-260`) and `### What Jev sees`
  (`:285-300`) ✓ both assert domains-only and strip-then-bound.

### Contract stability

- ✓ v1 stays for additions (`README.md:119-121`).
- **Tension** (Thread 1): replacing `state.sender_domains` with six address
  lists is a documented-field removal → v2 under DEC-029, breaking every
  consumer's version check. Resolutions: keep `sender_domains` beside the new
  lists, accept v2, or move `state` under the schema (X-1).

## Thread 2 — code map

### Hotspots

- `src/screwtape/classify/state.gleam` — every text path:
  ✓ `subject_json` (`:61-71`), ✓ `body_json` (`:90-135`),
  ✓ `build_attachments` (`:174-202`), ✓ `sender_domains` (`:208-236`). All
  pipe `strip_controls |> pii.strip |> utf8.prefix`; must become
  `strip_controls |> utf8.prefix |> pii.strip`. ✓ `build` returns `Json` only
  (`:45`), so `seen` needs a richer return.
- `src/screwtape/classify/input.gleam` — ✓ `Mail.senders: List(String)`
  (`:31`) decoded from `from` only, `email` only (`:82`, `:101-104`). Needs
  all six lists with names.
- `src/screwtape/render.gleam` — ✓ `classify` (`:36-52`) and
  `classify_state` (`:56-70`); `seen` goes on `classify`, and arguably on
  `classify_state` for symmetry.
- `src/screwtape/cli.gleam` — `classify_mail` (`:537-559`), single call site
  of `state.build`; a flag threads `argv` → `dispatch` → `read_classifier` /
  `classify_run`.
- `src/screwtape/pii.gleam` — ✓ `strip` (`:203-212`), ✓ `strip_url` four
  passes (`:217-223`), ✓ remainder rule `\1/[…]` (`:79-81`), ✓ email rule
  (`:45-57`). Called only from `state.gleam` (5 sites).
- `README.md` — ✓ classify_state table, What Jev sees; bounds; classify fields.
- Tests — `classify_state_test`, `pii_test` (a `#(input, expected)` table,
  "the specification"), `render_test` byte-exact classify contracts,
  `cli_test` classify helpers.

### Cited facts

- ✓ Bounds (`state.gleam:24-42`): `body_text_bytes` 16,384 shared;
  `max_bodies` 10; `subject_bytes` 512; `max_sender_domains` 10;
  `sender_domain_bytes` 253; `max_attachments` 20; `attachment_text_bytes` 128.
- ✓ Body: `drop_last_word` on cut-on-arrival, then strip, then
  `utf8.prefix(stripped, remaining)`; `is_truncated` compares sent vs
  stripped size (`:114-128`). Budget spent on *sent* (stripped, cut) bytes
  (`:131`).
- ✓ Sender domain: bound tested **after** stripping (`:215-219`).
- ✓ The model has every address with its display name:
  `Address(field, name: Option(String), email)` (`model.gleam:94-96`), and
  `read` prints `sender`, `to`, `cc`, `bcc`, `reply_to` (`render.gleam:170-174`)
  plus `from`, each `{name, email}`. Only `input.gleam` must widen.
- ✓ `render.read` spends the *uncut input* text against `--max-bytes`
  (`render.gleam:354`); `state` spends the cut text — two different `spend`
  copies (`render.gleam:366`, `state.gleam:290`), a POL-001 smell.
- `--state` wiring: `argv.gleam:119-120` → `cli.gleam:141-142` →
  `read_classifier` `Local` (`:479-481`) → `render.classify_state`.

### Naming precedents

- `<thing>_bytes` per-text cap, `max_<thing>` count, `<field>_omitted` after
  the list; snake_case; `is_*` flags. No `seen` key exists anywhere.

### Test helpers

- `classify_state_test`: `base_mail()`, `model_body`, `state_of`, hand-written
  `state_decoder` (must gain fields), `keys_of`.
  `state_holds_only_the_contract_fields_test` (`:293-320`) forbids sentinels
  such as `"Alice"` — directly contradicted by goal 5.
- `cli_test`: `run_classify`, `panicking_fakes`, `read_after_lines()` fixtures;
  `classify_posts_each_line_…` recomputes `json.to_string(state.build(mail))`.

## Cross-thread findings

- **X-1 The state is already schema-versioned in all but name.** DEC-035 bumps
  the schema id on any state change, and DEC-036 tells consumers to refuse an
  unknown schema. Yet the README documents `state.*` as contract-v1 fields,
  so reshaping the state looks like a v2 bump. Declaring the state's shape
  owned by `schema` (amend DEC-036 + README) removes the tension: reshape
  freely under a new schema id, contract stays v1, and no dead
  `sender_domains` field is carried for compatibility. Consumers already
  refuse an unknown schema, so malebolge's fail-safe holds.
- **X-2 `seen` can replace the JEV_WINDOW table.** Malebolge's commitments 3
  and 4 split the window into one dynamic part (`seen.bodies`) and a static
  part (README bounds, pinned by a malebolge test). If `seen` reports the raw
  bytes kept for *every* bounded text (subject, bodies, attachment type/name,
  address entries) and the kept count per list, the consumer clamps to `seen`
  alone: no table to mirror, no pinned test, no drift class. That is the
  "simplify the client contract" goal. README bounds stay as documentation.
- **X-3 Relax in place vs flag.** Relaxing the email and URL rules in
  `pii.strip` keeps one implementation and keeps the module (IPv4, digit runs,
  dates, and partial URL stripping remain). A flag (CLI or config) adds two
  states to test and document, threads three layers (`argv` → `cli` →
  `state`), and doubles the contract a consumer must reason about — Jev's view
  would depend on how screwtape was invoked. If a switch is wanted, a `jev`
  config key is the narrower home (operator policy about egress, not a
  per-call choice), and `seen`'s meaning is unchanged by it.
- **X-4 Raw-before-strip has to define "raw kept bytes" exactly.** `utf8.prefix`
  cuts on a codepoint boundary and `drop_last_word` removes more; `seen` must
  be the byte length of the raw text after both, i.e. the raw prefix whose
  stripped form Jev saw. The body budget then spends raw bytes, which also
  makes `state` agree with `render.read`'s raw accounting (and may let the two
  `spend` copies merge).
- **X-5 Token limits need measuring, not assuming.** Raw-before-strip lets
  stripped text exceed the raw budget (placeholders: `a@b.co` → `[email]`;
  URLs → `/[…]`), though relaxing email/URL rules mostly removes that growth.
  Six address lists × count bound × (name + address) add more. DEC-034's
  ~51 KB worst case was never converted to tokens.
- **X-6 Display names are untrusted attacker text** like the subject; they
  pass through `strip_controls` and the same bound discipline.

## Design-input deltas

1. Propose X-1 (state owned by `schema`) instead of keeping `sender_domains`
   for v1 compatibility — fewer fields, one rule. Needs a DEC-036 amendment.
2. Propose X-2 (`seen` covers every bounded text and list) — drops
   malebolge's JEV_WINDOW table; resolves OQ-1 and most of OQ-2's consumer
   impact. Confirm with malebolge's owner (the operator).
3. Recommend relaxing `pii.strip` in place, no flag (X-3); keep IPv4, digit
   runs, URL query/fragment stripping and partial path stripping. Present the
   config-key variant as the fallback if the operator wants a switch.
4. URL rule (operator): keep host and path, drop query and fragment, and erase
   identifier-shaped path segments (long digit runs already go via rule 5;
   long hex/base64 tokens need a rule). OQ-5.
5. Body addresses: keep whole (operator direction) — then the email rule
   disappears, and `[email]` with it; URL userinfo stripping remains.
6. Measure the worst-case state in tokens in a test or VA step (X-5).
7. Rewrite `state_holds_only_the_contract_fields_test` as a positive key-set
   test; add a raw-prefix property test (every sent text = strip of a raw
   prefix of length `seen`).
