# Screwtape

![img](./screwtape3.jpg)


Infernal bureaucrat responsible for mediating [SATAN](https://github.com/davidlee/satan)'s access to mail.

Written in Gleam, runs on BEAM, a systemd runner, login to Fastmail via JMAP.

Intended to broker read-only agent access for summarisation & authoring reviewable, 
auditable execution plans for deterministic invocation by the user.

TBD: the role of Jev / system one models vs traditional LLMs; classifiers are likely 
better suited to classification, unsurprisingly.

These systems in aggregate (secure, agentic mail augmentation) constitute Belphegor - the patron daemon of 
elaborate automation to avoid doing any actual work (and sysadmins).

Uses [quotient](https://github.com/davidlee/quotient) for subagent confinement in development; 
this repo provides an example of its forms.

## What it is

Screwtape is a read-only mirror. It copies a bounded window of one Fastmail
account, over JMAP, into a local SQLite store, and a systemd user timer
refreshes it on a schedule. Agents and humans read that store through the
CLI and never talk to the mail server. The window is explicit: named
mailboxes, a maximum age in days, a maximum message count, and byte and page
ceilings per run.

## CLI

```text
screwtape --config <path> <verb>
```

| Verb | Arguments |
|---|---|
| `sync` | none |
| `mailboxes` | none |
| `list` | `[--mailbox <id\|role\|name>] [--since <YYYY-MM-DD>] [--from <substring>] [--unread] [--limit <1..500>] [--offset <n>] [--after <cursor>]` |
| `read <id>` | `[--max-bytes <n>]` |
| `read --after <cursor> --max-bytes <n>` | `[list's filters] [--limit <1..500>]` |
| `thread <id>` | `[--limit <1..500>]` |

`list`, and the `read` selection, take their flags in any order, each at most
once. `--limit` defaults to 50 and accepts 1 to 500; `--offset` defaults to
0. `--since` selects from midnight UTC of that day. `--after` starts strictly
after a cursor instead of at an offset, and may not be combined with
`--offset`. In the `read --after` row both `--after` and `--max-bytes` are
required: a `read` whose first argument is a flag is a selection, not a
message id. `thread --limit` keeps the last that many entries.

`--max-bytes` caps the bytes shared by the message's body texts together;
bodies are cut on codepoint boundaries and `output_truncated` says whether
anything was shortened.

`--config` must come first. The `screwtape` that the Home Manager module
installs is a wrapper that supplies it, so you type `screwtape list ...`.
`mailboxes`, `list`, `read <id>` and `thread` write exactly one JSON document
to stdout, in a versioned envelope. `read --after` writes zero or more lines,
one `read` envelope each, oldest first; a selection that matches nothing
writes nothing and exits 0.

```json
{"version":1,"kind":"list","data":{"offset":0,"limit":50,"items":[]}}
```

`kind` is the verb name. Optional values print as `null`, never omitted. The
envelope and every kind's fields are specified in [Contract](#contract).
A failure writes nothing to stdout. Diagnostics go to stderr as one JSON
line each:

```json
{"level":"error","error":"usage","reason":"unknown_verb"}
```

`reason` is a fixed code and never one of the arguments. The read verbs add
`invalid_cursor`, `offset_with_after`, `missing_after` and
`missing_max_bytes`.

There is one warning: an account the session does not report as read-only
adds `{"level":"warning","warning":"account_not_read_only"}` to stderr and
still exits 0.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | runtime failure: credential, transport, JMAP, store, or a ceiling exceeded |
| 2 | usage or configuration error: bad argv, unknown mailbox, unknown message or thread, unreadable config |

## Contract

The contract is what the read verbs print to stdout: `mailboxes`, `list`,
`read` and `thread`. The store's tables are private (screwtape DEC-027): a
consumer reads this JSON, never the SQLite file.

Every document is one envelope:

```json
{"version":1,"kind":"read","data":{}}
```

**Compatibility.** One version number covers the whole contract, and it is 1.
Within a version, new fields, new verbs and new optional flags may appear;
consumers must ignore fields they do not know. Raising the version is
reserved for removing, renaming or retyping a field, for changing a field's
meaning or an ordering, and for adding a value to an existing enumerated
field (`source_type`, `truncated_by`). Consumers check `version` and refuse
one they do not know. Values are never omitted: an absent value is `null`.

The tables below follow print order. `[t]` means an array of `t`.

### mailboxes

`data` is `{"items": [mailbox]}`, ordered by `sort_order`, then name, then
id.

| Field | Type | Meaning |
|---|---|---|
| `id` | string | JMAP mailbox id. |
| `name` | string | Name, as the server spells it. |
| `parent_id` | string \| null | Parent mailbox's id. |
| `role` | string \| null | JMAP role, for example `inbox`. |
| `sort_order` | int | Server sort position. |
| `total_emails` | int | The server's total for this mailbox. |
| `unread_emails` | int | The server's unread total. |

### summary

The item shape shared by `list`, in-store `thread` items and `read`.

| Field | Type | Meaning |
|---|---|---|
| `id` | string | JMAP message id. |
| `thread_id` | string | Its thread's id. |
| `received_at` | string | Arrival instant, the raw JMAP `UTCDate` text, not normalised. |
| `subject` | string \| null | Subject as received. |
| `from` | [address] | `From` addresses, in position order. |
| `preview` | string | The server's preview text. |
| `is_seen` | bool | The `$seen` keyword. |
| `is_flagged` | bool | The `$flagged` keyword. |
| `mailbox_ids` | [string] | Mailboxes holding it, sorted. |
| `has_attachment` | bool | The server's flag. |
| `cursor` | string | Opaque arrival position; see Cursor below. |

### list

| Field | Type | Meaning |
|---|---|---|
| `offset` | int | Position of the first item, counted from the newest; printed without `--after`. |
| `after` | string | The cursor the page starts strictly after; printed with `--after`. |
| `limit` | int | Page size in effect. |
| `items` | [summary] | Newest first without `--after`, oldest first with it. |

A `list` document carries exactly one of `offset` and `after`; the other key
is not printed at all.

### read

The summary table's fields in the order above, then:

| Field | Type | Meaning |
|---|---|---|
| `sent_at` | string \| null | Raw `UTCDate`. |
| `size` | int | Message size in bytes, as the server reports it. |
| `keywords` | [string] | JMAP keywords. |
| `sender` | [address] | `Sender` header. |
| `to` | [address] | `To`. |
| `cc` | [address] | `Cc`. |
| `bcc` | [address] | `Bcc`. |
| `reply_to` | [address] | `Reply-To`. |
| `message_id` | [string] | `Message-Id`. |
| `in_reply_to` | [string] | `In-Reply-To`. |
| `references` | [string] | `References`. |
| `bodies` | [body] | Text parts, in body order. |
| `bodies[].part_id` | string | JMAP part id. |
| `bodies[].source_type` | `"text"` \| `"html"` | `"text"` is as received; `"html"` was converted at sync time, so no consumer sees HTML. |
| `bodies[].text` | string | The text, after sync-time and read-time cuts. |
| `bodies[].is_truncated` | bool | Cut at sync time. |
| `bodies[].truncated_by` | `"server"` \| `"message_limit"` \| null | Which bound cut it: JMAP `maxBodyValueBytes`, or the configured per-message `max_body_bytes`. Set exactly when `is_truncated` is. |
| `bodies[].is_encoding_problem` | bool | The server reported a charset or encoding problem with the part. |
| `bodies[].conversion_failed` | bool | HTML conversion failed, so `text` is `""`. |
| `attachments` | [attachment] | Metadata only, never the bytes. |
| `attachments[].part_id` | string | JMAP part id. |
| `attachments[].blob_id` | string | JMAP blob id. |
| `attachments[].name` | string \| null | Filename. |
| `attachments[].type` | string | Media type. |
| `attachments[].size` | int | Size in bytes. |
| `attachments[].disposition` | string \| null | `Content-Disposition`, for example `attachment` or `inline`. |
| `attachments[].cid` | string \| null | Content id. |
| `provenance.account_id` | string | The account the store mirrors. |
| `provenance.email_state` | string | JMAP Email state at the last fetch. Not a change marker: sync restamps it. |
| `output_truncated` | bool | Whether this read's `--max-bytes` cut any text. |

Truncation has two levels: per body, `is_truncated` and `truncated_by` record
a cut at sync time; per read, `output_truncated` records a `--max-bytes` cut
of this output.

### thread

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Thread id, as asked for. |
| `total` | int | Entries in the thread. |
| `truncated` | bool | True when `--limit` dropped entries. |
| `items` | [item] | The last entries, in thread order. |
| `items[].in_store` | bool | Whether the store holds this message. |
| `items[].id` | string | Message id. |

An in-store item is the summary table's fields in the order above followed by
`in_store: true`. An item the store does not hold carries only `id` and
`in_store: false`, for example a message outside the window.

### address

| Field | Type | Meaning |
|---|---|---|
| `name` | string \| null | Display name. |
| `email` | string | Address. |

### Cursor

A `cursor` is an opaque string: store it and hand it back. Do not construct
cursors or compare them; their order is the store's, not a string order. The
one sanctioned look inside is the future-date check under Known limits.

`""` starts from the beginning. `list --after c` and `read --after c` return
messages strictly after `c`, oldest first by arrival (`received_at`, then
id), ties included.

Paging: pass the last returned item's `cursor` as the next `--after`. You are
caught up when fewer than `--limit` items came back. A consumer that drops
items after reading, for example ids it has already seen on a deliberate
re-read of an overlap, still continues from the last *returned* item's
cursor and is caught up when fewer than `--limit` were *returned*: both
counted before its own filtering.

### `read --after`

`read --after` is line-delimited JSON: zero or more `read` envelopes, one per
line, oldest first, and nothing else. It selects and reads in one read
transaction, so a page is one snapshot and a concurrent sync cannot
interleave. No messages match: empty stdout, exit 0.

```sh
cursor=""
while :; do
  screwtape read --after "$cursor" --max-bytes 8192 --limit 100 > page.jsonl \
    || exit
  if [ ! -s page.jsonl ]; then break; fi             # empty page: caught up
  jq -c . page.jsonl                                 # your reader here
  cursor=$(tail -n 1 page.jsonl | jq -r '.data.cursor')
  if [ "$(wc -l < page.jsonl)" -lt 100 ]; then break; fi  # short page
done
```

### Bounds

- `--limit` is 1 to 500 and defaults to 50.
- `--max-bytes` caps body text only, per message, shared across that
  message's bodies in body order. A `read --after` page's body text is
  therefore at most `--limit` × `--max-bytes`. Headers, addresses and
  attachment metadata are uncapped. `output_truncated` says whether that
  read cut anything.
- `thread --limit` keeps the last entries in thread order, 50 by default;
  `total` is the thread's entry count and `truncated` is true when entries
  were dropped.

### Known limits

The cursor is an arrival position, not a change marker (screwtape DEC-028),
so:

- Mail that enters the window with a `received_at` older than a passed
  position is not returned; re-read from an earlier cursor if that matters.
- Filters do not reopen passed positions: a message that starts matching
  `--mailbox`, `--unread` or `--from` after the cursor passed it is not
  returned.
- A future-dated `received_at`, which `Email/import` can set, moves a cursor
  past later real arrivals. Do not store a cursor whose millisecond part (the
  integer before the first `:`) is later than now plus a skew allowance.
- The cursor is not scoped to an account: after the store is re-synced to a
  different account, an old cursor is still accepted.

### What a reader needs

The `screwtape` binary, a `--config` naming the store, and a writable store
directory: a read-only WAL connection still creates `-wal` and `-shm` beside
the store. Nothing else (screwtape DEC-031).

## `sync` is service-only

`sync` reads the token from the credentials directory systemd hands the unit
(`$CREDENTIALS_DIRECTORY`). Run from a shell, that variable is unset, so the
verb fails with a credential error. To sync on demand:

```sh
systemctl --user start screwtape.service
```

## How `sync` works

A run takes one of two paths and reports which in its summary:

```text
"mode": "incremental" | "full"
"fallback_reason": null | "no_state" | "window_changed" | "cannot_calculate_changes" | "too_many_changes"
```

```text
stored snapshot? ──no──────────────────────────────▶ full (no_state)
      │yes
same server, account, maxBodyBytes? ────no─────────▶ full (no_state)
      │yes
same window and mailbox ids? ──no──────────────────▶ full (window_changed)
      │yes
Email/changes ── cannotCalculateChanges ───────────▶ full (cannot_calculate_changes)
      │       └─ still more changes after maxPages ─▶ full (too_many_changes)
      ▼
incremental
```

- **Incremental** asks the server what changed since the stored Email
  state (`Email/changes`). When nothing changed, the run sends no `Email/get`
  with ids and only re-reads the threads. When something changed, it re-runs
  the window query, fetches new messages in full and refreshes the changed
  stored ones (their mailboxes and keywords).
- **Full** fetches everything in the window. When it has a usable stored
  snapshot (every reason but `no_state`), stored bodies are kept and only
  their mailboxes and keywords are refreshed.

`fallback_reason` is `null` on an incremental run and names the reason on a
full one. `maxPages` bounds the `Email/changes` pages as well as the
`Email/query` pages.

**After upgrading** from a version without incremental sync, the first run
is full with `window_changed`: the stored window gained a key
(`retain_messages`). This happens once, and stored bodies are kept.

**Retention.** `window.retainMessages` (`retain_messages` in the config)
keeps up to that many messages in the store, newest first, while each run
fetches only the window. It requires `window.maxMessages` and must be at
least that. Unset, the store holds exactly the window. With it set,
retention ignores `maxAgeDays`.

Retention covers the configured mailboxes only: a message moved out of
every configured mailbox, for example archived, is dropped from the store.
To keep archived mail, add the archive mailbox to `window.mailboxes`.

**Budget.** `maxTotalBytes` bounds the bytes a run receives, with one
exception. When the server answers `cannotCalculateChanges` (its change log
no longer reaches the stored state), the bytes of that error reply are not
charged to the full run that follows, so the run can receive up to about
twice `maxTotalBytes`. The overspend is bounded, and expected to be rare.

## Installation (Home Manager)

The flake exports `homeManagerModules.default`:

```nix
{
  imports = [inputs.screwtape.homeManagerModules.default];

  services.screwtape = {
    enable = true;
    opRef = "op://Private/Fastmail read-only/credential";
  };
}
```

Options:

| Option | Default | Meaning |
|---|---|---|
| `enable` | `false` | Install the service, timer, wrapper and `screwtape-provision`. |
| `package` | this flake's default package | The Screwtape package to run. |
| `opRef` | (required) | 1Password reference to the Fastmail API token, read by `screwtape-provision`. |
| `sessionUrl` | `https://api.fastmail.com/jmap/session` | The JMAP session resource (https only). |
| `window.mailboxes` | `["inbox"]` | Mailboxes to mirror, each matched by role first, then by name. |
| `window.maxAgeDays` | `30` | Mirror messages received within this many days. |
| `window.maxMessages` | `2000` | Mirror at most this many messages, newest first. |
| `window.retainMessages` | `null` | Keep at most this many messages in the store; requires `window.maxMessages` and is at least it (see [How `sync` works](#how-sync-works)). |
| `maxBodyBytes` | `262144` | Bound on one message's stored body text, summed over its parts. |
| `maxPages` | `20` | Bound on `Email/query` pages, and on `Email/changes` pages, per sync. |
| `maxTotalBytes` | `268435456` | Bound on every HTTP response body received in one sync, summed. |
| `requestTimeoutMs` | `30000` | Per-request timeout. |
| `caFile` | `null` | Absolute path of a CA bundle to trust instead of the system store. |
| `onCalendar` | `*:0/15` | When the timer runs a sync (`systemd.time(7)`). |
| `timeoutStartSec` | `5min` | `TimeoutStartSec` of the sync unit. |
| `memoryMax` | `1G` | `MemoryMax` of the sync unit: contains the process if the application bounds fail. |

Two host notes:

- Leave `xdg.stateHome` at its default. The module asserts it is
  `~/.local/state`, because the unit's `StateDirectory` resolves from the
  user manager's own default and the two must agree.
- The timer runs only while the operator's user manager runs. Enabling
  lingering, so a sync also happens while logged out, is a host choice:
  `loginctl enable-linger <user>`. Without it, `Persistent=true` catches up
  at the next login.

## Provisioning

The token must be a Fastmail API token with mail scope, stored in 1Password.
Run `screwtape-provision` once per token rotation:

```sh
screwtape-provision
```

It runs `op read --no-newline <opRef>` piped into
`systemd-creds encrypt --user --name=fastmail -`, writing a staged file
`~/.config/credstore.encrypted/screwtape.fastmail.new` under `umask 077`. Only
if both steps succeed does it move the staged file onto
`~/.config/credstore.encrypted/screwtape.fastmail`; otherwise it removes the
staged file, leaves the stored credential unchanged, and exits 1. It then
starts `screwtape.service` once: success prints that the first sync
succeeded, failure points at `journalctl --user -u screwtape` and exits 1.

The token never appears in argv, in an environment variable, or in a clear
file.

## Plaintext at rest

The store is `~/.local/state/screwtape/mail.sqlite3`: the mirrored mail,
unencrypted. The directory is mode 0700 and the files are created under
`UMask=0077`, so the mirror is readable by the operator's uid and by anything
running as it.

This is DEC-016. Screwtape runs as a `systemd --user` oneshot under the
operator's uid rather than as a separate system user, on the basis that jails
are the safety boundary and the operator's unjailed processes are trusted;
those processes already reach the same mail through Gnus and Thunderbird, and
likely a full-access Fastmail session. The store sits inside the `$HOME` that
the operator's jails shadow with their own bind, so the boundary against
agents is the `$HOME` shadow plus 0700, not a uid.

That boundary has one condition (design § 5.4 and I7): **a jail must not bind
the store's directory or any path that contains it** — that is
`~/.local/state/screwtape`, and equally `~/.config/credstore.encrypted` and
`~/.config/systemd/user`, and their ancestors including `$HOME`. A jail
launched from such a directory would see the plaintext mirror, and it is
therefore a launch error, not a configuration preference.

## Operations

Smoke checks:

```sh
systemctl --user status screwtape.service
journalctl --user -u screwtape
screwtape mailboxes
```

A run that fails leaves the store exactly as it was: the whole snapshot is
written in one transaction, and a failure before the commit rolls back
(including migrations). A rate limit is not retried; the next timer tick is
the retry.

Disable everything with:

```nix
services.screwtape.enable = false;
```

## Development

```sh
nix develop
just check          # format check, warning-free build, import check, tests
nix flake check     # the gleam tests and the module-eval check
```

Design docs:

 - first [slice: SL-001](./.doctrine/slice/001/design.md)

Built with [Doctrine](https://github.com/davidlee/doctrine).
