# IDE-001: Mail classifier: typesafe.ai decision model over PII-stripped CLI JSON

<!-- Backlog item body — context, detail, links. The structured, queried fields
     live in the sister `backlog-NNN.toml`; this prose is free-form and is never
     structurally parsed (the storage rule). -->

Operator direction, 2026-10-27, during SL-003 design.

A classifier that consumes Screwtape's CLI JSON contract (SL-003) and emits
typed classifications. It is entirely separate from `sync` and composes by
pipe: a tool pipes Screwtape's read output into the classifier, and SATAN
sees a subset of already-classified mail.

- **Model:** typesafe.ai (https://docs.typesafe.ai/introduction), a decision
  model, not an LLM. It emits typed classifications against a schema we
  design. LiteLLM does not support it yet, so it needs a direct API key.
- **Credential:** its own API key, held as securely as the mail token: the
  DEC-001 / DEC-012 pattern (encrypted credential, opaque token, redaction
  tests). One credential per process.
- **PII stripping:** a regex pass over message text before anything leaves the
  host. Scope: "all the good ones" (email addresses, phone numbers, card and
  bank numbers, postal addresses, government ids, ...). Best-effort: names and
  free-text addresses will leak through regex.
- **Dimensions (first cut, operator):**
  - mail type: non-exclusive tags (personal, marketing, invoice,
    transactional, reading, ...);
  - risk profile: percentages (spam, prompt injection, phishing, boring);
  - interest / urgency.
- **Output handling:** classifier output is derived from attacker-controlled
  text. Validate it against the schema; never let it drive anything
  irreversible.
- **Governance:** conflicts with satan:RFC-020 D1 ("M1/M2 involve no LLM") only
  if it lives inside the mirror; as a separate piped tool it narrows
  satan:RFC-020 D5 (SATAN triages a pre-classified subset). The amendment is
  drafted with SL-003's satan:RFC-020 OQ-11 answer or with this item's slice.

Open: where it lives (this repo as a second package or verb, or its own
repo); where classifications persist, if anywhere (outside the mail tables,
because DEC-008 wipes them each sync); whether the operator reviews results
before SATAN gets any (operator: "I'd probably see the results first").
