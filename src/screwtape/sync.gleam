//// One bounded sync run (PHASE-05; design § 5.2 JMAP usage, § 5.4).
////
//// The opening request carries three calls — `Mailbox/get`, then an
//// `Email/get` and a `Thread/get` with no ids, which serve only the Email and
//// Thread states (ISS-001). Then phase 1 — `Email/query` pages that settle on
//// one coherent id list under a single `queryState` — then phase 2 —
//// `Email/get` over those ids, each once, in chunks of `maxObjectsInGet` —
//// then `Thread/get`, `normalise`, and one `store.write_snapshot`. Nothing is
//// written until every fetch has succeeded (DEC-008), so a failed run leaves
//// the store as it was (I2).
////
//// After the opening request every request carries one call through
//// `client.call_one` (A1) on the `Client` value the previous call handed back,
//// so the byte budget is spent across the whole run. The one exception is a
//// `cannotCalculateChanges` answer: the run continues on the `Client` held
//// before it, so its bytes are not charged (DEC-026). Nothing is retried.

import gleam/bool
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
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
import screwtape/retain
import screwtape/store.{type Writer}

/// What a run needs from the config: the window and the two run bounds.
pub type Bounds {
  Bounds(window: config.Window, max_pages: Int, max_body_bytes: Int)
}

/// How a run chose the messages to refresh (DEC-026): from `Email/changes`
/// since the Prior's state, or every stored one.
pub type Mode {
  Incremental
  Full
}

/// What a committed run reports (design § 5.2, the `sync` envelope's `data`).
/// `messages` and `threads` count stored rows; `truncated_bodies` and
/// `conversion_failures` count stored bodies; `not_found` counts the ids
/// `Email/get` no longer had; `states` are ordered by type name.
/// `fallback_reason` says why a run is `Full`, and is `None` for an
/// `Incremental` one.
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
    mode: Mode,
    fallback_reason: Option(String),
  )
}

/// Run one sync over a client already bound to its session, and commit the
/// snapshot through `writer`. `prior` is the committed store the run may reuse
/// (design § 5.4 Choosing the path): its messages are kept, subject to the
/// merge, when it is from the same server, account and body limit; under the
/// same window, only what `Email/changes` reports is refreshed, unless it
/// cannot say (a fallback to the full run with the Prior).
pub fn run(
  client: Client,
  writer: Writer,
  bounds: Bounds,
  prior: Option(model.Prior),
  now: Timestamp,
) -> Result(Summary, Error) {
  let session = jmap_client.session_of(client)
  let account_id = session.account_id
  let chunk_size = session.max_objects_in_get
  let now = whole_seconds(now)
  let window = bounds.window

  use #(client, opened) <- result.try(opening(
    client,
    account_id,
    bounds.max_body_bytes,
  ))
  use mailbox_ids <- result.try(resolve_mailboxes(
    opened.mailboxes,
    window.mailboxes,
  ))
  use #(client, scope) <- result.try(scope(
    client,
    choose(prior, session, bounds, mailbox_ids),
    opened.email_state,
    account_id,
    chunk_size,
    bounds.max_pages,
  ))
  let is_stored = set.contains(set.from_list(ids_of(scope.stored)), _)
  let filter =
    request.email_query_filter(mailbox_ids, after(now, window.max_age_days))
  let query =
    Query(
      account_id:,
      filter:,
      max_messages: window.max_messages,
      max_pages: bounds.max_pages,
    )
  use #(client, query_ids, query_record) <- result.try(case scope.carried {
    Some(record) -> Ok(#(client, [], record))
    None -> {
      use #(client, settled) <- result.map(query_ids(client, query, 0))
      #(client, settled.ids, query_row(filter, settled))
    }
  })
  use #(client, fetched) <- result.try(get_emails(
    client,
    account_id,
    list.filter(query_ids, fn(id) { !is_stored(id) }),
    chunk_size,
    bounds.max_body_bytes,
  ))
  use #(client, refreshed) <- result.try(get_lights(
    client,
    account_id,
    scope.refresh,
    chunk_size,
  ))
  let not_found = list.append(fetched.not_found, refreshed.not_found)
  let messages =
    retain.merge(
      scope.stored,
      refreshed.lights,
      fetched.messages,
      set.from_list(list.append(scope.gone, not_found)),
      rule(window, mailbox_ids, now),
    )
  use #(_client, threads) <- result.try(get_threads(
    client,
    account_id,
    distinct_thread_ids(messages),
    chunk_size,
  ))

  let snapshot =
    model.Snapshot(
      account: account_meta(session, window, synced_at(now)),
      // Ordered by type name.
      states: [
        model.TypeState("Email", scope.email_state),
        model.TypeState("Mailbox", opened.mailbox_state),
        model.TypeState("Thread", opened.thread_state),
      ],
      query: query_record,
      mailboxes: opened.mailboxes,
      messages:,
      threads:,
    )
  use Nil <- result.map(store.write_snapshot(writer, snapshot))
  summary(snapshot, list.length(not_found), scope.fallback_reason)
}

// ---------------------------------------------------------------- path

/// Why a run is full (design § 5.2 `sync.run`).
const no_state = "no_state"

const window_changed = "window_changed"

const cannot_calculate_changes = "cannot_calculate_changes"

const too_many_changes = "too_many_changes"

/// What a run starts from.
type Start {
  /// No usable Prior: everything in the window is fetched again.
  Fresh
  /// The Prior's messages, each light-refreshed and kept subject to the merge;
  /// `reason` says why the run is full.
  Reuse(prior: model.Prior, reason: String)
  /// The Prior's messages, refreshed where `Email/changes` reports a change.
  Changes(prior: model.Prior)
}

/// The run's start (design § 5.4 Choosing the path), before any call past the
/// opening request. A Prior from another server, account or body limit is
/// unusable: JMAP ids are unique only within one account on one server, and a
/// stored body is only as long as the limit it was fetched under. A usable
/// Prior over another window is reused, for `window_changed`.
fn choose(
  prior: Option(model.Prior),
  session: Session,
  bounds: Bounds,
  mailbox_ids: List(String),
) -> Start {
  case prior {
    None -> Fresh
    Some(prior) -> {
      use <- bool.guard(
        !is_usable(prior, session, bounds.max_body_bytes),
        Fresh,
      )
      use <- bool.guard(
        !is_same_window(prior, bounds.window, mailbox_ids),
        Reuse(prior, window_changed),
      )
      Changes(prior)
    }
  }
}

/// What a run refreshes once its start is settled (design § 5.4 Ids per run):
/// the stored messages the merge starts from, the stored ids to light-refresh,
/// the ids known destroyed, the Email state to store (I-M3), the Prior's
/// query record when nothing changed, so no `Email/query` runs, and why the
/// run is full (`None` for an incremental one).
type Scope {
  Scope(
    stored: List(model.Message),
    refresh: List(String),
    gone: List(String),
    email_state: String,
    carried: Option(model.QueryState),
    fallback_reason: Option(String),
  )
}

/// The scope of `start`. A full run stores the opening request's Email state;
/// an incremental one the last `newState`, returned before any `Email/get`,
/// so a change landing mid-run is reported again next run (I-M3). When
/// `Email/changes` cannot say what changed, the run falls back to `Reuse`.
fn scope(
  client: Client,
  start: Start,
  opening_state: String,
  account_id: String,
  max_changes: Int,
  max_pages: Int,
) -> Result(#(Client, Scope), Error) {
  case start {
    Fresh ->
      Ok(#(client, Scope([], [], [], opening_state, None, Some(no_state))))
    Reuse(prior, reason) -> Ok(#(client, reuse(prior, reason, opening_state)))
    Changes(prior) -> {
      let since = Delta(prior.email_state, set.new(), set.new())
      use #(client, change_set) <- result.map(changes(
        client,
        account_id,
        max_changes,
        max_pages,
        since,
        0,
      ))
      case change_set {
        Known(delta) -> #(client, incremental(prior, delta))
        Unknown(reason) -> #(client, reuse(prior, reason, opening_state))
      }
    }
  }
}

/// A full run with the Prior: every stored id is light-refreshed.
fn reuse(prior: model.Prior, reason: String, opening_state: String) -> Scope {
  Scope(
    stored: prior.messages,
    refresh: ids_of(prior.messages),
    gone: [],
    email_state: opening_state,
    carried: None,
    fallback_reason: Some(reason),
  )
}

/// An incremental run over `delta`: only changed stored ids are refreshed, and
/// with nothing changed the Prior's query record is carried.
fn incremental(prior: model.Prior, delta: Delta) -> Scope {
  let changed = set.difference(delta.changed, delta.destroyed)
  let is_unchanged = set.is_empty(changed) && set.is_empty(delta.destroyed)
  Scope(
    stored: prior.messages,
    refresh: list.filter(ids_of(prior.messages), set.contains(changed, _)),
    gone: set.to_list(delta.destroyed),
    email_state: delta.new_state,
    carried: case is_unchanged {
      True -> Some(prior.query)
      False -> None
    },
    fallback_reason: None,
  )
}

/// The changes since a state, folded across pages (design § 5.4 Accumulating
/// changes): the latest `newState`, the ids created or updated, and the ids
/// destroyed. Destroyed wins over changed once the pages are done.
type Delta {
  Delta(new_state: String, changed: Set(String), destroyed: Set(String))
}

/// What `Email/changes` answered: the changes when they are known, else why
/// they are not.
type ChangeSet {
  Known(Delta)
  Unknown(reason: String)
}

/// `Email/changes` from `delta.new_state`, `max_changes` ids at most per page,
/// paging while `hasMoreChanges`, at most `max_pages` pages. Two answers are
/// `Unknown` (design § 5.4 Choosing the path): more pages than `max_pages`,
/// with the pages spent, and `cannotCalculateChanges`, with the client held
/// before that call, so its error bytes are not charged (DEC-026).
fn changes(
  client: Client,
  account_id: String,
  max_changes: Int,
  max_pages: Int,
  delta: Delta,
  pages: Int,
) -> Result(#(Client, ChangeSet), Error) {
  use <- bool.guard(
    pages >= max_pages,
    Ok(#(client, Unknown(too_many_changes))),
  )
  let method = request.method_name(request.EmailChanges)
  let answer =
    call(
      client,
      request.email_changes(
        account_id,
        delta.new_state,
        max_changes,
        request.call_id,
      ),
      decode.email_changes,
    )
  case answer {
    Error(error.JmapMethod(failed, "cannotCalculateChanges"))
      if failed == method
    -> Ok(#(client, Unknown(cannot_calculate_changes)))
    Error(error) -> Error(error)
    Ok(#(client, page)) ->
      case page.has_more {
        True ->
          changes(
            client,
            account_id,
            max_changes,
            max_pages,
            fold(delta, page),
            pages + 1,
          )
        False -> Ok(#(client, Known(fold(delta, page))))
      }
  }
}

/// `delta` with one more page: its `newState`, and its ids added.
fn fold(delta: Delta, page: decode.ChangesPage) -> Delta {
  Delta(
    new_state: page.new_state,
    changed: delta.changed
      |> set.union(set.from_list(page.created))
      |> set.union(set.from_list(page.updated)),
    destroyed: set.union(delta.destroyed, set.from_list(page.destroyed)),
  )
}

fn ids_of(messages: List(model.Message)) -> List(String) {
  list.map(messages, fn(message) { message.id })
}

/// The Prior was synced from this server and account, and every stored body
/// under `max_body_bytes`. A store with no bodies has no limit to differ.
fn is_usable(
  prior: model.Prior,
  session: Session,
  max_body_bytes: Int,
) -> Bool {
  prior.api_url == session.api_url
  && prior.account_id == session.account_id
  && list.all(prior.messages, fn(message) {
    list.all(message.bodies, fn(body) {
      body.max_body_value_bytes == max_body_bytes
    })
  })
}

/// The Prior was synced under this window: the same `window_json`, and the
/// configured entries resolve to the same mailbox ids against its mailboxes as
/// against the server's now (a rename or a role reassignment does not).
fn is_same_window(
  prior: model.Prior,
  window: config.Window,
  mailbox_ids: List(String),
) -> Bool {
  prior.window_json == config.window_json(window)
  && case resolve_mailboxes(prior.mailboxes, window.mailboxes) {
    Ok(ids) -> set.from_list(ids) == set.from_list(mailbox_ids)
    Error(_) -> False
  }
}

/// The retention rule (DEC-024, DEC-025): the window's mailboxes; keep
/// `retain_messages`, else `max_messages`; and the age bound only when
/// retention does not extend the window.
fn rule(
  window: config.Window,
  mailbox_ids: List(String),
  now: Timestamp,
) -> retain.Rule {
  retain.Rule(
    mailbox_ids: set.from_list(mailbox_ids),
    keep: option.or(window.retain_messages, window.max_messages),
    after_ms: case window.retain_messages {
      Some(_) -> None
      None ->
        age_bound(now, window.max_age_days)
        |> option.map(fn(bound) { unix_seconds(bound) * 1000 })
    },
  )
}

// ---------------------------------------------------------------- clock

/// `now` without its sub-second part: `to_rfc3339` then prints no fraction
/// (A11), so `synced_at` and `after` read `…T09:00:00Z`.
fn whole_seconds(now: Timestamp) -> Timestamp {
  timestamp.from_unix_seconds(unix_seconds(now))
}

fn unix_seconds(time: Timestamp) -> Int {
  let #(seconds, _) = timestamp.to_unix_seconds_and_nanoseconds(time)
  seconds
}

fn rfc3339(time: Timestamp) -> String {
  timestamp.to_rfc3339(time, calendar.utc_offset)
}

// A whole-second timestamp as a `UtcDate`: its RFC 3339 text and epoch
// milliseconds, the value `normalise.utc_date` would parse back from that
// text. Built directly, so the run needs no error for a parse that cannot fail.
fn synced_at(now: Timestamp) -> model.UtcDate {
  model.UtcDate(raw: rfc3339(now), ms: unix_seconds(now) * 1000)
}

/// The `after` bound of a window with an age limit, as `Email/query` sends it.
fn after(now: Timestamp, max_age_days: Option(Int)) -> Option(String) {
  option.map(age_bound(now, max_age_days), rfc3339)
}

/// `max_age_days` before now, for a window with an age limit.
fn age_bound(now: Timestamp, max_age_days: Option(Int)) -> Option(Timestamp) {
  use days <- option.map(max_age_days)
  timestamp.add(now, duration.hours(-24 * days))
}

// ---------------------------------------------------------------- calls

/// What the opening request yields: the mailboxes, and the state of each type
/// the run starts from (ISS-001).
type Opened {
  Opened(
    mailboxes: List(model.Mailbox),
    mailbox_state: String,
    email_state: String,
    thread_state: String,
  )
}

/// The opening request: its three calls sent together, their answers matched
/// by position (D1).
fn opening(
  client: Client,
  account_id: String,
  max_body_bytes: Int,
) -> Result(#(Client, Opened), Error) {
  use #(client, responses) <- result.try(jmap_client.call(
    client,
    request.opening(account_id, max_body_bytes),
  ))
  case responses {
    [mailbox, email, thread] -> {
      use #(mailboxes, mailbox_state) <- result.try(decode.mailboxes(mailbox))
      use email_state <- result.try(decode.state(email))
      use thread_state <- result.try(decode.state(thread))
      Ok(#(
        client,
        Opened(mailboxes:, mailbox_state:, email_state:, thread_state:),
      ))
    }
    // Unreachable while `call` holds D1; kept so the match stays total.
    _ -> Error(error.Decode("methodResponses"))
  }
}

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

/// The messages of every `Email/get` and the ids the server no longer had.
type Fetched {
  Fetched(messages: List(model.Message), not_found: List(String))
}

/// The mutable fields of every light `Email/get`, each with its page's state,
/// and the ids the server no longer had.
type Refreshed {
  Refreshed(lights: List(#(normalise.Light, String)), not_found: List(String))
}

fn get_emails(
  client: Client,
  account_id: String,
  ids: List(String),
  chunk_size: Int,
  max_body_bytes: Int,
) -> Result(#(Client, Fetched), Error) {
  use #(client, pages) <- result.map(
    get_chunked(
      client,
      ids,
      chunk_size,
      request.email_get(account_id, _, max_body_bytes, request.call_id),
      decode.emails,
      fn(page) {
        #(list.map(page.emails, fn(email) { email.id }), page.not_found)
      },
    ),
  )
  let messages =
    list.flat_map(pages, fn(page) {
      list.map(page.emails, normalise.message(_, page.state, max_body_bytes))
    })
  let not_found = list.flat_map(pages, fn(page) { page.not_found })
  #(client, Fetched(messages:, not_found:))
}

/// The light refresh of `ids` (DEC-026): their mutable fields only, over the
/// same chunked loop as the full get.
fn get_lights(
  client: Client,
  account_id: String,
  ids: List(String),
  chunk_size: Int,
) -> Result(#(Client, Refreshed), Error) {
  use #(client, pages) <- result.map(
    get_chunked(
      client,
      ids,
      chunk_size,
      request.email_get_light(account_id, _, request.call_id),
      decode.light_emails,
      fn(page) {
        #(list.map(page.lights, fn(light) { light.id }), page.not_found)
      },
    ),
  )
  let lights =
    list.flat_map(pages, fn(page) {
      list.map(page.lights, fn(light) { #(light, page.state) })
    })
  let not_found = list.flat_map(pages, fn(page) { page.not_found })
  #(client, Refreshed(lights:, not_found:))
}

/// One `Email/get` loop for every kind of get (POL-001): `ids` in chunks of
/// `chunk_size`, each sent as `invoke(chunk)` and decoded by `decoder`, whose
/// page `answered` splits into the ids returned and the ids not found. Each
/// page holds only ids its chunk asked for, and answers every one of them.
fn get_chunked(
  client: Client,
  ids: List(String),
  chunk_size: Int,
  invoke: fn(List(String)) -> request.Invocation,
  decoder: fn(MethodResponse) -> Result(page, Error),
  answered: fn(page) -> #(List(String), List(String)),
) -> Result(#(Client, List(page)), Error) {
  use client, chunk <- in_chunks(client, ids, chunk_size)
  use #(client, page) <- result.try(call(client, invoke(chunk), decoder))
  let #(returned, not_found) = answered(page)
  use Nil <- result.try(only_requested(chunk, returned, "list"))
  // `notFound` removes stored messages (`gone`), so it too must be asked for.
  use Nil <- result.try(only_requested(chunk, not_found, "notFound"))
  use Nil <- result.map(all_answered(chunk, returned, not_found))
  #(client, page)
}

/// The threads of `thread_ids`, in chunk order.
fn get_threads(
  client: Client,
  account_id: String,
  thread_ids: List(String),
  chunk_size: Int,
) -> Result(#(Client, List(model.Thread)), Error) {
  use #(client, pages) <- result.map(
    in_chunks(client, thread_ids, chunk_size, fn(client, chunk) {
      use #(client, page) <- result.try(call(
        client,
        request.thread_get(account_id, chunk, request.call_id),
        decode.threads,
      ))
      let returned = list.map(page, fn(thread) { thread.id })
      use Nil <- result.map(only_requested(chunk, returned, "list"))
      #(client, page)
    }),
  )
  #(client, list.flatten(pages))
}

/// A get's `field` (`list` or `notFound`) holds only ids the chunk asked for
/// (RFC 8620 § 5.1): an object outside the window would break I3, and a
/// stranger in `notFound` would remove a stored message.
fn only_requested(
  requested: List(String),
  returned: List(String),
  field: String,
) -> Result(Nil, Error) {
  let requested = set.from_list(requested)
  case list.all(returned, set.contains(requested, _)) {
    True -> Ok(Nil)
    False -> Error(error.Decode(field))
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

/// The distinct thread ids of `messages`, sorted: a canonical order that does
/// not depend on where each message came from (fetched, refreshed or kept).
fn distinct_thread_ids(messages: List(model.Message)) -> List(String) {
  messages
  |> list.map(fn(message) { message.thread_id })
  |> list.unique
  |> list.sort(string.compare)
}

/// `fetch` over `items` in chunks of `size`, threading the client, stopping at
/// the first error. No items is no chunk, so no request.
fn in_chunks(
  client: Client,
  items: List(String),
  size: Int,
  fetch: fn(Client, List(String)) -> Result(#(Client, a), Error),
) -> Result(#(Client, List(a)), Error) {
  items
  |> list.sized_chunk(size)
  |> list.try_fold(#(client, []), fn(acc, chunk) {
    let #(client, results) = acc
    use #(client, result) <- result.map(fetch(client, chunk))
    #(client, [result, ..results])
  })
  |> result.map(fn(acc) {
    let #(client, results) = acc
    #(client, list.reverse(results))
  })
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

/// The summary of a committed `snapshot`; a run with a `fallback_reason` is
/// full.
fn summary(
  snapshot: model.Snapshot,
  not_found: Int,
  fallback_reason: Option(String),
) -> Summary {
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
    mode: case fallback_reason {
      None -> Incremental
      Some(_) -> Full
    },
    fallback_reason:,
  )
}
