# CHR-003: Swap the quotient flake input from the host-local git+file pin to a published tag

<!-- Backlog item body — context, detail, links. The structured, queried fields
     live in the sister `backlog-NNN.toml`; this prose is free-form and is never
     structurally parsed (the storage rule). -->

Split from CHR-001's open items (2026-10-26). Operator decision for SL-001
PHASE-09/EN-3: accept the host-local pin for now; backlog the tag swap.

The `quotient` input is pinned to
`git+file:///home/david/dev/quotient?rev=dc46a9e`, because the form builder
(`quotient.lib.mkFormFamily`) is not in `v0.3.1`. So `~/flakes` can consume
this flake only on this host.

Done when:

1. quotient publishes a tag that carries `mkFormFamily` and `checkFormFamily`;
2. `flake.nix` points the input at that tag, and `nix flake lock` updates;
3. `just quotient-forms` rebuilds both forms and `nix flake check` passes;
4. the operator re-runs `quotient allow ~/dev/screwtape` if the form
   identities changed.

Update (2026-10-27, SL-001 PHASE-09): `~/flakes`' gate refuses a local
source in `flake.lock`, so the input now pins the same rev by GitHub,
`github:davidlee/quotient/dc46a9e…` (6c31cf9; narHash unchanged). Item 1
already holds: `dc46a9e` is inside tags v0.4.0, v0.4.1 and v0.5.0. Remaining:
items 2–4 against a chosen tag.
