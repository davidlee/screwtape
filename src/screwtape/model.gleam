//// The normalised model (PHASE-03; design § 5.3): one record per store table,
//// the values `normalise` produces and `store` writes.
////
//// Pure data. This module imports only `gleam_stdlib` (invariant I5, enforced
//// by `just check-imports`).

import gleam/option.{type Option}

/// A JMAP `UTCDate`, kept twice: the raw text for provenance, and Unix epoch
/// milliseconds as the key for sorting and filtering (RV-001 F-17). Sub-
/// millisecond digits are dropped; ties order by message id (F-23).
pub type UtcDate {
  UtcDate(raw: String, ms: Int)
}

/// The `sync` row: what the run saw of the account and its limits.
pub type AccountMeta {
  AccountMeta(
    account_id: String,
    synced_at: UtcDate,
    api_url: String,
    window_json: String,
    max_objects_in_get: Int,
    max_calls_in_request: Int,
    is_read_only: Bool,
  )
}

/// A `type_state` row: the earliest state of one JMAP type seen in the run.
pub type TypeState {
  TypeState(type_: String, state: String)
}

/// The `query_state` row: the one `queryState` phase 1 settled on.
pub type QueryState {
  QueryState(
    filter_json: String,
    sort_json: String,
    collapse_threads: Bool,
    query_state: String,
    can_calculate_changes: Bool,
  )
}

pub type Mailbox {
  Mailbox(
    id: String,
    name: String,
    parent_id: Option(String),
    role: Option(String),
    sort_order: Int,
    total_emails: Int,
    unread_emails: Int,
  )
}

pub type Message {
  Message(
    id: String,
    thread_id: String,
    blob_id: String,
    received_at: UtcDate,
    /// The `sentAt` header date, raw: it carries the sender's offset and is
    /// never a sort key.
    sent_at: Option(String),
    subject: Option(String),
    preview: String,
    size: Int,
    has_attachment: Bool,
    is_seen: Bool,
    is_flagged: Bool,
    keywords: List(String),
    /// The Email `state` of the response that delivered this message (M4).
    email_state: String,
    mailbox_ids: List(String),
    header_ids: HeaderIds,
    addresses: List(Address),
    bodies: List(Body),
    attachments: List(Attachment),
  )
}

/// RFC 5322 message identifiers, kept apart from JMAP ids, each list in its
/// header's order.
pub type HeaderIds {
  HeaderIds(
    message_id: List(String),
    in_reply_to: List(String),
    references: List(String),
  )
}

pub type Address {
  Address(field: AddressField, name: Option(String), email: String)
}

pub type AddressField {
  From
  Sender
  To
  Cc
  Bcc
  ReplyTo
}

/// One `textBody` part as stored. `text` is plain text: an HTML part is
/// converted by `html_text` before it is stored.
pub type Body {
  Body(
    part_id: String,
    source: Source,
    text: String,
    is_truncated: Bool,
    /// Set exactly when `is_truncated` is (invariant I4).
    truncated_by: Option(TruncatedBy),
    is_encoding_problem: Bool,
    conversion_failed: Bool,
    /// The `maxBodyValueBytes` the part was fetched under.
    max_body_value_bytes: Int,
  )
}

pub type Source {
  PlainText
  Html
}

/// Who cut a body: the server under `maxBodyValueBytes`, or `normalise` under
/// the per-message `max_body_bytes` bound (RV-001 F-9).
pub type TruncatedBy {
  Server
  MessageLimit
}

/// Attachment metadata only; the blob itself is never fetched.
pub type Attachment {
  Attachment(
    part_id: String,
    blob_id: String,
    name: Option(String),
    type_: String,
    size: Int,
    disposition: Option(String),
    cid: Option(String),
  )
}

/// A thread's message ids in thread order. They may name messages outside the
/// window.
pub type Thread {
  Thread(id: String, email_ids: List(String))
}

/// Everything one run commits, replacing the store's previous rows.
pub type Snapshot {
  Snapshot(
    account: AccountMeta,
    states: List(TypeState),
    query: QueryState,
    mailboxes: List(Mailbox),
    messages: List(Message),
    threads: List(Thread),
  )
}
