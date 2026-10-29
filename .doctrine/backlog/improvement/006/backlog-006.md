# IMP-006: classify owns its window: raw-byte bounds, every address list, a seen field

<!-- Backlog item body — context, detail, links. The structured, queried fields
     live in the sister `backlog-NNN.toml`; this prose is free-form and is never
     structurally parsed (the storage rule). -->

Origin: malebolge SL-007 design review (RV-020), decision malebolge DEC-077
(operator, 2026-10-29). Malebolge shows its mail agent only text Jev was shown;
today it has to mirror classify's window from outside, and the mirror keeps
breaking. Three additive v1 changes let screwtape own the window:

1. **Raw-byte bounds.** Bound every text in raw bytes *before* `pii.strip`
   (cut, drop the partial word, then strip), with no cut after stripping.
   Today the 16,384-byte body budget is spent on stripped bytes, and stripping
   can grow text by up to 1.5x (a short URL `http://a/ ` → `http://a/[…] `),
   so Jev can see as little as ~10,922 raw bytes. Jev's limits (64,000 tokens
   per request, 32,000 per question) leave room for the growth.
2. **Every address list.** `classify_state` gains the domains of `sender`,
   `reply_to`, `to`, `cc` and `bcc` beside `from`, under documented count
   bounds (and display names, when IMP-005 lands). Reply-To / Sender
   mismatches are also phishing signals for Jev.
3. **`seen`.** Each classify line reports what Jev saw: `seen.bodies`, the raw
   bytes kept per body (after the partial-word drop). A consumer clamps its own
   view to it without re-implementing these rules.

Interacts with IMP-005 (PII relaxation). Malebolge SL-007's window-dependent
phases wait on this.

## What malebolge relies on (DEC-077, 2026-10-29)

| # | screwtape commits to | malebolge uses it as |
|---|---|---|
| 1 | Every text bounded in raw bytes before `pii.strip`: cut, drop the partial word (bodies), strip; no second cut after stripping | each agent field ⊆ a raw prefix Jev saw |
| 2 | `classify_state` carries every address list — `from`, `sender`, `reply_to`, `to`, `cc`, `bcc` — with a documented count bound per list | address lists shown up to that bound (10 for now, provisional) |
| 3 | Each classify line carries `seen.bodies`: raw bytes kept per body, in body order, after the partial-word drop | agent body *i* clamped to `seen.bodies[i]`, cached beside the answers |
| 4 | The raw bounds (subject, attachment name/type, domain, per-list counts) are documented in the README contract | one `JEV_WINDOW` table in malebolge, pinned by a test against it |

All four are additive within contract v1. `jev_context` and its cursor-bearing
error line stay as they are. Open choices are screwtape's: the exact shape of
`seen`, and the per-list bounds.

Until this ships, malebolge treats a classify line without `seen` as a
contract violation and withholds all mail. Afterwards, a changed bound fails
its pinned test (update one table); a removed/tightened bound or a reshaped
`seen` is a real contract change and malebolge withholds everything until
updated (fails safe, loudly). Only dropping raw-before-strip or `seen` would
reopen malebolge's design.

Neighbour: IMP-002 (per-list bounds in the CLI read contract) — item 2's count
bounds are the classify-side instance; choose them consistently.

## Slicing (operator, 2026-10-29)

Take IMP-005 in the same slice. Sending Jev more (display names, full sender
addresses) only widens the set malebolge's view must fit inside, so it is safe
for malebolge; the third-party egress trade-off is IMP-005's.
