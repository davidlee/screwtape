//// Contract tests for `screwtape/retain` (PHASE-02; EX-3, EX-4; VT-1).
////
//// Each case is the id list `merge` returns for one minimal input, and each
//// names the wrong implementation it kills. Nothing calls `merge` until sync is
//// wired (PHASE-05), so a merge that is "green and wrong" cannot be caught by
//// any integration path: the order of the seven steps is the whole contract.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleeunit
import gleeunit/should
import screwtape/model
import screwtape/normalise
import screwtape/retain
import support/snapshot_fixture

pub fn main() -> Nil {
  gleeunit.main()
}

/// A `Message` received at `ms`, delivered to `mailbox_ids`; every other field
/// is `bare_message`'s filler, bent per test with record update.
fn message(id: String, ms: Int, mailbox_ids: List(String)) -> model.Message {
  model.Message(
    ..snapshot_fixture.bare_message(id, at(ms)),
    mailbox_ids: mailbox_ids,
  )
}

/// A `UtcDate` at `ms`: the merge reads only `ms`, so the raw text is nominal.
fn at(ms: Int) -> model.UtcDate {
  model.UtcDate(raw: "2026-01-01T00:00:00Z", ms: ms)
}

fn rule(
  mailboxes: List(String),
  keep: Option(Int),
  after_ms: Option(Int),
) -> retain.Rule {
  retain.Rule(
    mailbox_ids: set.from_list(mailboxes),
    keep: keep,
    after_ms: after_ms,
  )
}

fn ids(messages: List(model.Message)) -> List(String) {
  list.map(messages, fn(message) { message.id })
}

/// A gone id is dropped, whatever the other steps would do with it.
pub fn merge_drops_gone_test() {
  let stored = [message("a", 100, ["mb-1"]), message("b", 200, ["mb-1"])]

  retain.merge(stored, [], [], set.from_list(["b"]), rule(["mb-1"], None, None))
  |> ids
  |> should.equal(["a"])
}

/// Refreshes are applied by id *before* the mailbox filter: a refresh that
/// moves a message out of the window drops it, while one that stays keeps the
/// refreshed fields. Kills filter-before-refresh, and filter with no refresh
/// at all.
pub fn merge_refresh_out_of_window_drops_test() {
  let stored = [message("a", 100, ["mb-1"])]
  let refresh = #(
    normalise.Light(id: "a", mailbox_ids: ["mb-2"], keywords: ["$seen"]),
    "state-2",
  )

  retain.merge(stored, [refresh], [], set.new(), rule(["mb-1"], None, None))
  |> should.equal([])

  let kept =
    retain.merge(stored, [refresh], [], set.new(), rule(["mb-2"], None, None))
  ids(kept) |> should.equal(["a"])
  let assert [kept_message] = kept
  kept_message.mailbox_ids |> should.equal(["mb-2"])
  kept_message.email_state |> should.equal("state-2")
  kept_message.is_seen |> should.be_true
}

/// Fetched wins on an id clash, and no refresh is applied to it afterwards: the
/// fetched message keeps its own state and flags. Kills appending `stored`
/// last, and refreshing after adding `fetched`.
pub fn merge_fetched_wins_test() {
  let stored = [
    model.Message(..message("a", 100, ["mb-1"]), subject: Some("stored")),
  ]
  let fetched = [
    model.Message(..message("a", 200, ["mb-1"]), subject: Some("fetched")),
  ]
  let refresh = #(
    normalise.Light(id: "a", mailbox_ids: ["mb-1"], keywords: ["$seen"]),
    "state-2",
  )

  let merged =
    retain.merge(
      stored,
      [refresh],
      fetched,
      set.new(),
      rule(["mb-1"], None, None),
    )

  ids(merged) |> should.equal(["a"])
  let assert [merged_message] = merged
  merged_message.subject |> should.equal(Some("fetched"))
  merged_message.received_at |> should.equal(at(200))
  merged_message.email_state |> should.equal("state-1")
  merged_message.is_seen |> should.be_false
}

/// `keep` is applied after the sort, so it trims the oldest: `stored` arrives
/// in ascending order, where "the first two" are not "the newest two".
pub fn merge_trims_to_keep_test() {
  let stored = [
    message("a", 100, ["mb-1"]),
    message("b", 200, ["mb-1"]),
    message("c", 300, ["mb-1"]),
  ]

  retain.merge(stored, [], [], set.new(), rule(["mb-1"], Some(2), None))
  |> ids
  |> should.equal(["c", "b"])
}

/// The bound is inclusive and applies to `fetched` too, because it follows
/// adding `fetched`. Kills an exclusive comparison and a bound on `stored` only.
pub fn merge_age_bound_some_drops_older_test() {
  let stored = [message("old", 100, ["mb-1"]), message("new", 300, ["mb-1"])]
  let fetched = [message("older", 50, ["mb-1"])]

  retain.merge(stored, [], fetched, set.new(), rule(["mb-1"], None, Some(200)))
  |> ids
  |> should.equal(["new"])

  retain.merge(stored, [], [], set.new(), rule(["mb-1"], None, Some(300)))
  |> ids
  |> should.equal(["new"])
}

/// `after_ms: None` keeps every age.
pub fn merge_age_bound_none_keeps_all_test() {
  let stored = [message("old", 100, ["mb-1"]), message("new", 300, ["mb-1"])]

  retain.merge(stored, [], [], set.new(), rule(["mb-1"], None, None))
  |> ids
  |> should.equal(["new", "old"])
}

/// Newest first by `normalise.compare_received`, reversed: milliseconds
/// descending, and within equal milliseconds ids descending. Kills ascending
/// order (a missing `list.reverse`) and a local comparison.
pub fn merge_orders_newest_first_test() {
  let stored = [
    message("m-300", 300, ["mb-1"]),
    message("m-100", 100, ["mb-1"]),
    message("tie-b", 200, ["mb-1"]),
    message("tie-d", 200, ["mb-1"]),
  ]

  retain.merge(stored, [], [], set.new(), rule(["mb-1"], None, None))
  |> ids
  |> should.equal(["m-300", "tie-d", "tie-b", "m-100"])
}
