-module(thinwrap_location_httpc_tests).

%% The default transport against a real local TLS listener (a throwaway CA
%% from public_key:pkix_test_data/1), so the adapter's own behaviour — status
%% passthrough, header shape, no redirects, timeout, User-Agent — is tested
%% without the network.

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

-define(T, thinwrap_location_httpc).

httpc_test_() ->
    {setup, fun start/0, fun stop/1, fun(Ctx) ->
        [
            {"2xx returns status, lower-cased joined headers and body", fun() ->
                ok_response(Ctx)
            end},
            {"non-2xx is a response, not an error", fun() -> error_status(Ctx) end},
            {"a redirect is surfaced, never followed", fun() -> redirect(Ctx) end},
            {"names itself in User-Agent; a caller's wins", fun() -> user_agent(Ctx) end},
            {"POST sends body and one content type", fun() -> post(Ctx) end},
            {"a hung server is {error, timeout}", fun() -> hung(Ctx) end},
            {"refuses non-https URLs with invalid_request", fun refuses_non_https/0},
            {"default TLS rejects an untrusted certificate", fun() -> untrusted(Ctx) end}
        ]
    end}.

start() ->
    {ok, _} = application:ensure_all_started([inets, ssl]),
    #{server_config := SOpts, client_config := COpts} =
        public_key:pkix_test_data(#{
            %% P-256/SHA-256: OTP's default test keys cannot be served to a
            %% TLS 1.3 client (unable_to_supply_acceptable_cert).
            server_chain => #{
                root => [{key, {namedCurve, secp256r1}}, {digest, sha256}],
                intermediates => [],
                peer => [{key, {namedCurve, secp256r1}}, {digest, sha256}, {extensions, [san()]}]
            },
            client_chain => #{
                root => [{key, {namedCurve, secp256r1}}],
                intermediates => [],
                peer => [{key, {namedCurve, secp256r1}}]
            }
        }),
    {ok, L} = ssl:listen(0, [binary, {active, false}, {reuseaddr, true} | SOpts]),
    {ok, {_, Port}} = ssl:sockname(L),
    Self = self(),
    Acceptor = spawn(fun() -> accept_loop(L, Self) end),
    ok = ssl:controlling_process(L, Acceptor),
    %% The client trusts the test root and checks the host name like the default.
    Ssl = [
        {verify, verify_peer},
        {cacerts, proplists:get_value(cacerts, COpts)},
        {server_name_indication, "localhost"},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ],
    #{port => Port, ssl => Ssl, acceptor => Acceptor, listen => L}.

san() ->
    {'Extension', ?'id-ce-subjectAltName', false, [{dNSName, "localhost"}]}.

stop(#{acceptor := A, listen := L}) ->
    exit(A, kill),
    _ = ssl:close(L),
    ok.

url(#{port := P}, Path) -> iolist_to_binary(["https://localhost:", integer_to_list(P), Path]).

opts(Ctx) -> #{ssl => maps:get(ssl, Ctx), timeout => 5000}.

accept_loop(L, Owner) ->
    case ssl:transport_accept(L) of
        {ok, T} ->
            case ssl:handshake(T, 5000) of
                {ok, S} ->
                    Pid = spawn(fun() -> serve(S, Owner) end),
                    _ = ssl:controlling_process(S, Pid),
                    Pid ! go;
                _ ->
                    ok
            end,
            accept_loop(L, Owner);
        _ ->
            ok
    end.

serve(S, Owner) ->
    %% `go` follows the socket handoff; without it this process cannot read S.
    receive
        go -> ok
    after 5000 -> exit(no_socket_handoff)
    end,
    {ok, Req} = read_request(S, <<>>),
    [Head | _] = binary:split(Req, <<"\r\n\r\n">>),
    [RequestLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
    [_Method, Path | _] = binary:split(RequestLine, <<" ">>, [global]),
    %% eunit runs setup and each test in different processes, so the test
    %% that wants the raw request registers itself under this name.
    _ = Owner,
    case whereis(httpc_test_sink) of
        undefined -> ok;
        Sink -> Sink ! {request, Req}
    end,
    Reply =
        case Path of
            <<"/ok">> ->
                <<"HTTP/1.1 200 OK\r\nX-Dup: 1\r\nX-Dup: 2\r\nContent-Length: 2\r\n\r\nhi">>;
            <<"/teapot">> ->
                <<"HTTP/1.1 418 I'm a teapot\r\nContent-Length: 5\r\n\r\nnope!">>;
            <<"/redirect">> ->
                <<"HTTP/1.1 302 Found\r\nLocation: https://example.com/\r\nContent-Length: 0\r\n\r\n">>;
            <<"/echo-ua">> ->
                UA = hd(
                    [
                        V
                     || L <- HeaderLines,
                        [K, V] <- [binary:split(L, <<": ">>)],
                        string:lowercase(K) =:= <<"user-agent">>
                    ] ++ [<<>>]
                ),
                <<"HTTP/1.1 200 OK\r\nContent-Length: ", (integer_to_binary(byte_size(UA)))/binary,
                    "\r\n\r\n", UA/binary>>;
            <<"/hang">> ->
                timer:sleep(3000),
                <<>>;
            _ ->
                <<"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n">>
        end,
    _ = ssl:send(S, Reply),
    ssl:close(S).

read_request(S, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Body] ->
            Need =
                case
                    re:run(Head, "(?i)content-length: *([0-9]+)", [{capture, all_but_first, binary}])
                of
                    {match, [N]} -> binary_to_integer(N);
                    nomatch -> 0
                end,
            case byte_size(Body) < Need of
                true -> more(S, Acc);
                false -> {ok, Acc}
            end;
        [_] ->
            more(S, Acc)
    end.

more(S, Acc) ->
    case ssl:recv(S, 0, 5000) of
        {ok, D} -> read_request(S, <<Acc/binary, D/binary>>);
        E -> E
    end.

req(Ctx, Method, Path, Headers) ->
    ?T:request(#{method => Method, url => url(Ctx, Path), headers => Headers}, opts(Ctx)).

ok_response(Ctx) ->
    ?assertMatch(
        {ok, #{status := 200, body := <<"hi">>, headers := #{<<"x-dup">> := <<"1, 2">>}}},
        req(Ctx, get, <<"/ok">>, #{})
    ).

error_status(Ctx) ->
    ?assertMatch({ok, #{status := 418, body := <<"nope!">>}}, req(Ctx, get, <<"/teapot">>, #{})).

redirect(Ctx) ->
    ?assertMatch({ok, #{status := 302}}, req(Ctx, get, <<"/redirect">>, #{})).

user_agent(Ctx) ->
    ?assertMatch(
        {ok, #{body := <<"thinwrap-location-erlang">>}}, req(Ctx, get, <<"/echo-ua">>, #{})
    ),
    ?assertMatch(
        {ok, #{body := <<"mine/1">>}},
        req(Ctx, get, <<"/echo-ua">>, #{<<"user-agent">> => <<"mine/1">>})
    ).

post(Ctx) ->
    flush(),
    true = register(httpc_test_sink, self()),
    {ok, #{status := 200}} = ?T:request(
        #{
            method => post,
            url => url(Ctx, <<"/post">>),
            headers => #{<<"Content-Type">> => <<"application/json">>},
            body => <<"{\"a\":1}">>
        },
        opts(Ctx)
    ),
    receive
        {request, Raw} ->
            ?assertNotEqual(nomatch, binary:match(Raw, <<"{\"a\":1}">>)),
            {match, CTs} = re:run(Raw, "(?i)content-type: ([^\r]+)", [
                global, {capture, all_but_first, binary}
            ]),
            ?assertEqual([[<<"application/json">>]], CTs)
    after 5000 -> ?assert(false)
    end,
    unregister(httpc_test_sink).

hung(Ctx) ->
    ?assertEqual(
        {error, timeout},
        ?T:request(#{method => get, url => url(Ctx, <<"/hang">>), headers => #{}}, (opts(Ctx))#{
            timeout => 300
        })
    ).

refuses_non_https() ->
    [
        ?assertMatch(
            {error, {connector_error, #{code := invalid_request}}},
            ?T:request(#{method => get, url => U, headers => #{}}, #{})
        )
     || U <- [
            <<"http://localhost:5000/route">>,
            <<"file:///etc/passwd">>,
            <<"ftp://h/x">>,
            <<"host-only">>
        ]
    ].

%% No `ssl` option: the OTP defaults (OS trust store + host check) must reject
%% the throwaway CA.
untrusted(Ctx) ->
    ?assertMatch(
        {error, {failed_connect, _}},
        ?T:request(#{method => get, url => url(Ctx, <<"/ok">>), headers => #{}}, #{timeout => 5000})
    ).

flush() ->
    receive
        {request, _} -> flush()
    after 0 -> ok
    end.
