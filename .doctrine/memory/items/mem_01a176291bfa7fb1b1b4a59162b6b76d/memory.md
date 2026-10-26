Observed 2026-10-26 (SL-001 PHASE-02, OTP 28.5.0.8 / inets 9.6.2.4), via the transport tests and controls:
- max_body_size over cap: fixed-length `{error, body_too_big}`; chunked `{error, {body_too_long, {max, Cap}}}`.
- read timeout `{error, timeout}`; connect timeout `{failed_connect, [{to_address,_},{inet,[inet],timeout}]}`.
- unknown CA `{failed_connect, [..., {inet,[inet],{tls_alert,{unknown_ca,_}}}]}`; missing cacertfile `{failed_connect, [..., {options,{cacertfile,Path,{error,enoent}}}]}` (TLS-class, not connect-class); refused `{inet,[inet],econnrefused}`.
- `public_key:cacerts_get/0` RAISES when the host has no CA store (the Nix build sandbox): wrap it, or `ca_file = None` crashes the caller. The NixOS dev host has 118 system certs (PHASE-01 EX-5).
- Without `{body_format, binary}` (Options, 4th arg) the body is a charlist and `unicode:characters_to_binary/1` happily re-encodes bytes as Latin-1 codepoints: guard `is_binary(Body)`.
- Under OTP's default autoretry, an OVERSIZED 503 is still one request: max_body_size fires before the retry logic. Only a within-cap 503 + Retry-After exposes the retry.
- Every option in the wrong httpc list is silently dropped (logged to the silenced logger only); each one needs a test that fails when it is misplaced (screwtape transport_test has one per option).

- Loopback TLS for tests: with hostname verification on, the server cert needs SAN `localhost` (the URL host), not only `127.0.0.1` (PHASE-01 F5; DEC-018). `public_key:pkix_test_data/1` generates the CA and cert per run.
