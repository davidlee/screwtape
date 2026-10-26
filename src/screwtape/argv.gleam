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
//// it names (A2). `read <id> [--max-bytes n]` and `thread <id>` (A7) take no
//// other flag, and `sync` and `mailboxes` take no argument at all.

import gleam/int
import gleam/option.{type Option, None, Some, is_some, unwrap}
import gleam/result
import gleam/string
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
  List(ListArgs)
  Read(id: String, max_bytes: Option(Int))
  Thread(id: String)
}

/// `list`'s checked flags with their defaults applied; `since_ms` is the
/// midnight-UTC instant a `--since YYYY-MM-DD` names (A2).
pub type ListArgs {
  ListArgs(
    mailbox: Option(String),
    since_ms: Option(Int),
    from: Option(String),
    unread: Bool,
    limit: Int,
    offset: Int,
  )
}

/// The page size and start `list` uses when no flag names them, and the range
/// `--limit` and `--offset` accept (A5).
const default_limit = 50

const default_offset = 0

const min_limit = 1

const max_limit = 500

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
      parse_list(args) |> result.map(fn(args) { Command(path, List(args)) })
    "read", _ ->
      parse_read(args)
      |> result.map(fn(parsed) {
        let #(id, max_bytes) = parsed
        Command(path, Read(id, max_bytes))
      })
    "thread", _ ->
      parse_thread(args) |> result.map(fn(id) { Command(path, Thread(id)) })
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
      use max_bytes <- result.try(parse_max_bytes(rest, None))
      Ok(#(id, max_bytes))
    }
  }
}

fn parse_max_bytes(
  args: List(String),
  found: Option(Int),
) -> Result(Option(Int), Error) {
  case args {
    [] -> Ok(found)
    ["--max-bytes", ..rest] -> {
      use _ <- result.try(fresh(is_some(found)))
      use pair <- result.try(value_flag(rest))
      let #(raw, rest) = pair
      use value <- result.try(max_bytes_value(raw))
      parse_max_bytes(rest, Some(value))
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

/// `thread <id>`, with no other argument (A7).
fn parse_thread(args: List(String)) -> Result(String, Error) {
  case args {
    [id] -> Ok(id)
    [] -> usage("missing_thread_id")
    _ -> usage("unexpected_argument")
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
  )
}

fn parse_list(args: List(String)) -> Result(ListArgs, Error) {
  use flags <- result.try(parse_list_flags(args, empty_flags()))
  use since_ms <- result.try(optional_since(flags.since))
  Ok(ListArgs(
    mailbox: flags.mailbox,
    since_ms: since_ms,
    from: flags.from,
    unread: flags.unread,
    limit: unwrap(flags.limit, default_limit),
    offset: unwrap(flags.offset, default_offset),
  ))
}

fn empty_flags() -> ListFlags {
  ListFlags(None, None, None, False, None, None)
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
          parse_text_flag(
            rest,
            flags.mailbox,
            fn(flags, value) { ListFlags(..flags, mailbox: Some(value)) },
            flags,
          )
        "--since" ->
          parse_text_flag(
            rest,
            flags.since,
            fn(flags, value) { ListFlags(..flags, since: Some(value)) },
            flags,
          )
        "--from" ->
          parse_text_flag(
            rest,
            flags.from,
            fn(flags, value) { ListFlags(..flags, from: Some(value)) },
            flags,
          )
        "--limit" ->
          parse_int_flag(
            rest,
            flags.limit,
            fn(value) { value >= min_limit && value <= max_limit },
            fn(flags, value) { ListFlags(..flags, limit: Some(value)) },
            flags,
          )
        "--offset" ->
          parse_int_flag(
            rest,
            flags.offset,
            fn(value) { value >= 0 },
            fn(flags, value) { ListFlags(..flags, offset: Some(value)) },
            flags,
          )
        _ -> usage("unknown_argument")
      }
  }
}

/// A flag taking one text value, which it stores once.
fn parse_text_flag(
  args: List(String),
  found: Option(String),
  store: fn(ListFlags, String) -> ListFlags,
  flags: ListFlags,
) -> Result(ListFlags, Error) {
  use _ <- result.try(fresh(is_some(found)))
  use pair <- result.try(value_flag(args))
  let #(value, rest) = pair
  parse_list_flags(rest, store(flags, value))
}

/// A flag taking one integer value `allowed` accepts, stored once.
fn parse_int_flag(
  args: List(String),
  found: Option(Int),
  allowed: fn(Int) -> Bool,
  store: fn(ListFlags, Int) -> ListFlags,
  flags: ListFlags,
) -> Result(ListFlags, Error) {
  use _ <- result.try(fresh(is_some(found)))
  use pair <- result.try(value_flag(args))
  let #(raw, rest) = pair
  use value <- result.try(int_value(raw, allowed))
  parse_list_flags(rest, store(flags, value))
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
