//// The accepted command line (design § 5.2 CLI; PHASE-06 A2/A4/A5/D6): argv
//// in, one `Command` out, or the one `Usage`.
////
//// argv is `--config <path> <verb> [args]`: `sync`, or one of the read verbs
//// `mailboxes`, `list`, `read` and `thread` (PHASE-06, D7). `parse` turns it
//// into one `Command`; every shape it does not accept is a `Usage`, whose
//// reason is a fixed code and never one of the arguments (I1).
////
//// Pure: no file, no environment, no store. `list`'s flags may come in any
//// order, each at most once (A5); the page size and start default when no flag
//// names them, and `--since YYYY-MM-DD` is turned into the midnight-UTC instant
//// it names (A2). `--after <cursor>` instead starts the page strictly past a
//// position the consumer held, oldest first (C2, C3); it may not be combined
//// with `--offset`. `read <id> [--max-bytes n]` and `thread <id> [--limit n]`
//// (A7) take no other flag, and `sync` and `mailboxes` take no argument at all.

import gleam/int
import gleam/option.{type Option, None, Some, is_some, unwrap}
import gleam/result
import gleam/string
import screwtape/cursor.{type Cursor}
import screwtape/error.{type Error}
import screwtape/normalise

/// One accepted invocation: the config file to read and the verb to run.
pub type Command {
  Command(config_path: String, verb: Verb)
}

/// The verbs the CLI serves.
pub type Verb {
  Sync
  Mailboxes
  List(filters: Filters, page: Page)
  Read(id: String, max_bytes: Option(Int))
  Thread(id: String, limit: Int)
}

/// `list`'s checked filters with their defaults applied; `since_ms` is the
/// midnight-UTC instant a `--since YYYY-MM-DD` names (A2).
pub type Filters {
  Filters(
    mailbox: Option(String),
    since_ms: Option(Int),
    from: Option(String),
    unread: Bool,
  )
}

/// Which page `list` asks for (C2): the newest first from an `offset`, or the
/// oldest first strictly after a cursor the consumer held.
pub type Page {
  Offset(limit: Int, offset: Int)
  After(limit: Int, after: Cursor)
}

/// The page size `list` and `thread` use when no flag names them, and the range
/// `--limit` and `--offset` accept (A5): `--offset` reaches SQLite's signed
/// 64-bit maximum, because a larger value cannot be bound.
const default_limit = 50

const default_offset = 0

const min_limit = 1

const max_limit = 500

const max_offset = 9_223_372_036_854_775_807

/// The accepted command line: `--config <path> <verb> [args]`. Every other
/// shape is a `Usage` whose reason is a fixed code, never an argument.
pub fn parse(argv: List(String)) -> Result(Command, Error) {
  case argv {
    [] -> usage("missing_command")
    ["--config"] -> usage("missing_config_path")
    ["--config", _] -> usage("missing_verb")
    ["--config", path, verb, ..args] -> verb_command(path, verb, args)
    _ -> usage("unknown_argument")
  }
}

fn verb_command(
  path: String,
  verb: String,
  args: List(String),
) -> Result(Command, Error) {
  case verb, args {
    "sync", [] -> Ok(Command(path, Sync))
    "sync", _ -> usage("unexpected_argument")
    "mailboxes", [] -> Ok(Command(path, Mailboxes))
    "mailboxes", _ -> usage("unexpected_argument")
    "list", _ ->
      parse_list(args)
      |> result.map(fn(parsed) {
        let #(filters, page) = parsed
        Command(path, List(filters, page))
      })
    "read", _ ->
      parse_read(args)
      |> result.map(fn(parsed) {
        let #(id, max_bytes) = parsed
        Command(path, Read(id, max_bytes))
      })
    "thread", _ ->
      parse_thread(args)
      |> result.map(fn(parsed) {
        let #(id, limit) = parsed
        Command(path, Thread(id, limit))
      })
    _, _ -> usage("unknown_verb")
  }
}

fn usage(reason: String) -> Result(a, Error) {
  Error(error.Usage(reason))
}

/// A flag that may appear once: a second appearance is `Usage` (A5).
fn fresh(taken: Bool) -> Result(Nil, Error) {
  case taken {
    False -> Ok(Nil)
    True -> usage("repeated_argument")
  }
}

// ---------------------------------------------------------------- read argv

/// `read <id> [--max-bytes n]`.
fn parse_read(args: List(String)) -> Result(#(String, Option(Int)), Error) {
  case args {
    [] -> usage("missing_message_id")
    [id, ..rest] -> {
      use max_bytes <- result.try(parse_sole_int_flag(
        rest,
        "--max-bytes",
        max_bytes_value,
        None,
      ))
      Ok(#(id, max_bytes))
    }
  }
}

/// A verb's one optional integer flag, which may appear once (A5): `value`
/// reads and range-checks the raw text, and `found` carries what earlier
/// occurrences stored.
fn parse_sole_int_flag(
  args: List(String),
  flag: String,
  value: fn(String) -> Result(Int, Error),
  found: Option(Int),
) -> Result(Option(Int), Error) {
  case args {
    [] -> Ok(found)
    [name, ..rest] if name == flag -> {
      use _ <- result.try(fresh(is_some(found)))
      use pair <- result.try(value_flag(rest))
      let #(raw, rest) = pair
      use parsed <- result.try(value(raw))
      parse_sole_int_flag(rest, flag, value, Some(parsed))
    }
    _ -> usage("unknown_argument")
  }
}

fn max_bytes_value(raw: String) -> Result(Int, Error) {
  case int.parse(raw) {
    Ok(value) if value >= 0 -> Ok(value)
    _ -> usage("invalid_max_bytes")
  }
}

/// `thread <id> [--limit n]`, whose page defaults to `default_limit` (A7).
fn parse_thread(args: List(String)) -> Result(#(String, Int), Error) {
  case args {
    [] -> usage("missing_thread_id")
    [id, ..rest] -> {
      use limit <- result.try(parse_sole_int_flag(
        rest,
        "--limit",
        limit_value,
        None,
      ))
      Ok(#(id, unwrap(limit, default_limit)))
    }
  }
}

/// `list`'s flags, in any order, each at most once (A5).
type ListFlags {
  ListFlags(
    mailbox: Option(String),
    since: Option(String),
    from: Option(String),
    unread: Bool,
    limit: Option(Int),
    offset: Option(Int),
    after: Option(Cursor),
  )
}

/// `list`'s flags in, the filters and the page out (design § 5.2); the two
/// are separate so PHASE-05's `read --after` can reuse the filters.
fn parse_list(args: List(String)) -> Result(#(Filters, Page), Error) {
  use flags <- result.try(parse_list_flags(args, empty_flags()))
  use filters <- result.try(filters_of(flags))
  use page <- result.try(page_of(flags))
  Ok(#(filters, page))
}

fn empty_flags() -> ListFlags {
  ListFlags(None, None, None, False, None, None, None)
}

fn parse_list_flags(
  args: List(String),
  flags: ListFlags,
) -> Result(ListFlags, Error) {
  case args {
    [] -> Ok(flags)
    [flag, ..rest] ->
      case flag {
        "--unread" -> {
          use _ <- result.try(fresh(flags.unread))
          parse_list_flags(rest, ListFlags(..flags, unread: True))
        }
        "--mailbox" ->
          parse_value_flag(
            rest,
            is_some(flags.mailbox),
            Ok,
            fn(flags, value) { ListFlags(..flags, mailbox: Some(value)) },
            flags,
          )
        "--since" ->
          parse_value_flag(
            rest,
            is_some(flags.since),
            Ok,
            fn(flags, value) { ListFlags(..flags, since: Some(value)) },
            flags,
          )
        "--from" ->
          parse_value_flag(
            rest,
            is_some(flags.from),
            from_value,
            fn(flags, value) { ListFlags(..flags, from: Some(value)) },
            flags,
          )
        "--limit" ->
          parse_value_flag(
            rest,
            is_some(flags.limit),
            limit_value,
            fn(flags, value) { ListFlags(..flags, limit: Some(value)) },
            flags,
          )
        "--offset" ->
          parse_value_flag(
            rest,
            is_some(flags.offset),
            offset_value,
            fn(flags, value) { ListFlags(..flags, offset: Some(value)) },
            flags,
          )
        "--after" ->
          parse_value_flag(
            rest,
            is_some(flags.after),
            cursor_value,
            fn(flags, value) { ListFlags(..flags, after: Some(value)) },
            flags,
          )
        _ -> usage("unknown_argument")
      }
  }
}

/// `--offset` accepts only a value the store can bind: zero or more, up to
/// `max_offset`.
fn offset_in_range(value: Int) -> Bool {
  value >= 0 && value <= max_offset
}

/// `--from` takes a non-empty text: an empty one selects nothing and is
/// `Usage("invalid_from")`.
fn from_value(raw: String) -> Result(String, Error) {
  case raw {
    "" -> usage("invalid_from")
    _ -> Ok(raw)
  }
}

/// A `list` flag taking one value that `parse` reads and checks, stored once
/// (A5). Every `list` flag but `--unread` has this shape.
fn parse_value_flag(
  args: List(String),
  taken: Bool,
  parse: fn(String) -> Result(a, Error),
  store: fn(ListFlags, a) -> ListFlags,
  flags: ListFlags,
) -> Result(ListFlags, Error) {
  use _ <- result.try(fresh(taken))
  use pair <- result.try(value_flag(args))
  let #(raw, rest) = pair
  use parsed <- result.try(parse(raw))
  parse_list_flags(rest, store(flags, parsed))
}

fn int_value(raw: String, allowed: fn(Int) -> Bool) -> Result(Int, Error) {
  case int.parse(raw) {
    Ok(value) ->
      case allowed(value) {
        True -> Ok(value)
        False -> usage("invalid_integer")
      }
    Error(Nil) -> usage("invalid_integer")
  }
}

/// `--limit`'s value for `list` and `thread`: an integer in 1..500 (A5).
fn limit_value(raw: String) -> Result(Int, Error) {
  int_value(raw, in_limit_range)
}

fn in_limit_range(value: Int) -> Bool {
  value >= min_limit && value <= max_limit
}

/// `--offset`'s value for `list`: an integer in `offset_in_range`.
fn offset_value(raw: String) -> Result(Int, Error) {
  int_value(raw, offset_in_range)
}

/// `--after`'s value: only the canonical cursor text `cursor.parse` accepts
/// (C3); anything else is `Usage("invalid_cursor")`.
fn cursor_value(raw: String) -> Result(Cursor, Error) {
  case cursor.parse(raw) {
    Ok(after) -> Ok(after)
    Error(Nil) -> usage("invalid_cursor")
  }
}

/// The filters `list`, and in PHASE-05 `read --after`, select by (A2).
fn filters_of(flags: ListFlags) -> Result(Filters, Error) {
  use since_ms <- result.try(optional_since(flags.since))
  Ok(Filters(
    mailbox: flags.mailbox,
    since_ms: since_ms,
    from: flags.from,
    unread: flags.unread,
  ))
}

/// The page `list` asks for: `--after` may not be combined with `--offset`,
/// and the other flags' defaults apply otherwise (A5, C2).
fn page_of(flags: ListFlags) -> Result(Page, Error) {
  let limit = unwrap(flags.limit, default_limit)
  case flags.after {
    Some(after) ->
      case is_some(flags.offset) {
        True -> usage("offset_with_after")
        False -> Ok(After(limit, after))
      }
    None -> Ok(Offset(limit, unwrap(flags.offset, default_offset)))
  }
}

/// The value after a flag; a flag with nothing after it is `Usage`.
fn value_flag(args: List(String)) -> Result(#(String, List(String)), Error) {
  case args {
    [value, ..rest] -> Ok(#(value, rest))
    [] -> usage("missing_value")
  }
}

/// `--since` must be exactly `YYYY-MM-DD`; `normalise.utc_date` then validates
/// the calendar date at midnight UTC (A2).
fn optional_since(raw: Option(String)) -> Result(Option(Int), Error) {
  case raw {
    None -> Ok(None)
    Some(raw) -> since_ms(raw) |> result.map(Some)
  }
}

fn since_ms(raw: String) -> Result(Int, Error) {
  case string.to_graphemes(raw) {
    [_, _, _, _, "-", _, _, "-", _, _] ->
      case normalise.utc_date(raw <> "T00:00:00Z") {
        Ok(date) -> Ok(date.ms)
        Error(Nil) -> usage("invalid_since")
      }
    _ -> usage("invalid_since")
  }
}
