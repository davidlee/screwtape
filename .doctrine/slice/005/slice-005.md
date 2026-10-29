# classify window: raw-byte bounds, every address list, seen, PII relaxed for malice signals

## Context

`classify` (SL-004) sends Jev a fixed, PII-stripped state built from the read
envelope (DEC-034). Two pressures change that state:

- **Consumers need to own a view inside Jev's** (IMP-006). Malebolge (SL-007,
  its DEC-077) shows its mail agent only text Jev was shown. Today it mirrors
  classify's window from outside and the mirror keeps breaking: bounds are
  spent on *stripped* bytes, so the raw prefix Jev saw is not recoverable, and
  only `from` domains reach Jev. Until this slice ships, malebolge treats a
  classify line without `seen` as a contract violation and withholds all mail.
- **Stripping hides phishing signals from Jev** (IMP-005). Display names
  (`"PayPal Security" <x@evil.example>`), local parts
  (`hacker@wor.ldbank.com`), URL paths (`/login-verify-account`,
  `/ignore-previous-instructions`) and addresses in bodies are erased, so
  `mail-1`'s `deception_cues` and `agent_directive` (DEC-035) cannot see them.

Operator direction (2026-10-29): take both in one slice; Jev should see sender
addresses, display names and domains; relax URL paths and body addresses in
the same slice ("a phishing signal among other things").

Operator notes (2026-10-29, open to persuasion):
- **Primary goal: simplify the client contract** for malebolge and pi. Strip
  relaxations serve that and Jev's signal; they are not the point.
- Reluctant to delete the stripping code outright; would rather put it behind
  a flag — weighed against the complexity a flag adds.
- URL paths: partial may be enough, domain intact.

**Posture:** rigorous simplicity.

## Scope & Objectives

Settled by DEC-040 to DEC-044 and ASM-006 (design inquiries inq-1..inq-7).

1. **One window, then strip** (DEC-041). classify builds `seen` once: every
   text control-stripped (bidi overrides included), cut raw to its bound,
   partial word dropped when cut (a whitespace-free prefix is kept).
   `state` = `pii.strip` mapped over `seen`'s texts. Nothing is cut after
   stripping. Reverses DEC-034's "strip first, cut after".
2. **Every address list** (DEC-042). `from`, `sender`, `reply_to`, `to`,
   `cc`, `bcc` as `[{name, email}]`, at most 10 per list, names cut to 128
   bytes, an email over 254 bytes drops its entry; overflow in
   `<list>_omitted`. `sender_domains` is removed.
3. **`seen` on the line** (DEC-041). Both `classify` and `classify_state`
   carry `seen`, the texts Jev's view was made from, so a consumer shows it
   as is: no counts, no bounds table to mirror.
4. **State owned by the schema** (DEC-040). Contract stays v1; `state` and
   `seen` shapes belong to the schema id; consumers check `schema` and
   `version`. Amends DEC-036 and DEC-029; README documents state and seen
   under the schema and states the per-line output ceiling.
5. **Relax `pii.strip` in place** (DEC-043). Email rule removed; URLs keep
   scheme, host, port, path, lose userinfo, query → `?[…]`, fragment →
   `#[…]`; new `[token]` rule; IPv4, dates, digit runs unchanged. No flag.
6. **Schema `mail-2`** (DEC-044), superseding DEC-034; SL-004 design I3 no
   longer holds.

`jev_context` and its cursor-bearing error line are unchanged.

## Non-Goals

- Changing questions, instructions or rubrics; evaluating `mail-2` on real
  mail (IMP-003, which now targets `mail-2`).
- Non-ASCII digit coverage in rule 5 (RSK-001).
- URL reputation lookup (IDE-003).
- Per-list bounds in the `read` envelope itself (IMP-002).
- Malebolge changes (Follow-Ups).
- A retry with a smaller budget on `jev_context` (ASM-006 residual).

## Affected surface

- `src/screwtape/classify/state.gleam` — window type, bounds, cut order, state
- `src/screwtape/classify/input.gleam` — all six address lists with names
- `src/screwtape/pii.gleam` — strip rules (`screwtape_pii_ffi.erl` unchanged)
- `src/screwtape/classify/schema.gleam` — schema id `mail-2`
- `src/screwtape/render.gleam`, `src/screwtape/cli.gleam` — `seen` on both
  lines; shared `spend`
- `README.md` — contract, Compatibility, What Jev sees, Bounds
- `src/screwtape/utf8.gleam` — shared `spend`
- `test/screwtape/{classify_state,classify_input,classify_schema,pii,render,cli,docs,utf8}_test.gleam`

## Risks & assumptions

- **More personal data leaves the machine** for typesafe.ai: display names,
  local parts, recipients, URL paths (operator direction; README says so).
- **Jev token limits**: ASM-006 (typical text fits; adversarial may be
  skipped as `jev_context`, consumer withholds).
- **Token rule misses** short account ids, all-letter tokens, UUIDs
  (DEC-043, accepted).
- **Consumers must check `schema`** (DEC-040); malebolge already does.

## Verification / closure intent

- Tests: `state` = strip of `seen` for every text; `seen` bounds (cut,
  word drop, whitespace-free prefix, budget total ≤ 16,384); all six lists
  bounded with overflow counts; each strip rule's keep/erase rows in
  `pii_test`; token rule linear on a long run.
- Byte-exact `classify` and `classify_state` contract tests include `seen`;
  README tables match code (`docs_test` pins `mail-2`).
- VT pins the worst-case encoded state size (stripped, so placeholder
  growth counts); VH live probe with a synthetic
  worst-case mail (ASM-006).

## Summary

## Follow-Ups
- Malebolge DEC-077: switch from clamping by `seen.bodies` counts to
  showing `seen` (DEC-041); drop its `JEV_WINDOW` table.
- POL-002 wording: the `classify --state` form is no longer PII-stripped
  only (REV at reconcile).
- IDE-002: topic relevance targets a schema id after `mail-2` (DEC-044).
