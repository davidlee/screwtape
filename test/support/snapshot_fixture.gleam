//// Snapshots for store and sync tests.

import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import screwtape/model.{
  type Body, type Mailbox, type Message, type Snapshot, type Source,
  type TruncatedBy, AccountMeta, Address, Attachment, Bcc, Body, Cc, From,
  HeaderIds, Html, Mailbox, Message, MessageLimit, PlainText, QueryState,
  ReplyTo, Sender, Server, Snapshot, Thread, To, TypeState, UtcDate,
}

/// A snapshot that fills every table, with each `Option` both set and unset,
/// both body sources, a body truncated by each cause, every address field and
/// every header-id kind. Every id and text carries `account_id`, so a dump that
/// still mentions it holds a row of this snapshot.
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
    mailboxes: [inbox, archive],
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
/// two references), two `To` addresses (order matters), an attachment with all
/// its options set, and one body per source.
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
    mailbox_ids: [inbox_id, account_id <> "-mb2"],
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
      Address(
        To,
        Some("To One " <> account_id),
        account_id <> "-to1@example.test",
      ),
      Address(To, None, account_id <> "-to2@example.test"),
      Address(Cc, Some("Cc " <> account_id), account_id <> "-cc@example.test"),
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
