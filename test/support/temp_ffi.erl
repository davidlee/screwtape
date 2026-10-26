%% Temporary directories and files for tests (PHASE-01/EX-7).
%%
%% Everything lives under TMPDIR (falling back to /tmp) and its name carries a
%% unique integer plus the OS pid, so parallel runs cannot collide. `temp.gleam`
%% is the Gleam face for directories; local_tls_ffi and subprocess_ffi call in
%% directly.
%%
%% Creation is exclusive and the modes are explicit: a directory is 8#700, a
%% file 8#600, and an existing path makes `dir/1` crash and `file/1` return an
%% error rather than silently reusing something another test wrote.
-module(temp_ffi).

-export([dir/1, remove_dir/1, file/1, remove_file/1]).

dir(Prefix) ->
    Path = path(Prefix),
    %% The base (TMPDIR, or /tmp) is shared; only our own leaf must be new.
    ok = filelib:ensure_dir(filename:join(tmp_base(), "unused")),
    ok = file:make_dir(Path),
    ok = file:change_mode(Path, 8#700),
    ffi_terms:to_binary(Path).

remove_dir(Path) ->
    _ = file:del_dir_r(ffi_terms:to_list(Path)),
    nil.

%% An empty file the caller owns, e.g. a subprocess's stderr sink.
file(Prefix) ->
    Path = path(Prefix),
    case file:open(Path, [write, exclusive, binary]) of
        {ok, Fd} ->
            ok = file:change_mode(Path, 8#600),
            case file:close(Fd) of
                ok ->
                    {ok, ffi_terms:to_binary(Path)};
                {error, Reason} ->
                    {error, ffi_terms:format("cannot close ~ts: ~p", [Path, Reason])}
            end;
        {error, Reason} ->
            {error, ffi_terms:format("cannot create ~ts: ~p", [Path, Reason])}
    end.

remove_file(Path) ->
    _ = file:delete(ffi_terms:to_list(Path)),
    nil.

%% Internals

path(Prefix) ->
    Name =
        ffi_terms:to_list(Prefix)
            ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))
            ++ "-" ++ os:getpid(),
    filename:join(tmp_base(), Name).

tmp_base() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        "" -> "/tmp";
        Value -> Value
    end.
