# ASM-001: sqlight's esqlite NIF builds offline under nix-gleam with rebar3 pc

<!-- Knowledge record body — context, detail, links. The structured, queried
     fields live in the sister `record-NNN.toml`; this prose is free-form and is
     never structurally parsed (the storage rule). -->


## Outcome (2026-10-26, SL-001 PHASE-01)

Validated on the vendored path; no fallback needed. `nix build .#screwtape` with `sandbox = true` built esqlite 0.10.0's NIF (`lib/esqlite/priv/esqlite3_nif.so`) through `rebar3WithPlugins { plugins = [beamPackages.pc]; }` (pc 1.15.0), offline, at commit 8604d32. `checks.gleam-test` ran `gleam test` in the sandbox: 13 passed, including the sqlight temp-file round trip.