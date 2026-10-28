%% Loopback TLS test helper (PHASE-01/EX-7, DEC-018).
%%
%% A CA and server certificate are generated per run by
%% public_key:pkix_test_data/1. `start/0` names the server `localhost` and adds
%% the loopback IP as a second SAN; `start_for/1` names it whatever it is given
%% and adds no IP SAN, so a test can point httpc at `localhost` and watch
%% hostname verification reject the certificate.
%%
%% The CA chain is written as PEM to a file in a fresh temporary directory
%% (temp_ffi), an ssl listener on 127.0.0.1:0 (kernel-assigned port) answers a
%% fixed HTTP/1.1 200, and httpc is driven with verify_peer against that CA.
%%
%% `listen/1` and `serve/2` are the bootstrap both this module and
%% local_jmap_ffi use (PHASE-02/EX-2, DEC-018): SANs in, a fresh CA and a
%% listening socket out. `listen/1` starts no accept loop, so a caller can own
%% the sockets; `serve/2` adds the shared one (accept, handshake, read the
%% request) and hands each connection to a responder fun. `stop/1`, `port/1`
%% and `ca_path/1` serve that map as well.
%%
%% The fixed-200 server here is just a responder on top of `serve/2`; the
%% scripted server in local_jmap_ffi is another.
-module(local_tls_ffi).

-export([
    listen/1, serve/2, start/0, start_for/1, stop/1, port/1, ca_path/1,
    http_get/2, http_get_verified/2, http_get_async/2, await/2
]).

-include_lib("public_key/include/public_key.hrl").

-define(RECV_TIMEOUT, 5000).

%% A fixed minimal HTTP/1.1 response: 200, Content-Length, body "ok", close.
-define(RESPONSE,
    <<"HTTP/1.1 200 OK\r\n"
      "Content-Type: text/plain\r\n"
      "Content-Length: 2\r\n"
      "Connection: close\r\n"
      "\r\n"
      "ok">>
).

%%% ------------------------------------------------------------------
%%% Server lifecycle
%%% ------------------------------------------------------------------

start() ->
    start_with([{dNSName, "localhost"}, {iPAddress, <<127, 0, 0, 1>>}]).

%% The server certificate carries this DNS name and no IP SAN.
start_for(DnsName) ->
    start_with([{dNSName, ffi_terms:to_list(DnsName)}]).

start_with(Sans) ->
    serve(Sans, fun fixed_response/2).

%% The one responder this module has: the fixed 200 and nothing else.
fixed_response(Socket, _Head) ->
    _ = ssl:send(Socket, ?RESPONSE),
    ok.

%%% ------------------------------------------------------------------
%%% Certificate and listener bootstrap (shared with local_jmap_ffi)
%%% ------------------------------------------------------------------

%% Listen on a kernel-assigned loopback port with a CA and a server
%% certificate generated for `Sans`. The caller owns the accept loop; the
%% returned map is what stop/1, port/1 and ca_path/1 expect.
listen(Sans) ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(inets),
    Dir = temp_ffi:dir("screwtape-local-tls"),
    CaPath = filename:join(Dir, "ca.pem"),
    Conf = server_config(Sans),
    ok = file:write_file(CaPath, ca_pem(Conf)),
    ListenOpts = [
        {ip, {127, 0, 0, 1}},
        {reuseaddr, true},
        {active, false},
        {mode, binary},
        {log_level, none}
        | Conf
    ],
    {ok, Listen} = ssl:listen(0, ListenOpts),
    {ok, {_Ip, Port}} = ssl:sockname(Listen),
    #{
        listen => Listen,
        port => Port,
        ca_path => CaPath,
        dir => Dir
    }.

%% listen/1 plus the accept loop: every handshaken connection has its request
%% read for it, then goes to `Responder` as `fun(Socket, Head) -> ok`, `Head`
%% being the request line and headers as received (`<<>>` when none arrived).
%% The socket is closed when the responder returns.
serve(Sans, Responder) ->
    Handle = listen(Sans),
    _Accepter = spawn(fun() -> accept_loop(maps:get(listen, Handle), Responder) end),
    Handle.

stop(#{listen := Listen, dir := Dir}) ->
    catch ssl:close(Listen),
    temp_ffi:remove_dir(Dir),
    nil.

port(#{port := Port}) ->
    Port.

ca_path(#{ca_path := CaPath}) ->
    CaPath.

%%% ------------------------------------------------------------------
%%% httpc client
%%% ------------------------------------------------------------------

%% verify_peer against the per-run CA, no max_body_size and no retry tuning,
%% with the wire headers kept: the plain client whose view of a withheld body
%% the self-tests assert on.
http_get(Url, CaPath) ->
    SslOpts = [
        {verify, verify_peer},
        {cacertfile, ffi_terms:to_list(CaPath)},
        {log_level, none}
    ],
    HttpOpts = [{ssl, SslOpts}],
    RequestOpts = [{body_format, binary}],
    case httpc:request(get, {ffi_terms:to_list(Url), []}, HttpOpts, RequestOpts) of
        {ok, {{_, Status, _}, Headers, Body}} ->
            {ok, {Status, wire_headers(Headers), Body}};
        {error, Reason} ->
            {error, ffi_terms:format("~0p", [Reason])}
    end.

%% The same request, in the shape skeleton_test asserts on: status and body.
http_get_verified(Url, CaPath) ->
    case http_get(Url, CaPath) of
        {ok, {Status, _Headers, Body}} ->
            {ok, {Status, Body}};
        {error, Reason} ->
            {error, Reason}
    end.

%% Gleam strings are binaries; httpc hands back charlists.
wire_headers(Headers) ->
    [{ffi_terms:to_binary(Name), ffi_terms:to_binary(Value)}
     || {Name, Value} <- Headers].

%% Run the same request in a process of its own, so the test can watch the
%% connection from outside while the server withholds the body end.
http_get_async(Url, CaPath) ->
    Caller = self(),
    Ref = make_ref(),
    _ = spawn(fun() -> Caller ! {Ref, http_get(Url, CaPath)} end),
    Ref.

%% `none` when nothing has arrived within TimeoutMs; a reply that has
%% arrived is consumed.
await(Ref, TimeoutMs) ->
    receive
        {Ref, Result} -> {some, Result}
    after TimeoutMs -> none
    end.

%%% ------------------------------------------------------------------
%%% Internals
%%% ------------------------------------------------------------------

%% A single chain: the returned options carry the server certificate (peer),
%% its private key, and the CA certificates that signed it.
server_config(Sans) ->
    Chain = #{
        root => [{key, {rsa, 2048, 65537}}, {digest, sha256}],
        intermediates => [],
        peer => [
            {key, {rsa, 2048, 65537}},
            {digest, sha256},
            {extensions, [
                #'Extension'{
                    extnID = ?'id-ce-subjectAltName',
                    extnValue = Sans,
                    critical = false
                }
            ]}
        ]
    },
    public_key:pkix_test_data(Chain).

ca_pem(Conf) ->
    CaCerts = proplists:get_value(cacerts, Conf),
    public_key:pem_encode([
        {'Certificate', Der, not_encrypted}
     || Der <- CaCerts
    ]).

accept_loop(Listen, Responder) ->
    case ssl:transport_accept(Listen, ?RECV_TIMEOUT) of
        {ok, Transport} ->
            %% One process per connection, so a responder that blocks (a
            %% withheld reply) never stops the acceptor: a retry made while a
            %% body end is held back is still accepted and counted.
            Server = spawn(fun() ->
                receive
                    {serve, T} -> serve_connection(T, Responder)
                end
            end),
            ok = ssl:controlling_process(Transport, Server),
            Server ! {serve, Transport},
            accept_loop(Listen, Responder);
        {error, closed} ->
            ok;
        {error, _Other} ->
            accept_loop(Listen, Responder)
    end.

serve_connection(Transport, Responder) ->
    case ssl:handshake(Transport, ?RECV_TIMEOUT) of
        {ok, Socket} ->
            Head = read_request(Socket),
            Responder(Socket, Head),
            catch ssl:close(Socket),
            ok;
        {error, _Reason} ->
            %% A rejected handshake (the negative case) is not an error here.
            catch ssl:close(Transport),
            ok
    end.

%%% ------------------------------------------------------------------
%%% Request reading
%%% ------------------------------------------------------------------

%% Read headers, then a Content-Length body if the request carries one (JMAP
%% POSTs do; GETs do not). The body is read even when none of it arrived with
%% the headers, which is when a POST's payload follows in its own record.
%% Returns the request line and headers.
read_request(Socket) ->
    read_request(Socket, <<>>).

read_request(Socket, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            read_body(Socket, Head, Rest);
        [_Incomplete] ->
            case ssl:recv(Socket, 0, ?RECV_TIMEOUT) of
                {ok, Data} -> read_request(Socket, <<Acc/binary, Data/binary>>);
                {error, _Reason} -> <<>>
            end
    end.

read_body(Socket, Head, Rest) ->
    case body_length(Head) - byte_size(Rest) of
        Missing when Missing > 0 ->
            _ = ssl:recv(Socket, Missing, ?RECV_TIMEOUT),
            Head;
        _Room ->
            Head
    end.

body_length(Head) ->
    Lines = binary:split(Head, <<"\r\n">>, [global]),
    lists:foldl(fun header_length/2, 0, Lines).

header_length(Line, 0) ->
    header_length_value(string:lowercase(Line));
header_length(_Line, Length) ->
    Length.

header_length_value(<<"content-length:", Value/binary>>) ->
    try binary_to_integer(string:trim(Value))
    catch _:_ -> 0
    end;
header_length_value(_Line) ->
    0.
