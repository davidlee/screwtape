**Fact (host test 2026-10-26, SL-001 research P10):** `op read`/`op run` from a
`systemd-run --user` unit (no tty) raises a 1Password prompt and succeeds once
approved — but an immediate second unit prompts **again**. Authorisation is
per tty session (1Password docs: "based on the current `tty`, plus the start
time"), so a timer that resolves `op://` at unit start prompts on every run.
Approving while the app is locked unlocks the whole app (docs).

**Do instead — the LLM gateway pattern** (`~/flakes/features/agents/gateway/`):
- Operator runs a provisioning step interactively, once per rotation
  (`just gateway-credentials` → `llm-gateway credentials`):
  `op read --no-newline <ref> | sudo systemd-creds encrypt --with-key=host+tpm2 --name=<id> - <staged>`,
  then `mv` staged → `/etc/credstore.encrypted/<user>.<id>` only if both steps succeeded.
- System unit, static uid, `LoadCredentialEncrypted=<id>:<path>`; the program
  reads `$CREDENTIALS_DIRECTORY/<id>`. No prompt at run time, no cleartext
  file, no bootstrap token; 1Password stays source of truth.
- `--name` must equal the unit's credential id (systemd checks it).

Other gotchas:
- Use `/run/wrappers/bin/op` (setgid `onepassword-cli`); the raw
  `/run/current-system/sw/bin/op` can't reach the app (GID check).
- `systemd-run … sh -c '…${#var}…'`: systemd expands `${…}` in ExecStart
  itself; escape as `$${#var}`.

Applied to: screwtape SL-001 (RFC-020 D3/OQ-4 in `~/dev/satan`).
