Observed in SL-001 (RV-001 F-6; PHASE-09 F5, systemd 262).

- The user manager has no `network-online.target` (systemd.special(7), "Special User Units"), so a user unit can't order itself after the network. A run started before the network is up just fails. Design for "the next timer tick retries" instead.
- `systemctl --user is-active X` is false while a `Type=oneshot` unit is still `activating`. To wait for a oneshot, poll `systemctl --user show -p ActiveState,Result X`, not `is-active`.
- `LoadCredentialEncrypted=name:%E/…` works in a user unit (`%E` = `$XDG_CONFIG_HOME`) under `ProtectHome=tmpfs` (ASM-005, validated). `systemd-run --user --pipe --wait -p LoadCredentialEncrypted=…` gives a one-off probe the same credential (`probes.local.d/jmap/jmap-probe.sh`).
- Credential pattern: [[mem.pattern.host.op-secrets-for-units]].
