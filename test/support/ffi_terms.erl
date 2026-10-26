%% Erlang values at the FFI boundary: binary/list coercion and term rendering.
%%
%% Gleam strings cross as binaries while OTP APIs take lists. Shared by the test
%% support FFI modules so each one does not grow its own copy.
-module(ffi_terms).

-export([to_list/1, to_binary/1, format/2]).

to_list(Value) when is_binary(Value) -> unicode:characters_to_list(Value);
to_list(Value) when is_list(Value) -> Value.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8).

%% `io_lib:format/2` returns chardata; flatten it to one binary.
format(Fmt, Args) ->
    to_binary(io_lib:format(Fmt, Args)).
