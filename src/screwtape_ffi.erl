%% The three effects `main` needs that Gleam cannot express, each written to
%% keep a secret out of a crash report (design § 5.2, token-leak containment):
%% `halt/1` flushes pending stdout so an exit cannot truncate a document into
%% parseable garbage; `silence_logger/0` stops OTP from printing reports whose
%% process memory can hold the bearer token; `guard/1` catches every exception
%% class but keeps nothing of Class/Reason/Stacktrace, because the reason may be
%% the token, emitting only one fixed internal-error line.
-module(screwtape_ffi).

%% `halt/1` is also an auto-imported BIF; ours is the flushing one.
-compile({no_auto_import, [halt/1]}).

-export([halt/1, silence_logger/0, guard/1]).

halt(Code) ->
    erlang:halt(Code, [{flush, true}]).

silence_logger() ->
    logger:set_primary_config(level, none),
    nil.

guard(Fun) ->
    try Fun() of
        Value ->
            Value
    catch
        _Class:_Reason ->
            io:put_chars(standard_error, "{\"level\":\"error\",\"error\":\"internal\"}\n"),
            halt(1)
    end.
