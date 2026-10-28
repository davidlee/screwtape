# RSK-001: pii rule 5 misses non-ASCII digits and separators (fullwidth digits, U+00A0, U+2011)

<!-- Backlog item body — context, detail, links. The structured, queried fields
     live in the sister `backlog-NNN.toml`; this prose is free-form and is never
     structurally parsed (the storage rule). -->

Source: SL-004 PHASE-12 VA-2 (Codex gpt-6.1-sol review), confirmed by erl probe:
`１２３４５６７８`, `1234‑5678` (U+2011) and `1234 5678` (U+00A0) survive
`pii.strip` unchanged. Rule 5 and the date shapes use `[0-9]` and `[ .-]`,
which stay ASCII under `re`'s `unicode` flag (no `ucp`), and design § 5.2
does not say whether non-ASCII digits or separators count.

Decide whether `mail-1`'s strip should cover them (e.g. `\p{Nd}` digits and
Unicode space/dash separators, or NFKC normalisation first). Any change to
the strip changes the state, so per DEC-035 it bumps the schema id.
