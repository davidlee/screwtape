# CHR-001: Bootstrap flake: Gleam devshell, checks, quotient forms

Prerequisite for SL-001: the repo has no flake.

- **Devshell:** gleam, erlang, rebar3, sqlite. Lint and format go through
  `gleam format --check`; tests through `gleam test`.
- **`checks`:** the format check and tests, runnable under `nix flake check`.
- **Quotient forms.** `pi_agent` is the operator's delegation tool: it runs one
  confined pi agent per call, and a *form* is the executable that confines
  that run (`quotient help form`, contract `form-1`).
  - Export `quotient-read` and `quotient-write` for this repo, after satan's
    `quotientFormFamily` (`~/dev/satan/flake.nix`). The jail must carry the
    Gleam toolchain so delegates can build and test.
  - Include a forms check, after satan's `quotient-forms`.
  - **How quotient finds a project form** (`quotient help policy` § Project
    forms):
    - The project form is the link `<root>/.quotient/forms/<capability>`. It
      replaces the policy's machine `forms.<capability>` for this root only.
    - The link's target must be executable and lie outside every `roots`
      entry, every `exposure` path and the session home. A Nix store path
      satisfies that.
    - So a `just quotient-forms` recipe builds `.#quotient-read` and
      `.#quotient-write` and points the gitignored links at the store paths.
  - **Operator steps, outside the repo:**
    1. Add `~/dev/screwtape` to the policy's `roots`
       (`~/.config/quotient/policy.json`, mode 0444).
    2. Run `quotient allow ~/dev/screwtape`. It reports each link's real path
       and sha256, and prints the record command.
    3. Run that record command:
       `quotient allow <root> <capability>=<realpath>@<sha256>`.
  - Every rebuild of a form changes its identity and needs a fresh `allow`.
## Done (2026-10-26)

- **`flake.nix`:**
  - The forms are built with `quotient.lib.mkFormFamily` and checked with
    `checkFormFamily`. These come from quotient's SL-003; screwtape is the
    second consumer after satan's hand-rolled family, and no satan code was
    copied.
  - The gateway wiring is `LLM_GATEWAY_URL` as `env`, the pi key file as
    `secretEnv`, and `models.json` as `piFiles`. pi, jail.nix and the gateway
    data come from the agents flake.
  - The devshell carries gleam, erlang, rebar3, sqlite, just and doctrine.
- **`justfile`:** `quotient-forms` builds both forms and links
  `.quotient/forms/{read,write}` to their store paths. `.quotient/`,
  `/build/` and `/result*` are gitignored.
- **Verified:**
  - `nix flake check` passes. The `quotient-forms` residue over the baseline
    is exactly the root bind plus the session bind, for both capabilities.
  - `quotient allow ~/dev/screwtape` reports both links as usable, with no
    approval recorded yet.
- **Open:**
  - **The quotient input is pinned to a local commit,**
    `git+file:///home/david/dev/quotient?rev=dc46a9e`. The builder is not in
    `v0.3.1`, so this repo only evaluates on this host. Swap the input to a
    github tag once quotient publishes one, then rebuild, then re-run
    `quotient allow` if the identities change.
  - **The gateway model set is read from `"${agents}/gateway.nix"`,** an
    internal file of the agents flake, because `mkJailedAgents` exports
    `piGatewayConfig` but not the models. Design improvement: have the agents
    lib export the rendered pi `models.json`, which satan's family would also
    use.
  - **Approval is the operator's act:** the two `quotient allow …` record
    commands that the report prints.
  - **Hermetic `gleam test` under `nix flake check`** needs a Gleam/hex Nix
    packaging story. That belongs to SL-001's research.

## Notes

- **Package output:** left for SL-001 (Gleam on BEAM under Nix is part of its
  research).
