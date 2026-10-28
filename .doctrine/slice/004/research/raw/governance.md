## Binding constraints

- **POL-001** — every behaviour has one implementation: classify must reuse the existing opaque `Token`/`bearer`, the DEC-006 `Send` seam, `credential.read`, `file`, `error`, and the existing redaction tests / `test/support`; no second HTTP client, credential reader or harness.
- **DEC-006** — the module layout is a pure core with *one* injected seam: `Send = fn(Request(String), Int) -> Result(Response(String), HttpFailure)`, production `Send` being `screwtape_http.erl` (https, `max_body_size` cap, autoretry 0, autoredirect false). classify injects a `Send`; it may not import `httpc` or open sockets itself, and its request/response codec and PII pass are pure modules.
- **DEC-012** — key ingress is `$CREDENTIALS_DIRECTORY/<credential_name>`, non-empty, wrapped in an opaque `Token` holding `fn() -> String`; only the authorization-header builder calls it; error types carry no headers or response bodies; a sentinel key is asserted absent from stdout, stderr, inspected errors and a full SQLite dump; argv carries only the credential name.
- **DEC-001** — the credential is provisioned once, encrypted, and loaded with `LoadCredentialEncrypted=` (user-scoped per DEC-016), never resolved at run time.
- **DEC-018** — https stays mandatory for configured URLs; an optional `ca_file` replaces system CAs, with `verify_peer` and hostname verification unchanged. Classify's gateway base URL is subject to both.
- **DEC-014** — one `Error` type, stderr one JSON line, type strings only; no response bodies. Jev responses are attacker-influenced text, so `Decode(path)` style failure without payload is mandatory.
- **DEC-011** — hand-matched argv, one `{version, kind, data}` envelope on stdout, exit 0/1/2. classify's per-message line output and its Jev failures must map onto this (Jev error → exit 1, bad argv/config → 2).
- **DEC-029** — one contract version (1); new verbs/flags/fields keep it, but adding a value to an existing enum is *breaking*. A classification tag/risk enum is therefore frozen once published unless the version bumps.
- **DEC-030** — the contract is documented in README field tables and pinned by render/CLI tests; no JSON Schema. classify's output shape needs the same treatment (README section + pinned tests), with runtime validation done in Gleam.
- **DEC-027** — the contract is CLI JSON on stdout; consumers run the binary. classify is a consumer only: it parses SL-003 envelopes and never opens the store.
- **DEC-028 / DEC-032** — classify may rely only on the published pipe surface (`list --after`, `read --after --limit --max-bytes`, line-per-message read envelopes, `cursor`); no further query operations exist.
- **DEC-008** — sync replaces every data-table row; classifications must not land in the store (SL-004 non-goal, and they'd be wiped).
- **DEC-009** — one JSON config file, path baked in by the module; gateway fields belong there, and "no retry, including httpc's autoretry" and "concurrency 1" carry over to the Jev calls.
- **DEC-016 / DEC-017** — runs under the operator uid; reads need no sudo re-exec. classify is a caller-side pipe verb with no store access, so it must not assume unit context or a re-exec helper.
- **DEC-031** — Screwtape states reader access needs (binary, `--config`, writable store dir); jail binds are satan's. Applies if a consumer pipes inside a jail.
- **SPEC-002 NF-006 (REQ-018)** — no host literals: the gateway base URL comes from config, never a compiled-in hostname.
- **DEC-015** — a SPEC-002 entry for Screwtape is deferred to M3.

## Checked, not applicable

- **DEC-002, DEC-003** — superseded by DEC-016 / DEC-017 (system uid, sudo re-exec).
- **DEC-004** — module options/unit wiring; SL-004 says `nix/module.nix` changes only if the verb needs unit wiring, and a pipe verb does not.
- **DEC-005** — SL-001 packaging spike; historical.
- **DEC-007** — schema/migration ledger; classify never touches the store.
- **DEC-010, DEC-020, DEC-021** — HTML fold, htmerl crash wrapper, normalise input records; classify consumes already-extracted text.
- **DEC-013** — `op-unjailed` jail check; no `op` in the classify path.
- **DEC-019** — I1 crash/guard evidence; precedent for redaction, no new obligation beyond DEC-012.
- **DEC-022–DEC-026** — retention/merge/incremental sync; unrelated to read-only consumer logic.
- **ASM-001–ASM-005** — build, parser, 1Password socket, single account, unit hardening; ASM-005's `RestrictAddressFamilies = "AF_UNIX AF_INET AF_INET6"` already admits a second upstream, so no relaxation is needed.
- **EVD-001**, **CHR-002/003**, **IMP-001/002** — probe evidence and unrelated backlog. **CHR-004** is a caution under POL-001, not a constraint.
- **SL-001, SL-002, SL-003** — closed slice records; their binding content is carried by the DEC ids above.
- **SPEC-002 NF-001 (REQ-013)** — schema ownership; classify is not a schema owner.

## Tensions / revision candidates

- **README Contract** (pinned by DEC-030): "The contract is what the read verbs print to stdout: `mailboxes`, `list`, `read` and `thread`." classify adds a fourth output surface with its own `kind`, so this sentence and DEC-029's "One envelope version for the whole contract" need reconciling: is the classification envelope part of the contract, or a sibling?
- **satan:RFC-020 D1** (archived copy, `.doctrine/state/slice/001/rfc-020.pre-phase-08.md`): the diagram reads "screwtape.service (oneshot, timer; no LLM, no Emacs)" and "Milestones 1 and 2 involve no LLM." SL-004 sends mail text to an external decision model. The escape is SL-004's "It is not an LLM"; that claim needs a durable record, or D1's wording becomes "no model inference".
- **satan:RFC-020 D5**: "`mail_*` read tools are pi-durable native tools ... over the store" — a pre-classified subset narrows D5; the amendment is promised by IDE-001 and SL-004 and is not yet drafted.
- **satan:SPEC-002 NF-004 (REQ-016)**: "Every jail holding model output has a declared, test-asserted profile with no protocol bypass." classify emits model output *and* holds a bearer key; run from inside a SATAN jail it would be exactly the case NF-004 governs.
- **DEC-012** assumes systemd: "Read `$CREDENTIALS_DIRECTORY/<credential_name>`". A shell-run pipe verb has no credentials directory, so the ingress rule needs an amendment or a documented wrapper (DEC-017's wrapper precedent) before classify can hold a key at all.
- **DEC-016** accepted that "The decrypted token is readable by the operator's processes while a run is live". classify extends that to the gateway key and to mail text in flight; the README's "authenticated access to Jev classifiers" (README:13) makes that inheritance a feature, so it should be said explicitly rather than left implied.
- **`nix/module.nix:241-243`** — `ProtectHome = "tmpfs"` plus `PrivateTmp` mean a unit-run classify cannot see a host key file; `RestrictAddressFamilies` is compatible, but any future `IPAddressDeny` on the unit would block the gateway.

## Open questions

- Does DEC-006's single `Send` seam carry a second base URL and credential cleanly, or does it need generalising (POL-001 says generalise, not fork)?
- Where does the gateway key come from when classify is not started by systemd (DEC-012 gap)?
- Is "Jev is not an LLM" recorded anywhere durable, and is that the basis RFC-020 D1 will be amended on?
- One request per message, or one batched request with many questions — and does either change the fail-closed unit (per message vs per line)?
- Is the classification envelope inside contract version 1, and does a new tag or risk value count as a breaking bump?
- Is flakes:IMP-054 settled (route path, auth shape) before design, or does design proceed against both shapes?
