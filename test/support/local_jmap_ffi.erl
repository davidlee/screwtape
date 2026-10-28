%% Scripted loopback TLS test server (PHASE-02/EX-2, DEC-018).
%%
%% local_jmap serves a fixed script of raw HTTP/1.1 responses, one per
%% request, over TLS from a certificate generated per run. The certificate,
%% listener, accept loop, handshake and request reading are
%% local_tls_ffi:serve/2's, not a second copy; this module adds the scripted
%% responder.
%%
%% One process holds the state (how many requests have been received, whether
%% a reply end is currently withheld, what is left of the script). The
%% responder asks it for the next reply, so a request that arrives after the
%% script runs out is still counted and answered with a bare 500 and a closed
%% socket.
%%
%% Withholding is the point of the helper: a reply marked `withhold_end`
%% registers as withheld, sends its headers and every body byte but the last
%% piece, and then sits in a receive until the test calls release/1 (or
%% stop/1). Content-Length withholds the body's last byte; chunked withholds
%% the final chunk and the `0\r\n\r\n` terminator. No timer is involved, so a
%% test can prove that something returned *while the body was still open*.
%%
%% Every reply carries `Connection: close` (the sheet's Risks note): httpc
%% cannot reuse a connection across a scenario, so request counts stay
%% per-server.
%%
%% A reply crosses from Gleam as {Status, Headers, Framing, Body, WithholdEnd}
%% with Framing {<<"content_length">>, 0} or {<<"chunked">>, ChunkSize};
%% local_jmap.gleam does that encoding, so this module never depends on Gleam
%% constructors.
-module(local_jmap_ffi).

-export([
    start/1, load/2, stop/1, port/1, ca_path/1,
    request_count/1, request_heads/1, withholding/1, release/1
]).

%% The certificate the scripted server presents: the same SANs as local_tls.
-define(SANS, [{dNSName, "localhost"}, {iPAddress, <<127, 0, 0, 1>>}]).

%%% ------------------------------------------------------------------
%%% Server lifecycle
%%% ------------------------------------------------------------------

start(Script) ->
    State = spawn(fun() ->
        state_loop(#{script => Script, count => 0, heads => [], withheld => [], blocking => false})
    end),
    Handle = local_tls_ffi:serve(?SANS, fun(Socket, Head) -> respond(Socket, Head, State) end),
    Handle#{state => State}.

%% Close the listener, unblock any withheld connection, delete the CA PEM.
stop(#{state := State} = Handle) ->
    call(State, stop),
    local_tls_ffi:stop(Handle).

port(#{port := Port}) ->
    Port.

ca_path(#{ca_path := CaPath}) ->
    CaPath.

%% Replace the script before any request: for a script that must name the
%% server's own URL, which exists only once the listener has a port.
load(#{state := State}, Script) ->
    call(State, {load, Script}),
    nil.

%%% ------------------------------------------------------------------
%%% Script state
%%% ------------------------------------------------------------------

request_count(#{state := State}) ->
    call(State, request_count).

%% The request line and headers of every request received, in arrival order.
request_heads(#{state := State}) ->
    call(State, request_heads).

withholding(#{state := State}) ->
    call(State, withholding).

%% Let the withheld body finish: the waiting connection sends the tail and
%% closes. `withholding` is false from here on.
release(#{state := State}) ->
    _ = call(State, release),
    nil.

%% The script and the two counters, in one place. `blocking` is what
%% withholding/1 reports; `withheld` is the connections waiting for a release.
state_loop(#{script := Script, count := Count, withheld := Withheld} = State) ->
    receive
        {{next, Head}, From} ->
            From ! {reply, next_from_script(Script)},
            state_loop(State#{
                script := rest_of_script(Script),
                count := Count + 1,
                heads := [Head | maps:get(heads, State)]
            });
        {request_heads, From} ->
            From ! {reply, lists:reverse(maps:get(heads, State))},
            state_loop(State);
        {{withheld, Worker}, From} ->
            From ! {reply, ok},
            state_loop(State#{withheld := [Worker | Withheld], blocking := true});
        {release, From} ->
            [Worker ! release || Worker <- Withheld],
            From ! {reply, ok},
            state_loop(State#{withheld := [], blocking := false});
        {{load, NewScript}, From} ->
            From ! {reply, ok},
            state_loop(State#{script := NewScript});
        {request_count, From} ->
            From ! {reply, Count},
            state_loop(State);
        {withholding, From} ->
            From ! {reply, maps:get(blocking, State)},
            state_loop(State);
        {stop, From} ->
            [Worker ! close || Worker <- Withheld],
            From ! {reply, ok},
            ok
    end.

next_from_script([Reply | _]) ->
    Reply;
next_from_script([]) ->
    exhausted.

rest_of_script([_Reply | Rest]) ->
    Rest;
rest_of_script([]) ->
    [].

%%% ------------------------------------------------------------------
%%% Responder
%%% ------------------------------------------------------------------

%% The responder local_tls_ffi:serve/2 calls, with the request already read:
%% one scripted reply, after which the shared loop closes the socket.
respond(Socket, Head, State) ->
    send_reply(Socket, State, call(State, {next, Head})).

%% One scripted reply, or a 500 once the script is spent. A withheld reply
%% registers with the state process *before* its first byte goes out: a client
%% can give up on the headers alone (httpc's TooLarge) and return while the
%% prefix is still being written, so withholding/1 must already be true then.
send_reply(Socket, _State, exhausted) ->
    send(Socket, [
        status_line(500),
        "Content-Length: 0\r\n",
        "Connection: close\r\n\r\n"
    ]);
send_reply(Socket, State, {Status, Headers, Framing, Body, WithholdEnd}) ->
    {Prefix, Tail} = frame(Framing, Body),
    Head = [
        status_line(Status),
        [[Name, ": ", Value, "\r\n"] || {Name, Value} <- Headers],
        framing_header(Framing, Body),
        "Connection: close\r\n\r\n"
        | Prefix
    ],
    case WithholdEnd of
        true ->
            call(State, {withheld, self()}),
            ok = send(Socket, Head),
            receive
                release -> send(Socket, Tail);
                close -> ok
            end;
        false ->
            ok = send(Socket, Head),
            send(Socket, Tail)
    end.

%% Split a body into the bytes that go out at once and the piece withheld
%% until release. Content-Length holds back the last byte; chunked holds back
%% the last whole chunk and the terminator.
frame({<<"content_length">>, _}, Body) ->
    Cut = max(byte_size(Body) - 1, 0),
    <<Prefix:Cut/binary, Tail/binary>> = Body,
    {[Prefix], [Tail]};
frame({<<"chunked">>, ChunkSize}, Body) ->
    case chunks(Body, max(ChunkSize, 1)) of
        [] ->
            {[], [<<"0\r\n\r\n">>]};
        Chunks ->
            {Init, [Last]} = lists:split(length(Chunks) - 1, Chunks),
            {[chunk(Data) || Data <- Init], [chunk(Last), <<"0\r\n\r\n">>]}
    end.

framing_header({<<"content_length">>, _}, Body) ->
    ["Content-Length: ", integer_to_binary(byte_size(Body)), "\r\n"];
framing_header({<<"chunked">>, _}, _Body) ->
    "Transfer-Encoding: chunked\r\n".

%% Hex length, CRLF, data, CRLF: the one piece a chunk wire format has.
chunk(Data) ->
    [integer_to_binary(byte_size(Data), 16), "\r\n", Data, "\r\n"].

%% The body cut into whole chunks, the last one possibly short.
chunks(<<>>, _Size) ->
    [];
chunks(Body, Size) when byte_size(Body) =< Size ->
    [Body];
chunks(Body, Size) ->
    <<ChunkData:Size/binary, Rest/binary>> = Body,
    [ChunkData | chunks(Rest, Size)].

status_line(Status) ->
    ["HTTP/1.1 ", integer_to_binary(Status), " ", reason(Status), "\r\n"].

%% Only the statuses the fixtures use; httpd_util's table is not ours to reach
%% for, and an unknown code needs no phrase to be valid.
reason(200) -> "OK";
reason(500) -> "Internal Server Error";
reason(503) -> "Service Unavailable";
reason(_) -> "".

%%% ------------------------------------------------------------------
%%% Internals
%%% ------------------------------------------------------------------

%% A message to the state process and its answer. The worker list is the only
%% shared thing, so a plain send/receive pair is enough.
call(State, Message) ->
    Ref = monitor(process, State),
    State ! {Message, self()},
    receive
        {'DOWN', Ref, process, State, _Reason} ->
            exit(state_down);
        {reply, Value} ->
            demonitor(Ref, [flush]),
            Value
    end.

%% A client that has already gone away is not this helper's failure: the test
%% only cares about what it saw before that.
send(Socket, IoData) ->
    case ssl:send(Socket, IoData) of
        ok -> ok;
        {error, _Reason} -> ok
    end.
