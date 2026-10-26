%% Test-support FFI for test/support/subprocess.gleam. Run the suite through
%% `just test` (which re-exports the erlang-shipment) or the nix check:
%% `gleam test` alone may test a stale shipment, because erl_eval puts
%% `build/erlang-shipment/*/ebin` on the code path.
%%
%% open_port/2 cannot split a child's stderr from its stdout, so the child is
%% started through /bin/sh with `2>"$1"` redirecting stderr into a private temp
%% file (temp_ffi). stdout arrives over the port (binary); stderr is read back
%% from the file once `exit_status` arrives. os:cmd/1 is never used: it goes
%% through a shell, needs quoting and merges the streams.
%%
%% No failure is folded into a plausible-looking value: an unreadable stderr
%% capture and a child that never exits (the port loop's inactivity timeout)
%% are both `{error, T}` terms, so a test asserting empty stderr cannot pass
%% because the capture was lost.
%%
%% All paths cross the FFI boundary as binaries (Gleam Strings); arguments are
%% passed as positional parameters of `sh -c`, so no shell quoting is needed
%% for the executable or its arguments.
-module(subprocess_ffi).

-export([run/2, getenv/1, is_dir/1, ebin_dirs/1, find_executable/1]).

%% $0 = "screwtape-subprocess", $1 = stderr path, $2.. = executable + args.
-define(SCRIPT, "s=$1; shift; exec \"$@\" 2>\"$s\"").

%% A child that has written nothing for this long is hung: close the port
%% rather than block the whole run.
-define(TIMEOUT_MS, 60000).

%% Returns {ok, {ExitCode, Stdout, Stderr}} or
%% {error, {spawn_failed, Reason}} / {error, {timed_out, Seconds}}: the error
%% terms are the Gleam constructors `SpawnFailed(reason)` and
%% `TimedOut(after_seconds)`.
run(Executable, Args) ->
    case temp_ffi:file("screwtape-subprocess") of
        {ok, StderrPath} -> run_with_stderr(StderrPath, Executable, Args);
        {error, Reason} -> {error, {spawn_failed, Reason}}
    end.

%% Returns {ok, Value} or {error, nil} (Gleam Result(String, Nil)).
getenv(Name) ->
    case os:getenv(ffi_terms:to_list(Name)) of
        false -> {error, nil};
        "" -> {error, nil};
        Value -> {ok, ffi_terms:to_binary(Value)}
    end.

is_dir(Path) ->
    filelib:is_dir(ffi_terms:to_list(Path)).

%% Lists "<dir>/<app>/ebin" for every app directory that has one.
ebin_dirs(Dir) ->
    Root = ffi_terms:to_list(Dir),
    case file:list_dir(Root) of
        {ok, Names} ->
            Ebins = [
                Ebin
             || Name <- lists:sort(Names),
                Ebin <- [filename:join([Root, Name, "ebin"])],
                filelib:is_dir(Ebin)
            ],
            {ok, [ffi_terms:to_binary(Ebin) || Ebin <- Ebins]};
        {error, Reason} ->
            {error, ffi_terms:format("cannot list ~ts: ~p", [Root, Reason])}
    end.

%% Returns {ok, Path} or {error, nil}.
find_executable(Name) ->
    case os:find_executable(ffi_terms:to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, ffi_terms:to_binary(Path)}
    end.

%% Internals

run_with_stderr(StderrPath, Executable, Args) ->
    Started = start(
        StderrPath,
        ffi_terms:to_list(Executable),
        [ffi_terms:to_list(Arg) || Arg <- Args]
    ),
    Collected =
        case Started of
            {ok, Port} -> collect(Port, []);
            {error, _} = Failed -> Failed
        end,
    Stderr = read_stderr(StderrPath),
    temp_ffi:remove_file(StderrPath),
    case {Collected, Stderr} of
        {{ok, ExitCode, Stdout}, {ok, Bin}} ->
            {ok, {ExitCode, Stdout, Bin}};
        {{error, Reason}, _} ->
            {error, Reason};
        {_, {error, Reason}} ->
            {error, {spawn_failed, Reason}}
    end.

start(StderrPath, Executable, Args) ->
    PortArgs = [
        "-c",
        ?SCRIPT,
        "screwtape-subprocess",
        ffi_terms:to_list(StderrPath),
        Executable
        | Args
    ],
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
            {error, {spawn_failed, ffi_terms:format("open_port failed: ~p", [Reason])}}
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
            {error,
                {spawn_failed, ffi_terms:format("subprocess port died: ~p", [Reason])}}
    after ?TIMEOUT_MS ->
        catch port_close(Port),
        {error, {timed_out, ?TIMEOUT_MS div 1000}}
    end.

read_stderr(StderrPath) ->
    case file:read_file(StderrPath) of
        {ok, Bin} ->
            {ok, Bin};
        {error, Reason} ->
            {error,
                ffi_terms:format(
                    "cannot read the stderr capture file ~ts: ~p", [StderrPath, Reason]
                )}
    end.
