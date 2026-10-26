%% Test-support FFI for test/support/subprocess.gleam.
%%
%% open_port/2 cannot split a child's stderr from its stdout, so the child is
%% started through /bin/sh with `2>"$1"` redirecting stderr into a private temp
%% file. stdout arrives over the port (binary); stderr is read back from the
%% file once `exit_status` arrives. os:cmd/1 is never used: it goes through a
%% shell, needs quoting and merges the streams.
%%
%% All paths cross the FFI boundary as binaries (Gleam Strings); arguments are
%% passed as positional parameters of `sh -c`, so no shell quoting is needed
%% for the executable or its arguments.
-module(subprocess_ffi).

-export([
    run/2,
    getenv/1,
    is_dir/1,
    ebin_dirs/1,
    find_executable/1
]).

%% $0 = "screwtape-subprocess", $1 = stderr path, $2.. = executable + args.
-define(SCRIPT, "s=$1; shift; exec \"$@\" 2>\"$s\"").

%% Returns {ok, {ExitCode, Stdout, Stderr}} or {error, Reason}.
run(Executable, Args) ->
    Tmp = tmp_path(),
    case file:write_file(Tmp, <<>>) of
        ok ->
            Started = start(Tmp, to_list(Executable), [to_list(A) || A <- Args]),
            Result =
                case Started of
                    {ok, Port} -> collect(Port, []);
                    {error, _} = Failed -> Failed
                end,
            Stderr = read_stderr(Tmp),
            _ = file:delete(Tmp),
            case Result of
                {ok, Code, Stdout} -> {ok, {Code, Stdout, Stderr}};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, format("cannot create stderr file ~ts: ~p", [Tmp, Reason])}
    end.

%% Returns {ok, Value} or {error, nil} (Gleam Result(String, Nil)).
getenv(Name) ->
    case os:getenv(to_list(Name)) of
        false -> {error, nil};
        "" -> {error, nil};
        Value -> {ok, to_binary(Value)}
    end.

is_dir(Path) ->
    filelib:is_dir(to_list(Path)).

%% Lists "<dir>/<app>/ebin" for every app directory that has one.
ebin_dirs(Dir) ->
    Root = to_list(Dir),
    case file:list_dir(Root) of
        {ok, Names} ->
            Ebins = [
                Ebin
             || Name <- lists:sort(Names),
                Ebin <- [filename:join([Root, Name, "ebin"])],
                filelib:is_dir(Ebin)
            ],
            {ok, [to_binary(Ebin) || Ebin <- Ebins]};
        {error, Reason} ->
            {error, format("cannot list ~ts: ~p", [Root, Reason])}
    end.

%% Returns {ok, Path} or {error, nil}.
find_executable(Name) ->
    case os:find_executable(to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, to_binary(Path)}
    end.

%% Internals

start(Tmp, Executable, Args) ->
    PortArgs = ["-c", ?SCRIPT, "screwtape-subprocess", Tmp, Executable | Args],
    try
        {ok,
            open_port(
                {spawn_executable, "/bin/sh"},
                [
                    binary,
                    exit_status,
                    use_stdio,
                    %% Keeps a crashing subprocess from dropping erl_crash.dump
                    %% in the caller's working directory (design 5.4).
                    {env, [{"ERL_CRASH_DUMP_SECONDS", "0"}]},
                    {args, PortArgs}
                ]
            )}
    catch
        error:Reason ->
            {error, format("open_port failed: ~p", [Reason])}
    end.

collect(Port, Acc) ->
    Previous = process_flag(trap_exit, true),
    Result = collect_loop(Port, Acc),
    process_flag(trap_exit, Previous),
    Result.

collect_loop(Port, Acc) ->
    receive
        {Port, {data, Bin}} ->
            collect_loop(Port, [Bin | Acc]);
        {Port, {exit_status, Code}} ->
            {ok, Code, iolist_to_binary(lists:reverse(Acc))};
        {Port, closed} ->
            collect_loop(Port, Acc);
        {'EXIT', Port, Reason} ->
            {error, format("subprocess port died: ~p", [Reason])}
    end.

read_stderr(Tmp) ->
    case file:read_file(Tmp) of
        {ok, Bin} -> Bin;
        {error, _} -> <<>>
    end.

tmp_path() ->
    Dir =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            "" -> "/tmp";
            Value -> Value
        end,
    Unique = erlang:unique_integer([positive, monotonic]),
    Filename =
        "screwtape-subprocess-" ++ os:getpid() ++ "-" ++ integer_to_list(Unique) ++ ".err",
    filename:join(Dir, Filename).

format(Fmt, Args) ->
    to_binary(io_lib:format(Fmt, Args)).

to_list(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
to_list(Value) when is_list(Value) -> Value.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8).
