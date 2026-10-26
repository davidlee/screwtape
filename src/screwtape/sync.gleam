//// One bounded sync run (PHASE-05; design § 5.2 JMAP usage, § 5.4).
////
//// Mailbox/get, then phase 1 — `Email/query` pages that settle on one
//// coherent id list under a single `queryState` — then phase 2 — `Email/get`
//// over those ids, each once, in chunks of `maxObjectsInGet` — then
//// `Thread/get`, `normalise`, and one `store.write_snapshot`. Nothing is
//// written until every fetch has succeeded (DEC-008), so a failed run leaves
//// the store as it was (I2).
////
//// Every call goes through `client.call_one` (one call per request, A1) on the
//// `Client` value the previous call handed back, so the byte budget is spent
//// across the whole run. Nothing is retried.

import gleam/bool
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import screwtape/config
import screwtape/error.{type Error}
import screwtape/jmap/client.{type Client} as jmap_client
import screwtape/jmap/decode.{type MethodResponse, type QueryPage, type Session}
import screwtape/jmap/request
import screwtape/model
import screwtape/normalise
import screwtape/store.{type Writer}

/// What a run needs from the config: the window and the two run bounds.
pub type Bounds {
  Bounds(window: config.Window, max_pages: Int, max_body_bytes: Int)
}

/// What a committed run reports (design § 5.2, the `sync` envelope's `data`).
/// `messages` and `threads` count stored rows; `truncated_bodies` and
/// `conversion_failures` count stored bodies; `not_found` counts the ids
/// `Email/get` no longer had; `states` are ordered by type name.
pub type Summary {
  Summary(
    account_id: String,
    synced_at: model.UtcDate,
    mailboxes: Int,
    messages: Int,
    threads: Int,
    truncated_bodies: Int,
    not_found: Int,
    conversion_failures: Int,
    states: List(model.TypeState),
    is_read_only: Bool,
  )
}

/// Run one sync over a client already bound to its session, and commit the
/// snapshot through `writer`.
pub fn run(
  client: Client,
  writer: Writer,
  bounds: Bounds,
  now: Timestamp,
) -> Result(Summary, Error) {
  let session = jmap_client.session_of(client)
  let account_id = session.account_id
  let chunk_size = session.max_objects_in_get
  let now = whole_seconds(now)
  let window = bounds.window

  use #(client, #(mailboxes, mailbox_state)) <- result.try(call(
    client,
    request.mailbox_get(account_id, request.call_id),
    decode.mailboxes,
  ))
  use mailbox_ids <- result.try(resolve_mailboxes(mailboxes, window.mailboxes))
  let filter =
    request.email_query_filter(mailbox_ids, after(now, window.max_age_days))
  let query =
    Query(
      account_id:,
      filter:,
      max_messages: window.max_messages,
      max_pages: bounds.max_pages,
    )
  use #(client, settled) <- result.try(query_ids(client, query, 0))
  use #(client, fetched) <- result.try(get_emails(
    client,
    account_id,
    settled.ids,
    chunk_size,
    bounds.max_body_bytes,
  ))
  use #(_client, #(threads, thread_state)) <- result.try(get_threads(
    client,
    account_id,
    distinct_thread_ids(fetched.messages),
    chunk_size,
  ))

  let snapshot =
    model.Snapshot(
      account: account_meta(session, window, synced_at(now)),
      // Ordered by type name.
      states: [
        model.TypeState("Email", fetched.state),
        model.TypeState("Mailbox", mailbox_state),
        model.TypeState("Thread", thread_state),
      ],
      query: query_row(filter, settled),
      mailboxes:,
      messages: fetched.messages,
      threads:,
    )
  use Nil <- result.map(store.write_snapshot(writer, snapshot))
  summary(snapshot, fetched.not_found)
}

// ---------------------------------------------------------------- clock

/// `now` without its sub-second part: `to_rfc3339` then prints no fraction
/// (A11), so `synced_at` and `after` read `…T09:00:00Z`.
fn whole_seconds(now: Timestamp) -> Timestamp {
  let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(now)
  timestamp.from_unix_seconds(seconds)
}

fn rfc3339(time: Timestamp) -> String {
  timestamp.to_rfc3339(time, calendar.utc_offset)
}

// A whole-second timestamp as a `UtcDate`: its RFC 3339 text and epoch
// milliseconds, the value `normalise.utc_date` would parse back from that
// text. Built directly, so the run needs no error for a parse that cannot fail.
fn synced_at(now: Timestamp) -> model.UtcDate {
  let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(now)
  model.UtcDate(raw: rfc3339(now), ms: seconds * 1000)
}

/// The `after` bound of a window with an age limit: `max_age_days` before now.
fn after(now: Timestamp, max_age_days: Option(Int)) -> Option(String) {
  use days <- option.map(max_age_days)
  rfc3339(timestamp.add(now, duration.hours(-24 * days)))
}

// ---------------------------------------------------------------- calls

/// One call, its response decoded, and the client it hands back (which
/// carries the budget left).
fn call(
  client: Client,
  invocation: request.Invocation,
  decoder: fn(MethodResponse) -> Result(a, Error),
) -> Result(#(Client, a), Error) {
  use #(client, response) <- result.try(jmap_client.call_one(client, invocation))
  use value <- result.map(decoder(response))
  #(client, value)
}

// ---------------------------------------------------------------- mailboxes

/// The ids of the window's mailboxes, in config order, each once (A6). An
/// entry names the mailboxes with that role, else those with that exact name;
/// an entry naming none is `Config("unknown_mailbox")`.
fn resolve_mailboxes(
  mailboxes: List(model.Mailbox),
  window: List(String),
) -> Result(List(String), Error) {
  window
  |> list.try_map(fn(entry) {
    case model.mailboxes_matching(mailboxes, entry) {
      [] -> Error(error.Config("unknown_mailbox"))
      matches -> Ok(matches)
    }
  })
  |> result.map(fn(matches) {
    matches |> list.flatten |> list.map(fn(m) { m.id }) |> list.unique
  })
}

// ---------------------------------------------------------------- phase 1

/// What every page of phase 1 asks with.
type Query {
  Query(
    account_id: String,
    filter: json.Json,
    max_messages: Option(Int),
    max_pages: Int,
  )
}

/// One attempt's progress: pages sent, where the next starts, the server's
/// latest clamp, the ids so far, and the attempt's first page (`None` until it
/// arrives), whose `queryState` every later page must match (A5).
type Attempt {
  Attempt(
    pages: Int,
    position: Int,
    clamp: Option(Int),
    ids: Collected,
    first: Option(QueryPage),
  )
}

/// Ids in first-seen order (held reversed), each once (A7).
type Collected {
  Collected(reversed: List(String), seen: Set(String), count: Int)
}

/// The id list phase 1 settled on, with its attempt's first-page values.
type Settled {
  Settled(ids: List(String), query_state: String, can_calculate_changes: Bool)
}

/// How an attempt ended without an error.
type Outcome {
  Complete(Settled)
  StateMoved
}

/// A run tolerates this many restarts; one more mismatch is `QueryUnstable`.
const max_restarts = 2

/// Phase 1: attempts from position 0 until one completes under a single
/// `queryState`.
fn query_ids(
  client: Client,
  query: Query,
  restarts: Int,
) -> Result(#(Client, Settled), Error) {
  let fresh = Attempt(0, 0, None, Collected([], set.new(), 0), None)
  use #(client, outcome) <- result.try(query_pages(client, query, fresh))
  case outcome {
    Complete(settled) -> Ok(#(client, settled))
    StateMoved if restarts < max_restarts ->
      query_ids(client, query, restarts + 1)
    StateMoved -> Error(error.QueryUnstable)
  }
}

/// The pages of one attempt, at most `max_pages` of them (A4).
fn query_pages(
  client: Client,
  query: Query,
  attempt: Attempt,
) -> Result(#(Client, Outcome), Error) {
  use <- bool.guard(
    attempt.pages >= query.max_pages,
    Error(error.LimitExceeded("max_pages")),
  )
  let limit = next_limit(query.max_messages, attempt.ids.count, attempt.clamp)
  use #(client, page) <- result.try(call(
    client,
    request.email_query(
      query.account_id,
      query.filter,
      attempt.position,
      limit,
      request.call_id,
    ),
    decode.email_query,
  ))
  let first = option.unwrap(attempt.first, page)
  case first.query_state == page.query_state {
    False -> Ok(#(client, StateMoved))
    True -> {
      let attempt =
        Attempt(
          pages: attempt.pages + 1,
          position: page.position + list.length(page.ids),
          // A clamp holds until the server names another (F9).
          clamp: option.or(page.limit, attempt.clamp),
          ids: collect(attempt.ids, page.ids, query.max_messages),
          first: Some(first),
        )
      case is_last_page(page, limit, attempt.ids.count, query.max_messages) {
        True -> Ok(#(client, Complete(settled(attempt.ids, first))))
        False -> query_pages(client, query, attempt)
      }
    }
  }
}

/// The `limit` of the next page (A3): the messages still wanted, at most the
/// server's clamp; `None` when neither is known.
fn next_limit(
  max_messages: Option(Int),
  collected: Int,
  clamp: Option(Int),
) -> Option(Int) {
  let remaining = option.map(max_messages, fn(max) { max - collected })
  case remaining, clamp {
    Some(remaining), Some(clamp) -> Some(int.min(remaining, clamp))
    Some(remaining), None -> Some(remaining)
    None, clamp -> clamp
  }
}

/// Whether `page`, asked for with `requested`, ends phase 1 (A3): the window
/// is full, the page is shorter than its effective size (the server's limit,
/// else the one asked for), it reaches `total`, or it is empty.
fn is_last_page(
  page: QueryPage,
  requested: Option(Int),
  collected: Int,
  max_messages: Option(Int),
) -> Bool {
  let length = list.length(page.ids)
  let is_full = case max_messages {
    Some(max) -> collected >= max
    None -> False
  }
  let is_short = case option.or(page.limit, requested) {
    Some(size) -> length < size
    None -> False
  }
  is_full || is_short || page.position + length >= page.total || length == 0
}

/// `collected` with the new ids of a page, in first-seen order, up to
/// `max_messages` in all: a page longer than the window still wants is cut
/// there (I4), and the full window then ends phase 1.
fn collect(
  collected: Collected,
  ids: List(String),
  max_messages: Option(Int),
) -> Collected {
  use collected, id <- list.fold_until(ids, collected)
  let is_full = case max_messages {
    Some(max) -> collected.count >= max
    None -> False
  }
  use <- bool.guard(is_full, list.Stop(collected))
  case set.contains(collected.seen, id) {
    True -> list.Continue(collected)
    False ->
      list.Continue(Collected(
        reversed: [id, ..collected.reversed],
        seen: set.insert(collected.seen, id),
        count: collected.count + 1,
      ))
  }
}

fn settled(ids: Collected, first: QueryPage) -> Settled {
  Settled(
    ids: list.reverse(ids.reversed),
    query_state: first.query_state,
    can_calculate_changes: first.can_calculate_changes,
  )
}

// ---------------------------------------------------------------- phase 2

/// The messages of every `Email/get`, the earliest Email state, and how many
/// ids the server no longer had.
type Fetched {
  Fetched(messages: List(model.Message), state: String, not_found: Int)
}

fn get_emails(
  client: Client,
  account_id: String,
  ids: List(String),
  chunk_size: Int,
  max_body_bytes: Int,
) -> Result(#(Client, Fetched), Error) {
  use #(client, first, rest) <- result.map(
    in_chunks(client, ids, chunk_size, fn(client, chunk) {
      use #(client, page) <- result.try(call(
        client,
        request.email_get(account_id, chunk, max_body_bytes, request.call_id),
        decode.emails,
      ))
      let returned = list.map(page.emails, fn(email) { email.id })
      use Nil <- result.try(only_requested(chunk, returned))
      use Nil <- result.map(all_answered(chunk, returned, page.not_found))
      #(client, page)
    }),
  )
  let pages = [first, ..rest]
  let messages =
    list.flat_map(pages, fn(page) {
      list.map(page.emails, normalise.message(_, page.state, max_body_bytes))
    })
  let not_found =
    int.sum(list.map(pages, fn(page) { list.length(page.not_found) }))
  #(client, Fetched(messages:, state: first.state, not_found:))
}

/// The threads of `thread_ids` and the earliest Thread state.
fn get_threads(
  client: Client,
  account_id: String,
  thread_ids: List(String),
  chunk_size: Int,
) -> Result(#(Client, #(List(model.Thread), String)), Error) {
  use #(client, first, rest) <- result.map(
    in_chunks(client, thread_ids, chunk_size, fn(client, chunk) {
      use #(client, page) <- result.try(call(
        client,
        request.thread_get(account_id, chunk, request.call_id),
        decode.threads,
      ))
      let returned = list.map(page.0, fn(thread) { thread.id })
      use Nil <- result.map(only_requested(chunk, returned))
      #(client, page)
    }),
  )
  let #(_, state) = first
  #(client, #(list.flat_map([first, ..rest], fn(page) { page.0 }), state))
}

/// A get's `list` holds only ids the chunk asked for (RFC 8620 § 5.1): an
/// object outside the window would break I3.
fn only_requested(
  requested: List(String),
  returned: List(String),
) -> Result(Nil, Error) {
  let requested = set.from_list(requested)
  case list.all(returned, set.contains(requested, _)) {
    True -> Ok(Nil)
    False -> Error(error.Decode("list"))
  }
}

/// Every id a get asked for comes back in `list` or `notFound` (RFC 8620
/// § 5.1), so no message drops out of the window silently.
fn all_answered(
  requested: List(String),
  returned: List(String),
  not_found: List(String),
) -> Result(Nil, Error) {
  let answered = set.from_list(list.append(returned, not_found))
  case list.all(requested, set.contains(answered, _)) {
    True -> Ok(Nil)
    False -> Error(error.Decode("notFound"))
  }
}

/// The distinct thread ids of `messages`, in first-seen order (A8).
fn distinct_thread_ids(messages: List(model.Message)) -> List(String) {
  messages |> list.map(fn(message) { message.thread_id }) |> list.unique
}

/// `fetch` over `items` in chunks of `size`, threading the client, stopping at
/// the first error. The first chunk's result comes apart from the rest, so
/// the earliest state needs no fallback.
fn in_chunks(
  client: Client,
  items: List(String),
  size: Int,
  fetch: fn(Client, List(String)) -> Result(#(Client, a), Error),
) -> Result(#(Client, a, List(a)), Error) {
  let #(first_chunk, later_chunks) = chunks(items, size)
  use #(client, first) <- result.try(fetch(client, first_chunk))
  use #(client, later) <- result.map(
    list.try_fold(later_chunks, #(client, []), fn(acc, chunk) {
      let #(client, results) = acc
      use #(client, result) <- result.map(fetch(client, chunk))
      #(client, [result, ..results])
    }),
  )
  #(client, first, list.reverse(later))
}

/// `items` in chunks of at most `size`, first chunk apart. There is always a
/// first chunk: no items is one empty chunk, so an empty window still sends
/// one get of each type and records its state (A9).
fn chunks(items: List(a), size: Int) -> #(List(a), List(List(a))) {
  case list.sized_chunk(items, size) {
    [first, ..rest] -> #(first, rest)
    [] -> #([], [])
  }
}

// ---------------------------------------------------------------- snapshot

fn account_meta(
  session: Session,
  window: config.Window,
  synced_at: model.UtcDate,
) -> model.AccountMeta {
  model.AccountMeta(
    account_id: session.account_id,
    synced_at:,
    api_url: session.api_url,
    window_json: config.window_json(window),
    max_objects_in_get: session.max_objects_in_get,
    max_calls_in_request: session.max_calls_in_request,
    is_read_only: session.is_read_only,
  )
}

/// The `query_state` row: the filter and sort as sent, and the settled
/// attempt's values (A5).
fn query_row(filter: json.Json, settled: Settled) -> model.QueryState {
  model.QueryState(
    filter_json: json.to_string(filter),
    sort_json: json.to_string(request.email_query_sort()),
    collapse_threads: False,
    query_state: settled.query_state,
    can_calculate_changes: settled.can_calculate_changes,
  )
}

/// The summary of a committed `snapshot`.
fn summary(snapshot: model.Snapshot, not_found: Int) -> Summary {
  let bodies = list.flat_map(snapshot.messages, fn(message) { message.bodies })
  Summary(
    account_id: snapshot.account.account_id,
    synced_at: snapshot.account.synced_at,
    mailboxes: list.length(snapshot.mailboxes),
    messages: list.length(snapshot.messages),
    threads: list.length(snapshot.threads),
    truncated_bodies: list.count(bodies, fn(body) { body.is_truncated }),
    not_found:,
    conversion_failures: list.count(bodies, fn(body) { body.conversion_failed }),
    states: snapshot.states,
    is_read_only: snapshot.account.is_read_only,
  )
}
