# Jev fixtures: provenance

## Recorded (SL-004 PHASE-14 live check, 2026-10-29)

Recorded through the operator's llm-gateway (LiteLLM 1.106.2 at
`http://127.0.0.1:4000`, key scoped to `typesafe/jev-1.14.0`), from a transient
`systemd-run --user` unit holding the key as an encrypted credential. Bytes are
the response bodies verbatim. They hold no key bytes and no mail text.

- `mail-1-reply.json` — `POST /v1/systemone`, HTTP 200. Request: `model`
  `typesafe/jev-1.14.0`, `questions` = `schema.mail_1()`, `state` built by
  `screwtape classify --state` from a scrubbed fixture in `test/fixtures/mail/`
  (the request body was `jev.request_body`). The reply reports `model`
  `jev-1.14.0` and carries `usage` and, for score questions, `legend`; it
  contains no state text.
- `max-tokens-exceeded-400.gateway.json` — same endpoint and request shape,
  HTTP 400, with a synthetic state: one body of ~206 KB of repeated filler
  words (no mail). The gateway wraps Jev's error as
  `{"error":{"message":"litellm.BadRequestError: TypesafeException - {\"detail\":{\"error_type\":\"max_tokens_exceeded\"}} …","type":"invalid_request_error","code":"400"}}`:
  upstream Jev puts the code at `detail.error_type`; through the gateway it
  survives only inside `error.message`. Used by `jev_client_test`
  (`context_400_gateway_fixture_test`) and `cli_test`, mapped to
  `LimitExceeded("jev_context")` per DEC-039.

## Derived from the recording

- `max-tokens-exceeded-400.direct.json` — `{"detail":{"error_type":"max_tokens_exceeded"}}`:
  the inner body of the recorded gateway message above, i.e. what direct Jev
  sends. Used by `jev_client_test` (`context_400_direct_fixture_test`).
