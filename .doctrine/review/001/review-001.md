# Review RV-001 — design of SL-001

Adversarial-review ledger. Structured findings live in the sister
ledger toml; this prose companion carries the reviewer's framing.

## Brief

<!-- Pre-reading + lines of attack: what this review is probing, the invariants
     it must hold the subject to, and where the bodies are likely buried. Seeded
     at `review new`; the reviewer fills it before raising findings. -->

### codex pass, 2026-10-26

Read SL-001's design independently before reading F-1..F-8. Reviewed SL-001,
DEC-001..DEC-015, ASM-001..ASM-004, satan RFC-020, POL-001 and SPEC-002
REQ-013/016/018. Research was evidence only; its unverified rows were not
treated as established facts. Inspected the gateway credential/admin and
hardening precedents, satan's launcher scan, primary JMAP RFCs, gleam_httpc
5.0.0 source, SQLite documentation, systemd and 1Password documentation,
and nix-gleam builder source (main 1f381546b732babf13e2d7695cfc1a0d9fecb08e).

Attack lines: credential ingress and crash/error egress; effective jail
capabilities; JMAP result references, query consistency, bounds and body
selection; migration/write/read transaction boundaries; invariant coverage;
offline NIF packaging; module cohesion. The pure-core/module decomposition
is coherent. The packaging walking skeleton remains an explicit assumption,
not demonstrated feasibility. Phase references in the design mostly route
validation obligations; they are not independently raised as prose defects.

Checked the back-reference shape and textBody/fetchTextBodyValues selection
against RFC 8620 section 3.7 and RFC 8621 sections 4.1.4/4.2. The intended
mailbox union intersected with after is expressible with an outer AND; total
is optional unless calculateTotal is requested. Earliest observed /get
states are useful /changes baselines, not a guarantee of one point-in-time
snapshot. Email/get notFound handling is explicitly covered by the design.

Verification limits: no real account/token, provisioning, sudo invocation,
1Password IPC attempt, service activation, jail launch, VM crash, NIF build
or nix flake check was performed. Reproductions used synthetic data and
in-memory SQLite. Existing F-1..F-8 were neither re-raised nor dispositioned;
new findings identify any earlier fix they challenge. No confirmed token
exfiltration is asserted by this pass.

### codex round 2, 2026-10-26

Read all F-1..F-18 before adjudicating them against the current design,
SL-001, DEC-001..DEC-015 and ASM-001..ASM-004. Re-read satan RFC-020,
POL-001, SPEC-002 REQ-013/016/018 and ISS-028, the research legend and
relevant rows, and the gateway provisioning/hardening and launcher-scan
precedents. The only authored changes in this pass are on RV-001.

F-1..F-11, F-14..F-16 and F-18 are verified at design/disposition level.
F-12, F-13 and F-17 are contested with specific evidence. F-2's historical
null-query-state response is superseded by the stronger F-10/F-11 design.
None of the original findings has an instrument route set; no deferred
criterion has been mistaken for an implemented or passing test.

New findings: F-19..F-22 major; F-23/F-24/F-26 minor. F-25 is withdrawn
because its evidence was prematurely attributed to a refused sudo help
command; F-26 replaces it using the actual installed manual. Finding
immutability was preserved rather than silently correcting the raise.

Direct experiments used no credentials: OTP 28.5.0.8 over synthetic
loopback HTTP demonstrated full buffering of a chunked 500 response and
a hidden 503/Retry-After retry; in-memory SQLite demonstrated DDL/version/
data rollback, a possible unchecked old-writer overwrite and timestamp
precision collisions. Exact sqlight 1.2.0 and esqlite 0.10.0 Hex release
sources were inspected in memory; no dependencies were installed or built.

Additional attack conclusions:

- Two-phase sync now refreshes unstable id queries as RFC 8620 section 5.5
  requires, with bounded attempts and unique subsequent gets. Query state
  represents membership/order, while per-type get states are independent
  content baselines; this is not a simultaneous upstream snapshot.
  cannotCalculateChanges and tooManyChanges belong to changes/queryChanges,
  which M1 does not issue; anchorNotFound requires an anchor, which its
  position-based queries do not send. Unexpected method errors must follow
  DEC-014's failure path and leave the prior store intact. M2 recovery is
  not implemented or verified by storing these strings.
- The all-status buffering and automatic-retry failures are proved at OTP's
  API, not against the still-unimplemented screwtape_http.erl. Chunked,
  fixed-length and close-delimited bodies must all meet the repaired cap;
  a Content-Length declaration is not evidence of an incremental bound.
  No transparent gzip decompression was found in the inspected OTP HTTP
  client sources. Compressed responses need an explicit reject/decode
  policy; bounded decompression must be proved if added. Autoredirect=false
  avoids following redirects with a bearer token. Peer verification/system
  CAs and request timeout are specified, but TLS failure and receive-loop
  cleanup/cancellation still require the production adapter's tests.
- esqlite's direct sqlite3_exec path does not force a DDL auto-commit.
  SQLite supports transactional schema changes and old WAL reader snapshots.
  Reader schema-version validation should share the read snapshot. Standard
  .dump/iterdump does not include user_version: test it explicitly, and
  distinguish logical schema/data preservation from physical file identity.
- Service-only sync is a legitimate F-18 choice: same-unit systemd starts
  serialize. An unset CREDENTIALS_DIRECTORY is not itself a security lock;
  unsupported direct service-UID invocations are not claimed to serialize.
- module-vm is feasible offline once its dependency closure is available:
  synthetic JMAP over loopback TLS with a test CA in the guest, synthetic
  credentials, an operator identity and the actual wrapper/sudoers contract.
  The current design explicitly substitutes plain LoadCredential, not TPM
  encryption. It can prove guest hardening/access behavior; it cannot prove
  host+TPM provisioning/decryption, the live host's sudoers, real Fastmail
  behavior or 1Password IPC. Keep WAL/SHM files alive while testing their
  permissions; their absence after last-close cleanup proves no boundary.
- Narrowing the satan scan does not contradict POL-001's language/disable
  choices. It also does not discharge REQ-016's remaining abstract-socket
  obligation; F-21 records the missing owned deployment gate, without
  claiming that the current host has an exploitable bypass.

Limits: no Screwtape implementation, esqlite/WAL integration, VM, Nix build,
flake check, real credential, provisioning, TPM, TLS host handshake, jail,
service activation or live Fastmail acceptance was exercised. Sudo help
attempts were refused by no_new_privs; no privileged command executed.
No runtime token-leak or credential-bypass finding is asserted.
