# Jev fixtures: provenance

Both files are spec-derived, not recordings. They follow the TypeSafe OpenAPI
document at `https://api.typesafe.ai/openapi.json`:

- `mail-1-reply.json` — `SystemOneResponse`; the observed live reply shape
  from flakes SL-019 VH-1, where a configured `typesafe/jev-1.14.0` replies
  with the bare model `jev-1.14.0`.
- `max-tokens-exceeded-400.json` — `HTTPBadRequestError`, whose `detail` is
  string or object; the location of the error code is unconfirmed until A1.

Pending A1: SL-004 PHASE-14 replaces them with recordings.
