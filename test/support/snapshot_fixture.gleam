//// Snapshots for store and sync tests.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order}
import gleam/string
import screwtape/model.{
  type Address, type AddressField, type Body, type Mailbox, type Message,
  type MessageSummary, type Snapshot, type Source, type TruncatedBy,
  type UtcDate, AccountMeta, Address, Attachment, Bcc, Body, Cc, From, HeaderIds,
  Html, Mailbox, Message, MessageLimit, MessageSummary, PlainText, QueryState,
  ReplyTo, Sender, Server, Snapshot, Thread, To, TypeState, UtcDate,
}

/// A snapshot that fills every table, with each `Option` both set and unset,
/// both body sources, a body truncated by each cause, every address field and
/// every header-id kind. Every id and text carries `account_id`, so a dump that
/// still mentions it holds a row of this snapshot.
///
/// The rows are inserted in an order that is *not* the order a read returns
/// them in: the mailboxes are scrambled and two `sort_order`s tie, a message
/// names its mailboxes and lists its attachments and its address fields out of
/// the canonical order. `canonical` below is what a read must return.
pub fn full(account_id: String) -> Snapshot {
  let inbox =
    mailbox(
      account_id <> "-mb1",
      "Inbox " <> account_id,
      Some(account_id <> "-mb-root"),
      Some("inbox"),
      1,
    )
  let archive =
    mailbox(account_id <> "-mb2", "Archive " <> account_id, None, None, 2)
  // Two sort_order ties, so the name and then id tie-breaks decide the order:
  // `mb0` ties with `mb2` on 2, and `mb3` and `mb4` tie with `mb1` on 1 and
  // with each other on the name.
  let drafts =
    mailbox(account_id <> "-mb0", "Alpha " <> account_id, None, None, 2)
  let later =
    mailbox(account_id <> "-mb3", "Zeta " <> account_id, None, None, 1)
  let twin = mailbox(account_id <> "-mb4", "Zeta " <> account_id, None, None, 1)

  Snapshot(
    account: AccountMeta(
      account_id: account_id,
      synced_at: UtcDate(raw: "2026-10-26T09:00:00Z", ms: 1_793_005_200_000),
      api_url: "https://" <> account_id <> ".example.test/jmap/",
      window_json: json.to_string(
        json.object([
          #("account", json.string(account_id)),
          #("since", json.string("2026-10-01T00:00:00Z")),
        ]),
      ),
      max_objects_in_get: 500,
      max_calls_in_request: 4,
      is_read_only: False,
    ),
    states: [
      TypeState("Mailbox", "state-" <> account_id <> "-mailbox"),
      TypeState("Email", "state-" <> account_id <> "-email"),
    ],
    query: QueryState(
      filter_json: json.to_string(
        json.object([
          #("account", json.string(account_id)),
          #("inMailbox", json.string(inbox.id)),
        ]),
      ),
      sort_json: json.to_string(json.array(["receivedAt"], json.string)),
      collapse_threads: True,
      query_state: "state-" <> account_id <> "-query",
      can_calculate_changes: True,
    ),
    mailboxes: [inbox, archive, later, drafts, twin],
    messages: [
      first_message(account_id, inbox.id),
      second_message(account_id, inbox.id),
    ],
    threads: [
      // `-m0` is outside the window: a thread may name messages we do not hold.
      Thread(account_id <> "-th1", [account_id <> "-m1", account_id <> "-m0"]),
      Thread(account_id <> "-th2", [account_id <> "-m2"]),
    ],
  )
}

/// `full("acct-a")` with one message repeated: its insert violates the primary
/// key, so a write of it must fail and roll back.
pub fn broken() -> Snapshot {
  let snapshot = full("acct-a")
  let assert [message, ..] = snapshot.messages
  Snapshot(..snapshot, messages: list.append(snapshot.messages, [message]))
}

fn mailbox(
  id: String,
  name: String,
  parent_id: Option(String),
  role: Option(String),
  sort_order: Int,
) -> Mailbox {
  Mailbox(
    id: id,
    name: name,
    parent_id: parent_id,
    role: role,
    sort_order: sort_order,
    total_emails: 10 + sort_order,
    unread_emails: sort_order,
  )
}

/// The first message carries every address field, every header-id kind (with
/// two references), two `To` addresses (order matters), two attachments (one
/// with all its options set), and one body per source. Its mailboxes, its
/// attachments and its address fields are all out of canonical order.
fn first_message(account_id: String, inbox_id: String) -> Message {
  Message(
    id: account_id <> "-m1",
    thread_id: account_id <> "-th1",
    blob_id: account_id <> "-blob1",
    received_at: UtcDate(raw: "2026-10-26T10:15:30Z", ms: 1_793_009_730_000),
    sent_at: Some("2026-10-26T10:15:00+00:00"),
    subject: Some("Subject " <> account_id),
    preview: "Preview " <> account_id <> " first",
    size: 4096,
    has_attachment: True,
    is_seen: True,
    is_flagged: False,
    keywords: ["$seen", account_id <> "-kw1"],
    email_state: "state-" <> account_id <> "-email-1",
    mailbox_ids: [inbox_id, account_id <> "-mb2", account_id <> "-mb0"],
    header_ids: HeaderIds(
      message_id: [account_id <> "-mid1@example.test"],
      in_reply_to: [account_id <> "-mid0@example.test"],
      references: [
        account_id <> "-mid0@example.test",
        account_id <> "-mid-root@example.test",
      ],
    ),
    addresses: [
      Address(
        From,
        Some("Sender " <> account_id),
        account_id <> "-from@example.test",
      ),
      Address(Cc, Some("Cc " <> account_id), account_id <> "-cc@example.test"),
      Address(
        To,
        Some("To One " <> account_id),
        account_id <> "-to1@example.test",
      ),
      Address(To, None, account_id <> "-to2@example.test"),
      Address(Bcc, None, account_id <> "-bcc@example.test"),
      Address(
        ReplyTo,
        Some("Reply " <> account_id),
        account_id <> "-reply@example.test",
      ),
    ],
    bodies: [
      body("1", PlainText, "Plain body " <> account_id, Some(Server), False),
      body("2", Html, "<p>Html body " <> account_id <> "</p>", None, False),
    ],
    attachments: [
      // `part_id` order is the canonical order, and this list is not in it.
      Attachment(
        part_id: "5",
        blob_id: account_id <> "-blob-a0",
        name: None,
        type_: "text/plain",
        size: 12,
        disposition: None,
        cid: None,
      ),
      Attachment(
        part_id: "3",
        blob_id: account_id <> "-blob-a1",
        name: Some("file-" <> account_id <> ".pdf"),
        type_: "application/pdf",
        size: 1024,
        disposition: Some("attachment"),
        cid: Some(account_id <> "-cid1"),
      ),
    ],
  )
}

/// The second message leaves `sent_at`, `subject`, its header ids, its keyword
/// list and its attachment's options empty, and its body is cut by the
/// per-message limit.
fn second_message(account_id: String, inbox_id: String) -> Message {
  Message(
    id: account_id <> "-m2",
    thread_id: account_id <> "-th1",
    blob_id: account_id <> "-blob2",
    received_at: UtcDate(raw: "2026-10-27T08:00:00Z", ms: 1_793_088_000_000),
    sent_at: None,
    subject: None,
    preview: "Preview " <> account_id <> " second",
    size: 512,
    has_attachment: True,
    is_seen: False,
    is_flagged: True,
    keywords: [],
    email_state: "state-" <> account_id <> "-email-2",
    mailbox_ids: [inbox_id],
    header_ids: HeaderIds(message_id: [], in_reply_to: [], references: []),
    addresses: [
      Address(Sender, None, account_id <> "-sender@example.test"),
      Address(
        From,
        Some("From Two " <> account_id),
        account_id <> "-from2@example.test",
      ),
    ],
    bodies: [
      body(
        "1",
        PlainText,
        "Second body " <> account_id,
        Some(MessageLimit),
        True,
      ),
    ],
    attachments: [
      Attachment(
        part_id: "4",
        blob_id: account_id <> "-blob-a2",
        name: None,
        type_: "image/png",
        size: 64,
        disposition: None,
        cid: None,
      ),
    ],
  )
}

/// `is_truncated` and `truncated_by` are set together or not at all
/// (invariant I4).
fn body(
  part_id: String,
  source: Source,
  text: String,
  truncated_by: Option(TruncatedBy),
  is_encoding_problem: Bool,
) -> Body {
  Body(
    part_id: part_id,
    source: source,
    text: text,
    is_truncated: truncated_by != None,
    truncated_by: truncated_by,
    is_encoding_problem: is_encoding_problem,
    conversion_failed: False,
    max_body_value_bytes: 4096,
  )
}

/// A `Message` with every field at its empty value, for a test that reads only
/// one or two fields; bend it with record update.
pub fn bare_message(id: String, received_at: UtcDate) -> Message {
  Message(
    id: id,
    thread_id: "thread-1",
    blob_id: "blob-1",
    received_at: received_at,
    sent_at: None,
    subject: None,
    preview: "",
    size: 0,
    has_attachment: False,
    is_seen: False,
    is_flagged: False,
    keywords: [],
    email_state: "state-1",
    mailbox_ids: [],
    header_ids: HeaderIds(message_id: [], in_reply_to: [], references: []),
    addresses: [],
    bodies: [],
    attachments: [],
  )
}

/// The order a read must return a message's unordered relations in: its
/// `mailbox_ids` by id, its `attachments` by `part_id`, and its `addresses` by
/// field (the model's order, `From` first) then position. The store keeps no
/// position for mailboxes or attachments, and numbers addresses within their
/// field, so this is the only order a read can produce. `list.sort` is stable,
/// so a field keeps the order it had.
pub fn canonical(message: Message) -> Message {
  Message(
    ..message,
    mailbox_ids: list.sort(message.mailbox_ids, string.compare),
    addresses: message.addresses |> list.sort(address_order),
    attachments: message.attachments
      |> list.sort(fn(a, b) { string.compare(a.part_id, b.part_id) }),
  )
}

/// The rank of an address field in the model: `From`, `Sender`, `To`, `Cc`,
/// `Bcc`, `ReplyTo`.
fn address_rank(field: AddressField) -> Int {
  case field {
    From -> 0
    Sender -> 1
    To -> 2
    Cc -> 3
    Bcc -> 4
    ReplyTo -> 5
  }
}

fn address_order(a: Address, b: Address) -> Order {
  int.compare(address_rank(a.field), address_rank(b.field))
}

/// The `list`- and `thread`-shaped summary of `message` (design § 5.2): its
/// `from` addresses in position order, its mailbox ids sorted.
pub fn summary_of(message: Message) -> MessageSummary {
  MessageSummary(
    id: message.id,
    thread_id: message.thread_id,
    received_at: message.received_at,
    subject: message.subject,
    preview: message.preview,
    from: message.addresses
      |> list.filter(fn(address) { address.field == From }),
    is_seen: message.is_seen,
    is_flagged: message.is_flagged,
    has_attachment: message.has_attachment,
    mailbox_ids: list.sort(message.mailbox_ids, string.compare),
  )
}

/// Unix epoch milliseconds of 2026-10-25T00:00:00Z, the midnight UTC that
/// `--since 2026-10-25` compares from, and the boundary `listing` pins.
pub const listing_midnight_ms = 1_792_886_400_000

/// A snapshot of six messages chosen so every `list` filter and its boundary
/// shows: two messages with the same `received_at_ms` (the id tie-break), one
/// at the `since` boundary, one half a second after it, one millisecond before
/// it, a message in two mailboxes, seen and unseen messages, and the only
/// address with a `%` or a `_` in it. An `acme` address also sits in a `To`
/// and a `Cc`, where the `from` filter must not find it. `th1` names `-m0`,
/// a message the snapshot does not hold.
pub fn listing() -> Snapshot {
  let account_id = "acct-l"
  let inbox =
    mailbox(
      account_id <> "-mb1",
      "Inbox " <> account_id,
      None,
      Some("inbox"),
      1,
    )
  let archive =
    mailbox(account_id <> "-mb2", "Archive " <> account_id, None, None, 2)
  let sent =
    mailbox(account_id <> "-mb3", "Sent " <> account_id, None, Some("sent"), 3)

  Snapshot(
    account: AccountMeta(
      account_id: account_id,
      synced_at: UtcDate(raw: "2026-10-26T09:00:00Z", ms: 1_793_005_200_000),
      api_url: "https://" <> account_id <> ".example.test/jmap/",
      window_json: json.to_string(json.object([])),
      max_objects_in_get: 500,
      max_calls_in_request: 4,
      is_read_only: False,
    ),
    states: [TypeState("Email", "state-" <> account_id <> "-email")],
    query: QueryState(
      filter_json: "{}",
      sort_json: json.to_string(json.array(["receivedAt"], json.string)),
      collapse_threads: False,
      query_state: "state-" <> account_id <> "-query",
      can_calculate_changes: True,
    ),
    mailboxes: [inbox, archive, sent],
    messages: [
      // The boundary itself: a `since` of midnight includes it.
      listing_message(
        account_id,
        "th1",
        "m1",
        UtcDate(raw: "2026-10-25T00:00:00Z", ms: listing_midnight_ms),
        False,
        [inbox.id],
        [
          Address(From, Some("Acme Billing"), "billing@acme.test"),
          Address(From, Some("ACME Support"), "support@acme.test"),
          Address(To, None, "someone@example.test"),
        ],
      )
        |> with_attachment,
      // One millisecond before the boundary: a `since` of midnight excludes it.
      listing_message(
        account_id,
        "th2",
        "m2",
        UtcDate(raw: "2026-10-24T23:59:59.999Z", ms: listing_midnight_ms - 1),
        False,
        [inbox.id],
        [Address(From, Some("Old Mail"), "old@example.test")],
      ),
      // Half a second after midnight (design § 9), in two mailboxes, seen.
      listing_message(
        account_id,
        "th1",
        "m3",
        UtcDate(raw: "2026-10-25T00:00:00.500Z", ms: listing_midnight_ms + 500),
        True,
        [archive.id, inbox.id],
        [Address(From, None, "other@example.test")],
      ),
      // The same receipt millisecond as `m5`: the id tie-break decides.
      listing_message(
        account_id,
        "th2",
        "m4",
        UtcDate(
          raw: "2026-10-25T01:00:00Z",
          ms: listing_midnight_ms + 3_600_000,
        ),
        True,
        [archive.id],
        [
          Address(From, Some("Person"), "person@corp.test"),
          Address(To, None, "billing@acme.test"),
          Address(Cc, None, "cc@acme.test"),
        ],
      ),
      listing_message(
        account_id,
        "th1",
        "m5",
        UtcDate(
          raw: "2026-10-25T01:00:00Z",
          ms: listing_midnight_ms + 3_600_000,
        ),
        False,
        [inbox.id],
        [Address(From, Some("Tie Break"), "tie@example.test")],
      ),
      // Newest, flagged, and the only address with `%` or `_` in it.
      listing_message(
        account_id,
        "th2",
        "m6",
        UtcDate(
          raw: "2026-10-25T02:00:00Z",
          ms: listing_midnight_ms + 7_200_000,
        ),
        False,
        [sent.id],
        [Address(From, None, "odd%name_under@example.test")],
      )
        |> flagged,
    ],
    threads: [
      // Position order, not receipt order, and `-m0` is outside the window.
      Thread(account_id <> "-th1", [
        account_id <> "-m5",
        account_id <> "-m3",
        account_id <> "-m0",
        account_id <> "-m1",
      ]),
      Thread(account_id <> "-th2", [
        account_id <> "-m6",
        account_id <> "-m4",
        account_id <> "-m2",
      ]),
    ],
  )
}

/// One `listing` message: every field the filters and the summary read is set
/// from the arguments, and the rest is fixed filler.
fn listing_message(
  account_id: String,
  thread: String,
  suffix: String,
  received_at: UtcDate,
  is_seen: Bool,
  mailbox_ids: List(String),
  addresses: List(Address),
) -> Message {
  Message(
    id: account_id <> "-" <> suffix,
    thread_id: account_id <> "-" <> thread,
    blob_id: account_id <> "-blob-" <> suffix,
    received_at: received_at,
    sent_at: None,
    subject: Some("Subject " <> suffix),
    preview: "Preview " <> suffix,
    size: 100,
    has_attachment: False,
    is_seen: is_seen,
    is_flagged: False,
    keywords: [],
    email_state: "state-" <> account_id <> "-email",
    mailbox_ids: mailbox_ids,
    header_ids: HeaderIds(message_id: [], in_reply_to: [], references: []),
    addresses: addresses,
    bodies: [],
    attachments: [],
  )
}

fn with_attachment(message: Message) -> Message {
  Message(..message, has_attachment: True, attachments: [
    Attachment(
      part_id: "2",
      blob_id: message.blob_id <> "-a1",
      name: Some("invoice.pdf"),
      type_: "application/pdf",
      size: 64,
      disposition: Some("attachment"),
      cid: None,
    ),
  ])
}

fn flagged(message: Message) -> Message {
  Message(..message, is_flagged: True)
}
