`doctrine check gate` runs the project's build, including `gleam export
erlang-shipment`. Run alongside `just check` (or any second gleam build in the
same tree) and the two collide in `build/`:

- `escript ... build/prod/erlang/argv/_gleam_artefacts/argv_ffi.erl: no such file or directory`
- or the token_leak tests fail with "erlang-shipment not found".

An immediate serial rerun is green. Observed in SL-003 PHASE-04 and again in
the RV-015 audit (2026-10-28). Run build-bearing commands one at a time; never
background one while starting another.
