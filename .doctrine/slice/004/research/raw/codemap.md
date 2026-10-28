## Hotspots
- `src/screwtape/cli.gleam:99` — verb dispatch; `classify` slots beside `sync`/read, and `production_send` (`:88`) is the one production binding.
- `src/screwtape/argv.gleam:34` — closed `Verb` type; parse at `:76`, verb cases at `:86`.
- `src/screwtape/render.gleam:22` — sole envelope writer; classify output should reuse it.
- `src/screwtape/config.gleam:28` — `Config` record, decoder `:51`, validation `:114`.
- `src/screwtape/credential.gleam:20` — opaque `Token`/`bearer` (`:30`, `:39`), reusable unchanged.
- `src/screwtape/error.gleam:14` — one closed `Error` type; new Jev failures need variants or reuse.
- `src/screwtape_http.erl:32` — `send/4`, the transport for a second upstream.
- `src/screwtape/jmap/client.gleam:42` — `Send`/`HttpFailure` seam; budget `:44`, JMAP-bound exchange `:141`, status map `:178`.
- `src/screwtape.gleam:44` — process edge; stdout write `:52`, no stdin.
- `test/support/cli_fixture.gleam:41` — config/credential fixtures the CLI tests reuse.
- `test/check_imports.gleam:78` — governed-module allowlist; new pure modules need a `Rule` if they may import I/O.
- `nix/module.nix:22` — generated config document; new keys must be wired there.
- `README.md:100` — public contract documentation.

## HTTP seam
- Entry: `send(Request, Cap, TimeoutMs, CaFile)` exported at `src/screwtape_http.erl:32`, defined `:75`. `Request` is `gleam_http` `Request(String)` (`src/screwtape/jmap/client.gleam:42-43`), matched as `{request, Method, Headers, Body, Scheme, Host, Port, Path, Query}` at `src/screwtape_http.erl:99`. POST/PUT/PATCH move `content-type` into httpc's own slot (`:133-135`).
- Success is a `gleam_http` response record with lowercased headers and a UTF-8 binary body (`src/screwtape_http.erl:114-116`, `:152`). Failure is exactly one of `timeout`, `connect_failed`, `tls_failed`, `bad_utf8`, `too_large` (`:2-6`), typed as `HttpFailure` at `src/screwtape/jmap/client.gleam:32-38`.
- Injection: `Client` holds a `Send` (`client.gleam:51`); `cli.production_send` closes over the run's timeout and CA file (`src/screwtape/cli.gleam:88-91`), used at `:299`. Transport tests import that binding rather than re-binding (`test/screwtape/transport_test.gleam:1-10`, `:58-67`).
- Base URL: the only upstream URL is `session_url` in config (`src/screwtape/config.gleam:30`), required `https://` (`:143-144`); JMAP's actual POST URL is the session document's `apiUrl` (`src/screwtape/jmap/client.gleam:90`, decoded into `Session.api_url` at `src/screwtape/jmap/decode.gleam:159-166`). There is no generic base-URL field.
- TLS/CA: `verify_peer` plus an HTTPS hostname match fun; system CAs via `public_key:cacerts_get/0`, or the configured `cacertfile` (`src/screwtape_http.erl:180-193`). `ca_file` is optional but absolute (`src/screwtape/config.gleam:60-64`, `:170-176`).
- Timeouts: one `request_timeout_ms` (`config.gleam:37`) passed through `production_send` (`cli.gleam:299`) and applied to both request and connect timeouts (`screwtape_http.erl:105-106`).
- Body limits: the cap is per request; the client refuses a non-positive cap and sends under the remaining budget (`client.gleam:147-151`), derived from `max_total_bytes` (`cli.gleam:304`, `client.gleam:56`). `max_body_size` is httpc's option (`screwtape_http.erl:111`). `max_body_bytes` is a per-message body bound, not HTTP (`config.gleam:34`, `src/screwtape/normalise.gleam:310-314`).
- Second upstream: the transport is URL-agnostic (URL assembled from the `Request`, `screwtape_http.erl:99-100`, `:195-197`) and supports POST JSON, so it survives as-is. The JMAP `Client`, private `exchange` and `status` mapping do not (`client.gleam:51`, `:141`, `:178`); `classify` needs its own thin exchange/status layer over `Send`, or a new generic module. CA and timeout are per-run single values, so a different trust store or timeout needs config additions.

## Credential & config
- `Token` wraps a closure, not the secret (`src/screwtape/credential.gleam:20-22`). `read(dir, name)` reads `<dir>/<name>` via `screwtape/file` (`:30-31`; `src/screwtape/file.gleam:14-21`), trims, then rejects empty/control bytes (`credential.gleam:43-57`). `bearer` yields `#("authorization", "Bearer …")` (`:39-41`).
- `CREDENTIALS_DIRECTORY` is read only at `src/screwtape/cli.gleam:347-352`, from the injected `env`; the real env comes from `getenv` at `src/screwtape.gleam:35-36`, `:44`. The systemd credential id is `fastmail` (`nix/module.nix:15-17`, asserted `nix/module-eval.nix:197-198`).
- Config decoding: total; bad JSON is `Config("invalid_json")` (`config.gleam:44-47`). Required fields are `session_url`, `credential_name`, `store_path`, `window`, `max_body_bytes`, `max_pages`, `max_total_bytes`, `request_timeout_ms` (`:52-59`); `ca_file` is optional (`:60-64`). Validation reasons are fixed, sometimes field-qualified: `non_https:session_url` (`:143-144`), `non_positive:` (`:160`), `relative_ca_file` (`:175`).
- Adding an optional second credential: `credential_name` is already per-config (`config.gleam:31`); add e.g. `jev_credential_name` using the `decode.optional_field` pattern (`:60-64`) and call `credential.read(dir, name)` in the classify path. Keep `sync`'s existing read untouched (`cli.gleam:297-299`).
- Adding a base URL: add an optional field to `Config`/decoder (`config.gleam:28-39`, `:51-76`), validate `https://` like `:143-144`, and emit it in `nix/module.nix:22-38`; mirror it in `test/support/cli_fixture.gleam:93-125`.

## CLI & argv
- Grammar is `--config <path> <verb> [args]` (`src/screwtape/argv.gleam:76-84`); unknown verb is `Usage("unknown_verb")` (`:117`). `Verb` is closed (`:34-41`) and `verb_command` matches each spelling (`:86-118`).
- `dispatch` is an exhaustive case over `Verb` (`src/screwtape/cli.gleam:99-118`); `sync` runner `:290`, read runner `:121`.
- stdin is never read: no `stdin`/`read_line`/`io.read` anywhere under `src/` or `test/`. Only `src/screwtape.gleam:22-23` imports `gleam/io`; governed modules are denied it (`test/check_imports.gleam:36`).
- stdout: `Outcome(stdout: Option(String), stderr, exit_code)` (`cli.gleam:52-56`); `main` prints the document plus one newline (`screwtape.gleam:52`). Line-per-message already exists: `read --after` renders each message and `string.join("\n")` (`cli.gleam:258-265`).
- Exit codes: 2 for `Usage`/`Config`, 1 otherwise (`error.gleam:76-82`); `failure` wraps one stderr line and the code (`cli.gleam:417-419`); `main` halts with `write`'s code (`screwtape.gleam:44`).
- Error rendering is one JSON object with `level`, `error`, and fixed payload fields (`error.gleam:46-74`); reasons are codes, never values.

## Contract & render
- Envelope is `{"version":1,"kind":<verb>,"data":…}` (`src/screwtape/render.gleam:22-28`); version is integer 1, `kind` is the verb name.
- `read`'s fields are assembled at `render.gleam:78-116`; shared summary fields `:134-158`; addresses `:190-199`; bodies `:223-232`; helpers include `json.object`, `json.array`, `json.nullable`, `json.preprocessed_array` (`:103`).
- Line-per-message format is documented at `README.md:243-245` and implemented at `cli.gleam:258-265`: zero or more `read` envelopes, one per line, oldest first.
- No envelope decoder exists in `src/`: “`envelope` is its only writer” (`render.gleam:2-3`). Tests decode dynamically (`test/screwtape/cli_test.gleam:223`, `test/screwtape/render_test.gleam:73`). A generic `decode.document` can validate arbitrary JSON into `Decode(path)` errors (`src/screwtape/jmap/decode.gleam:812-818`), but there is no SL-003 schema decoder for our own output.

## Test patterns
- `test/screwtape/`: `check_imports`, `cli`, `config`, `credential`, `cursor`, `error`, `ffi`, `html_text`, `jmap/client`, `jmap/decode`, `jmap/request`, `jmap_fixture`, `local_jmap`, `model`, `normalise`, `read_snapshot`, `render`, `retain`, `skeleton`, `store`, `sync`, `token_leak`, `transport`, `utf8`, plus `test/check_imports.gleam` and `test/screwtape_test.gleam`.
- HTTP faking is two-layered: a scripted in-process `Send` via `fixture_send.start`/`send`/`recorded`/`caps` (`test/support/fixture_send.gleam:79`, `:92`, `:110`, `:120`), and a real loopback TLS server via `local_jmap.start`/`start_with`/`url`/`reply`/`stop` (`test/support/local_jmap.gleam:60`, `:68`, `:75`, `:81`, `:109`); `local_tls` supplies the CA/verification controls (`test/support/local_tls.gleam:31`, `:55`).
- CLI tests run in process through `cli.run` (`test/screwtape/cli_test.gleam:183`) and through the shipment's own entrypoint for the true process edge (`cli_test.gleam:493-521`; `test/support/subprocess.gleam:65`, `:122`).
- Redaction: the token-leak suite uses one sentinel across stdout/stderr/errors (`test/screwtape/token_leak_test.gleam:77`); `Token.inspect` is pinned at `test/screwtape/credential_test.gleam:115-125`; fixed error lines at `test/screwtape/error_test.gleam:1-80`.
- Shared helpers: `cli_fixture.config_text`/`config_dir`/`credential_dir`/`token`/`stdout_json`/`field`/`keys` (`test/support/cli_fixture.gleam:41`, `:58`, `:127`, `:136`, `:143`, `:286`, `:301`, `:311`); `temp.dir`/`write`/`remove_dir` (`test/support/temp.gleam:13`, `:18`, `:24`); plus `store_dump`, `snapshot_fixture`, `jmap_fixture`, `sync_fixture`, `paging.walk`.

## Naming precedents
- Modules are `<domain>/<role>` (`jmap/client`, `jmap/request`, `jmap/decode`, `store/codec`, `store/query`), lowercase and underscore-joined for phrases (`html_text`).
- Opaque handles protect secrets/lifetimes: `Token` (`credential.gleam:20`), `Client`, `Budget` (`client.gleam:44-52`).
- Error constructors are PascalCase nouns with scalar payloads (`error.gleam:14-40`); reasons are lowercase snake_case, field-qualified where useful (`config.gleam:143-144`, `:160`).
- Functions are verb-first snake_case (`read`, `bearer`, `parse`, `session`, `call`, `call_one`, `envelope`); accessors end `_of` (`session_of` `client.gleam:129`, `budget_of` `:134`); encoders `_json` (`window_json` `config.gleam:79`), decoders `_decoder` (`config.gleam:51`), predicates `is_*`.
- Tests are `<module>_test.gleam` with `pub fn <behaviour>_test()` over gleeunit.

## Not found
- Any stdin reading or stdin test helper.
- Any envelope/`read` JSON decoder in `src/`.
- A regex dependency or `gleam/regex`: `gleam.toml:5-14` lists none, and the pinned stdlib is noted as lacking it (`test/check_imports.gleam:14-16`). PII stripping needs a new dependency or a hand-rolled scanner.
- Any `classify`, Jev, `systemone`, or TypeSafe code; the only design mention is `src`-external at `.doctrine/slice/004/slice-004.md:28-31`.
- A second base URL, gateway URL, or client-key config field (`config.gleam:28-39`).
- An exported generic exchange/status mapper: `exchange` and `status` are private (`client.gleam:141`, `:178`).
- PII-redaction fixtures/tests (only credential/token redaction exists).
- Per-upstream timeout or CA configuration.
