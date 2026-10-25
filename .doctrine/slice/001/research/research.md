# Research: SL-001 Screwtape M1

## Header

- **Round:** first round, 2026-10-26, at screwtape head `7c0262a`. Baseline: `baseline.toml`, stamped by `doctrine slice research SL-001`.
- **Producers:**
  - The project defines no research agents, so the orchestrating agent (Claude Opus 5.5) ran Threads 1 and 2 itself. Raw output: `raw/governance-codemap.md`.
  - Three web threads ran as read-only Claude general-purpose subagents. Their output is kept verbatim:
    - `raw/gleam-ecosystem.md`: Gleam libraries and Nix packaging.
    - `raw/fastmail-jmap.md`: Fastmail JMAP facts.
    - `raw/onepassword.md`: 1Password in a systemd timer (RFC-020 OQ-4).
- **Inputs:**
  - SL-001 § Risks;
  - satan RFC-020 (D1–D8, OQ-4, OQ-9, OQ-11);
  - CHR-001 § Done;
  - `~/flakes/agents/README.md` § Secrets via 1Password;
  - the brief, `~/dev/satan/docs/email-brief.local.md`, read in full (gitignored; evidence, not authority). It is cross-checked below.
- **Scope:** evidence only. This document makes no design decisions. Where a row carries a recommendation, it is a proposal for `/design`.

## Verification legend

- ✓ means the orchestrator checked the claim at the cited site in this round, by reading, grep, the hex API, a fetch of the primary page, or a host command.
- No mark means a researcher claim: cited, but not checked by the orchestrator.
- "Inference" marks a reasoned conclusion, not an observation.
- Design and plan may load-bear only ✓ rows, or rows they verify where they use them.

## Thread 1: governance applicability

**Screwtape's own governance:** none. `doctrine adr|policy|standard|spec list` returns nothing, and the backlog holds only CHR-001 ✓. Binding sources come from the user's `CLAUDE.md` and from satan, since Screwtape sits in SATAN's orbit (RFC-020 D0).

### Binding or near-binding constraints

| # | Constraint | Source | Effect on SL-001 |
|---|---|---|---|
| G1 | Each durable store has exactly one schema owner, with one migration ledger and one numbering sequence | satan SPEC-002 NF-001 (REQ-013) ✓ | Screwtape owns the store schema and its migrations. M3's `mail_*` tools must never migrate it. This fits OQ-11's "versioned views over private tables". |
| G2 | State and sockets are found through named, configurable roots, never host literals (`/home/<user>`, `/run/user/<uid>`) | SPEC-002 NF-006 (REQ-018) ✓ | The store path must not be hard-coded as `~/.local/state/screwtape`. Derive it from configuration or `XDG_STATE_HOME` and set it in `~/flakes`. |
| G3 | Every jail holding model output has a declared, test-asserted profile with no protocol bypass | SPEC-002 NF-004 (REQ-016) ✓ | This grounds the new `check-jails` assertion in RFC-020 D3 (no `op` wrapper or socket in such jails). |
| G4 | Host facts (paths, uids, units) live in `~/flakes/SATAN.md`, not in specs | SPEC-002 header ✓ | The unit, timer and `op://` ref belong in `~/flakes` and `SATAN.md`. |
| G5 | Rust is the target language for SATAN-orbit **daemons**; one binary per extraction; a disable switch on every extraction | satan POL-001 § Standing principles ✓ | Gleam is allowed because Screwtape is a oneshot, not a daemon (RFC-020 D2 notes the precedent). A disable switch maps naturally to enabling or disabling the timer. Whether POL-001's "extraction" clauses apply to a new subsystem at all is a question for design (R1). |
| G6 | Code standards: TDD red/green/refactor, lint and format clean, DRY, small pure functions | `~/.claude/CLAUDE.md` | `gleam format --check` plus `gleam test` in `nix flake check` (CHR-001). |

### Checked, not applicable

- **satan ADR-017 authority ledger, row 10.** It is deferred by RFC-020 OQ-2 and a non-goal of SL-001.
- **SPEC-002 NF-002 (acyclic repo composition) and NF-003 (one revision per repo).** Screwtape has no flake input from satan, and satan has none from Screwtape. `~/flakes` consumes both, which keeps the graph acyclic. Re-check if satan ever takes Screwtape as an input for M3.
- **SPEC-002 NF-005 (SATAN never writes the notes root).** Screwtape writes only its own state directory.
- **RFC-019 D2 (tools, not a mirror).** RFC-020 D1 already argues it is not in conflict: the mirror caches remote data on the host, not host data in the room.

### Revision candidates (proposals; need the operator's assent)

- **R1.** RFC-020 D2 or POL-001 could say explicitly whether a non-daemon tool in SATAN's orbit falls under POL-001's language clause.
- **R2.** RFC-020 OQ-4 and OQ-9 can be partly settled from this round (see the cross-thread findings). The handover says to record findings in RFC-020 only with the operator's assent.
- **R3.** The doctrine-managed `.gitignore` has no entry for `.doctrine/slice/*/research/`, but `/research` says the folder is "gitignored in place". `research/` shows as untracked ✓. This is drift between the skill and the install, and belongs upstream in doctrine; it was not edited here.

## Thread 2: code map

### Hotspots (files likely to change)

**This repo** (no Gleam sources exist yet ✓):

| File | Change |
|---|---|
| `gleam.toml`, `manifest.toml` (new) | dependencies; `manifest.toml` pins checksums that the Nix builder reads |
| `src/screwtape.gleam`, `src/screwtape/**` (new) | CLI, JMAP client, model, store, HTML-to-text |
| `test/**` (new) | fixture-driven tests |
| `flake.nix` | add `packages.screwtape` and a test check. The current outputs are the `quotient-read`/`-write` packages, the `quotient-forms` check and the devshell ✓. The toolchain list is shared by the devshell and the forms ✓. |
| `justfile`, `README.md` | recipes; the README states the plaintext-store risk (SL-001 § Risks) |

**`~/flakes`:**

| Site | Relevance |
|---|---|
| `flake.nix:98-105` ✓ | the `satan-attrd` input block: the precedent for a `screwtape` input with `nixpkgs.follows` |
| `features/satan/attrd.nix` ✓ | **Precedent A:** the unit is defined in the app's repo as `homeManagerModules.default`, and `~/flakes` only enables it |
| `features/satan/postgres-backup.nix` ✓ | **Precedent B:** a oneshot plus timer defined inline in `~/flakes`, with `Environment = ["HOME=%h" "XDG_RUNTIME_DIR=%t" …]` and `Persistent = true` |
| `features/attention.nix:22-37` ✓ | a oneshot with `TimeoutStartSec = "5min"` to bound a blocking run |
| `agents/jailed-agents.nix:652-668` ✓ | the `op run --no-masking --env-file=<store refs>` precedent. It hard-codes `/run/wrappers/bin/op` because "PATH order can't be trusted". |
| `SATAN.md` | the deployment note (G4) |

**`~/dev/satan`:**

| Site | Relevance |
|---|---|
| `justfile:21-25` ✓ | `check-jails` lives here, not in `~/flakes`. It builds four flake checks. |
| `flake.nix:660-686` ✓ | `runner-socket-unjailed`: a text scan of every `jailPkgs` launcher for forbidden strings (`satan-runner`, ` /run/user/1000 `), which fails if no launcher is scanned. This is the template for an `op`-unjailed assertion. |
| `.doctrine/rfc/020/` | RFC-020, uncommitted; operator-owned |

### Naming precedents

- The deployment uses `services.<name>` via a Home Manager module (attrd), or `systemd.user.services.<name>` plus `.timers.<name>` (backup, nudge) ✓.
- Gleam: the package is `screwtape` and modules are `screwtape/<area>`. This follows Gleam convention and is not checked against any local precedent, since no other Gleam repo exists in the orbit.

### Library facts (Gleam on BEAM)

| # | Need | Finding | Mark |
|---|---|---|---|
| L1 | JMAP client | No Gleam or Erlang client exists. The only BEAM option is Elixir `jmap` 0.0.5 (2025-07, 924 downloads, coverage undocumented). | raw only |
| L2 | HTTP | `gleam_httpc` 5.0.0 (hex updated 2025-07-15). `configure()` gives `verify_tls: True`, `timeout: 30_000` and `follow_redirects: False`, with setters. | version ✓; API raw only |
| L3 | JSON | `gleam_json` 3.1.0 (2025-11-08) decodes with stdlib `gleam/dynamic/decode`, and uses OTP's built-in `json` on Erlang. | version ✓ |
| L4 | SQLite | `sqlight` 1.2.0 (2026-07-10) requires `esqlite ~> 0.8` ✓. `esqlite` 0.10.0 was published 2026-10-25 ✓, so `~> 0.8` resolves to a one-day-old release. esqlite is a C NIF (a native Erlang extension) built through the rebar3 `pc` plugin (`rebar.config.script:56-61`), and honours `ESQLITE_USE_SYSTEM` (line 14) ✓. sqlight has no transaction helper; write `BEGIN`/`COMMIT`/`ROLLBACK` by hand. | ✓ except the transaction point |
| L5 | HTML to text | `htmgrrrl` 1.0.1 (2026-07-23) is a SAX-style (streaming parse-event) wrapper over `htmerl` 0.2.1 (2025-08-22, pure Erlang, no dependencies). Neither does any fetching. Text extraction is a small fold written by hand. | versions ✓ |
| L6 | CLI | `argv` 1.1.0 ✓; `clip` 1.2.2 ✓ (stdlib-only dependencies); `glint` 1.3.0 (heavier). For the exit status, `gleam_erlang` has no `halt`, so use an FFI call to `erlang:halt/1`. | versions ✓ |
| L7 | Env and stderr | `envoy` 1.2.0 ✓; `gleam/io.println_error`. | ✓ / raw |
| L8 | Executable form | Gleam 1.19.2 offers `gleam export escript` and `erlang-shipment` ✓. Inference: an escript cannot load the esqlite NIF `.so` from its archive, so ship the erlang-shipment. | export targets ✓ |
| L9 | Nix | nixpkgs has no Gleam builder (raw). `arnarg/nix-gleam` reads `manifest.toml`, fetches each hex dependency with its checksum, and exports an erlang-shipment with a `bin/` wrapper. Its README documents the NIF case: on "Errors loading plugin pc", override `rebar3Package` ✓ (README:112-117). It has no `checkPhase` of its own, but passes extra attributes through, so `doCheck`/`checkPhase = "gleam test"` is plausible (raw, untested). | partial ✓ |

## Thread 2b: external facts

### Fastmail JMAP

| # | Fact | Source | Mark |
|---|---|---|---|
| F1 | Session URL `https://api.fastmail.com/jmap/session`; header `Authorization: Bearer {token}` | fastmail.com/dev | ✓ |
| F2 | JMAP token scopes are separate checkboxes: **"Read-only access"** ("download and view your data, but your data cannot be changed"), "Email" (modify and delete), "Email submission" (requires Email), "Contacts…", "Masked Email". How Read-only combines with Email is **not documented**. No API tokens on the Basic plan. | fastmail.help 5254602856719 | ✓ |
| F3 | Capability URIs: `urn:ietf:params:jmap:{core,mail,submission,vacationresponse,contacts}` and `https://www.fastmail.com/dev/maskedemail` | fastmail.com/dev | ✓ |
| F4 | Fastmail documents no numeric caps (`maxObjectsInGet`, `maxCallsInRequest`, …). The RFC's suggested minimums are 16 calls and 500 objects. A third-party, undated sample shows 50 calls and 4096 objects. **Read them from the live session.** | RFC 8620 §2 ✓; sample in raw | minimums ✓ |
| F5 | Rate limits: "there are rate limits in place", with no numbers. Whether 429 or `Retry-After` is used on `apiUrl` is unknown. | fastmail.com/dev | ✓ |
| F6 | Whether Fastmail supports `Email/queryChanges` is **undocumented**. Per the spec, each `/query` response carries `canCalculateChanges`; read it at runtime. | RFC 8620 §5.5, §5.6 | raw |
| F7 | `/changes`: `cannotCalculateChanges` means "the server cannot calculate the changes from the state string given by the client". Servers "SHOULD be able to calculate changes from any state string … within the last 30 days". | RFC 8620 §5.2 | ✓ |
| F8 | `state`: "A (preferably short) string representing the state on the server for all the data of this type in the account", so one per type per account. It is opaque, with no ordering. | RFC 8620 §5.1 | ✓ (opacity is an inference) |
| F9 | `/query`: "The server MAY choose to enforce a maximum 'limit'", clamping it and returning the new limit. `total` appears only with `calculateTotal`. | RFC 8620 §5.5 | ✓ |
| F10 | `maxBodyValueBytes` > 0: the value "MUST be truncated … so it does not exceed this number of octets", and the server "MUST ensure the truncation results in valid UTF-8 and does not occur mid-codepoint". `EmailBodyValue.isTruncated`: "true if the 'value' has been truncated". `isEncodingProblem`: malformed sections were found while decoding the charset. | RFC 8621 §4.1.4, §4.2 | ✓ |
| F11 | `textBody` may contain `text/html` parts ("…with a preference for 'text/plain' when alternative versions are available"), so an HTML-only message presents HTML in `textBody`. | RFC 8621 §4.1.4 | ✓ |
| F12 | `messageId`, `inReplyTo` and `references` are `String[]\|null`. `attachments` carry `partId`, `blobId`, `size`, `name`, `type`, `disposition`, `cid`. A mail may sit in more than one mailbox (`mailboxIds`). `Thread.emailIds` are oldest first. | RFC 8621 §2–4 | raw |
| F13 | Errors: request-level problem details (`unknownCapability`, `notJSON`, `notRequest`, `limit`) versus method-level `["error", …]` (`serverFail`, `accountNotFound`, `requestTooLarge`, `forbidden`, `accountReadOnly`, …). The 401 on a bad token is undocumented. | RFC 8620 §3.6 | raw |

### 1Password from a systemd user unit (RFC-020 OQ-4)

| # | Fact | Source | Mark |
|---|---|---|---|
| P1 | "Authorization expires after 10 minutes of inactivity in the terminal session", with "a hard limit of 12 hours" | 1password.dev cli/app-integration-security | ✓ |
| P2 | "On macOS and Linux, authorization is confined to a terminal session but extends to sub-shell processes". On Linux the session ID is "based on the current `tty`, plus the start time". A unit has no tty, and the docs are **silent** on that case. | same | ✓ |
| P3 | "Authorizing use of 1Password CLI while the 1Password app is locked will result in the 1Password app unlocking." | same | ✓ |
| P4 | Linux binary check: the CLI is setgid `onepassword-cli`, and "if the GID doesn't match, the connection is reset". The socket "is owned by the current user/group, allowing any process started by this user to connect to it". | same | ✓ |
| P5 | Host: `/run/wrappers/bin/op` is `-r-x--s--x root onepassword-cli`. | `stat` | ✓ |
| P6 | Linux needs a running PolKit agent (the desktop's system-authentication prompt) and "Unlock using system authentication". The prompt is a PolKit dialog. | 1password.dev cli/app-integration | raw |
| P7 | There is no `--no-interactive` flag. One community report says a prompt "will hang forever if there's no user" (secondary). Exit codes are undocumented. | raw | raw |
| P8 | The 1Password app listens on `~/.1password/agent.sock`, `/run/user/1000/s.sock`, `/run/user/1000/1Password-BrowserSupport.sock`, and the **abstract** socket `@1PASSWORD_SDK_INTERGATIONS`. Which one serves the CLI is undetermined. | `ss -xlp` | ✓ |
| P9 | The precedent already warns that a timer-driven `op run` makes the biometric prompt "per-tick noise" | `~/flakes/agents/README.md:361-364` | ✓ |
| P10 | **Host test, 2026-10-26** (`optest.sh`, log in the session scratchpad). With the app unlocked, a `systemd-run --user` unit with no tty gets a prompt and, once approved, exits 0 in about 2.5 s (test 1). An immediate second unit **prompts again** (test 2). Authorisation is not shared across units: **every timer run would prompt**. | operator report + journal | ✓ |
| P11 | **Precedent: the LLM gateway resolves `op` once, at provisioning time, not at run time.** `llm-gateway credentials` runs as the operator and pipes `op read --no-newline <ref>` into `sudo systemd-creds encrypt --with-key=host+tpm2 --name=<provider> - <staged>`. It moves the result into `/etc/credstore.encrypted/llm-gateway.<provider>` only when both steps succeed, so a failed read leaves the stored credential as it was. The `llm-gateway` system unit runs as a static system user with `LoadCredentialEncrypted=` and reads `$CREDENTIALS_DIRECTORY`. The key never touches argv, a cleartext file, or the CLI's memory. | `~/flakes/features/agents/gateway/llm-gateway:1-19, 312-357`; `gateway.nix:52-63, 100-128`; `llm-gateway-serve:25-40`; `justfile:115-117` | ✓ |

## Cross-thread findings

1. **The `op://` plan for an unattended timer is weaker than RFC-020 D3 assumes** (P1, P2, P3, P9; inference).
   - Authorisation is scoped to a tty session with a 10-minute idle expiry. So a timer firing at any realistic interval will likely need a fresh PolKit approval on every run.
   - D3 assumes that "while the desktop app is locked … the run fails loudly". P3 says otherwise: the request asks to unlock the app, and approving it unlocks the whole vault.
   - It may also block rather than fail (P7), so the unit needs a `TimeoutStartSec` (`attention.nix:29` precedent ✓).
   - This bears directly on D3 and OQ-4 and needs the operator's tests (below) before design commits.
   - The alternatives, each a change to the security boundary needing the operator's assent:
     - a 1Password service account: its token is itself a bootstrap secret, and it cannot read the Personal vault;
     - `LoadCredential`/`LoadCredentialEncrypted` holding the Fastmail token itself;
     - resolving once per login into a 0600 file on tmpfs.
2. **The jail assertion can't be only a bind check** (P4, P8, G3; inference).
   - The 1Password app exposes an abstract-namespace unix socket. A bwrap jail without `--unshare-net` can reach abstract sockets whatever its binds are.
   - The binary check is a GID test, so the risk is any process gaining group `onepassword-cli`, which in practice means reaching the setgid wrapper.
   - A `check-jails` assertion modelled on `runner-socket-unjailed` (`satan/flake.nix:660-686` ✓) can scan launchers for `/run/wrappers/bin/op`, `onepassword-cli` and the `/run/user/1000` binds.
   - Whether the CLI integration rides the abstract socket must be established before the assertion can claim to be complete.
3. **The NIF links three questions** (L4, L8, L9).
   - The SQLite binding is a C NIF built by rebar3's `pc` plugin. That forces an erlang-shipment over an escript.
   - It also needs `rebar3WithPlugins [pc]` in the Nix builder, which nix-gleam documents ✓.
   - And `esqlite` resolves to a release one day old ✓; pinning in `manifest.toml` is cheap.
   - An offline `nix flake check` build of esqlite is the single riskiest packaging unknown. A spike should settle it before design commits to sqlight.
4. **Bounded sync and the M2-ready schema line up with the spec** (F6–F12; inference).
   - Store state per (account, type) as opaque text from the M1 `/get` responses.
   - Store `queryState` with the exact filter, sort and `collapseThreads` that produced it, plus `canCalculateChanges`.
   - Model mailbox membership many-to-many, `messageId` as a list, and body values with `is_truncated`, `is_encoding_problem` and the `maxBodyValueBytes` used.
   - `Email/changes` is account-wide, so M2 must re-test window membership; storing `receivedAt` makes that cheap.
   - The brief §4.4 "explicit error or truncation metadata" maps one-to-one onto `isTruncated` plus a server-clamped `limit` (F9, F10 ✓).
5. **Limits are runtime facts, not constants** (F4, F5, F9). Batch sizes must derive from the live session's `maxObjectsInGet` and `maxCallsInRequest`, capped by Screwtape's own configured bounds. The tests need a fixture session with small limits.
6. **There is no JMAP library to adopt** (L1, brief §11 item 3). A thin hand-written client over `gleam_httpc` and `gleam_json` is the only realistic path, and it matches SL-001's "not a general-purpose client".
7. **The gateway precedent answers finding 1, and also reopens D3's premise about a dedicated uid** (P10, P11; inference).
   - With `op` at unit start, every run prompts (P10 ✓). The gateway pattern prompts once, when the operator provisions or rotates the token, and never at run time (P11 ✓).
   - It reuses an existing mechanism: a host-plus-TPM-sealed credential delivered by systemd. It adds no new secret store, and leaves no cleartext file and no bootstrap token. 1Password stays the source of truth.
   - RFC-020 D3 rejected a dedicated uid because it "would need a 1Password service-account token, which is a bootstrap secret on disk again". The gateway runs as a dedicated static uid without one. So a `screwtape` system user is feasible after all.
   - That bears on D3's "plaintext store" gap. A store at `StateDirectory=screwtape`, mode 0700 under that uid, would hide mail from unjailed `david` processes.
   - The cost is that the human read verbs and M3's tools then need a sanctioned path in: a group, or a `sudo -u` re-exec like `llm-gateway`'s admin commands (DEC-050, `llm-gateway:10-11`). That also bears on OQ-11's contract form.
   - The system-versus-user unit, uid and store-access choices are security-boundary decisions for design and the operator.
   - If adopted, the remaining `op` tests (3–7) no longer gate design, because `op` leaves the run-time path. Their answers are still useful facts for RFC-020.

## Brief cross-check

The brief is `~/dev/satan/docs/email-brief.local.md`. It is evidence: RFC-020 restates it, and the operator's decisions supersede it where the two differ. These rows are where it bears on SL-001 in ways the scope does not already carry.

| Brief | Bears on | Finding |
|---|---|---|
| §4.1 "Fastmail supports this scope explicitly" | token | Confirmed: a "Read-only access" JMAP scope exists (F2 ✓). Its combination with "Email" is undocumented (test 9). |
| §4.4 bounds: also "aggregate bytes per invocation", "thread size", "request concurrency and timeouts" | sync config | SL-001 § Scope lists window, body bytes, page depth and timeouts. Aggregate bytes per sync, and concurrency, are not named. Design should decide whether they apply to `sync`, to the read verbs, or to both. A oneshot can simply fix concurrency at 1. |
| §3.1 `mail.list` filters: mailbox, date range, sender, unread, count, pagination | store schema | The read verbs query the store, so keywords (`$seen`), `from` addresses and `receivedAt` must be queryable columns, not only inside JSON blobs. |
| §3.2 `messageIdHeader?: string` (singular) | model | JMAP gives `messageId: String[]\|null` (F12, raw). The normalised model should keep the list, or record how it reduces it. |
| §3.2 `body.sourceType: "text" \| "html"`, `truncated` | model | Maps onto F10/F11 ✓. HTML-to-text output carries `sourceType = html`, and `truncated` comes from JMAP's `isTruncated`. |
| §6 proposals need "stable references" and "expected source state" | provenance | The M1 store should keep accountId, JMAP ids and the per-type state at fetch time per row, so M4 can express expected state. Cheap now, and it touches the schema. |
| §7 logical boundaries `jmap/`, `reader/`, `model/`, `cli/` | module layout | A naming precedent for `src/screwtape/*`. The brief: "prefer a small number of cohesive modules". |
| §9 tests: "mailbox membership changes", "state-token invalidation", "repeated runs and duplicate handling" | test scope | These are M2 behaviour per RFC-020 D8 and are not in SL-001's test list. In M1, "repeated runs" still applies: a second full sync must replace, not duplicate. |
| §9 "verify the deployed process capabilities — not just the tool declarations" | deployment check | This supports the `check-jails` assertion scanning built launchers (finding 2), not just the Nix configuration. |
| §11.3 "maintained … JMAP client library" | client | Re-asked for Gleam: none exists (L1, finding 6). |

## Design-input deltas

- **D3/OQ-4: `op://` at unit start prompts on every run** (P10 ✓).
  - The local precedent is the LLM gateway's pattern (finding 7, P11 ✓): provision once with `op read | systemd-creds encrypt`, then `LoadCredentialEncrypted=`.
  - Design should take it as the leading option, and decide with the operator:
    - a system unit under a dedicated uid, or a user unit;
    - who owns the store, and how humans and M3 consumers read it.
- **The `check-jails` assertion lives in satan** (`justfile:21-25` ✓), not `~/flakes`. Affected surface: SL-001 § Scope 2 places it in `~/flakes`, which needs correcting. It must also decide about abstract sockets.
- **Packaging spike first.** A minimal Gleam project with `sqlight`, built by nix-gleam with `pc`, running `gleam test` in `nix flake check` offline. It also checks `erlang:halt/1` stdout flushing, and CA certificates for `httpc` on NixOS.
- **Store path via configuration or XDG** (G2), not a literal.
- **Bounds and columns from the brief:**
  - Decide on aggregate bytes per sync and on concurrency (brief §4.4).
  - Make `$seen`, `from` and `receivedAt` queryable for the read verbs (brief §3.1).
  - Keep per-row provenance, meaning account, JMAP ids and state at fetch time, for M4 (brief §6).
- **Deployment shape is a design choice:** Precedent A (a Home Manager module exported from screwtape) or Precedent B (an inline unit in `~/flakes`).
- **Library shortlist** (proposal): `gleam_httpc`, `gleam_json` with stdlib decode, `sqlight` (pin esqlite), `htmgrrrl`, `argv` with `clip` or hand-parsing, `envoy`, and FFI `halt`.
- **The live run must record** the session's `capabilities`, the account `isReadOnly`, and `canCalculateChanges` for the window query. These are cheap to capture and answer F2, F4 and F6.

## Must be tested on the host by the operator

From `raw/onepassword.md` § Must be tested; abbreviated here. Use `systemd-run --user --wait --collect -p TimeoutStartSec=120 /run/wrappers/bin/op read op://<vault>/<item>/<field> >/dev/null; echo $?` as the probe.

1. **App unlocked, no tty:** does a PolKit dialog appear? Note the exit code. **Done (P10): prompt, then exit 0.**
2. **Repeat at about 2, 9 and 11 minutes:** is the session reused, or is there a prompt on every run? **Done (P10): prompts on every run.**
3. **App locked, prompt unanswered:** does it block until the timeout? Does approving it unlock the vault? *Not run: not needed if `op` leaves the run-time path (finding 7).*
4. **App not running:** the error text and exit code. *Not run: not needed if `op` leaves the run-time path (finding 7).*
5. **`op run --env-file=<refs> -- sh -c 'touch $XDG_RUNTIME_DIR/ran'` with a failing ref:** is the child skipped? *Not run: not needed if `op` leaves the run-time path (finding 7).*
6. **Before graphical login, or over ssh with linger:** does it fail fast or hang? *Not run: not needed if `op` leaves the run-time path (finding 7).*
7. **The raw `/run/current-system/sw/bin/op`:** is the connection reset? *Not run: not needed if `op` leaves the run-time path (finding 7).*

Also:

8. **`ss -xp` while `op read` runs:** which 1Password socket does the CLI connect to? This answers finding 2.
9. **In the Fastmail UI:** can "Read-only access" be combined with "Email", and which combination yields a working mail read-only session (F2)?
