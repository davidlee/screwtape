//// Tests for `screwtape/model`'s pure rules (PHASE-06, T1).
////
//// `mailboxes_matching` is the per-entry mailbox rule `sync` applies to the
//// window; role beats name, and no match is no match.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit
import gleeunit/should
import screwtape/model

pub fn main() -> Nil {
  gleeunit.main()
}

fn mailbox(id: String, name: String, role: Option(String)) -> model.Mailbox {
  model.Mailbox(
    id: id,
    name: name,
    parent_id: None,
    role: role,
    sort_order: 0,
    total_emails: 0,
    unread_emails: 0,
  )
}

fn ids(mailboxes: List(model.Mailbox)) -> List(String) {
  list.map(mailboxes, fn(mailbox) { mailbox.id })
}

pub fn role_beats_name_test() {
  model.mailboxes_matching(
    [
      mailbox("mb-a", "Inbox", Some("inbox")),
      mailbox("mb-b", "inbox", None),
    ],
    "inbox",
  )
  |> ids
  |> should.equal(["mb-a"])
}

pub fn every_mailbox_with_the_role_matches_test() {
  model.mailboxes_matching(
    [
      mailbox("mb-a", "Inbox", Some("inbox")),
      mailbox("mb-b", "Inbox copy", Some("inbox")),
    ],
    "inbox",
  )
  |> ids
  |> should.equal(["mb-a", "mb-b"])
}

pub fn name_fallback_is_exact_test() {
  model.mailboxes_matching(
    [
      mailbox("mb-a", "Receipts", None),
      mailbox("mb-r", "receipts", None),
    ],
    "Receipts",
  )
  |> ids
  |> should.equal(["mb-a"])
}

pub fn no_match_is_empty_test() {
  model.mailboxes_matching([mailbox("mb-a", "Inbox", Some("inbox"))], "archive")
  |> should.equal([])
}
