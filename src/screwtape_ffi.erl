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

-export([halt/1, silence_logger/0, guard/1, getenv/1]).

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
