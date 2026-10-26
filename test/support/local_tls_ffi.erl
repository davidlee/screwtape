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
%% Grows into PHASE-02's local_jmap; keep it small until then.
-module(local_tls_ffi).

-export([start/0, start_for/1, stop/1, port/1, ca_path/1, http_get_verified/2]).

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
    _Accepter = spawn(fun() -> accept_loop(Listen) end),
    #{
        listen => Listen,
        port => Port,
        ca_path => CaPath,
        dir => Dir
    }.

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

http_get_verified(Url, CaPath) ->
    SslOpts = [
        {verify, verify_peer},
        {cacertfile, ffi_terms:to_list(CaPath)},
        {log_level, none}
    ],
    HttpOpts = [{ssl, SslOpts}],
    RequestOpts = [{body_format, binary}],
    case httpc:request(get, {ffi_terms:to_list(Url), []}, HttpOpts, RequestOpts) of
        {ok, {{_, Status, _}, _Headers, Body}} ->
            {ok, {Status, Body}};
        {error, Reason} ->
            {error, ffi_terms:format("~0p", [Reason])}
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

accept_loop(Listen) ->
    case ssl:transport_accept(Listen, ?RECV_TIMEOUT) of
        {ok, Transport} ->
            serve(Transport),
            accept_loop(Listen);
        {error, closed} ->
            ok;
        {error, _Other} ->
            accept_loop(Listen)
    end.

serve(Transport) ->
    case ssl:handshake(Transport, ?RECV_TIMEOUT) of
        {ok, Socket} ->
            _ = read_request(Socket),
            _ = ssl:send(Socket, ?RESPONSE),
            ssl:close(Socket);
        {error, _Reason} ->
            %% A rejected handshake (the negative case) is not an error here.
            catch ssl:close(Transport),
            ok
    end.

read_request(Socket) ->
    case ssl:recv(Socket, 0, ?RECV_TIMEOUT) of
        {ok, Request} -> Request;
        {error, Reason} -> {error, Reason}
    end.
