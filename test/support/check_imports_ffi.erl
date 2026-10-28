%% Filesystem access for check_imports (PHASE-03, EX-6/VT-4).
%%
%% The checker's rules are pure (test/check_imports.gleam); only locating the
%% sources, reading a beam's import table, probing the build tree and exiting
%% need the outside world. Paths are relative to the project root, which is the
%% cwd `gleam run` uses.
%%
%% `ffi_terms` is the suite's existing string/list conversion helper.
-module(check_imports_ffi).

-export([gleam_sources/0, beam_imports/1, beam_exports/1, package_names/0,
         exists/1, halt/1]).

gleam_sources() ->
    [ffi_terms:to_binary(Path)
     || Path <- lists:sort(filelib:wildcard("src/**/*.gleam"))].

%% The imports chunk of a compiled module: every remote call it can make, which
%% no source-level trick can hide. `{error, nil}` when the beam is missing or
%% unreadable.
beam_imports(Path) ->
    case beam_lib:chunks(ffi_terms:to_list(Path), [imports]) of
        {ok, {_Module, [{imports, Imports}]}} ->
            {ok, [{atom_to_binary(Module, utf8),
                   atom_to_binary(Function, utf8),
                   Arity}
                  || {Module, Function, Arity} <- Imports]};
        _ ->
            {error, nil}
    end.

%% The exports chunk of a compiled module: the functions it offers, which a
%% wrapper may only keep within the list `check_imports` allows. `{error, nil}`
%% when the beam is missing or unreadable.
beam_exports(Path) ->
    case beam_lib:chunks(ffi_terms:to_list(Path), [exports]) of
        {ok, {_Module, [{exports, Exports}]}} ->
            {ok, [{atom_to_binary(Function, utf8), Arity}
                  || {Function, Arity} <- Exports]};
        _ ->
            {error, nil}
    end.

%% The package names whose sources are present: build/packages/<name>/src.
package_names() ->
    [ffi_terms:to_binary(filename:basename(filename:dirname(Path)))
     || Path <- lists:sort(filelib:wildcard("build/packages/*/src")),
        filelib:is_dir(Path)].

exists(Path) ->
    filelib:is_regular(ffi_terms:to_list(Path)).

halt(Status) ->
    erlang:halt(Status).
