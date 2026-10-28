%% The one call `screwtape/pii` needs and the Gleam standard library does not
%% have: a global, case-insensitive, Unicode-aware regular-expression
%% replacement (design § 5.2).
%%
%% The patterns live in `screwtape/pii` as Gleam constants, so this wrapper
%% stays a single call and nothing else: the beam-import check in
%% `just check-imports` allows exactly `re:replace/4` here (plus the
%% `erlang:get_module_info/1,2` imports the compiler emits itself).
-module(screwtape_pii_ffi).

-export([replace/3]).

replace(Text, Pattern, Replacement) ->
    re:replace(Text, Pattern, Replacement,
               [global, unicode, caseless, {return, binary}]).
