<!-- raw thread output: Thread 1 (governance applicability) and Thread 2 (code map).
     Producer: orchestrating agent (Claude Opus 5.5), inline — the project defines no research agents. 2026-10-26.
     Commands run are listed so each fact can be re-derived. -->

## Governance sweep (commands)

- `doctrine adr list` / `policy list` / `standard list` / `spec list` (screwtape): empty.
- `doctrine backlog list` (screwtape): CHR-001 only.
- satan: `doctrine show RFC-020`, `doctrine show POL-001` (§ Standing principles), `doctrine show SPEC-002` (NF-001..NF-006).

Excerpts:

- POL-001 § Standing principles: "**Rust is the target language for SATAN-orbit daemons** (PG + LISTEN/NOTIFY + RPC + invariant-heavy dispatchers + replay determinism ...)"; "**One binary per extraction**"; "**Disable switch on every extraction**".
- SPEC-002 NF-001 (REQ-013): "Every durable SATAN store ... has exactly one component that owns its schema and migrations, with one migration ledger and one numbering sequence."
- SPEC-002 NF-004 (REQ-016): "Every jail holding model output has a declared, test-asserted profile with no protocol bypass" (open gaps ISS-028, ISS-043).
- SPEC-002 NF-006 (REQ-018): "A component locates another component's state or sockets only through named, configurable roots, never through host literals ..." AC: "No SATAN repo hard-codes `/home/<user>`, `/run/user/<uid>`, or a host name outside its deployment configuration."
- SPEC-002 header: host facts (paths, uids, units) "live in the deployment note `~/flakes/SATAN.md`".

## Code map (commands)

- screwtape: `cat flake.nix justfile README.md .gitignore`; no `gleam.toml`, `src/`, `test/` yet.
- `~/flakes`: `ls`; `grep -rn satan-attrd`; read `features/satan/attrd.nix`, `features/satan/postgres-backup.nix`, `features/attention.nix:22-37`.
- satan: `sed -n 21,25p justfile`; `sed -n 660,686p flake.nix`.
- host: `stat /run/wrappers/bin/op`; `ls /run/user/1000`; `ss -xlp | grep -i 1pass`.

Observations:

- `~/flakes/flake.nix:98-105`: `satan-attrd = { url = "github:davidlee/satan-attrd"; inputs = { nixpkgs.follows = "nixpkgs-home"; agents.follows = "agents"; ... }; }`.
- `~/flakes/features/satan/attrd.nix`: feature imports `inputs.satan-attrd.homeManagerModules.default` and sets `services.satan-attrd = { enable = true; package = inputs.satan-attrd.packages.${system}.satan-attrd; }` — the service unit is defined in the app's own repo.
- `~/flakes/features/satan/postgres-backup.nix`: unit + timer defined inline in `~/flakes` (`Type = "oneshot"`, `Environment = [ "HOME=%h" "XDG_RUNTIME_DIR=%t" ... ]`, timer `OnCalendar` + `Persistent = true`, `Install.WantedBy = ["timers.target"]`).
- `~/flakes/features/attention.nix:22-37`: oneshot with `TimeoutStartSec = "5min"`; timer `OnCalendar = "*:0/10"`.
- `~/dev/satan/justfile:21-25`: `check-jails: malebolge-unbound` then `nix build` of `harness-jail-profile`, `runner-socket-unjailed`, `malebolge-jail-profile`, `quotient-forms`.
- `~/dev/satan/flake.nix:660-686`: `runnerSocketUnjailed` — text scan of every `jailPkgs` outer launcher and its exec'd inner launcher; fails if any contains `satan-runner` or ` /run/user/1000 `; fails if zero launchers scanned.
- `/run/wrappers/bin/op`: `-r-x--s--x root onepassword-cli`.
- 1Password app (pid 37133) listening unix sockets, 2026-10-26:
  - `/home/david/.1password/agent.sock`
  - `/run/user/1000/s.sock`
  - `/run/user/1000/1Password-BrowserSupport.sock`
  - `@1PASSWORD_SDK_INTERGATIONS` (abstract namespace; spelling verbatim)
  Which of these serves the CLI integration was not determined.
- `.gitignore` (doctrine-managed block) has no entry for `.doctrine/slice/*/research/`; `git status` shows `research/` untracked.
