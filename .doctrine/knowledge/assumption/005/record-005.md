# ASM-005: systemd user units run the BEAM under the planned hardening and load user-scoped encrypted credentials

<!-- Knowledge record body — context, detail, links. The structured, queried
     fields live in the sister `record-NNN.toml`; this prose is free-form and is
     never structurally parsed (the storage rule). -->


## Settlement (2026-10-27, PHASE-09/EX-2)

Validated with no key relaxed. On Sleipnir, systemd 262, the deployed unit
(`nix/module.nix` at 6c31cf9, through `~/flakes`) ran the real BEAM under
every listed key:

- `screwtape-provision`: `systemd-creds encrypt --user` ran unprivileged;
  the first sync started by the script succeeded (08:50:56–08:51:03 local;
  exit 0; 7.8 s wall, 2.1 s CPU, 107 MB peak against `MemoryMax=1G`).
- A second `systemctl --user start` succeeded too (6.3 s, 101 MB).
- `LoadCredentialEncrypted=fastmail:%E/…` decrypted under `ProtectHome=tmpfs`.
- TPM binding: yes. The credential's header GUID is
  `2a1f877a-4275-431a-b3f9-ed1f5d8f6601`, which systemd 262's
  `src/shared/creds-util.h` names
  `CRED_AES256_GCM_BY_HOST_AND_TPM2_HMAC_SCOPED_PINNED_SRK`: host key and
  TPM2, user-scoped. `--with-key` defaulted to `auto` (TPM2 present).
