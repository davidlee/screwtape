%% The three effects `main` needs that Gleam cannot express, each written to
%% keep a secret out of a crash report (design § 5.2, token-leak containment):
%% `halt/1` flushes pending stdout so an exit cannot truncate a document into
%% parseable garbage; `silence_logger/0` stops OTP from printing reports whose
%% process memory can hold the bearer token; `guard/1` catches every failure
%% class but keeps nothing of Class/Reason/Stacktrace, because the reason may
%% be the token, emitting only one fixed internal-error line.
%%
%% `guard/1` runs the body in a process of its own rather than in a try/catch
%% (which would run in the caller): a try/catch cannot contain an exit signal.
%% A process the body links to can crash, and the signal would kill the caller,
%% which gleam's generated `main` wrapper does not trap — the BEAM would then
%% print the exit reason, token included. In a separate process the signal
%% stops there; the caller only sees the `'DOWN'` reason and never prints it.
-module(screwtape_ffi).

%% `halt/1` is also an auto-imported BIF; ours is the flushing one.
-compile({no_auto_import, [halt/1]}).

-export([halt/1, silence_logger/0, guard/1, getenv/1, read_stdin/0]).

%% The success reason the guarded process exits with, so a normal-looking
%% `normal`/`killed`/exception reason can never be mistaken for a result.
-define(OK_TAG, screwtape_guard_ok).

-define(INTERNAL_ERROR, "{\"level\":\"error\",\"error\":\"internal\"}\n").

halt(Code) ->
    erlang:halt(Code, [{flush, true}]).

silence_logger() ->
    logger:set_primary_config(level, none),
    nil.

%% `getenv/1` is the one environment read the CLI makes: the credentials
%% directory systemd hands the unit. It answers a Gleam `Result(String, Nil)` —
%% `{ok, Binary}`, or `{error, nil}` when the variable is unset — so no caller
%% has to know that `os:getenv/1` says `false`. The value is a path, never the
%% token, so it may enter an error reason.
getenv(Name) ->
    %% A Gleam String is a binary; os:getenv/1 takes a list (or an atom).
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% The classify run's stdin ceiling: 16 MiB (design § 5.5).
-define(STDIN_LIMIT, 16 * 1024 * 1024).

%% One `file:read/2` per chunk, so a large body costs few requests.
-define(STDIN_CHUNK, 65536).

guard(Fun) ->
    {Pid, Ref} = spawn_monitor(fun() -> exit({?OK_TAG, Fun()}) end),
    receive
        {'DOWN', Ref, process, Pid, {?OK_TAG, Value}} ->
            Value;
        {'DOWN', Ref, process, Pid, _Other} ->
            internal_error()
    end.

%% One fixed line, nothing of the reason: it may hold the bearer token.
internal_error() ->
    io:put_chars(standard_error, ?INTERNAL_ERROR),
    halt(1).

%% `read_stdin/0` is the classify run's only stdin read (EX-4). It answers a
%% Gleam `Result(String, ReadStdinError)`: `{ok, Binary}`, or
%% `{error, too_large | bad_utf8 | read_failed}`.
%%
%% Standard input is read as raw bytes: `{encoding, latin1}` says so
%% explicitly, and `unicode:characters_to_binary/1` then decides whether those
%% bytes are UTF-8. Leaving the device's input encoding as unicode does not work
%% — `file:read/2` then answers `{error, {no_translation, unicode, latin1}}`
%% for any input holding a byte above 127, valid UTF-8 included (a fixture
%% `read` line fails that way through both a pipe and a redirect; verified with
%% `erl -noshell`), while a lone `\xff` comes back as `{ok, <<255>>}` with no
%% error at all. Naming latin1 keeps the bytes as they arrive; a body that does
%% not decode is `bad_utf8`, and every `{error, Reason}` from `file:read/2`
%% itself is `read_failed`.
read_stdin() ->
    Encoding = proplists:get_value(encoding, io:getopts(standard_io), unicode),
    case io:setopts(standard_io, [binary, {encoding, latin1}]) of
        ok ->
            Result = read_stdin(?STDIN_CHUNK, 0, []),
            %% The encoding is the device's, output included: left at latin1,
            %% `io:put_chars` would print every codepoint above 255 as `\x{…}`.
            ok = io:setopts(standard_io, [{encoding, Encoding}]),
            Result;
        {error, _} ->
            {error, read_failed}
    end.

read_stdin(Chunk, Size, Acc) ->
    case file:read(standard_io, Chunk) of
        eof ->
            finish_stdin(iolist_to_binary(Acc));
        {ok, Bytes} ->
            Total = Size + byte_size(Bytes),
            case Total > ?STDIN_LIMIT of
                true -> {error, too_large};
                false -> read_stdin(Chunk, Total, [Acc, Bytes])
            end;
        {error, _} ->
            {error, read_failed}
    end.

finish_stdin(Bytes) ->
    case unicode:characters_to_binary(Bytes) of
        Converted when is_binary(Converted) -> {ok, Bytes};
        _ -> {error, bad_utf8}
    end.
