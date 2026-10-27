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
| `list` | `[--mailbox <id\|role\|name>] [--since <YYYY-MM-DD>] [--from <substring>] [--unread] [--limit <1..500>] [--offset <n>]` |
| `read <id>` | `[--max-bytes <n>]` |
| `thread <id>` | none |

`list` flags may come in any order, each at most once. `--limit` defaults to
50 and accepts 1 to 500; `--offset` defaults to 0. `--since` selects from
midnight UTC of that day. `--max-bytes` caps the bytes shared by the
message's body texts together; bodies are cut on codepoint boundaries and
`output_truncated` says whether anything was shortened.

`--config` must come first. The `screwtape` that the Home Manager module
installs is a wrapper that supplies it, so you type `screwtape list ...`.
A verb that succeeds writes exactly one JSON document to stdout, in a
versioned envelope:

```json
{"version":1,"kind":"list","data":{"offset":0,"limit":50,"items":[]}}
```

`kind` is the verb name. Optional values print as `null`, never omitted.
A failure writes nothing to stdout. Diagnostics go to stderr as one JSON
line each:

```json
{"level":"error","error":"usage","reason":"unknown_verb"}
```

There is one warning: an account the session does not report as read-only
adds `{"level":"warning","warning":"account_not_read_only"}` to stderr and
still exits 0.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | runtime failure: credential, transport, JMAP, store, or a ceiling exceeded |
| 2 | usage or configuration error: bad argv, unknown mailbox, unknown message or thread, unreadable config |

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
