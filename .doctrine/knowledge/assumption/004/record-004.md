# ASM-004: Screwtape M1 serves one Fastmail account

<!-- Knowledge record body — context, detail, links. The structured, queried
     fields live in the sister `record-NNN.toml`; this prose is free-form and is
     never structurally parsed (the storage rule). -->


## Settlement (2026-10-27, PHASE-09/EX-4)

Validated. A separate read-only session (`jmap-probe.sh`, a transient user
unit loading the Screwtape credential) at 2026-10-26T21:52:32Z and 21:53:00Z:

- `accounts` holds exactly one account, `u821e43a5`: `isPersonal: true`,
  `isReadOnly: true`, account capabilities `urn:ietf:params:jmap:mail` only.
- `primaryAccounts["urn:ietf:params:jmap:mail"]` is `u821e43a5`, the
  `account_id` the sync reports.
- Session capabilities: `urn:ietf:params:jmap:core`, `urn:ietf:params:jmap:mail`.
