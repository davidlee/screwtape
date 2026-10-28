<!-- doctrine:section sec-01 -->
## 1. Design Problem

Screwtape's read verbs print the SL-003 contract for consumers. Before SATAN
triages mail (M3), the operator wants each message classified by TypeSafe's
Jev, a decision model that answers typed questions about a `state`. The
operator sees the results first; SATAN later sees a pre-classified subset.
Nothing is persisted, and nothing irreversible follows from a classification.

```
screwtape read --after "$CUR" --limit 50 --max-bytes 16384 \
  | screwtape classify            # one `classify` envelope per message
screwtape read --after … | screwtape classify --state   # what would be sent
```

**Boundary.**

In:
- lifting the HTTP seam;
- the `classify` verb and `--state`;
- the PII-stripped state (DEC-034);
- question schema `mail-1` (DEC-035);
- the output envelope (DEC-036);
- failure semantics (DEC-037);
- the config `jev` block and key ingress (DEC-038, DEC-033);
- the POL-002 guard on `PII_hidden_fixtures.local/`;
- the README.

Out:
- the evaluation on real mail (IMP-003);
- the gateway route (flakes:IMP-054);
- persistence, and retries;
- spam, interest and topic relevance (IDE-002);
- SATAN triage.

<!-- doctrine:section sec-02 -->
## 2. Current State

- **HTTP.** `Send` and `HttpFailure` live in `jmap/client`
  (`src/screwtape/jmap/client.gleam:32-44`). The status mapping (`:178`) and
  the transport-failure mapping are private there. The Erlang transport is
  URL-agnostic and supports POST (`src/screwtape_http.erl:99-135`).
  `cli.production_send` binds it with the run's timeout and CA file
  (`src/screwtape/cli.gleam:88-91`).
- **Credentials.** `credential.read(dir, name)` gives an opaque `Token`.
  `bearer` is the only place it is revealed (`src/screwtape/credential.gleam`).
  The directory comes only from `$CREDENTIALS_DIRECTORY`
  (`src/screwtape/cli.gleam:346-352`).
- **CLI.**
  - `cli.run(args, env) -> Outcome` is pure. `Outcome` already holds
    optional stdout, stderr lines and an exit code (`cli.gleam:52-56`).
  - `dispatch` returns `Result(#(Option(String), List(String)), Error)`, so
    a verb cannot return stdout and an error together today.
  - No code reads stdin (research, Thread 2).
- **Contract.** `render.envelope` is the only envelope writer
  (`src/screwtape/render.gleam:22-28`). No decoder exists for Screwtape's
  own output.
- **Regex.** There is no regex dependency, and the pinned stdlib has no
  `gleam/regex` (`test/check_imports.gleam:14-16`).
- **Import rules.** `check_imports` pins each governed pure module's
  imports. `html_sax` is the precedent for a pure module that reaches an
  Erlang FFI file (`test/check_imports.gleam:78-110`).
- **Fixtures.**
  - `test/fixtures/jmap/` holds the JMAP fixtures.
  - malebolge's `test/mail/fixtures/real/` holds 11 scrubbed real `read`
    envelopes, taken at Screwtape commit `e61d01b`.
- **Nix.** The Home Manager wrapper only adds `--config`
  (`nix/module.nix:55-60`). `screwtape-provision` is specific to Fastmail
  and `op` (`nix/module.nix:66-98`).

<!-- doctrine:section sec-03 -->
## 3. Forces & Constraints

- **POL-001.** One seam, one credential reader, one envelope writer, one
  test-support layer. Generalise rather than copy.
- **POL-002.** Real mail stays in `PII_hidden_fixtures.local/`. SL-004 adds
  the folder and its guard; the eval that uses it is IMP-003.
- **DEC-006.** Pure core. HTTP goes only through an injected `Send`.
  Process effects (stdin, stdout, env, halt) stay in `src/screwtape.gleam`.
- **DEC-012 and DEC-014.**
  - The key never appears in output.
  - Errors carry fixed codes and paths, never server text.
  - mem.fact.gleam.decode-dict-key-in-path: `decode.dict` copies keys into
    error paths, so decoding is by known names only.
- **DEC-018 and DEC-033.**
  - The mail URLs are https-only.
  - The Jev `base_url` is https, or http to `127.0.0.1` exactly.
- **DEC-029.** Contract version 1 is unchanged. `classify` and
  `classify_state` are new kinds, and their vocabulary is versioned by
  `schema` (DEC-036).
- **DEC-009 and DEC-037.** Concurrency is 1, and there is no retry.
- **Jev limits** (research, Thread 3):
  - a 32 MiB body;
  - 64k tokens per request, and 32k for the state plus any one question;
  - status codes 400, 401, 413, 422, 429 and 529.
- **Rigorous simplicity.** No streaming, no concurrency, no persistence.

<!-- doctrine:section sec-04 -->
## 4. Guiding Principles

1. **Ask Jev only what the content shows.** Consent, relevance to the
   person, authenticity and real urgency belong to consumers (DEC-035).
2. **Nothing Jev chooses reaches stdout or stderr.**
   - Answers are re-encoded from our own question, label and level lists.
   - The one server string we print, `model`, must equal the configured
     model.
3. **One strip function** covers every text that leaves the host, and
   `--state` makes it inspectable.
4. **The schema is data.** Questions are a constant list that drives the
   request, the decoder, the renderer and the README table.
5. **Fail closed and resumable.** The first failure ends the run, and the
   cursor makes resuming exact.

<!-- doctrine:section sec-05-1 -->
## 5. Proposed Design

### 5.1 System Model

```
stdin lines ──▶ classify/input.line ──▶ Mail ──▶ classify/state.build ──▶ state Json
                 (decode own `read`)          (fields, pii.strip, bounds)     │
                                                                              │ --state: render.classify_state
                                                                              ▼
              schema.mail_1 ──▶ jev.request_body(model, state, questions) ──▶ jev/client.ask ──Send──▶ Jev / gateway
                                                                                   │
                render.classify(id, cursor, reply) ◀──── jev.reply(text, questions, model)
```

| module | role | effects |
|---|---|---|
| `screwtape/http` (new) | `Send`, `HttpFailure`, `status/1`, `failure/2` | none (types and pure mapping) |
| `screwtape/jmap/client` | the JMAP exchange over `http.Send`; budget; problem documents | none |
| `screwtape/pii` (new) | `strip(String) -> String`; self-contained, for reuse | the FFI `screwtape_pii_ffi` (Erlang `re`) |
| `screwtape/classify/input` (new) | decodes one stdin line (a v1 `read` envelope) into a `Mail` | none |
| `screwtape/classify/state` (new) | `Mail` → state `Json` (field set, strip, bounds) | none |
| `screwtape/jev` (new) | the Jev question and answer types, request encoding, reply decoding | none |
| `screwtape/jev/client` (new) | one authorised POST to `<base_url>/v1/systemone` over `http.Send` | none |
| `screwtape/classify/schema` (new) | the `mail-1` constant: schema id, preamble, questions | none |
| `screwtape/render` | adds `classify` and `classify_state` envelopes | none |
| `screwtape/cli` | the `classify` verb: config, credential, loop, `Outcome` | none |
| `src/screwtape.gleam` | the stdin read at the edge | process |

<!-- doctrine:section sec-05-2 -->
### 5.2 Interfaces & Contracts

#### `screwtape/http`

```gleam
pub type HttpFailure { Timeout ConnectFailed TlsFailed BadUtf8 TooLarge }
pub type Send = fn(Request(String), Int) -> Result(Response(String), HttpFailure)
/// 2xx → Ok; 401/403 → Auth(code); 429 → RateLimited; other → Http("status_<n>").
pub fn status(response: Response(String)) -> Result(Response(String), Error)
/// Timeout → Http("timeout") … TooLarge → LimitExceeded(bound)
pub fn failure(failure: HttpFailure, too_large: String) -> Error
```

`jmap/client` keeps its budget and its problem-document branch:

- it calls `decode.problem` only when `http.status` returns `Http(_)`;
- it passes `"max_total_bytes"` as the `too_large` bound.

Every caller of `client.Send` and `client.HttpFailure` moves to `http.`.
These are `cli`, `fixture_send`, `transport_test` and `client_test`. The
behaviour is unchanged, and the existing tests are the proof.

#### `screwtape/pii`

```gleam
pub fn strip(text: String) -> String
```

The module is self-contained, so it can be reused or ported: it imports only
`gleam_stdlib` and its own FFI, and knows nothing of mail or of Screwtape's
types. Each rule is a pattern and replacement constant. The rules are
applied in this order. All matching is case-insensitive and Unicode-aware.

1. Email addresses become `[email]`. An address is recognised by a dotted
   domain whose last label has 2 or more letters, so `user@localhost` and
   `a@b.c` survive. Rule 1 runs before rule 2, so a URL with userinfo
   (`https://user:pw@host.example/p`) loses its host to this rule too.
2. URLs (`https?://…` up to whitespace or `<>"'`) become `scheme://host`,
   followed by `/[…]` when a path, query or fragment was dropped. The host
   loses any port and userinfo.
3. IPv4 dotted quads become `[ip]`.
4. Date and time shapes are protected:
   - ISO dates and datetimes;
   - `d/m/y`, `d.m.y` and `y/m/d`, where the day is 1–31 and the month
     1–12 (a leading zero allowed), and the year has 2 or 4 digits (4 in
     `y/m/d`);
   - `hh:mm(:ss)`;
   - any of these dates followed by a single space and a time, as one shape.

   A shape is protected only as a whole token. Nothing that rule 5 would
   join may touch either end: no digit, and no space, `.`, `/` or `-`
   followed by a digit. So `0412.345.678` and `12.12.2026 3456` are numbers
   and are stripped, while `12.12.2026 14:00` survives. The implementation
   masks protected shapes, applies rule 5, then unmasks.
5. Runs of 8 or more digits, with single spaces, dashes or dots allowed
   between digits, become `[number]`.

`screwtape_pii_ffi.erl` exports one function, `replace(Text, Pattern,
Replacement) -> Text`. It calls `re:replace/4` with
`[global, unicode, caseless, {return, binary}]`. The patterns are Gleam
constants in `pii.gleam`, so the rules and their tests sit together.
`check_imports` gains:

- a `Rule("src/screwtape/pii.gleam", [], ["gleam_stdlib"], FfiOnly)` entry,
  which also keeps the module self-contained;
- a beam-import allowlist for the FFI module: `re:replace/4`, plus the
  compiler-generated `erlang:get_module_info/1,2`
  (mem.pattern.erlang.beam-imports-for-ffi-purity).

#### `screwtape/classify/input`

```gleam
pub type Mail {
  Mail(id: String, cursor: String, subject: Option(String),
       senders: List(String),            // from[].email, as printed
       bodies: List(MailBody),           // text, is_truncated, conversion_failed
       attachments: List(#(String, Option(String))),   // type, name
       output_truncated: Bool)           // read's own --max-bytes cut
}
pub fn line(text: String) -> Result(Mail, Error)
```

- The line must be `{"version": 1, "kind": "read", "data": {...}}`. Any
  other version or kind is `Decode("version")` or `Decode("kind")`.
- Missing or mistyped fields are `Decode(path)`. The paths use only our own
  field names: `data.bodies[2].text` style, with no keys from the input.
- Fields not listed are ignored. The read contract allows additions
  (DEC-029).
- Blank lines are skipped. A trailing newline is not a line.

#### `screwtape/classify/state`

```gleam
pub fn build(mail: Mail) -> Json
```

```json
{"subject": "…", "sender_domains": ["shop.example"], "sender_domains_omitted": 0,
 "bodies": [{"text": "…", "is_truncated": false, "conversion_failed": false}],
 "bodies_omitted": 0,
 "attachments": [{"type": "application/pdf", "name": "…"}], "attachments_omitted": 0}
```

Every field and list is bounded, so the encoded state is bounded. The
bounds are constants:

| field | bound |
|---|---|
| body texts | 16,384 bytes in total, shared in body order |
| `bodies` | 10 entries; the rest are counted in `bodies_omitted` |
| `subject` | 512 bytes |
| `sender_domains` | 10 entries of at most 253 bytes (the DNS limit); the rest are counted in `sender_domains_omitted` |
| `attachments` | 20 entries; the rest are counted in `attachments_omitted` |
| an attachment's `type` and `name` | 128 bytes each |

- `sender_domains`: the text after the last `@` of each sender, lowercased
  and deduplicated in order. A sender without `@`, with an empty domain, or
  with a domain over 253 bytes is dropped and counted.
- Every text first loses its control characters other than tab, line feed
  and carriage return. JSON would print each as a six-byte escape.
- `pii.strip` is applied next, to the subject, each text, each
  attachment type and name, and each sender domain. Each is then cut to its bound with `utf8.prefix`, the
  same rule `render.print_bodies` uses. The bound therefore holds for what
  is sent: stripping can lengthen text (`a@b.co` becomes `[email]`). A body
  cut here has `is_truncated: true`.
- A body is *cut on arrival* when its `is_truncated` is true, or when the
  line's `output_truncated` is true and it is the last body with text or
  any body after it (every body, if none has text). `render.read` reports
  its own `--max-bytes` cut only in `output_truncated`, and the body it cut
  is usually the last one left with text. The rule is conservative: a cut
  that leaves a later body empty also marks the earlier body, which may
  lose a word it did not need to. A body cut on arrival loses its last partial word (the text after
  its last whitespace) before stripping, and is sent with `is_truncated:
  true`. An address or number cut off by `read` is then never sent
  half-recognised.
- The worst case is about 51 KB encoded, since `"` and `\` print as two
  bytes. Typical states are a few KB. **Observed (PHASE-14 live
  check):** the largest request, 19.7 KB, took 5,884 input tokens, far under
  Jev's 32k-token limit. **Inference, unmeasured:** whether the worst case
  fits. A message that does not is skipped (§ 5.5).

#### `screwtape/jev`

```gleam
pub type Question {
  Choice(name: String, instructions: String, criteria: List(#(String, String)))
  Noul(name: String, instructions: String)
  Score(name: String, instructions: String, levels: List(String))
}
pub type Answer {
  ChoiceAnswer(choice: String, confidence: Float, probabilities: List(#(String, Float)))
  NoulAnswer(noul: Float)
  ScoreAnswer(score: Float, confidence: Float, probabilities: List(Float))
}
pub type Reply { Reply(model: String, answers: List(#(Question, Answer))) }

pub fn request_body(model: String, state: Json, questions: List(Question)) -> String
pub fn reply(text: String, questions: List(Question), model: String) -> Result(Reply, Error)
```

- **`request_body`** gives `{"model", "state", "questions": {name: {"type",
  "instructions", "criteria"?}}}`. Choice criteria are a `{label:
  description}` object, and score levels are an ordered array.
- **`reply`** reads each value with `decode.at`, one path per known key.
  The `probabilities` object is also read with `decode.dict`, for its key
  count only (operator ruling 2026-10-29), so no server key reaches an
  `Error`. It checks:
  - `answers.<name>.type` equals the question's type;
  - a choice's `choice` is one of its labels, and has the highest
    probability (ties allowed);
  - `probabilities` has exactly our keys, each in [0, 1], summing to
    1 ± 0.02: a choice's labels, or `"0"`…`"n-1"` for a score;
  - `confidence` and `noul` are in [0, 1];
  - `score` is in [0, n-1], and within 0.05 of the probability-weighted
    level, Σ i·pᵢ;
  - `model` equals the configured `model`, or the configured `model` after
    its last `/` (a gateway's provider prefix). Equality, not a shape: any
    shape a model id fits, a key can fit too.
- The two tolerances held on the PHASE-14 live check: the probabilities
  summed to 1 at float precision (30/30), and the largest gap between a
  score and Σ i·pᵢ was 0.01.
- Any failure is `Decode(path)`, where the path holds only our own question
  names and labels.
- Extra answers or keys are ignored. Jev chooses no output key.

#### `screwtape/jev/client`

```gleam
pub type Endpoint { Endpoint(base_url: String, model: String) }
pub fn ask(send: http.Send, token: Token, endpoint: Endpoint,
           state: Json, questions: List(Question)) -> Result(Reply, Error)
```

- It makes one POST to `base_url <> "/v1/systemone"`, with these headers:
  - `credential.bearer`;
  - `content-type: application/json`;
  - `accept: application/json`.
- The response cap is 65,536 bytes, a constant: answers are small.
  `TooLarge` maps to `LimitExceeded("jev_response_bytes")`.
- Then `http.status`, then `jev.reply`. A non-2xx body is never printed.
- One exception is decoded, by comparison only (DEC-039): a 400 whose
  `detail.error_type` equals `max_tokens_exceeded`, or whose gateway
  `error.message` holds `"error_type":"max_tokens_exceeded"`, and any 413,
  become `LimitExceeded("jev_context")`. Every other 400 stays
  `Http("status_400")`. IMP-004 removes the `error.message` match.

#### `screwtape/classify/schema`

```gleam
pub const id = "mail-1"
pub fn mail_1() -> List(Question)   // DEC-035, preamble prepended to each instructions
```

DEC-035 fixes the preamble, the question names, the choice labels and the
score levels. The instructions and label descriptions are fixed in
`classify/schema.gleam` under `mail-1`. The README table is checked against
`mail_1()` names by a test, so the docs and the code cannot drift.

#### config

The `jev` block is optional:

```json
"jev": {"base_url": "https://api.typesafe.ai",
        "credential_name": "jev",
        "model": "jev-1.14.0"}
```

Validation reasons:

| Reason | When |
|---|---|
| `non_https:jev.base_url` | the scheme is not https, unless DEC-033 applies: `http://127.0.0.1` with an optional `:port` and no path |
| `trailing_slash:jev.base_url` | the URL ends in a slash |
| `empty:jev.credential_name` | |
| `invalid:jev.credential_name` | the name contains `/` |
| `empty:jev.model` | |

A `base_url` that validates but cannot form the request URL (`https://`
with no host) fails `Config("jev_url")` at the first ask.

`classify` without `--state` and without the block fails with
`Config("no_jev")`, exit 2. `request_timeout_ms` and `ca_file` are shared.

#### argv and cli

- **argv.** `argv.Classify(state_only: Bool)` covers `classify` and
  `classify --state`. Any other argument is `Usage(...)`, following the
  existing reasons.
- **The cli entry points.** `cli.run(args, env)` keeps its signature for
  every existing caller and delegates to:

  ```gleam
  pub fn run_piped(args, env, read_stdin: fn() -> Result(String, Error)) -> Outcome
  ```

  `run` passes a `read_stdin` that answers `Error(Usage("no_stdin"))`.
  `main` calls `run_piped` with the edge reader. `classify` reports a stdin
  `Error` as it is, like any other.
- **dispatch.** It returns an `Outcome`, and the existing branches go
  through one `outcome(Result(…))` helper. The `classify` branch builds its
  own `Outcome`:
  - success: `Outcome(Some(lines), [], 0)`; empty stdin is
    `Outcome(None, [], 0)`;
  - first failure at message k > 0: `Outcome(Some(lines before k),
    [error line], code)`;
  - failure at k = 0: `stdout: None`.
- **The classify loop.** Config. Then the credential, skipped for
  `--state`. Then `production_send(request_timeout_ms, ca_file)`. Then, for
  each line, `input.line`, `state.build`, and then either
  `render.classify_state(...)` or `jev/client.ask` followed by
  `render.classify(...)`. It stops on the first `Error`.
- **The error line.** Once a line has decoded, a failure on it adds that
  message's `cursor` to the error line. The operator can then skip a
  message that fails on every run:

  ```json
  {"level":"error","error":"limit_exceeded","bound":"jev_context","cursor":"…"}
  ```

  `read --after` that cursor resumes past the message. The cursor is
  Screwtape's own value, already printed by `read`.

#### the edge

`screwtape_ffi:read_stdin/0` reads standard input to EOF as a UTF-8
binary. It sets `io:setopts(standard_io, [binary, {encoding, latin1}])` and
reads raw bytes with a `file:read/2` loop (`{encoding, unicode}` fails
`no_translation` on valid UTF-8 and passes `\xff`). It validates the bytes
with `unicode:characters_to_binary/1` and restores the device's encoding. It
answers `{ok, Binary}` or `{error,
Reason}`, where `Reason` is `too_large` (over 16 MiB, a constant),
`bad_utf8` or `read_failed`. `main` maps these to
`LimitExceeded("stdin_bytes")`, `Decode("stdin_utf8")` and
`Decode("stdin")`. Only `main` calls it, and only when `classify` asks.

#### render (published shape)

```json
{"version":1,"kind":"classify","data":{
  "id":"…","cursor":"…","schema":"mail-1","model":"jev-1.14.0",
  "answers":{
    "primary_purpose":{"choice":"promotion","confidence":0.71,
                       "probabilities":{"correspondence":0.01,…,"other":0.02}},
    "security_related":{"noul":0.03}, …,
    "claimed_time_pressure":{"score":0.4,"confidence":0.66,
                             "probabilities":{"0":0.62,"1":0.36,"2":0.02}},
    "substance":{…}}}}
{"version":1,"kind":"classify_state","data":{"id":"…","cursor":"…","schema":"mail-1","state":{…}}}
```

- Keys print in question order, then label or level order.
- Floats are printed as `gleam_json` prints them.

#### The published contract (README § Contract)

The README gains:
- `classify` and `classify_state` field tables;
- a `mail-1` question table, with each question's name, type, labels or
  levels, and meaning;
- the PII caveat;
- the resume rule: on exit 1, re-run from the `cursor` of the last line
  printed;
- the skip rule: on `jev_context`, re-run from the `cursor` on the error
  line, which skips that message;
- the `systemd-run` note: the Home Manager wrapper handles it.

<!-- doctrine:section sec-05-3 -->
### 5.3 Data, State & Ownership

- **No new persistent state.** Classify reads stdin, the config and one
  credential, then writes stdout and stderr.
- **Schema `mail-1`** is owned by `classify/schema`. Its id changes with any
  change to questions, instructions, criteria, levels, state fields, the cap
  or the strip rules (DEC-035).
- **Credentials.** The Jev key, a gateway client key (`llm-gateway issue`, then
  `screwtape-provision jev --from-file`), is an encrypted user-scope credential: `jev` in `credstore.encrypted`.
  Only the `systemd-run` transient unit decrypts it (DEC-038).
- **Real mail** lives only in `PII_hidden_fixtures.local/` (gitignored,
  POL-002). SL-004 creates the folder with its two notes; IMP-003's eval
  owns what goes in it.

<!-- doctrine:section sec-05-4 -->
### 5.4 Lifecycle, Operations & Dynamics

**Provisioning.** `screwtape-provision` takes a credential name, `fastmail`
(the default) or `jev`, and an optional `--from-file <path>`.

- The source is `cfg.opRef` for fastmail, `cfg.jev.opRef` for jev, or the
  file named by `--from-file`.
- Staging is a private per-run directory beside the store, and the move is
  atomic (`mv -fT`). A `--from-file` source that is a symlink, or is the
  stored credential itself, is refused. A `--from-file` source is removed
  after a successful move.
- `jev` is offered only when `services.screwtape.jev` is set; otherwise it
  is a usage error, exit 2.
- Only `fastmail` restarts `screwtape.service`.
- The gateway key comes from `llm-gateway issue screwtape --models
  typesafe/jev-1.14.0 --budget <USD> --out <file>`, run without sudo. That
  file is then fed to `screwtape-provision jev --from-file <file>`.

**Wrapper.** When `services.screwtape.jev` is set, the wrapper starts
`classify` invocations like this:

```
exec systemd-run --user --pipe --quiet --wait --collect \
  -p LoadCredentialEncrypted=jev:<configHome>/credstore.encrypted/screwtape.jev \
  -p LimitCORE=0 -E ERL_CRASH_DUMP_SECONDS=0 \
  <pkg>/bin/screwtape --config <file> "$@"
```

- The two crash-dump settings close the core-dump and `erl_crash.dump`
  channels for the key and the mail (I1). They come from one Nix
  definition, which `screwtape.service` also uses (POL-001).
- `classify --state` and the other verbs run directly as today.
- `--collect` removes the transient unit even when it fails.

**Swapping to the gateway:**
1. Set `jev.baseUrl = "http://127.0.0.1:<relayPort>"` and `jev.model =
   "typesafe/jev-1.14.0"`.
2. Re-provision `jev` from the issued key file.

No code change is needed.

**Live check.** Once deployed, `classify` runs on the copied scrubbed
fixtures through the gateway with a client key. That run confirms A1, the § 5.2 reply
tolerances and where a 400 carries `max_tokens_exceeded`; the codec is
fixed if they differ. The evaluation on real mail follows, as IMP-003.

<!-- doctrine:section sec-05-5 -->
### 5.5 Invariants, Assumptions & Edge Cases

**Invariants:**
- **I1.** No byte of the key appears on stdout or stderr, in errors or in
  crash output. The token-leak suite runs `classify` with a sentinel key.
- **I2.** Every stdout key, label and level comes from `mail_1()` or a fixed
  name. `model` is printed only if it equals the configured model or the configured model's text after its last `/`.
- **I3.** Every text in `state` has passed `pii.strip`. `state` holds no
  display name, local part, header id or provenance.
- **I4.** Output lines are in input order. Each line corresponds to one
  input line, and the run ends at the first failure.
- **I5.** Classify never opens the store and never writes a file.

**Edge cases:**
- Empty stdin gives empty stdout and exit 0.
- A `read` line whose text is all truncated or empty is still classified.
  Its `is_truncated` and `conversion_failed` flags tell Jev the evidence is
  partial.
- A message too large for Jev (400 `max_tokens_exceeded` per DEC-039, or 413) stops
  the run with `LimitExceeded("jev_context")` and the message's `cursor`.
  The state's bounds make it unlikely (**inference**, unmeasured). The
  README shows the error line and the skip: `read --after` that cursor.
- A gateway refusal (non-200) is handled the same way as an upstream one.

**Assumptions:**
- **A1.** Jev's reply shape matches the OpenAPI spec (research, Thread 3).
  Confirmed by the PHASE-14 live check (`model`, `answers`, `usage`; score
  answers add an ignored `legend`), except alias behaviour, untestable
  through the pinned key (403 on `typesafe/jev-latest`).
- **A2.** `systemd-run --pipe` carries stdin, stdout and the exit code, as
  the spike showed (research, finding A).

<!-- doctrine:section sec-06 -->
## 6. Open Questions & Unknowns

- Whether `substance` carries a signal, and how well Jev's probabilities are
  calibrated on this mail. IMP-003's eval gives first evidence before
  consumers rely on `mail-1`.
- Token usage per message. Screwtape does not record it. Once `classify`
  runs through the gateway, llm-gateway's own accounting is expected to
  show it (unverified).
- A1 is resolved (§ 5.5). Replies are not deterministic: 81 of 150 scalars
  differ between two runs (largest gap 0.13, one choice flipped). IMP-003's
  eval measures it.
- SL-004 inq-9, deferred to close: the satan:RFC-020 D1/D5 amendment draft
  in `~/dev/satan`, and the DEC-016 exposure note (the Jev key and mail in
  flight).

<!-- doctrine:section sec-07 -->
## 7. Decisions, Rationale & Alternatives

| id | decision | rejected |
|---|---|---|
| DEC-033 | Jev `base_url`: https, or http to literal `127.0.0.1` | a unix socket, relay TLS |
| DEC-034 | fixed, bounded state fields, strip then cut, Erlang `re` strip, `--state` | `gleam_regexp`, a scanner, sending the raw envelope |
| DEC-035 | `mail-1`: a `primary_purpose` choice, 5 nouls, 2 scores, a shared preamble | a noul per tag, spam, interest, novelty |
| DEC-036 | `classify` envelope with a `schema` id that versions its vocabulary | enum bumps, unversioned names |
| DEC-037 | stop at the first failure, keep the prefix, no retry | continue past errors, backoff |
| DEC-038 | optional `jev` config, a `systemd-run --pipe` wrapper, a generalised provision | a plaintext key directory, a new ingress |
| DEC-039 | a 400 is `jev_context` when `detail.error_type`, or the gateway's `error.message`, holds `max_tokens_exceeded`; so is any 413 | direct-Jev key only (`status_400` through the gateway) |
| POL-002 | real mail only in `PII_hidden_fixtures.local/` | a folder note alone |

Design-local choices:
- **`cli.run_piped`**, so the 16 existing `cli.run` callers stay unchanged.
  The alternative was threading stdin through every test.
- **`classify/input` decodes our own `read` output privately**, not as a
  shared contract decoder: no other Screwtape code consumes it.
- **A separate `screwtape_pii_ffi.erl`**, so its beam import allowlist is
  exactly `re:replace/4`.

<!-- doctrine:section sec-08 -->
## 8. Risks & Mitigations

| risk | mitigation |
|---|---|
| The strip leaks names and postal addresses | Documented. `--state` is inspectable. Real mail is only ever local (POL-002). |
| A regex mis-strips (eats dates) or misses (card with odd separators) | Table-driven tests with synthetic strings, including ones that must survive: dates, times, short numbers. |
| Jev answers drift under an alias | Pin a versioned model id in config. `model` is printed on every line. |
| Calibration unknown | Print raw distributions. Consumers set thresholds after IMP-003's eval. |
| One oversized or hostile message blocks the stream | Every state field is bounded. The README gives the skip procedure. |
| An agent copies real mail into git or records | POL-002, a gitignore test, folder notes. |
| A transient `systemd-run` unit is left behind | `--collect`. The process exits when stdin closes. |
| The seam lift breaks JMAP behaviour | A pure move, done first, behind the existing client and transport tests. |

<!-- doctrine:section sec-09 -->
## 9. Quality Engineering & Validation

Test by behaviour, with helpers in `test/support` (POL-001). Keep few
tests, each with a reason.

- **pii.** A table of `#(input, expected)` cases, covering:
  - each rule;
  - protected dates and times;
  - near-dates that must be stripped: a dotted phone (`0412.345.678`), a
    grouped card number, a date run into further digits by a space
    (`12.12.2026 3456`);
  - a date with a time (`12.12.2026 14:00`), which survives;
  - mixed text.
- **classify/input.** Copied scrubbed fixtures in `test/fixtures/mail/`,
  with a `PROVENANCE.md` citing malebolge's `SOURCE.md` and `SCRUB.md`.
  Also wrong version or kind, a missing field, and a path with no input
  keys.
- **classify/state.**
  - Each bound, cut on a codepoint, with the `_omitted` counts, and
    control characters removed.
  - Strip then cut: text that stripping lengthens (many short URLs) still
    fits 16,384 bytes.
  - Cut on arrival, from real `render.read` output with `max_bytes` ending
    mid-address: the partial word is dropped and the body is sent with
    `is_truncated: true`. Also a budget too small for the first codepoint
    (`€` with `max_bytes` 1), which leaves no body with text: every body is
    sent as truncated.
  - Sender domains, the field set (no names or local parts), and the strip
    applied everywhere.
- **jev.**
  - The `request_body` shape for each question type.
  - `reply`: a good reply from a fixture modelled on the OpenAPI spec, plus
    hostile replies, which must give `Decode` with paths holding only our
    names:
    - a wrong type;
    - an unknown choice;
    - probabilities out of range, with an extra or missing key, or not
      summing to 1;
    - a choice that is not the most probable label;
    - a score inconsistent with its probabilities;
    - a `model` other than the configured one;
    - a non-object.
- **jev/client.** Through `fixture_send`: the URL and headers, 401 → `Auth`,
  429 → `RateLimited`, 529 → `Http("status_529")`, and `TooLarge`. A 400
  with `max_tokens_exceeded` and a 413 → `LimitExceeded("jev_context")`;
  another 400 → `Http("status_400")`.
- **cli.**
  - `run_piped` with fixture stdin: `--state` output, classify success, a
    failure at message k keeping k lines and naming message k's cursor
    on the error line, and empty stdin.
  - `no_jev`, `no_stdin`, and the config validation reasons, including
    DEC-033's loopback cases.
  - The real edge: one subprocess test pipes 16 MiB + 1 bytes and gets
    `stdin_bytes`, exit 1.
- **token_leak.** Extend the sentinel suite to a `classify` run over the
  loopback TLS server (`local_jmap` generalised, or a sibling built on
  `local_tls`). This is one subprocess test. Its server reflects a
  lowercase sentinel key, valid in shape as a model id, in `model`.
- **check_imports.** Rules for the new pure modules and the `pii` FFI
  allowlist.
- **docs.** The README `mail-1` table names match `schema.mail_1()`.
- **POL-002.** A test asserts that `.gitignore` holds
  `/PII_hidden_fixtures.local/*`, with only `!…/CLAUDE.md` and `!…/AGENTS.md`
  negated, and that `git check-ignore` ignores a probe path inside the
  folder.
- **nix.** `module-eval.nix`: the jev options produce the config block and
  the wrapper branch, and with jev unset the wrapper is unchanged. The
  wrapper and `screwtape.service` carry the same crash-dump settings.
- **Manual.** The § 5.4 live check: `classify` on the scrubbed fixtures,
  through the gateway with its client key, confirms A1, the reply tolerances and the
  `max_tokens_exceeded` location. The eval on real mail is IMP-003.

<!-- doctrine:section sec-10 -->
## 10. Code Impact

| path | change |
|---|---|
| `src/screwtape/http.gleam` | new: the lifted `Send`, `HttpFailure`, `status`, `failure` |
| `src/screwtape/jmap/client.gleam` | uses `http`; keeps the budget and problem documents |
| `src/screwtape/pii.gleam`, `src/screwtape_pii_ffi.erl` | new: the strip |
| `src/screwtape/classify/input.gleam` | new: the stdin line decoder |
| `src/screwtape/classify/state.gleam` | new: the state builder |
| `src/screwtape/classify/schema.gleam` | new: `mail-1` |
| `src/screwtape/jev.gleam`, `src/screwtape/jev/client.gleam` | new: the codec and the exchange |
| `src/screwtape/render.gleam` | `classify`, `classify_state` |
| `src/screwtape/config.gleam` | the `jev` block and its validation |
| `src/screwtape/argv.gleam`, `src/screwtape/cli.gleam` | the `Classify` verb, `run_piped`, `Outcome` from dispatch |
| `src/screwtape.gleam`, `src/screwtape_ffi.erl` | `read_stdin` at the edge |
| `src/screwtape/error.gleam` | `decode_failure` and `to_json_line_at`, reused by the classify codecs and the error line (POL-001) |
| `test/check_imports.gleam` | the new rules and the FFI allowlist |
| `test/support/*` | `fixture_send` and `cli_fixture` (stdin, jev config); a Jev reply fixture; a loopback server for the leak test |
| `test/screwtape/*_test.gleam` | the tests in § 9; moved imports in `transport_test` and `client_test` |
| `test/fixtures/mail/` | copied scrubbed `read` envelopes and `PROVENANCE.md` |
| `.gitignore`, `PII_hidden_fixtures.local/{CLAUDE,AGENTS}.md` | POL-002: ignore `/PII_hidden_fixtures.local/*` and negate only the two notes, so nothing is ever force-added |
| `nix/module.nix`, `nix/module-eval.nix` | jev options, the wrapper branch, the generalised provision, the shared crash-dump settings |
| `nix/package.nix` | the check ships `.gitignore`, `README.md` and `gitMinimal`, so the POL-002 and docs tests run in `checks.gleam-test` |
| `test/fixtures/jev/` | the recorded `mail-1` reply, the gateway and direct `max_tokens_exceeded` 400s, `PROVENANCE.md` |
| `README.md` | the contract additions, `mail-1`, the PII caveat, provisioning |

