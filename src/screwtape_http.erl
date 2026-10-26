%% The production `Send`: one synchronous httpc request over TLS (design § 5.2,
%% PHASE-02 EX-1). Gleam calls it as `send(Request, Cap, TimeoutMs, CaFile)`,
%% where `Request` is a gleam_http `Request(String)` record and `CaFile` a
%% Gleam `Option(String)` (`none` | `{some, Path}`). It answers
%% `{ok, Response}` — the gleam_http `response` record, header names lowercased
%% and the body as a UTF-8 binary — or `{error, HttpFailure}` with exactly one
%% of `timeout`, `connect_failed`, `tls_failed`, `bad_utf8`, `too_large`.
%%
%% Option placement is the subtle part (RV-001 F-29). httpc takes two option
%% lists and *silently drops* an option that sits in the wrong one: it reports
%% such a mistake only to the logger, which the CLI silences. So
%% `{max_body_size, Cap}` and `{body_format, binary}` must go in the fourth
%% argument (Options), while `{autoretry, 0}`, `{autoredirect, false}`, the
%% timeouts and `{ssl, Ssl}` belong in the third (HttpOptions). A misplaced cap
%% leaves the response body unbounded (F-12, F-19); a missing `{autoretry, 0}`
%% lets OTP retry a 503 behind the caller's back, hiding the first response's
%% bytes from the byte budget (F-20).
%%
%% DEC-018: `verify_peer` with hostname verification, trusting the system CA
%% store via `public_key:cacerts_get/0`, or the configured `ca_file` when the
%% config sets one.
%%
%% `Cap` must be greater than 0: httpc rejects a cap of 0 with a crash, so the
%% caller answers an exhausted budget without sending at all (RV-001 F-29;
%% PHASE-10's `jmap/client`).
%%
%% Every failure is reduced to one `HttpFailure` here, and the httpc reason
%% term is dropped (D4): it can quote the request, including the bearer token,
%% so it is never logged, never returned and never kept.
-module(screwtape_http).

-export([send/4]).

-define(CONTENT_TYPE, "application/json").

%% httpc's error reasons, classified by the atoms anywhere inside them. The
%% nesting varies (and grew between OTP releases), so an atom walk is more
%% durable than matching shapes. Observed on OTP 28.5:
%%
%% too_large: `{error, body_too_big}` for a fixed-length body over
%% `max_body_size` (httpc_handler.erl), and
%% `{error, {body_too_long, {max, Cap}}}` for a chunked one (http_chunk.erl).
%% timeout: `{error, timeout}` for a read timeout; a connect timeout nests
%% `timeout` inside `failed_connect`.
%% tls_failed: `{error, {failed_connect, [{to_address, _}, {inet, _,
%% {tls_alert, {unknown_ca, _}}}]}}` — the alert sits inside the socket
%% wrapper. A handshake failure (`handshake_failure`, `bad_certificate`) or a
%% peer dying mid-handshake (`tls`) also lands here, and so do the `{options,
%% _}` shapes httpc returns for a bad CA source or an incompatible option
%% list (`{failed_connect, [..., {options, {cacertfile, Path, {error,
%% enoent}}}]}`, `{options, incompatible, [...]}`).
%% connect_failed: the remaining `failed_connect` shapes, e.g.
%% `{error, {failed_connect, [{to_address, {"localhost", Port}},
%% {inet, [inet], econnrefused}]}}`.
-define(CLASSES, [
    {too_large, [body_too_big, body_too_long]},
    {timeout, [timeout]},
    {tls_failed, [
        tls,
        tls_alert,
        handshake_failure,
        bad_certificate,
        options,
        certificate_expired,
        certificate_unknown,
        unknown_ca,
        insufficient_security,
        decrypt_error,
        unsupported_protocol,
        hostname_check_failed,
        selfsigned_peer
    ]}
]).

send(Request, Cap, TimeoutMs, CaFile) ->
    case start_apps() of
        ok ->
            case ssl_options(CaFile) of
                {ok, Ssl} -> do_send(Request, Cap, TimeoutMs, Ssl);
                {error, tls_failed} = Error -> Error
            end;
        {error, connect_failed} = Error ->
            Error
    end.

%% Neither inets nor ssl failing to start is the caller's problem to
%% distinguish: nothing was sent, so it is reported as a connect failure.
start_apps() ->
    case application:ensure_all_started(inets) of
        {ok, _} ->
            case application:ensure_all_started(ssl) of
                {ok, _} -> ok;
                {error, _Reason} -> {error, connect_failed}
            end;
        {error, _Reason} ->
            {error, connect_failed}
    end.

do_send({request, Method, Headers, Body, Scheme, Host, Port, Path, Query}, Cap, TimeoutMs, Ssl) ->
    Url = url(Scheme, Host, Port, Path, Query),
    Hs = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Headers],
    HttpOptions = [
        %% OTP retries a 503 carrying Retry-After unless told not to (F-20).
        {autoretry, 0},
        {autoredirect, false},
        {timeout, TimeoutMs},
        {connect_timeout, TimeoutMs},
        {ssl, Ssl}
    ],
    %% The cap and the body format are Options (4th argument), not HttpOptions.
    Options = [{max_body_size, Cap}, {body_format, binary}],
    case httpc:request(Method, request(Method, Url, Hs, Body), HttpOptions, Options) of
        {ok, {{_, Status, _}, RHs, RBody}} when is_binary(RBody) ->
            case unicode:characters_to_binary(RBody) of
                Utf8 when is_binary(Utf8) ->
                    {ok, {response, Status, response_headers(RHs), Utf8}};
                _ ->
                    {error, bad_utf8}
            end;
        {ok, _Response} ->
            %% Not a binary means `body_format` was dropped somewhere, not that
            %% the caller wants a charlist: re-encoding it could smuggle
            %% Latin-1 bytes through, so it is a decoding failure like any
            %% other.
            {error, bad_utf8};
        {error, Reason} ->
            {error, classify(Reason)}
    end.

%% A body-bearing method needs the content type as its own element; a
%% `content-type` already in the Gleam headers is moved there rather than
%% duplicated (httpc sends both otherwise).
request(Method, Url, Headers, Body) when Method =:= post; Method =:= put; Method =:= patch ->
    {ContentType, Rest} = take_content_type(Headers),
    {Url, Rest, ContentType, Body};
request(_Method, Url, Headers, _Body) ->
    {Url, Headers}.

take_content_type(Headers) ->
    take_content_type(Headers, ?CONTENT_TYPE, []).

take_content_type([], ContentType, Acc) ->
    {ContentType, lists:reverse(Acc)};
take_content_type([{K, V} | Rest], ContentType, Acc) ->
    case string:lowercase(K) of
        "content-type" -> take_content_type(Rest, V, Acc);
        _ -> take_content_type(Rest, ContentType, [{K, V} | Acc])
    end.

%% gleam_http response headers are lowercase, so lowercase what httpc gives
%% back; both names and values become binaries.
response_headers(Headers) ->
    [{list_to_binary(string:lowercase(K)), list_to_binary(V)} || {K, V} <- Headers].

classify(Reason) ->
    classify_atoms(?CLASSES, atoms(Reason, [])).

classify_atoms([], _Atoms) ->
    %% Nothing recognisable. Any httpc failure we cannot name is still a
    %% failure to reach the server, so it is reported as one; the alternative
    %% (a sixth variant) would leak the reason into the type and the caller.
    connect_failed;
classify_atoms([{Class, Markers} | Rest], Atoms) ->
    case lists:any(fun(Marker) -> lists:member(Marker, Atoms) end, Markers) of
        true -> Class;
        false -> classify_atoms(Rest, Atoms)
    end.

atoms(Term, Acc) when is_atom(Term) ->
    [Term | Acc];
atoms(Term, Acc) when is_tuple(Term) ->
    atoms(tuple_to_list(Term), Acc);
atoms(Term, Acc) when is_list(Term) ->
    lists:foldl(fun atoms/2, Acc, Term);
atoms(_Term, Acc) ->
    Acc.

%% `cacerts_get/0` raises when the host has no CA store (the Nix build sandbox
%% has none): nothing can be verified, so that is a TLS failure, not a crash.
ssl_options(none) ->
    try public_key:cacerts_get() of
        CaCerts -> {ok, [{verify, verify_peer}, {cacerts, CaCerts} | hostname_check()]}
    catch
        _:_ -> {error, tls_failed}
    end;
ssl_options({some, Path}) ->
    {ok, [{verify, verify_peer}, {cacertfile, binary_to_list(Path)} | hostname_check()]}.

%% httpc verifies the hostname by default once verify_peer is set, but only the
%% https match fun covers the system-CA path as well (A3).
hostname_check() ->
    [{customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]},
     {log_level, none}].

url(Scheme, Host, Port, Path, Query) ->
    P = case Port of none -> ""; {some, N} -> ":" ++ integer_to_list(N) end,
    Q = case Query of none -> ""; {some, S} -> "?" ++ binary_to_list(S) end,
    atom_to_list(Scheme) ++ "://" ++ binary_to_list(Host) ++ P ++ binary_to_list(Path) ++ Q.
