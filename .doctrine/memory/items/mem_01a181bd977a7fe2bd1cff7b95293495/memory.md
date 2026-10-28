Source: https://api.typesafe.ai/openapi.json and ~/.local/src/typesafe-sdk-js/src/types.ts, read 2026-10-28 (SL-004 research Thread 3). Not yet confirmed live (design A1).

- Request: `{model, state, questions: {name: {type, instructions?, criteria}}, assets?}`; bearer auth; JSON body (multipart only for assets); ≤ 32 MiB; 64k tokens per request, 32k for state + any one question.
- choice: criteria `{label: description}` → `{type, choice, confidence, probabilities: {label: p}}`.
- score: criteria = ordered array (1–10) → `{type, score (expected, fractional), confidence, legend: {"0": …}, probabilities: {"0": p, …}}`.
- noul: criteria `{true?, false?}` optional → `{type, noul}` (P(yes); no confidence).
- Reply `{model (versioned id that answered), answers: {name: answer}, usage: {input_tokens, output_tokens}}`.
- Errors: 400 (rule, incl. max_tokens_exceeded), 401, 413, 415, 422, 429, 529. SDK default retries 408/429/5xx.

Decode by our own names (see [[mem.fact.gleam.decode-dict-key-in-path]]); never echo server keys.
