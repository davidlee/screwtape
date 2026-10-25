<!-- raw thread output: 1Password in a systemd user timer (RFC-020 OQ-4).
     Producer: Claude subagent (general-purpose, web + read-only local), 2026-10-26. Verbatim. -->

## Q1: Non-interactive resolution from a systemd user service

- On Linux the app integration needs PolKit and "a PolKit authentication agent running", plus "Unlock using system authentication" turned on in the app. https://www.1password.dev/cli/app-integration/ [primary] (`developer.1password.com/docs/cli/*` now 301-redirects here.)
- The prompt comes from PolKit, which "is used to spawn a prompt that includes an authentication challenge for the user". https://www.1password.dev/cli/app-integration-security/ [primary]. Inference: the prompt is a GUI dialog drawn by the polkit agent in the desktop session, not text in the terminal. So the caller does not need a TTY to show the prompt. It does need a live polkit agent in the user's graphical session.
- Environment: the docs do not name the socket path. They do not say whether `XDG_RUNTIME_DIR`, `DISPLAY`, `WAYLAND_DISPLAY` or a DBus address is needed. They say only that the socket "is owned by the current user/group, allowing any process started by this user to connect to it" (app-integration-security [primary]).
- Observed on this host: the user manager's environment already holds `PATH=/run/wrappers/bin:…`, `XDG_RUNTIME_DIR=/run/user/1000`, `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus`, `DISPLAY=:0` and `WAYLAND_DISPLAY=wayland-0` (`systemctl --user show-environment`). Inference: these are imported when the session starts. A timer that fires before graphical login, or after logout, would run without them.
- Two binaries exist. `/run/wrappers/bin/op` is setgid (mode `r-x--s--x`, owner root, group `onepassword-cli`). `/run/current-system/sw/bin/op` is the raw `1password-cli-2.41.0`. The raw one comes from `features/security.nix:15`, and `programs._1password.enable` at `features/security.nix:14` adds the wrapper. The jail precedent hard-codes the wrapper path because the raw binary cannot reach the socket and PATH order cannot be trusted (`agents/jailed-agents.nix:652-668`, `agents/README.md:308-311`).
- The docs say nothing about cron, systemd or any caller without a TTY. https://www.1password.dev/cli/app-integration-security/ [primary]

## Q2: Authorization scope and duration

- Wording: "Authorization expires after 10 minutes of inactivity in the terminal session" and "There's a hard limit of 12 hours, after which you must reauthorize". Each use refreshes the 10 minutes. Authorization is per account. https://www.1password.dev/cli/app-integration-security/ [primary]
- Scope: "authorization is confined to a terminal session but extends to sub-shell processes in that window" (macOS and Linux). On Linux, "session IDs are based on the current `tty` plus start time" (same page [primary]).
- A systemd service has no controlling tty. The docs say nothing about how a session is identified without one.
- Inference: given hourly (or similar) timer runs, the 10-minute idle expiry alone means each run is a fresh authorization, so expect a PolKit prompt every run. It is unknown whether TTY-less callers share one session or get a new one each time; this must be tested.
- Precedent: the agents README already says that "for an agent that spawns the jail on a timer… the biometric prompt becomes per-tick noise" (`agents/README.md:361-364`).

## Q3: App locked or not running

- Locked app: "Authorizing use of 1Password CLI while the 1Password app is locked will result in the 1Password app unlocking", and locking "revokes all prior authorization". A process already running "will be able to finish its task and exit". https://www.1password.dev/cli/app-integration-security/ [primary]. Inference: an unattended timer could put up an unlock prompt at any time, and approving it unlocks the whole vault.
- Not running or unreachable: the documented errors are `LostConnectionToApp`, `connectionreset` and `No accounts configured for use with 1Password CLI`. The documented fix is to restart the app. https://www.1password.dev/cli/app-integration/ [primary]
- Exit codes are not documented on the CLI reference page, and there is no `--no-interactive` flag. https://www.1password.dev/cli/reference/ [primary]
- Hanging: a user reports that a sign-in prompt "will hang forever if there's no user". A 1Password employee logged it as a feature request (IDEA-I-2319, 2022), and a 2025 follow-up asking about it got no answer. https://www.1password.community/developers-69/feature-request-headless-non-interactive-mode-11450 [secondary]. The docs say nothing about a timeout on the PolKit prompt.
- Whether `op run` skips the child process when resolution fails is not documented. Inference: it exits non-zero without running the child, but this must be tested.

## Q4: Which callers are authorised, and how the binary is checked

- Linux check: the CLI "is owned by the `onepassword-cli` group and has the `set-gid` bit set". If the connecting process's GID does not match, "the connection is reset before any messages are accepted". The socket itself is reachable by any same-user process. https://www.1password.dev/cli/app-integration-security/ [primary]
- macOS checks code signatures and Windows checks Authenticode. Linux gets only the GID check (same page [primary]).
- Inference: on Linux any same-uid process that can run `/run/wrappers/bin/op` passes the binary check. After that, authorization is per session (tty plus start time), not per calling binary.
- Accepted risk in the docs: root can bypass authorization while the app is unlocked (same page [primary]).
- The docs say nothing NixOS-specific. The nix side is `_1password-gui.polkitPolicyOwners = [username]` (`features/desktop/core/gui.nix:143-146`) and `programs._1password.enable` (`features/security.nix:14`).

## Q5: Alternatives

- **Service account** (`OP_SERVICE_ACCOUNT_TOKEN`): for automation without a person in the loop.
  - It "can't [be granted] access to your built-in Personal, Private, or Employee vault", so the Fastmail token would have to move to a shared vault.
  - Accounts can't be edited, only revoked and recreated. `--expires-in` sets an expiry. https://www.1password.dev/service-accounts/get-started/ [primary]
  - The token is itself a bootstrap secret. It could be supplied the way existing units supply secrets: `LoadCredential=` in the satan-runner user unit (`features/satan/runner.nix:190`) or `LoadCredentialEncrypted=` in the gateway system unit (`features/agents/gateway.nix:120`).
  - Tradeoff: the token can read the whole granted vault, versus storing the Fastmail token directly.
- **Connect server**: self-hosted, REST API with access tokens, aimed at infrastructure and CI. https://www.1password.dev/connect/ [primary]. Inference: too heavy for one workstation and one secret, and it still needs a bootstrap token.
- **systemd credentials directly** (`LoadCredential` / `LoadCredentialEncrypted` holding the Fastmail read-only token itself): no 1Password at run time, and both unit types already have precedent here (citations above). Tradeoff: a second copy of the secret to rotate by hand, and `LoadCredential` reads a plaintext file at rest. User-scope `systemd-creds` encryption was not verified in this round.
- **Hybrid** (Inference): resolve once interactively with `op read` and write the result to a 0600 file under `$XDG_RUNTIME_DIR` (tmpfs). The timer reads that file. This is analogous to the `passApiKeysFromEnv` "pre-resolved secrets" pattern (`agents/README.md:359-370`).

## Q6: Local inspection

- **1Password config**: `features/desktop/core/gui.nix:143-146` (GUI plus `polkitPolicyOwners`) and `features/security.nix:14-15` (`programs._1password` plus the raw `_1password-cli` package). Nothing in `~/flakes` matches `onepassword`, apart from doctrine notes.
- **`op run` precedent**: `agents/jailed-agents.nix:652-668` runs `exec /run/wrappers/bin/op run --no-masking --env-file=<store refs> -- …`, exits 127 if `op` is missing, and falls back to PATH lookup off NixOS.
- **User unit conventions** (Home Manager `systemd.user.*`):
  - `Type = "oneshot"` plus a separate `.timer` with `Install.WantedBy = ["timers.target"]` and `OnCalendar` (`features/attention.nix:22-37`, `features/notes.nix:41-60`).
  - An explicit `Environment = "PATH=${lib.makeBinPath …}"` (`features/notes.nix:49`) and `TimeoutStartSec` to bound blocking (`features/attention.nix:29`).
  - `%h` specifiers and `ConditionPathExists` (`features/notes.nix:42-44`).
  - The satan-runner unit sets PATH, `LoadCredential`, and `RuntimeDirectory` with mode 0700 (`features/satan/runner.nix:178-193`).
  - Known trap: `systemd.user.*` is silently inert on darwin (memory `mem_01a14417…`, `.doctrine/memory/items/mem_01a14417d2c172e4b708c8b660d27249/memory.md:1`).
- **`check-jails`**: not in `~/flakes`. It is referenced at `SATAN.md:154` and defined at `~/dev/satan/justfile:21-25`. It runs `malebolge-unbound`, then builds four flake checks: `harness-jail-profile`, `runner-socket-unjailed`, `malebolge-jail-profile`, `quotient-forms` (registered at `~/dev/satan/flake.nix:834-837`).
  - `malebolge-unbound` (`justfile:30-41`): builds `jailed-malebolge` impurely with `JAIL_WORKSPACE_DEPS` set and fails if the launcher text contains `/workspace/`.
  - `runner-socket-unjailed` (`flake.nix:660-686`): iterates every `jailPkgs` outer launcher and the inner launcher it execs. It fails if a launcher contains `satan-runner` or ` /run/user/1000 `, or if no launchers were scanned. The check is text-only.
  - The other three checks' bodies were not read in this round.
  - In `~/flakes`, the jail assertions live in `just test` (`justfile:70-71`: the `jailed-agents` and `jailed-agents-env` checks).

## Must be tested on the host by the operator

1. **Prompt from a unit with no TTY.** With the app unlocked, run `systemd-run --user --wait --collect -p TimeoutStartSec=120 /run/wrappers/bin/op read op://<vault>/<item>/<field> > /dev/null; echo $?`.
   - Look for: whether a PolKit dialog appears on the desktop, and the exit status.
   - Then run it again within 10 minutes. A second prompt means each transient unit is its own session.
2. **Session reuse across timer runs.** Repeat test 1 at about 2, 9 and 11 minutes.
   - A prompt every time means no reuse. A prompt only after 10 minutes means TTY-less callers share one session.
3. **Locked app.** Lock 1Password, run test 1 and do not answer the prompt.
   - Note whether it blocks until `TimeoutStartSec`, and whether the unit fails with a timeout or an `op` error and exit code.
   - Then approve the prompt in a second run, and confirm the vault unlocks.
4. **App not running.** Quit the app fully (from the tray), then run test 1.
   - Note the error text (`LostConnectionToApp` / `connectionreset`?) and the exit code.
5. **`op run` with a failing ref.** With the app locked or not running, run `systemd-run --user --wait --collect /run/wrappers/bin/op run --env-file=<refs> -- sh -c 'touch $XDG_RUNTIME_DIR/ran'`.
   - Expect no `ran` file and a non-zero exit, which confirms the child is not started.
6. **Before login.** Start the timer before graphical login (or from an ssh session with linger on).
   - Note whether `op` fails fast or hangs when there is no polkit agent or display variables.
7. **Raw binary rejected.** Run test 1 with `/run/current-system/sw/bin/op`.
   - Expect `connectionreset` (the GID check), which confirms the unit must name the wrapper.

## Checked-not-applicable

- **`--no-interactive` / fail-fast flag**: not in the CLI reference (https://www.1password.dev/cli/reference/ [primary]). It is only an open request (community thread above [secondary]).
- **`--session` token**: issued only by `op signin` "when 1Password app integration is not enabled" (CLI reference [primary]). It also expires, so it does not fit unattended runs.
- **`OP_BIOMETRIC_UNLOCK_ENABLED=false`**: it only switches the integration off (app-integration page [primary]). It is not a way to authenticate without the app.
- **Connect server**: infrastructure-scale and needs its own token (connect page [primary]). Disproportionate for one secret on one host.
- **macOS code-signature path**: not applicable on NixOS. Linux uses only the GID check (app-integration-security [primary]).
