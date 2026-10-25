<!-- raw thread output: Gleam-on-BEAM ecosystem and Nix packaging (RFC-020 OQ-9, Gleam half).
     Producer: Claude subagent (general-purpose, web + hex API), 2026-10-26. Verbatim. -->

## Libraries

### 1. JMAP client
- No Gleam or Erlang JMAP client was found. GitHub repo search for `jmap` returns nothing in Gleam or Erlang. [primary] (`gh search repos jmap --language gleam|erlang`)
- The only BEAM option is the Elixir package `jmap` 0.0.5 ("Basic JMAP client library for Elixir"), updated 2025-07-02T17:51:55Z, with 924 downloads in total. [primary] https://hex.pm/packages/jmap
  - Its repo was last pushed 2025-07-02, has 3 stars, and its README says only "Basic JMAP library for Elixir". [primary] https://github.com/minton/jmap
  - It depends on `req` (optional) and `jason`. [primary] https://github.com/minton/jmap/blob/main/mix.exs
- Inference: it is dormant, Elixir-only (it would need mix in the build) and of unknown RFC coverage. Use a thin hand-written client instead. The methods you need (session GET, then batched POST of `Mailbox/get`, `Email/query`, `Email/get`, `Thread/get`) are plain JSON over HTTP using the libraries in sections 2 and 3.

### 2. HTTP client
- `gleam_httpc` 5.0.0, released 2025-07-12, last updated 2025-07-15. [primary] https://hex.pm/packages/gleam_httpc
  - Repo last pushed 2026-09-07; latest commit is "Bracket IPv6 hosts in request URLs"; 15 open issues. [primary] https://github.com/gleam-lang/httpc
  - Its dependencies are `gleam_http >= 3.0.0 and < 5.0.0` and `gleam_erlang`; it adds `inets` and `ssl` as extra applications. [primary] https://github.com/gleam-lang/httpc/blob/main/gleam.toml
  - `configure()` gives `verify_tls: True, follow_redirects: False, timeout: 30_000`. Setters `timeout/2` (milliseconds), `verify_tls/2` and `follow_redirects/2` exist, and requests go through `dispatch(config, req)`. [primary] https://github.com/gleam-lang/httpc/blob/main/src/gleam/httpc.gleam
  - When `verify_tls` is True, it passes no `ssl` option, so OTP's default applies. [primary] (same file)
- OTP `httpc` behaviour:
  - The default `ssl` option is `httpc:ssl_verify_host_options(true)`, which loads CAs from `public_key:cacerts_get()`. [primary] https://www.erlang.org/doc/apps/inets/httpc.html
  - `connect_timeout` defaults to the value of `timeout`. [primary] (same page)
- `gleam_http` 4.5.0, updated 2026-10-09. [primary] https://hex.pm/packages/gleam_http
- Inference: TLS is verified by default on OTP 28. A bearer token is just `request.set_header("authorization", "Bearer …")`.

### 3. JSON
- `gleam_json` 3.1.0, updated 2025-11-08. [primary] https://hex.pm/packages/gleam_json
  - `parse(from: String, using: decode.Decoder(t))` takes the stdlib `gleam/dynamic/decode` decoder. [primary] https://github.com/gleam-lang/json/blob/main/src/gleam/json.gleam
  - On Erlang it uses OTP's built-in `json:decode` and `json:encode_*`, so there is no `thoas` dependency. [primary] https://github.com/gleam-lang/json/blob/main/src/gleam_json_ffi.erl
- `gleam_stdlib` 1.0.5, updated 2026-08-11. [primary] https://hex.pm/packages/gleam_stdlib
  - It ships `gleam/dynamic/decode` with `field`, `optional_field`, `subfield`, `at`, `list`, `dict`, `one_of` and `run`. [primary] https://github.com/gleam-lang/stdlib/blob/main/src/gleam/dynamic/decode.gleam
  - Inference: this is the current decode API; older `dynamic.decodeN` code examples are obsolete.

### 4. SQLite
- `sqlight` 1.2.0, released 2026-07-10. [primary] https://hex.pm/packages/sqlight
  - Repo last pushed 2026-07-10; 7 open issues. [primary] https://github.com/lpil/sqlight
  - Dependencies: `esqlite = "~> 0.8"` and `gleam_stdlib`. [primary] https://github.com/lpil/sqlight/blob/main/gleam.toml
  - API: `open`, `close`, `with_connection`, `exec` (runs several statements), `query(sql, on:, with: List(Value), expecting: Decoder)` with positional parameter binding, and value constructors `int`, `float`, `text`, `blob`, `bool`, `null`, `nullable`. [primary] https://github.com/lpil/sqlight/blob/main/src/sqlight.gleam
  - It has no transaction helper. Inference: write `exec("BEGIN")` / `exec("COMMIT")` / `exec("ROLLBACK")` yourself in a small wrapper.
- `esqlite` 0.10.0, released 2026-10-25T12:54:47Z (yesterday); 0.9.0 was 2025-09-13. [primary] https://hex.pm/packages/esqlite
  - It is a C NIF: `c_src/esqlite3_nif.c` plus a vendored `c_src/sqlite3/sqlite3.c`, linked statically unless `ESQLITE_USE_SYSTEM` is set. [primary] https://github.com/mmzeeman/esqlite/blob/master/rebar.config.script
  - It compiles through the rebar3 plugin `pc` (`{plugins, [{pc, "~> 1.15"}]}`), which rebar3 fetches from Hex unless one is provided. [primary] (same file)
  - Inference: `~> 0.8` resolves to 0.10.0, which is one day old. Pin 0.9.0 in `manifest.toml` until 0.10 is tested.

### 5. HTML to text
- `htmgrrrl` 1.0.1, updated 2026-07-23. [primary] https://hex.pm/packages/htmgrrrl
  - Gleam bindings providing a SAX-style (streaming parse-event callback) parser, `sax(html, state, fn(state, line, SaxEvent) -> state)`. It depends on `htmerl`. [primary] https://github.com/lpil/htmgrrrl
- `htmerl` 0.2.1, updated 2025-08-22. [primary] https://hex.pm/packages/htmerl
  - Pure Erlang with `{deps, []}`, so no NIF. [primary] https://github.com/zadean/htmerl/blob/master/rebar.config
  - Inference: it does no network I/O, since it is a parser only.
- `presentable_soup` 2.0.0, updated 2026-02-08. It is a query/scrape layer over `htmerl` plus `houdini`. [primary] https://hex.pm/packages/presentable_soup
- Inference: a SAX fold that collects text nodes, emits newlines for block elements and skips `script`/`style` is a small amount of code on top of `htmgrrrl`. It is also more robust than a regex stripper.

### 6. CLI and process
- `argv` 1.1.0, updated 2026-05-11; usage is `argv.load().arguments`. [primary] https://hex.pm/packages/argv, https://github.com/lpil/argv
- `clip` 1.2.2, updated 2026-09-04; repo pushed 2026-10-05; 0 open issues; depends only on `gleam_stdlib`. [primary] https://hex.pm/packages/clip, https://github.com/drewolson/clip
- `glint` 1.3.0, updated 2026-05-31; 22 open issues; depends on `snag` and `gleam_community_ansi`/`gleam_community_colour`. [primary] https://hex.pm/packages/glint, https://github.com/TanklesXL/glint
- Exit status: `gleam_erlang` 1.3.0 has no `halt` function (searched its modules). [primary] https://github.com/gleam-lang/erlang/tree/main/src/gleam/erlang
  - Inference: declare a one-line FFI (foreign function interface) binding, `@external(erlang, "erlang", "halt") fn halt(Int) -> Nil`.
- Shipping as an executable:
  - Gleam v1.17 added `gleam export escript` (an escript is a single-file BEAM program). [primary] https://github.com/gleam-lang/gleam/blob/main/changelog/v1.17.md
  - `gleescript` 1.5.2's README says it is "redundant with Gleam v1.17's `gleam export escript`". [primary] https://github.com/lpil/gleescript
  - `gleam export erlang-shipment` is what nix-gleam uses (section 8).
  - Inference: escripts cannot load a NIF `.so` from inside the archive, so with esqlite, use the shipment, not an escript.

### 7. Environment variables and stderr
- `envoy` 1.2.0, updated 2026-04-18; provides `get(name) -> Result(String, Nil)` and `all()`. [primary] https://hex.pm/packages/envoy, https://github.com/lpil/envoy/blob/main/src/envoy.gleam
- `gleam/io` has `print_error` and `println_error`. [primary] https://github.com/gleam-lang/stdlib/blob/main/src/gleam/io.gleam

## Packaging
- nixpkgs packages `gleam` 1.19.2. [primary] https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/gl/gleam/package.nix
- nixpkgs has no Gleam builder.
  - `buildGleamApplication` does not appear in the nixpkgs tree I listed, and the BEAM manual section has no Gleam mention. [primary] https://github.com/NixOS/nixpkgs/blob/master/doc/languages-frameworks/beam.section.md
  - `beam-modules` does contain `fetch-hex.nix`, `pc` and `rebar3WithPlugins`. [primary] https://github.com/NixOS/nixpkgs/tree/master/pkgs/development/beam-modules
- `arnarg/nix-gleam`: repo pushed 2026-10-06; 1 open issue; 71 stars. [primary] https://github.com/arnarg/nix-gleam
  - It reads `manifest.toml` and fetches each Hex dependency with `fetchHex` using the manifest checksum.
  - It writes `build/packages/packages.toml` so Gleam does not go to the network.
  - Its build step runs `gleam export erlang-shipment`, then generates a `bin/<name>` wrapper that runs `erl … -eval "<name>@@main:run(<name>)" -noshell -extra "$@"`. [primary] https://github.com/arnarg/nix-gleam/blob/main/builder/default.nix
  - It has no `checkPhase`, but extra arguments are passed through to `stdenv.mkDerivation` (`attrs //`). [primary] (same file)
  - Its README documents the NIF case directly: for "Errors loading plugin pc", set `rebar3Package = pkgs.beamPackages.rebar3WithPlugins { plugins = [ pc ]; }`. [primary] https://github.com/arnarg/nix-gleam
  - Inference: `doCheck = true; checkPhase = "gleam test";` runs tests offline, because dev dependencies are in `manifest.toml` too. `nix flake check` can build that derivation, and the NIF compiles using stdenv's C compiler.
- Alternatives:
  - `mtoohey31/gleam2nix`, pushed 2026-06-20, 7 stars. [primary] https://github.com/mtoohey31/gleam2nix
  - `vic/gleam-nix` ("Build Gleam with Nix"), pushed 2026-01-26. [primary] https://github.com/vic/gleam-nix
  - Inference: the hand-rolled option is a `fetchHex` per manifest entry plus a `packages.toml`, which is roughly 50 lines that duplicate nix-gleam.

## Recommendations (proposals, not decisions)
1. Write a thin JMAP client. Build it from `gleam_httpc` (`dispatch` with explicit `timeout`), `gleam_http` and `gleam_json` with `gleam/dynamic/decode`.
2. Use `sqlight` for SQLite, with a local `transaction(conn, fn)` wrapper around `BEGIN`/`COMMIT`/`ROLLBACK`. Pin `esqlite` 0.9.0 at first.
3. Convert HTML to text with a minimal SAX fold over `htmgrrrl`, falling back to a stripper only if `htmerl` misparses real mail.
4. For the CLI, use `argv` plus `clip`, which has fewer dependencies and fewer open issues than `glint`. Parse by hand if there are only a few subcommands.
5. Use `envoy` for environment variables, `io.println_error` for stderr and an FFI `erlang:halt/1` for the exit code.
6. Package with `nix-gleam`'s `buildGleamApplication`, using `rebar3WithPlugins [pc]`, `doCheck = true` and `checkPhase = "gleam test"`, and ship the erlang-shipment, not an escript.

## Not found / checked-not-applicable
- `jmap` (Elixir): dormant since 2025-07, 924 downloads, Elixir/mix build, coverage unstated.
- `jmap_client`, `html_to_text`: not on Hex (API returned null).
- `exqlite` 0.43.0 (https://hex.pm/packages/exqlite): Elixir. Inference: awkward from Gleam, and it is also a NIF.
- `sqlite3` 1.1.15 (last update 2024-06-27) and `sqlitex` 1.7.1 (2020): stale.
- `sqlight_loom` / `esqlite_loom`: niche repackagings with no clear benefit (inference from their descriptions on the Hex search).
- `floki` 0.38.4 and `lazy_html` 0.1.13: Elixir; `lazy_html` is also a NIF (inference).
- `mochiweb_html` 2.15.0: last release 2016-05-20.
- `html_parser` 1.0.1 (Gleam): last updated 2024-11-27, 4875 downloads; less proven than `htmerl`.
- `gleescript`: superseded by `gleam export escript`; escripts and NIFs don't mix (inference).
- packages.gleam.run: the search page is client-rendered, so curl returned no results and I could not use it. I used the Hex API and GitHub instead.

## Unknowns needing local test
- Whether `public_key:cacerts_get()` finds CA certificates on NixOS, and inside the Nix sandbox if tests ever do TLS. It may need `SSL_CERT_FILE` or the `cacertfile` option.
- Whether esqlite 0.10.0 works with sqlight 1.2.0; I saw only the version bump commit.
- Whether nix-gleam with `rebar3WithPlugins [pc]` builds esqlite offline on Gleam 1.19.2 / OTP 28, and whether `gleam test` succeeds in `checkPhase` without any `HOME` or Hex cache access.
- Whether `erlang:halt/1` flushes stdout before exiting by default; the OTP docs list a `{flush, boolean()}` option but I did not confirm its default. Test JSON output followed by a non-zero exit.
- `htmerl`'s robustness on real Fastmail HTML bodies (malformed markup, entities).
- How `gleam_httpc` timeout errors are surfaced (`ResponseTimeout` vs connect errors) under real network failure.
