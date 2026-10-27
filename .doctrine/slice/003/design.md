<!-- doctrine:section sec-1 -->
## 1. Design Problem

Screwtape's read verbs (`mailboxes`, `list`, `read`, `thread`) print JSON for
humans. M3 consumers are separate programs: SATAN's `mail_*` tools
(TypeScript, pi-durable) and a classifier (IDE-001) that composes by pipe.
satan:RFC-020 D2 requires an **explicit, versioned contract that Screwtape
publishes and tests**; satan:RFC-020 OQ-11 asks its form; D1 gives each
consumer a cursor over the store.

This slice publishes the contract and adds what a pipe consumer lacks today:

- a way to read only what arrived since its last run (a **cursor**);
- a way to get bodies for many messages in one process and one snapshot;
- a bound on `thread`, the one unbounded read.

```
screwtape read --after "$CUR" --limit 100 --max-bytes 8192 | classifier
```

**Boundary.** In: the contract (DEC-027, DEC-029), the arrival cursor
(DEC-028), `list --after`, `read --after`, `thread --limit` (DEC-032), README
contract section (DEC-030, DEC-031), a satan:RFC-020 amendment draft. Out: the
classifier, the `mail_*` tools, multi-id `read`, plural `thread`, other
queries (deferred until evidence of need), schema changes, sync changes.

<!-- doctrine:section sec-10 -->
## 10. Code Impact

| Path | Change |
|---|---|
| `src/screwtape/cursor.gleam` | New: `Cursor`, `of`, `to_string`, `parse`, int64 bounds. |
| `src/screwtape/argv.gleam` | `Filters` + `Page` split; `--after`; `ReadAfter`; `limit_value`; `thread --limit`; new usage codes. |
| `src/screwtape/store/query.gleam` | `ListQuery` with `query.Page` (`Newest`/`Oldest`, optional limit); cursor predicate and ascending order; generalised `message_ids`; `messages_of` extracted from `prior`; `thread` with limit → `ThreadPage`. |
| `src/screwtape/model.gleam` | `ThreadPage`. |
| `src/screwtape/render.gleam` | `cursor` in `summary_fields`; `list` `after`; `thread` `total`/`truncated`. |
| `src/screwtape/cli.gleam` | `dispatch` → `Option(String)`; `read --after` document; `thread` limit. |
| `test/screwtape/{cursor,cli,render,read_snapshot}_test.gleam`, `test/support/snapshot_fixture.gleam` | Tests per § 9. |
| `test/screwtape/store_test.gleam`, `test/support/{cli_fixture,paging}.gleam` | Query tests per § 9; shared test support (`paging.walk`, fixture helpers). |
| `test/check_imports.gleam`, `test/screwtape/check_imports_test.gleam` | Purity rule for `cursor`; `render` may import it. |
| `src/screwtape.gleam` | Stdout prose for `read --after`. |
| `README.md` | CLI table; new § Contract. |
| `~/dev/satan/.doctrine/rfc/020` | Draft amendment (OQ-11 answered, D1 cursor, IDE-001 note), uncommitted, for the operator. |

<!-- doctrine:section sec-2 -->
## 2. Current State

- **Envelope.** `render.envelope` is the only writer of
  `{"version":1,"kind":<verb>,"data":…}` (`render.gleam:21-28`). Optional values
  print `null`, never omitted. `render_test` pins every field and its order.
- **Summaries.** `render.summary_fields` is the one field list for `list`,
  `thread` entries and `read` (`render.gleam:108-123`). `MessageSummary`
  carries `received_at: UtcDate`, whose `ms` is the millisecond key
  (`model.gleam:157-171`).
- **`list`.** `argv.parse_list` accepts `--mailbox --since --from --unread
  --limit 1..500 (50) --offset`, each once, any order (`argv.gleam:150-230`).
  `query.messages` orders `received_at_ms DESC, id DESC` with `LIMIT ? OFFSET
  ?` (`query.gleam:63-70,696-704`).
- **`read <id> [--max-bytes n]`.** One message; a missing id is
  `Usage("unknown_message")`, exit 2 (`cli.gleam:181-198`).
- **The ids → messages loop already exists.** `query.prior` reads every id
  through a private `message_ids(tx)` (`SELECT id FROM message ORDER BY
  received_at_ms, id`, `query.gleam:187-195,765-766`), then `message` per id,
  a missing one being `Store(read_failed)` (`query.gleam:130-135`).
- **`thread <id>`.** Every entry, unbounded (`query.gleam:90-114`).
- **One snapshot per verb.** `cli.read_store` runs every query of a verb in
  one `store.read` transaction (I8, `cli.gleam:124-133`).
- **stdout.** `cli.Outcome.stdout: Option(String)`; `main` prints it plus a
  newline when `Some` (`screwtape.gleam:48-55`). `dispatch` returns a
  `String` document, always `Some`.
- **No change marker in the store.** Every sync rewrites every row (DEC-008);
  `email_state` is restamped by every light refresh (`normalise.gleam:339-356`).
  Hence the arrival cursor (DEC-028).

<!-- doctrine:section sec-3 -->
## 3. Forces & Constraints

- **POL-001.** One selection path (`list`'s argv and query), one ids →
  messages loop (shared with `prior`), one limit parser, and one renderer
  (`render.read`, `summary_fields`); `read --after` composes them.
- **DEC-029.** Additions keep version 1. This slice first *publishes* the
  contract, so v1 is defined as the output at this slice's close, including
  `thread`'s new default limit.
- **DEC-011 / I1.** Usage errors carry fixed reason codes, never an argument.
- **I8.** Every query of a verb runs in one read transaction.
- **sqlight `badarg`.** Binding an integer outside int64 crashes
  (memory `mem.fact.sqlite.esqlite-readonly-uri`): `cursor.parse` range-checks
  the millisecond part against int64 bounds the cursor module owns; argv's
  `--offset` keeps its own `max_offset`.
- **Brief §4.4.** Bounded results and explicit truncation metadata.
- **Rigorous simplicity.** No schema change, no new verb.

<!-- doctrine:section sec-4 -->
## 4. Guiding Principles

- The cursor is **opaque** to consumers: they store and return it, and
  parse nothing except the integer before the first `:`, which DEC-028's
  future-date check reads. Screwtape owns its encoding in one module.
- `--after` always means **oldest first**, so a page that hits `--limit` can
  be continued from its last item without a gap.
- A line-per-message stream is a sequence of exactly the envelopes a single
  `read` prints: one shape, two framings.
- Bounds are explicit at every bulk edge: `--limit` caps the count,
  `--max-bytes` is required for bodies in bulk, `thread` reports what it cut.

<!-- doctrine:section sec-5-1 -->
## 5. Proposed Design

### 5.1 System Model

```
argv ──▶ Command ──▶ cli.dispatch ──▶ read_store (one tx) ──▶ render ──▶ stdout
           │                              │
           │  List(Filters, Page)          ├─ query.messages(ListQuery)                 list
           │  ReadAfter(Filters, Cursor,…) ├─ query.message_ids(..) + messages_of(..)   read --after
           │  Thread(id, limit)            └─ query.thread(id, limit) → ThreadPage      thread
           ▼
   screwtape/cursor: Cursor = Start | After(ms, id); to_string, parse
```

New module **`screwtape/cursor`** (pure): the only place the cursor's text
form is written or read.

<!-- doctrine:section sec-5-2 -->
### 5.2 Interfaces & Contracts

#### `screwtape/cursor`

```gleam
pub type Cursor { Start  After(received_at_ms: Int, id: String) }
pub fn of(received_at_ms: Int, id: String) -> Cursor        // After
pub fn to_string(cursor: Cursor) -> String                  // "" | "<ms>:<id>"
pub fn parse(text: String) -> Result(Cursor, Nil)
```

- `""` is `Start`, before every message: a consumer's first run.
- Otherwise split at the **first** `:`: the left is a decimal int within
  int64, the right a non-empty id (splitting at the first keeps any later `:`
  in the id).
- **Canonical only:** `parse(text)` is `Ok(c)` only when `to_string(c) ==
  text`, so `+05:x` and `007:x` are refused (Erlang's `binary_to_integer`
  accepts both).
- `cursor` holds the int64 bounds it checks. argv's `--offset` keeps its own
  `max_offset`: one bound serving two unrelated checks would couple argv's
  offset to the cursor module for no gain (RV-010 N-3).

#### argv

- `list` and the read selection accept `--after <cursor>` once. A bad cursor
  is `Usage("invalid_cursor")`.
- `read <id> [--max-bytes n]` is unchanged. When `read`'s first argument
  starts with `--`, it is a **selection**: `ReadAfter(filters: Filters,
  after: Cursor, limit: Int, max_bytes: Int)`. Its flags are `list`'s plus
  `--max-bytes`, any order, each once. (JMAP ids are 1–255 chars of
  `A-Za-z0-9_-`; an id starting `--` is not a real case.)
- **Precedence**, after the flags parse (RV-010 N-2):
  - `read` selection: no `--after` → `Usage("missing_after")`; then
    `--after` with `--offset` → `Usage("offset_with_after")`; then no
    `--max-bytes` → `Usage("missing_max_bytes")`.
  - `list`: `--after` with `--offset` → `Usage("offset_with_after")`.
- `ListArgs` is split so no invalid state is representable (argv types):
  `Filters(mailbox, since_ms, from, unread)` plus `Page = Offset(limit,
  offset) | After(limit, Cursor)`. `list` holds `List(Filters, Page)`;
  `ReadAfter` holds its cursor directly.
- **One limit parser:** `limit_value(raw) -> Result(Int, Error)` is
  `int_value(raw, in_limit_range)` with the 1..500 range named once.
  `list`'s and the selection's `--limit` (through `flag_value`, via
  `parse_value_flag`; `thread` via `parse_sole_int_flag`) and `thread --limit` all call it.
- `thread <id> [--limit 1..500]`, default 50.

#### query

- `query` keeps its own types; it imports `screwtape/cursor`, never argv
  (`cli` maps argv to query, as `cli.gleam:140-153` does today; RV-010 N-1).
  `ListQuery(mailbox_ids, since_ms, from, unread, page: query.Page)`, with
  `query.Page = Newest(limit: Int, offset: Int) | Oldest(after: Cursor,
  limit: Option(Int))`.
- `Oldest(c, limit)`: `WHERE` adds `(received_at_ms > ? OR (received_at_ms =
  ? AND id > ?))` for an `After` cursor, nothing for `Start`; `ORDER BY
  received_at_ms ASC, id ASC`; `LIMIT ?` only when `limit` is `Some`.
  `Newest`: unchanged (newest first, `LIMIT ? OFFSET ?`).
- The existing private `message_ids(tx)` is generalised to
  `message_ids(tx, ListQuery)`: the same `WHERE`/`ORDER`/`LIMIT` builder as
  `messages`, selecting only `id`. `prior` passes no filters and
  `Oldest(Start, None)`: the whole store, ascending, as today.
- One `messages_of(tx, ids) -> Result(List(Message), Error)` is extracted from
  `prior` (`message` per id, missing → `Store(read_failed)`), and used by both
  `prior` and `read --after`.
- `thread(tx, id, limit) -> Option(ThreadPage)`, `ThreadPage(total: Int,
  entries: List(ThreadEntry))`: all ids in position order, `total` their
  count, the **last** `limit` kept, summaries only for those.

#### render

- `summary_fields` gains `cursor` (`cursor.to_string(cursor.of(ms, id))`),
  appended after `has_attachment`, so `list` items, in-store `thread` items
  and `read` all carry it.
- `list` under `--after` prints `{"after": <cursor text>, "limit", "items"}`
  instead of `offset`; under `--offset` it is unchanged.
- `thread(id, page)` adds `total` and `truncated` (`total >
  length(entries)`).
- `read` is unchanged apart from `cursor`; the stream calls it per message.

#### cli and stdout

- `dispatch` returns `Option(String)`: `None` prints nothing.
- `read --after`: in one `read_store`, `account_id`, `message_ids`, then
  `messages_of`, each rendered by `render.read(…, Some(max_bytes))`; lines
  joined by `\n`; no messages → `None` (empty stdout, exit 0).
- An id that `message_ids` returned but `message` cannot find, within the same
  transaction, is an internal store fault: `Store("read_failed")` (as in
  `prior`).

#### Published shape (contract v1)

The JSON every read verb prints at this slice's close. `+` marks this slice's
additions; everything else is the current `render.gleam` output. Values are
never omitted (`null` when absent). The README's field tables and the C6
tests follow this block.

```jsonc
// envelope, every read verb (one per line under read --after)
{ "version": 1, "kind": "<mailboxes|list|read|thread>", "data": { … } }

// mailboxes
{ "items": [ { "id": str, "name": str, "parent_id": str|null, "role": str|null,
               "sort_order": int, "total_emails": int, "unread_emails": int } ] }

// summary — list items, in-store thread items, and read
{ "id": str, "thread_id": str, "received_at": str /* JMAP UTCDate, raw */,
  "subject": str|null, "from": [address], "preview": str,
  "is_seen": bool, "is_flagged": bool, "mailbox_ids": [str] /* sorted */,
  "has_attachment": bool,
+ "cursor": str /* opaque; see § 4 */ }

address = { "name": str|null, "email": str }

// list
{ "offset": int, "limit": int, "items": [summary] }        // without --after, newest first
+ { "after": str, "limit": int, "items": [summary] }       // with --after, oldest first

// read (also each line of read --after)
{ …summary,
  "sent_at": str|null, "size": int, "keywords": [str],
  "sender": [address], "to": [address], "cc": [address], "bcc": [address],
  "reply_to": [address],
  "message_id": [str], "in_reply_to": [str], "references": [str],
  "bodies": [ { "part_id": str, "source_type": "text"|"html", "text": str,
                "is_truncated": bool, "truncated_by": "server"|"message_limit"|null,
                "is_encoding_problem": bool, "conversion_failed": bool } ],
  "attachments": [ { "part_id": str, "blob_id": str, "name": str|null, "type": str,
                     "size": int, "disposition": str|null, "cid": str|null } ],
  "provenance": { "account_id": str, "email_state": str },
  "output_truncated": bool }

// thread
{ "id": str,
+ "total": int, "truncated": bool,
  "items": [ summary + { "in_store": true } | { "id": str, "in_store": false } ] }
```

Semantics a consumer needs:

- Truncation, two levels: per body, `is_truncated`/`truncated_by` record a cut
  at sync time (`server`: JMAP `maxBodyValueBytes`; `message_limit`: the
  configured per-message `max_body_bytes`), and `truncated_by` is set exactly
  when `is_truncated` is (`model.gleam:107-133`); per read, `output_truncated`
  records a `--max-bytes` cut of this output.
- `source_type: "html"`: text converted from HTML at sync time; no consumer
  sees HTML. When `conversion_failed` is true, `text` is `""`
  (`normalise.gleam:514-523`).
- `in_store: false`: the thread names a message the store does not hold (for
  example, one outside the window).
- `provenance.email_state` is not a change marker (sync restamps it).

#### The published contract (README § Contract)

- Envelope, `version` 1, compatibility rule (DEC-029); field table per `kind`.
- Cursor: opaque string (except the DEC-028 future-date check); `""` starts; paging rule: pass the last item's
  `cursor`, stop when fewer than `--limit` come back.
- `read --after` is line-delimited JSON, one `read` envelope per line.
- Bounds: `--limit ≤ 500`, `--max-bytes` per message, `thread` `total`/
  `truncated`.
- Known limits (DEC-028):
  - mail entering the window with an older `received_at` is not returned;
  - filters do not reopen passed positions: a message that starts matching
    `--mailbox`/`--unread`/`--from` after the cursor passed it is not
    returned;
  - a future-dated `received_at` (settable by `Email/import`) moves a cursor
    past later real arrivals; consumers must not store a cursor whose
    millisecond part is later than now plus a skew allowance;
  - the cursor is not scoped to an account: after the store is re-synced to
    another account an old cursor is still accepted.
- Reader needs (DEC-031): the binary, `--config`, a writable store directory.

<!-- doctrine:section sec-5-3 -->
### 5.3 Data, State & Ownership

- No schema change; no new store state. `user_version` stays 1.
- The cursor's state is the consumer's (satan:RFC-020 D1). Screwtape holds
  none per consumer.
- `screwtape/cursor` owns the text encoding; `query` owns the SQL predicate;
  `render` owns where `cursor` is printed.

<!-- doctrine:section sec-5-4 -->
### 5.4 Lifecycle, Operations & Dynamics

```
first run:   read --after '' --since 2026-10-01 --limit 100 --max-bytes 8192
             → 100 lines; store last cursor C1
next page:   read --after C1 --limit 100 ...      → 37 lines (< 100): caught up; store C2
next timer:  read --after C2 ...                  → new arrivals only
```

- A sync committing between two pages is harmless: each page is one
  snapshot, and the cursor is a position, not a snapshot id. A message deleted
  between pages is simply not returned.
- A consumer that fears the late-arrival gap (DEC-028) may re-read from an
  earlier cursor and drop ids it has seen.

<!-- doctrine:section sec-5-5 -->
### 5.5 Invariants, Assumptions & Edge Cases

- **C1** Every read verb's stdout is zero or more lines, each one complete
  `version: 1` envelope; only `read --after` prints other than exactly one.
- **C2** Over an unchanged store, a walk of `--after` pages from `""` with any
  `--limit` returns every message the store holds exactly once, ordered by `(received_at_ms, id)`
  ascending, including messages that share a millisecond.
- **C3** `cursor.parse(cursor.to_string(c)) == Ok(c)`, and `parse` accepts
  only canonical text; a malformed, non-canonical or out-of-int64 cursor is
  `Usage("invalid_cursor")`, never a crash.
- **C4** `read --after` selects and renders inside one read transaction (I8).
- **C5** `thread` returns the last `min(limit, total)` entries in thread
  order; `truncated` iff entries were dropped.
- **C6** Invocations that worked before print the same JSON plus the added
  fields (`cursor`; `thread`'s `total`/`truncated`), except that `thread`
  now stops at 50 entries by default. `thread <id> --limit n`, a usage error
  before, is now accepted.
- **Edge:** `--after` on an empty store → `list` items `[]`; `read` prints
  nothing. `--after` past the newest message → same.
- **Edge:** `--since` and `--after` combine with AND.
- **ASM:** `received_at_ms` fits int64 (it is decoded from JMAP UTCDate).

<!-- doctrine:section sec-6 -->
## 6. Open Questions & Unknowns

None blocking. Deferred by operator ruling (DEC-032): multi-id `read`,
plural `thread`, other batch or search queries, until evidence of need.

<!-- doctrine:section sec-7 -->
## 7. Decisions, Rationale & Alternatives

| Record | Decision |
|---|---|
| DEC-027 | The contract is the CLI JSON envelopes, not SQLite views. |
| DEC-028 | Arrival cursor over `(received_at_ms, id)`, held by the consumer. |
| DEC-029 | One version; additions keep it, breaking changes bump it. |
| DEC-030 | README contract section; render and CLI tests; no JSON Schema. |
| DEC-031 | The contract states reader access needs; jail binds are satan's. |
| DEC-032 | `list`/`read --after`, `thread --limit`; further queries deferred. |

Drafting choices (this document): `""` as the start cursor rather than an
optional `--after`; selection mode of `read` detected by a leading `--`;
`read --after` requires `--max-bytes`; an empty stream prints nothing.
RV-010 (adversarial review) changes: shared `message_ids`/`messages_of` with
`prior`; canonical-only cursor parse with int64 bounds owned by `cursor`;
`Filters`/`Page` argv split; one `limit_value`; `list --after` echoes
`after`; documented limits (future dates, filters, account scope).

<!-- doctrine:section sec-8 -->
## 8. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Late-arriving mail is skipped by the cursor | Documented gap; consumer may re-read an overlap (§ 5.4). |
| A future-dated message stalls a cursor until that date | Documented; consumer guard: never store a cursor later than now plus skew. Clamping in Screwtape is possible later if seen. |
| `thread`'s new default limit changes existing output | Pre-publication; `truncated`/`total` make it visible; README states it. |
| A consumer parses the cursor and breaks when its encoding changes | README calls it opaque; changing the encoding is a version bump (DEC-029). |
| `id > ?` uses SQLite BINARY collation | The order need only be total and stable within SQLite; C2 test covers ties. |

<!-- doctrine:section sec-9 -->
## 9. Quality Engineering & Validation

| Invariant | Evidence |
|---|---|
| C1 | `cli_test`: `read --after` stdout splits into lines that each decode as a `read` envelope; empty stream → `stdout == None`. Tests: `read_after_streams_the_listing_one_line_per_message_test`, `read_after_empty_selection_prints_nothing_test`. |
| C2 | `cli_test` over `snapshot_fixture.listing()` (already has `m4`/`m5` sharing a millisecond, `snapshot_fixture.gleam:421`): walk with `--limit 1`, `2` and `500`; ids in order, each once; `--after` with each filter. |
| C3 | `cursor_test`: round trip; `""`; missing `:`; empty id; non-int; `+05:x`, `007:x`; int64 ± 1; id with `:`. argv tests for `invalid_cursor`, `offset_with_after`, `missing_after`, `missing_max_bytes`, their precedence, repeated `--after`. |
| C4 | Extend the I8 tests (`read_snapshot_test.gleam:83-110`) to `read --after`, with snapshot B deleting or re-dating a selected message, so a two-transaction implementation fails; assert stdout equals snapshot A's. `prior` keeps its existing tests through the shared `messages_of`. Tests: the two `cli_read_after_stream_serves_one_snapshot_*` tests. |
| C5 | `render_test` and query tests: thread shorter than, equal to and longer than the limit; `total`, `truncated`. |
| C6 | Expectations that change, and only these: `render_test` field-order tests (`cursor`), `render_test` thread (`ThreadPage`, `total`, `truncated`, `render_test.gleam:726`), `cli_test` `summary_keys` and `read_keys` (`cli_test.gleam:549-552,909-915`), and `cli_test.gleam:646` (`thread … --limit 5` moves from usage error to accepted), `cli_test` `thread_marks_in_store_entries_test` (data keys gain `total`, `truncated`; in-store items gain `cursor` via `summary_keys`), and `store_test` thread tests (adapted to `query.thread(tx, id, limit)` / `ThreadPage`, values unchanged). |

Fixtures: `snapshot_fixture.listing()` as is (POL-001, CHR-004).

