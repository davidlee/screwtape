Observed in SL-001 (RV-001 F-12, F-19, F-20; PHASE-02 transport proof, OTP 28.5).

- `gleam_httpc` buffers the whole response body and exposes neither `max_body_size` nor `autoretry`. A byte ceiling built on it is checked only after the bytes are in memory.
- OTP `httpc` itself: `{max_body_size, Cap}` (Options, 4th arg) bounds the body for **every** status. A `Content-Length` over the cap fails before reading (`body_too_big`); a chunked body fails at the first chunk header past the cap.
- `httpc` autoretries a 503 with `Retry-After` by default, which hides the first response from any per-run byte budget. Set `{autoretry, 0}` and `{autoredirect, false}` (HttpOptions, 3rd arg).
- A cap of 0 crashes httpc (`function_clause`). Refuse before sending when the budget is spent.
- Option placement traps and reason shapes: [[mem.fact.erlang.httpc-reason-shapes]]. Screwtape's adapter: `src/screwtape_http.erl`. The wrong-adapter control is kept locally in `probes.local.d/httpc/`.
