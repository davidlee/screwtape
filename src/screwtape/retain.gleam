//// Apply the retention window to the messages a sync run holds (PHASE-02,
//// design § 5.2, DEC-025): drop what is gone, fold in refreshes and fetches,
//// then bound the window by mailbox, age and count.
////
//// Pure. This module imports only `gleam_stdlib`, `screwtape/model` and
//// `screwtape/normalise` (invariant I5, enforced by `just check-imports`), so it
//// cannot do I/O: the caller fetches, this decides what the account keeps.

import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import screwtape/model
import screwtape/normalise

/// The retention window: the resolved mailbox ids, how many messages to keep,
/// and, only when `retain_messages` is `None`, how old a message may be.
pub type Rule {
  Rule(mailbox_ids: Set(String), keep: Option(Int), after_ms: Option(Int))
}

/// The messages to keep, newest first (design § 5.2, DEC-025). The seven steps
/// run in order: refreshes are applied before the mailbox filter, `fetched` is
/// added before the age bound, and `keep` trims after the sort.
pub fn merge(
  stored: List(model.Message),
  refreshes: List(#(normalise.Light, String)),
  fetched: List(model.Message),
  gone: Set(String),
  rule: Rule,
) -> List(model.Message) {
  stored
  |> list.filter(fn(message) { !set.contains(gone, message.id) })
  |> refresh_all(refreshes)
  |> add_fetched(fetched)
  |> list.filter(fn(message) {
    list.any(message.mailbox_ids, fn(id) { set.contains(rule.mailbox_ids, id) })
  })
  |> within(rule.after_ms)
  |> list.sort(normalise.compare_received)
  |> list.reverse()
  |> take(rule.keep)
}

/// Step 2: apply each refresh to the message with its id. A refresh whose id is
/// absent from `messages` is dropped.
fn refresh_all(
  messages: List(model.Message),
  refreshes: List(#(normalise.Light, String)),
) -> List(model.Message) {
  let by_id =
    refreshes
    |> list.map(fn(refresh) { #({ refresh.0 }.id, refresh) })
    |> dict.from_list
  list.map(messages, fn(message) {
    case dict.get(by_id, message.id) {
      Ok(#(light, state)) -> normalise.refresh(message, light, state)
      Error(Nil) -> message
    }
  })
}

/// Step 3: add `fetched`; on an id clash `fetched` wins.
fn add_fetched(
  stored: List(model.Message),
  fetched: List(model.Message),
) -> List(model.Message) {
  let fetched_ids =
    fetched |> list.map(fn(message) { message.id }) |> set.from_list
  stored
  |> list.filter(fn(message) { !set.contains(fetched_ids, message.id) })
  |> list.append(fetched)
}

/// Step 5: keep those received at or after the bound, when there is one.
fn within(
  messages: List(model.Message),
  after_ms: Option(Int),
) -> List(model.Message) {
  case after_ms {
    Some(bound) ->
      list.filter(messages, fn(message) { message.received_at.ms >= bound })
    None -> messages
  }
}

/// Step 7: take the first `keep` messages, when there is a count.
fn take(
  messages: List(model.Message),
  keep: Option(Int),
) -> List(model.Message) {
  case keep {
    Some(count) -> list.take(messages, count)
    None -> messages
  }
}
