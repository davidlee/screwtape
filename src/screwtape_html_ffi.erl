%% A total wrapper around htmgrrrl's Erlang SAX entry point (DEC-020).
%%
%% htmerl 0.2.1 raises on some malformed input, notably an input that ends
%% inside a tag name and an unclosed table cell. An exception reason can carry
%% the input text, which must not escape the parser, so every exception is
%% reduced to {error, nil} here. The result from htmgrrrl_ffi is otherwise
%% returned unchanged.
-module(screwtape_html_ffi).

-export([sax/3]).

sax(Html, State, Fun) ->
    try htmgrrrl_ffi:sax(Html, State, Fun)
    catch _:_ -> {error, nil}
    end.
