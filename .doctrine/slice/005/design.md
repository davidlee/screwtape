<!-- doctrine:section sec-1 -->
## 1. Design Problem

`classify` (SL-004) sends Jev a PII-stripped state cut *after* stripping, with
only `from` domains (DEC-034). Two consequences:

- **Consumers cannot own a view inside Jev's.** Malebolge shows its agent only
  text Jev was shown. The raw prefix Jev's view came from is not recoverable,
  so malebolge mirrors classify's bounds from outside, and the mirror breaks.
- **Stripping hides phishing signals.** Display names, local parts, Reply-To /
  Sender, URL paths and addresses in bodies never reach Jev (IMP-005).

The goal is the simplest client contract: the classify line says what Jev's
view was made from, and the consumer shows that. Settled by DEC-040 to
DEC-044 and ASM-006; evidence in `research/research.md`.

<!-- doctrine:section sec-10 -->
## 10. Code Impact

| path | change |
|---|---|
| `src/screwtape/classify/state.gleam` | `Window`, `window`, `encode`; bounds; word-drop fallback; bidi controls; `build` removed |
| `src/screwtape/classify/input.gleam` | `Mail` gains six address lists with names; `senders` removed |
| `src/screwtape/pii.gleam` | email rule and three URL passes removed; query/fragment rule; token rule |
| `src/screwtape/utf8.gleam` | `spend` (shared) |
| `src/screwtape/render.gleam` | `classify` and `classify_state` take `seen`; local `spend` removed |
| `src/screwtape/cli.gleam` | `classify_mail` builds the window once |
| `src/screwtape/classify/schema.gleam` | id `mail-2` |
| `README.md` | Compatibility, classify, classify_state, mail-2, What Jev sees, Bounds |
| `test/screwtape/classify_state_test.gleam`, `pii_test.gleam`, `render_test.gleam`, `cli_test.gleam`, `docs_test.gleam`, `classify_input_test.gleam` (`senders` → address lists), `classify_schema_test.gleam` (`mail-2`), `utf8_test.gleam` (`spend`) | per § 9 |

<!-- doctrine:section sec-2 -->
## 2. Current State

- `state.build(mail) -> Json` (`src/screwtape/classify/state.gleam:45`) pipes
  each text `strip_controls |> pii.strip |> utf8.prefix(bound)`; bodies share
  16,384 stripped bytes; a body cut on arrival loses its last partial word
  before stripping (`state.gleam:90-135`).
- `input.Mail.senders` holds `from` emails only (`classify/input.gleam:26-36`,
  `:101-104`), though `read` prints all six lists as `{name, email}`
  (`render.gleam:170-174`, `:268-275`).
- `pii.strip` (`pii.gleam:203-212`): email → `[email]`; URL → scheme + host,
  remainder → `/[…]`, port and userinfo dropped (`:217-223`); IPv4 → `[ip]`;
  protected dates; 8+ digit runs → `[number]`.
- `render.classify` prints `{id, cursor, schema, model, answers}`;
  `render.classify_state` prints `{id, cursor, schema, state}`
  (`render.gleam:36-70`). Schema id `mail-1` (`classify/schema.gleam:11`).
- `spend` is duplicated in `render.gleam:366` and `state.gleam:290`.

<!-- doctrine:section sec-3 -->
## 3. Forces & Constraints

- **POL-001** one implementation: one window builder, one encoder, one strip.
- **POL-002** real mail stays outside the repo; fixtures are hand-made.
- **DEC-029 / README Compatibility**: within v1, only additions. DEC-040
  carves `state` and `seen` shapes out to the schema id.
- **DEC-035**: any state-preprocessing change bumps the schema id (→ `mail-2`).
- **DEC-039**: `max_tokens_exceeded` / 413 stay `jev_context`, line carries
  the cursor.
- **Jev limits**: 64,000 tokens per request; 32,000 for state plus one
  question (SL-004 design § 5.2).
- **Operator**: keep the stripping code (relax, don't remove); no flag; URL
  host intact; simplicity over edge cases.

<!-- doctrine:section sec-4 -->
## 4. Guiding Principles

- **The window is the unit.** Build once what Jev's view is made from; derive
  everything else from it.
- **Strip is a map.** `state` is `seen` with `pii.strip` applied to each
  text; nothing else differs.
- **Never cut after stripping.** Bounds apply to the window, so a consumer's
  view of the window is exactly bounded.
- **Signal over erasure** where the text is not a secret: addresses, names,
  paths. Erase what is a credential or an identifier: tokens, digit runs,
  userinfo, queries.

<!-- doctrine:section sec-5 -->
## 5. Proposed Design

### 5.1 System Model

```
read line ──input.line──► Mail ──state.window──► Window
                                                   │
                         ┌─────────────────────────┴───────────────┐
              state.encode(window, fn(t){t})          state.encode(window, pii.strip)
                         │                                         │
                       seen ──► classify / classify_state lines   state ──► Jev (and classify_state)
```

`state.gleam` exposes three pure functions:

- `window(mail: Mail) -> Window` — applies every bound (§ 5.3).
- `encode(window: Window, text: fn(String) -> String) -> Json` — the one
  encoder; every string value passes through `text`. `seen` is
  `encode(w, identity)`, `state` is `encode(w, pii.strip)`.
- the old `build` goes; callers use `window` then `encode` twice.

`Window` is a record mirroring the JSON: `subject: Option(String)`, six
`Addresses` (`entries: List(Entry)`, `omitted: Int`; `Entry(name:
Option(String), email: String)`), `bodies: List(WindowBody)` (`text`,
`is_truncated`, `conversion_failed`), `bodies_omitted`, `attachments:
List(#(String, Option(String)))`, `attachments_omitted`.

### 5.2 Interfaces & Contracts

Envelopes (contract v1; DEC-040 amends DEC-036):

| kind | data |
|---|---|
| `classify` | `{id, cursor, schema, model, seen, answers}` |
| `classify_state` | `{id, cursor, schema, seen, state}` |

`seen` and `state` have one shape, owned by the schema id `mail-2`:

| field | type | bound |
|---|---|---|
| `subject` | string \| null | 512 bytes |
| `from`, `sender`, `reply_to`, `to`, `cc`, `bcc` | `[{name: string\|null, email: string}]` | 10 entries; name 128 bytes; email ≤ 254 bytes or entry dropped |
| `from_omitted` … `bcc_omitted` | int | entries past the tenth or dropped |
| `bodies` | `[{text, is_truncated, conversion_failed}]` | 10 bodies; texts total 16,384 bytes in body order |
| `bodies_omitted` | int | bodies past the tenth |
| `attachments` | `[{type: string, name: string\|null}]` | 20; type and name 128 bytes each |
| `attachments_omitted` | int | attachments past the twentieth |

Field order is as listed (subject, the six lists each followed by its
`_omitted`, bodies, attachments). `sender_domains` is gone.

The bounds are on `seen`. Stripping runs after the cut, and a placeholder
can be longer than the text it replaces (`?` → `?[…]`, 1 byte → 6), so
`state` texts may exceed them.

README changes (DEC-030: documented and pinned):
- **Compatibility**: consumers check `schema` as well as `version`; `state`
  and `seen` shapes belong to the schema and change only with it.
- `### classify` and `### classify_state` gain `seen`: the un-stripped window
  `state` was stripped from, printed like `read`'s output. The field table
  above replaces `classify_state`'s `state.*` rows, its bounds stated for
  `seen`. `### mail-1` is renamed `### mail-2` and keeps only the questions
  table (`docs_test` reads every table row in that section).
- **What Jev sees**: rewritten for § 5.4 and for the egress (names, full
  addresses of all six lists, URL paths).
- **Bounds**: per-line output ceiling, about 45 KB of `seen` on `classify`;
  `classify_state` adds `state`, up to about 1.6 times `seen` through
  placeholder growth (VT-6 pins it).

### 5.3 Data, State & Ownership: the window rules

Every text, in this order:

1. **Controls removed**: U+0000–U+001F except tab, LF, CR; U+007F; and the
   bidi overrides U+202A–U+202E, U+2066–U+2069.
2. **Cut** to its bound with `utf8.prefix` (codepoint boundary).
3. **Partial word dropped** when the text was cut here or on arrival:
   everything after the last whitespace goes; if the cut prefix holds no
   whitespace it is kept whole (`drop_last_word`'s fallback changes from
   "drop all" to "keep all").

Per field:

- **subject, names, attachment type and name**: steps 1–3 at their bound.
- **emails**: step 1 only; an email over 254 bytes drops its entry (counted).
  Entries are kept in `read` order, not deduplicated; the first 10 survive.
- **bodies**: the first 10; each is steps 1–3 against the budget left.
  Cut on arrival as today (`is_cut_on_arrival`, unchanged). `is_truncated`
  = flagged by `read` ∨ cut on arrival ∨ cut here; control removal alone is
  not truncation. The budget is charged the
  seen text's byte size (`utf8.spend`, the shared helper, § 5.6). Once the
  budget is spent, a body prints `text: ""`, `is_truncated` true when its
  input text was non-empty.

### 5.4 The strip rules (`pii.strip`, DEC-043)

Order, one `re` pass each (all `[global, unicode, caseless]`):

1. forged mask markers removed (unchanged);
2. **URL userinfo** dropped: `(https?://)[^/?#\s<>"']*@` → `\1` (unchanged);
3. **URL query / fragment**: `(https?://[^\s<>"'?#]*)([?#])[^\s<>"']*` →
   `\1\2[…]` — path and port kept; from the first `?` or `#` up to the next
   whitespace, quote, `<` or `>` replaced, so `?[…]` or `#[…]`;
4. **token** (new): `(?<![A-Za-z0-9])(?=[A-Za-z]*[0-9])(?=[0-9]*[A-Za-z])[A-Za-z0-9]{20,}`
   → `[token]`. The lookbehind allows a match attempt only at a run's start, so
   each run is scanned once and the scan is linear. Runs before the digit rule, so a token holding 8+ digits is one
   `[token]`, not fragments;
5. IPv4 → `[ip]` (unchanged);
6. protected dates and 8+ digit runs → `[number]` (unchanged).

Removed: rule 1 email → `[email]`, the `[email]`-host URL pass, the port
pass, the `/[…]` remainder, and their constants.

Accepted misses: account ids under 8 digits, all-letter or all-digit tokens
under 8 digits, hyphenated UUIDs, tokens under 20 characters, a 20+ mixed
host label (becomes `[token]`). Schemeless URLs get rules 4–6 only.

### 5.5 Lifecycle, Operations & Dynamics

`cli.classify_mail` (`cli.gleam:537-559`): `let w = state.window(mail)`;
`Local` prints `render.classify_state(id, cursor, seen: encode(w, id),
state: encode(w, pii.strip))`; `Remote` sends `encode(w, pii.strip)` to
Jev and prints `render.classify(id, cursor, seen: encode(w, id), reply)`.
Errors, cursor handling and `jev_context` are unchanged.

### 5.6 Invariants, Assumptions & Edge Cases

- **I1** `state` = `seen` with `pii.strip` on every string; all other values
  equal (one encoder, § 5.1).
- **I2** every `seen` text is at most its bound; `seen`'s body texts total at
  most 16,384 bytes; nothing is cut after stripping.
- **I3** (replaces SL-004 I3) every text in `state` has passed `pii.strip`;
  `seen` texts have passed control removal only.
- `utf8.spend(text, remaining)` moves from `render` and `state` to `utf8`
  (pure, stdlib-only, so I5 of SL-004 holds); `render.read` keeps passing
  the uncut text, `state` passes the seen text.
- ASM-006: typical mail fits Jev's 32k tokens; adversarial text may get
  `jev_context`, and the consumer withholds that message.
- `seen` is raw mail on stdout, like `read`'s output; POL-002 already covers
  it (its wording changes at reconcile).

<!-- doctrine:section sec-6 -->
## 6. Open Questions & Unknowns

None blocking. ASM-006 is validated by the VT and VH in § 9.

<!-- doctrine:section sec-7 -->
## 7. Decisions, Rationale & Alternatives

| record | decides | rejected |
|---|---|---|
| DEC-040 | state and seen shapes owned by the schema id; consumers check `schema`; amends DEC-036, DEC-029 | keep `sender_domains` for v1; contract v2 |
| DEC-041 | one window `seen`; `state` = strip of it; cut raw, word drop with whitespace-free fallback; both lines carry `seen` | `seen` as byte counts (malebolge DEC-077 as proposed); strip then cut |
| DEC-042 | six address lists in full, 10 each, name 128 B, email > 254 B drops entry | recipients domain-only; dedup; 64 B names; rewrite oversize emails |
| DEC-043 | strip relaxed in place: no email rule, URL path and port kept, `?[…]`/`#[…]`, `[token]` | a flag or config switch; removing the strip |
| DEC-044 | schema `mail-2`; supersedes DEC-034; SL-004 I3 superseded | keep `mail-1` |
| ASM-006 | worst-case window fits for typical text; residual skip accepted | retry with a halved budget |

Pre-draft review dispositions: `notes.md` § Pre-draft adversarial review.

<!-- doctrine:section sec-8 -->
## 8. Risks & Mitigations

| risk | mitigation |
|---|---|
| More personal data to typesafe.ai (names, local parts, recipients, paths) | operator direction; README What Jev sees states it exactly |
| A token shape the rule misses leaks a secret path | digit and token rules cover the common shapes; misses listed in § 5.4 and README |
| Token rule erases a signal (20+ mixed run) | hyphen and underscore excluded, so phrases and lookalike domains survive |
| Adversarial size forces `jev_context` | fail-safe: consumer withholds; ASM-006 residual |
| A consumer ignores `schema` | README Compatibility makes the check mandatory; malebolge checks it |
| Output size (~45 KB per line) | documented in README Bounds |

<!-- doctrine:section sec-9 -->
## 9. Quality Engineering & Validation

Tests reuse `classify_state_test`'s `base_mail`, `state_of` and decoder
(extended for the new fields) and `pii_test`'s `#(input, expected)` table.

- **VT-1** I1: for a mail exercising every field, `state` equals `seen` with
  `pii.strip` applied to each string (decode both, compare).
- **VT-2** window bounds: subject, name, attachment text cut with word drop;
  whitespace-free prefix kept; body budget total ≤ 16,384; budget-spent
  bodies; control removal alone leaves `is_truncated` false; cut-on-arrival cases (existing tests, re-pointed at `seen`).
- **VT-3** address lists: six lists in order, 10 kept, overflow and oversize
  emails counted, names with controls and bidi overrides cleaned.
- **VT-4** strip table: addresses kept; URL userinfo dropped, port and path
  kept, `?[…]`, `#[…]`; token keep/erase rows (`/login-verify-account-2024`
  kept; a 32-hex hash and a mixed reset token erased); token before digit
  rule; a 16 KiB letter run strips fast (linear).
- **VT-5** byte-exact `classify` and `classify_state` contract strings carry
  `seen`; `docs_test` pins the `### mail-2` table; schema id `mail-2`.
- **VT-6** a worst-case `Window` (every field at its bound, text that
  placeholders lengthen) is encoded with `encode(w, pii.strip)` and its byte
  size pinned (ASM-006).
- **VH-1** live probe: one synthetic worst-case mail through `classify`
  against Jev; record tokens or `jev_context` (ASM-006).
- `state_holds_only_the_contract_fields_test` becomes a positive key-set
  test; prune TDD scaffolding after green.

