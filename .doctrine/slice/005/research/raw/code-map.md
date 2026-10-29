true
## Thread 2 — code map

### Hotspots

- `src/screwtape/classify/state.gleam` — goals (1), (2), (5). Goal (1) touches every text path: `subject_json` (`state.gleam:61-70`), `body_json` (`:90-133`), `build_attachments` (`:174-203`), `sender_domains` (`:208-236`). Each currently pipes `strip_controls |> pii.strip |> utf8.prefix(bound)`; the order must become `strip_controls |> utf8.prefix(bound) |> pii.strip`, which also makes `is_truncated` (`:124-128`) and the byte budget (`spend`, `:290-296`) compare pre-strip sizes. Goal (2) adds five address lists to `build`'s object (`:50-58`) with new bounds and `_omitted` counters, and (per goal 5) strips them differently. Goal (3) needs raw-kept-byte counts exported from here — today `build` returns only `Json` (`:45`), so either the signature changes to return `#(Json, List(Int))` or a second function reports the counts.
- `src/screwtape/classify/input.gleam` — goal (2). The `Mail` record (`input.gleam:26-36`) carries `senders: List(String)` only, decoded from `"from"` (`:82`), and `email_decoder` (`:101-103`) reads `email` and discards `name`. Need four more fields (`sender`, `reply_to`, `to`, `cc`, `bcc`) and a value type carrying `#(name, email)`; `empty_mail` (`:123-134`) and `document_decoder` (`:78-98`) follow.
- `src/screwtape/render.gleam` — goal (3). `classify` (`render.gleam:36-52`) and `classify_state` (`:55-69`) are the only two classify output lines; a `seen` object must be added to both to stay symmetric (the `classify_state` doc says "the same provenance", `:52-54`).
- `src/screwtape/cli.gleam` — goals (3), (5). `classify_mail` (`cli.gleam:537-559`) is the single call site of `classify_state.build` (`:546`, `:553`) and of both renderers; any extra argument (flag, seen-bytes) threads here from `classify_run` (`:455-470`) and `read_classifier` (`:472-497`).
- `src/screwtape/pii.gleam` — goal (5). Five rules plus the four URL passes (`pii.gleam:251-260`, `268-278`); relaxing email/URL-path/body rules means either new patterns or a policy parameter on `strip`.
- `README.md` — goals (4), (5): `classify_state` table (`README.md:236-260`), "What Jev sees" (`:285-300`), Bounds (`:400-410`), and `classify` fields (`:215-234`).
- Tests: `test/screwtape/classify_state_test.gleam` (bounds/text/PII/field-set), `pii_test.gleam` (table of input→expected), `render_test.gleam:931-958` (byte-exact classify contracts), `cli_test.gleam:1841-1930` (classify helpers).

### Cited facts

**Bounds.** `body_text_bytes = 16_384` (`state.gleam:24`), `max_bodies = 10` (`:27`), `subject_bytes = 512` (`:30`), `max_sender_domains = 10` (`:33`), `sender_domain_bytes = 253` (`:36`), `max_attachments = 20` (`:39`), `attachment_text_bytes = 128` (`:42`). Related: `response_bytes = 65_536` (`jev/client.gleam:23`), `max_bytes` CLI range 1–500 per `README.md:401`.

**Strip-before-cut today, per text.** Subject: `strip_controls` → `pii.strip` → `utf8.prefix(subject_bytes)` (`state.gleam:66-68`). Body: `strip_controls` (`:114`), optional `drop_last_word` (`:115-118`), `pii.strip` (`:119`), `utf8.prefix(stripped, remaining)` (`:120`); `is_truncated` is `cut_on_arrival || byte_size(sent) < byte_size(stripped) || body.is_truncated` (`:124-128`); budget `spend(sent, remaining)` (`:131`). Exhausted budget short-circuits before any stripping: text `""`, flag `cut_on_arrival || is_truncated || byte_size(body.text) > 0` (`:95-112`). Attachment `type` (`:184-186`) and `name` (`:191-193`): strip then cut. Sender domains: `domain_of` after last `@` (`:237-243`), `strip_controls |> lowercase |> pii.strip` (`:215`), the 253-byte test runs **after** stripping (`:219`), dedupe against `seen` (`:222-227`).

**`is_truncated` / partial word / spend.** `is_cut_on_arrival`: `body.is_truncated` ⇒ `True`; else when `output_truncated`, `index >= last_with_text`, and every body when no body has text (`state.gleam:154-172`), with `last_nonempty_index` (`:138-151`). `drop_last_word` keeps everything through the last whitespace, dropping all when there is none (`:264-287`; `from_last_whitespace` `:275-284`). `spend` = `remaining - byte_size(text)` capped at 0 (`:290-296`); `render`'s copy is called with the **uncut** text (`render.gleam:497-503` called at `:482`) while `state`'s is called with the cut text (`state.gleam:131`), so a codepoint dropped whole at the boundary spends its bytes in `render` but not in `state` (compare the comment `render.gleam:494-496` with `:498`).

**Classify output line.** Built only in `render.classify` (`render.gleam:36-52`): `envelope("classify", {id, cursor, schema: schema.id, model, answers})`; `classify_state` (`:55-69`) prints `{id, cursor, schema, state}`. `jev_context` appears only as the `LimitExceeded` bound in `jev/client.gleam:69` and `:72` (413 and DEC-039 400), documented at `README.md:371-374` and raised by `cli.gleam:537-559` propagating `jev_client.ask`'s error.

**Address model.** `Address(field: AddressField, name: Option(String), email: String)` (`model.gleam:91-93`); `AddressField = From | Sender | To | Cc | Bcc | ReplyTo` (`model.gleam:95-102`) — display names *are* present. `read` prints them all: `sender`, `to`, `cc`, `bcc`, `reply_to` (`render.gleam:170-174`) plus `from` via `summary_fields` (`:219`), each as `{name: string|null, email: string}` (`address_json`, `:268-275`); the fixture confirms names survive (`test/fixtures/mail/read-after-1.json`, `reply_to` entry). `input.gleam` reads only `from`, and only `email` (`:82`, `:101-103`).

**`pii.strip` rules, in order** (`pii.gleam:251-260`): forged markers removed (`:248-249`), then
1. email → `"[email]"` (`:24`), `email_pattern` `:60-66` with `email_atext` lookbehind `:71`;
2. URL → four passes: `[email]` host (`:72-75`), userinfo (`:78-82`), port (`:85-89`), then remainder `(https?://[^/?#\s<>"']+)([/?#][^\s<>"']*)` → `\1/[…]` (`:93-96`), ellipsis U+2026 (`:34`);
3. IPv4 → `"[ip]"` (`:27`, pattern `:99-101`);
4. protected date/time shapes → masked (`:160-178`, mask machinery `:225-247`);
5. digit runs of 8+ → `"[number]"` (`:30`, pattern `:190`).
All are `re:replace` with `[global, unicode, caseless]` (`src/screwtape_pii_ffi.erl:16-18`).

**Schema.** `pub const id = "mail-1"` (`classify/schema.gleam:11`), questions `mail_1()` (`:21-104`), preamble `:14-16`.

**`--state` wiring.** `argv.Classify(state_only)` (`argv.gleam:42`), parsed from `["--state"]` (`:119-120`), dispatched (`cli.gleam:141-142`), consumed in `read_classifier` where `True` ⇒ `Ok(Local)` and no config/credential/`Send` (`:479-481`), then `classify_mail` `Local` ⇒ `render.classify_state(... classify_state.build(mail))` (`:541-547`), `Remote` ⇒ `ask(... classify_state.build(mail), schema.mail_1())` then `render.classify` (`:548-557`). Stdin split by `input.lines` (`:467`, `input.gleam:66-71`).

### Naming precedents

- Byte bounds: `<thing>_bytes` for a per-text cap and `max_<thing>` for a count (`state.gleam:24-42`); `response_bytes` (`jev/client.gleam:23`).
- Omitted counts: `<field>_omitted`, printed immediately after the list (`state.gleam:53-57`; `README.md:248,253,257`), computed as `length - length(kept)` (`:86`, `:178`) or a dropped-counter (`:213-227`).
- JSON style: snake_case keys, lists plural, flags `is_*`/`*_failed`/`output_truncated` (`render.gleam:214-230`), one nested accounting object precedent only in `provenance` (`render.gleam:183-189`). Run summaries use bare plural counters `truncated_bodies`, `not_found`, `conversion_failures`, `states` (`cli.gleam:405-409`). No existing `seen` key anywhere in `src/` or `README.md`.

### Test helpers

- `classify_state_test.gleam`: `base_mail()` (`:337-347`), `at()` (`:349-351`), `model_body(text)` (`:353-364`), `state_of(mail)` → parsed `State` (`:366-370`), `json_value`/`keys_of`/`body_keys`/`attachment_keys` (`:372-400`), `total_bytes` (`:402-404`), and a hand-written `state_decoder` (`:406-432`) that must gain the new fields. Cut-on-arrival tests build real `render.read` output then `input.line` (`:260-291`), using `snapshot_fixture.bare_message` (`test/support/snapshot_fixture.gleam:266`) and the local `model_body`.
- `pii_test.gleam`: one `const table` of `#(input, expected)` plus `check_row` (`:61-89`) and a long-input performance case (`:93-97`) — relaxing a rule means editing table rows, which the header calls "the specification" (`:1-4`).
- `render_test.gleam`: value-tree decoders (`:53-136`), `contract_reply()` (`:916-929`), byte-exact `classify_contract_test` (`:931-936`) and `classify_state_contract_test` (`:938-948`) — a new `seen` field breaks both string literals.
- `cli_test.gleam`: `panicking_fakes()` (`:1899-1909`), `run_classify` (`:1913-1928`), `stdout_lines`/`kind_of`/`document_fields` (`:1853-1875`), `jev_config`/`unseeded` and the five `read_after_lines()` fixture lines (`test/support/cli_fixture.gleam:217,242,380`), plus `classify_posts_each_line_and_prints_a_document_test` (`:2054-2105`) which recomputes `json.to_string(classify_state.build(mail))` per line.

### Observations

- **Strip lengthens text**, so moving the cut before stripping changes byte accounting in both directions: `a@b.c` (5 bytes) → `[email]` (7) shrinks payloads, while the `sender_domains` 253-byte test (`state.gleam:219`) currently measures the *stripped* string. Goal (1) must decide whether the domain bound applies pre- or post-strip; the existing tests at `classify_state_test.gleam:221-238` and `:240-248` pin today's behaviour.
- **Goal (3) fights the current signature**: `state.build` returns `Json` only (`state.gleam:45`), so `seen.bodies` needs a returned count list or a sibling function; both call sites (`cli.gleam:546`, `:553`) and the test at `cli_test.gleam:2091` assert `json.to_string(build(mail))` equals the state in the POST body — an extra return value is invisible there, a changed `Json` is not.
- **Raw vs kept ambiguity**: `spend`'s asymmetry (state spends kept bytes, render spends requested) means "raw bytes kept per body" must be defined explicitly against `utf8.prefix`'s codepoint boundary (`utf8.gleam:11-30`), e.g. the `€` cases (`classify_state_test.gleam:107-116` give 16_383).
- **Goal (2) is cheap on the envelope, costly on the model**: `read` already prints names for all six fields (`render.gleam:170-174`), so only `input.gleam` needs widening; but the existing test `state_holds_only_the_contract_fields_test` (`classify_state_test.gleam:293-320`) hard-asserts the exact key set and forbids sentinels like `"Alice"`, so relaxed PII (goal 5) directly contradicts it (`:315-318`).
- **A flag would thread three layers**: `argv` (`argv.gleam:119-120`) → `dispatch` (`cli.gleam:141-142`) → `read_classifier`/`classify_run` (`:455-497`); `pii.strip` is called from `state.gleam:67,119,185,192,215` only, so a `strip(policy)` parameter localises to state plus `pii`.
- **README drift risk is already guarded**: `schema.id` is checked against the README table (doc comment `schema.gleam:6-8`), but nothing checks the state table, so goal (4) is manual; `README.md:287-300` currently *states* the lossy rules, and goal (5) rewrites both that prose and `:246-257`.
- `render.classify_state`'s comment promises "the same provenance" (`render.gleam:52-54`), so adding `seen` to only one of the two lines is a documented inconsistency, not a free choice.
