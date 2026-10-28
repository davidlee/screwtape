# Gateway passes Jev error bodies through, then drop the LiteLLM message match

DEC-039 (operator, 2026-10-29): `jev/client` recognises `max_tokens_exceeded`
inside the LLM gateway's rewrapped 400 (`error.message`, LiteLLM text), because
the gateway does not pass TypeSafe's `{"detail":{"error_type":…}}` body through.

1. In `~/flakes` (the gateway, flakes SL-019 surface): pass Jev 4xx bodies
   through on `/v1/systemone`, or map `max_tokens_exceeded` to a stable field.
   That is a flakes change, made in that repo by its own session.
2. Then, here: remove the `error.message` match from `jev/client`, keeping
   `detail.error_type`, and replace the gateway fixture with a recording.

Evidence: SL-004 PHASE-14 live check, `test/fixtures/jev/max-tokens-exceeded-400.gateway.json`.
