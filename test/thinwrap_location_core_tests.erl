-module(thinwrap_location_core_tests).

-include_lib("eunit/include/eunit.hrl").

-behaviour(thinwrap_location_transport).
-export([request/2]).

-define(F, thinwrap_location_fake_transport).
-define(U, thinwrap_location_util).
-define(P, thinwrap_location_polyline).

%% ---------------------------------------------------------------------------
%% Polyline parity (vectors shared with the TS/PHP/Go/Python siblings)

vectors() ->
    {ok, Bin} = file:read_file(
        filename:join([filename:dirname(?FILE), "data", "parity-vectors.json"])
    ),
    json:decode(Bin).

ll(#{<<"lat">> := La, <<"lng">> := Ln}) -> #{lat => La, lng => Ln}.

close(Got, Want, Eps) ->
    length(Got) =:= length(Want) andalso
        lists:all(
            fun({#{lat := A, lng := B}, #{<<"lat">> := C, <<"lng">> := D}}) ->
                abs(A - C) < Eps andalso abs(B - D) < Eps
            end,
            lists:zip(Got, Want)
        ).

polyline_parity_vectors_test() ->
    V = vectors(),
    [
        ?assertEqual(Exp, ?P:encode([ll(P) || P <- In]))
     || #{<<"input">> := In, <<"expected">> := Exp} <- maps:get(<<"encodePolyline">>, V)
    ],
    [
        begin
            {ok, Got} = ?P:decode(In),
            ?assert(close(Got, Exp, 1.0e-9))
        end
     || #{<<"input">> := In, <<"expected">> := Exp} <- maps:get(<<"decodePolyline">>, V)
    ],
    [
        begin
            {ok, Got} = ?P:decode_flex(In),
            ?assert(close(Got, Exp, 1.0e-9))
        end
     || #{<<"input">> := In, <<"expected">> := Exp} <- maps:get(<<"decodeFlexPolyline">>, V)
    ],
    [
        ?assertEqual(
            Exp,
            json:decode(
                iolist_to_binary(
                    json:encode(?P:encode_esri_paths([[ll(P) || P <- Path] || Path <- In]))
                )
            )
        )
     || #{<<"input">> := In, <<"expected">> := Exp} <- maps:get(<<"encodeEsriPaths">>, V)
    ].

polyline_roundtrip_test() ->
    Coords = [
        #{lat => 38.5, lng => -120.2},
        #{lat => 40.7, lng => -120.95},
        #{lat => 43.252, lng => -126.453}
    ],
    {ok, Got} = ?P:decode(?P:encode(Coords)),
    ?assert(
        close(
            Got, [#{<<"lat">> => La, <<"lng">> => Ln} || #{lat := La, lng := Ln} <- Coords], 1.0e-5
        )
    ).

polyline_decode_malformed_test() ->
    ?assertMatch({error, #{code := unknown}}, ?P:decode(<<"_p~iF~ps|U_ulL_">>)),
    ?assertMatch({error, #{code := unknown}}, ?P:decode_flex(<<"!!">>)).

polyline_misuse_is_badarg_test() ->
    ?assertError(badarg, ?P:encode([#{lat => <<"1">>, lng => 2}])),
    ?assertError(badarg, ?P:decode("not a binary")).

%% ---------------------------------------------------------------------------
%% Passthrough, errors, util

passthrough_deep_merge_and_wins_test() ->
    {Body, Headers, Query} = thinwrap_location_passthrough:merge(
        #{<<"a">> => 1, <<"nested">> => #{<<"x">> => 1}},
        #{<<"Authorization">> => <<"Bearer k">>},
        [{<<"key">>, <<"orig">>}],
        #{
            passthrough => #{
                body => #{a => 9, nested => #{y => 2}},
                headers => #{<<"X-Trace">> => <<"abc">>},
                query => #{pretty => <<"true">>}
            }
        }
    ),
    ?assertEqual(#{<<"a">> => 9, <<"nested">> => #{<<"x">> => 1, <<"y">> => 2}}, Body),
    ?assertEqual(#{<<"Authorization">> => <<"Bearer k">>, <<"X-Trace">> => <<"abc">>}, Headers),
    ?assertEqual([{<<"key">>, <<"orig">>}, {<<"pretty">>, <<"true">>}], Query).

passthrough_absent_is_identity_test() ->
    ?assertEqual(
        {#{<<"a">> => 1}, #{<<"H">> => <<"v">>}, [{<<"q">>, <<"v">>}]},
        thinwrap_location_passthrough:merge(
            #{<<"a">> => 1}, #{<<"H">> => <<"v">>}, [{<<"q">>, <<"v">>}], #{}
        )
    ).

passthrough_query_replaces_list_valued_key_test() ->
    {_, _, Q} = thinwrap_location_passthrough:merge(
        #{}, #{}, [{<<"avoid">>, [<<"tollRoads">>]}], #{
            passthrough => #{query => #{<<"avoid">> => <<"unpavedRoads">>}}
        }
    ),
    ?assertEqual([{<<"avoid">>, <<"unpavedRoads">>}], Q).

header_override_is_case_insensitive_test() ->
    ?assertEqual(
        #{<<"x-goog-fieldmask">> => <<"b">>},
        thinwrap_location_http:merge_headers(#{<<"X-Goog-FieldMask">> => <<"a">>}, #{
            <<"x-goog-fieldmask">> => <<"b">>
        })
    ).

provider_error_retry_after_test() ->
    E = thinwrap_location_error:provider_error(
        429,
        #{<<"retry-after">> => <<"30">>},
        #{<<"message">> => <<"slow down">>},
        rate_limited,
        <<"slow down">>
    ),
    ?assertMatch(
        #{
            code := rate_limited,
            status := 429,
            provider_message := <<"slow down; retry after 30 seconds">>,
            cause := #{<<"retryAfter">> := <<"30">>, <<"message">> := <<"slow down">>}
        },
        E
    ).

provider_error_no_retry_test() ->
    Body = #{<<"error">> => <<"bad">>},
    ?assertMatch(
        #{cause := Body, provider_message := <<"bad">>, message := <<"bad">>},
        thinwrap_location_error:provider_error(400, #{}, Body, invalid_request, <<"bad">>)
    ).

provider_error_redacts_cause_test() ->
    E = thinwrap_location_error:provider_error(
        400,
        #{},
        #{<<"echo">> => <<"https://h/x?key=supersecret">>},
        invalid_request,
        <<"bad key=supersecret">>
    ),
    ?assertEqual(nomatch, binary:match(term_to_binary(E), <<"supersecret">>)).

coordinate_formatting_test() ->
    C = #{lat => 40.7128, lng => -74.006},
    ?assertEqual(<<"40.7128,-74.006">>, ?U:to_lat_lng(C)),
    ?assertEqual(<<"-74.006,40.7128">>, ?U:to_lng_lat(C)),
    ?assertEqual(
        <<"2,1;4,3">>,
        ?U:join_coords([#{lat => 1, lng => 2}, #{lat => 3, lng => 4}], lnglat, <<";">>)
    ),
    ?assertEqual(<<"0.00005">>, ?U:fmt_coord(5.0e-5)),
    ?assertEqual(<<"40">>, ?U:fmt_coord(40.0)).

build_url_repeats_a_list_valued_key_test() ->
    ?assertEqual(
        <<"https://h/p?avoid=tollRoads&avoid=motorways&key=k">>,
        ?U:build_url(<<"https://h/p">>, [
            {<<"avoid">>, [<<"tollRoads">>, <<"motorways">>]}, {<<"key">>, <<"k">>}
        ])
    ),
    ?assertEqual(
        <<"https://h/p?q=a%2Cb">>, ?U:build_url(<<"https://h/p">>, [{<<"q">>, <<"a,b">>}])
    ).

redact_credentials_masks_url_userinfo_test() ->
    ?assertEqual(
        <<"GET https://[REDACTED]@host/x failed">>,
        ?U:redact_credentials(<<"GET https://alice:s3cret@host/x failed">>)
    ),
    ?assertEqual(<<"x?key=[REDACTED]&a=1">>, ?U:redact_credentials(<<"x?key=abc&a=1">>)),
    ?assertEqual(
        <<"https://[REDACTED]@host:8443/osrm">>,
        ?U:redact_url_userinfo(<<"https://alice:s3cret@host:8443/osrm">>)
    ),
    ?assertEqual(<<"[REDACTED]@host">>, ?U:redact_url_userinfo(<<"alice:s3cret@host">>)),
    ?assertEqual(<<"https://host/path@x">>, ?U:redact_url_userinfo(<<"https://host/path@x">>)).

waypoint_order_helpers_test() ->
    ?assert(?U:is_complete_waypoint_order([0, 2, 1, 3], 4)),
    ?assertNot(?U:is_complete_waypoint_order([0, 0, 3], 3)),
    ?assertNot(?U:is_complete_waypoint_order([0, 1], 3)),
    ?assertNot(?U:is_complete_waypoint_order([0, true, 2], 3)),
    ?assertEqual([0, 2, 1], ?U:invert_waypoint_positions([0, 2, 1], 3)),
    ?assertEqual([1, 2, 0], ?U:invert_waypoint_positions([2, 0, 1], 3)),
    ?assertEqual([0, 1], ?U:invert_waypoint_positions([0.0, 1.0], 2)),
    ?assertEqual(undefined, ?U:invert_waypoint_positions([0, 0], 2)).

departure_time_forms_test() ->
    Want = <<"2026-01-02T03:04:05.000Z">>,
    ?assertEqual(Want, ?U:iso_string(1767323045, <<"t">>)),
    ?assertEqual(Want, ?U:iso_string({{2026, 1, 2}, {3, 4, 5}}, <<"t">>)),
    ?assertEqual(Want, ?U:iso_string(<<"2026-01-02T05:04:05+02:00">>, <<"t">>)),
    ?assertEqual(
        <<"2026-01-02T03:04:05Z">>, ?U:iso_seconds_string(<<"2026-01-02T03:04:05.789Z">>, <<"t">>)
    ),
    ?assertThrow(
        {thinwrap_location_error, #{code := invalid_request}},
        ?U:iso_string(<<"tomorrow">>, <<"t">>)
    ),
    %% calendar:rfc3339_to_system_time/2 alone would roll month 13 into 2027.
    [
        ?assertThrow(
            {thinwrap_location_error, #{code := invalid_request}}, ?U:iso_string(Bad, <<"t">>)
        )
     || Bad <- [<<"2026-13-01T00:00:00Z">>, <<"2026-02-30T00:00:00Z">>, <<"2026-01-01T24:00:00Z">>]
    ].

json_decode_is_lenient_test() ->
    ?assertEqual(undefined, thinwrap_location_json:decode(<<>>)),
    ?assertEqual(undefined, thinwrap_location_json:decode(<<"{bad">>)),
    ?assertEqual(undefined, thinwrap_location_json:decode(<<"NaN">>)),
    ?assertEqual(#{<<"a">> => null}, thinwrap_location_json:decode(<<"{\"a\":null}">>)),
    ?assertEqual(undefined, thinwrap_location_json:get(#{<<"a">> => null}, <<"a">>)).

json_encode_invalid_utf8_is_invalid_request_test() ->
    ?assertThrow(
        {thinwrap_location_error, #{code := invalid_request, cause := invalid_byte}},
        thinwrap_location_json:encode(#{<<"a">> => <<255>>})
    ).

%% ---------------------------------------------------------------------------
%% Public surface: misuse is badarg, never {error, _}

google() -> #{provider => google, api_key => <<"k">>}.
two() -> [#{lat => 1, lng => 1}, #{lat => 2, lng => 2}].

misuse_is_badarg_test_() ->
    [
        ?_assertError({badarg, _}, thinwrap_location:route(undefined, #{waypoints => two()})),
        ?_assertError(
            {badarg, _}, thinwrap_location:route(#{provider => nope}, #{waypoints => two()})
        ),
        ?_assertError(
            {badarg, _}, thinwrap_location:route(#{provider => google}, #{waypoints => two()})
        ),
        ?_assertError(
            {badarg, _},
            thinwrap_location:route((google())#{apikey => <<"x">>}, #{waypoints => two()})
        ),
        ?_assertError(
            {badarg, _}, thinwrap_location:route((google())#{api_key => 42}, #{waypoints => two()})
        ),
        ?_assertError(
            {badarg, _},
            thinwrap_location:route((google())#{transport => "x"}, #{waypoints => two()})
        ),
        ?_assertError(
            {badarg, _},
            thinwrap_location:route((google())#{transport => {no_such_mod_xyz, #{}}}, #{
                waypoints => two()
            })
        ),
        ?_assertError({badarg, _}, thinwrap_location:route(google(), #{})),
        ?_assertError(
            {badarg, _},
            thinwrap_location:route(google(), #{waypoints => two(), travel_mode => flying})
        ),
        ?_assertError(
            {badarg, _},
            thinwrap_location:route(google(), #{waypoints => two(), travel_mode => <<"driving">>})
        ),
        ?_assertError(
            {badarg, _}, thinwrap_location:route(google(), #{waypoints => two(), optimise => true})
        ),
        ?_assertError(
            {badarg, _}, thinwrap_location:route(google(), #{waypoints => [#{lat => 1}]})
        ),
        ?_assertError(
            {badarg, _},
            thinwrap_location:route(google(), #{
                waypoints => two(), include => durationWithoutTraffic
            })
        ),
        ?_assertError(
            {badarg, _},
            thinwrap_location:route(google(), #{waypoints => two(), departure_time => 1.5})
        ),
        ?_assertError(
            {badarg, _},
            thinwrap_location:route(google(), #{waypoints => two(), passthrough => #{bdy => #{}}})
        ),
        ?_assertError(
            {badarg, _},
            thinwrap_location:isochrone(google(), #{
                center => #{lat => 1, lng => 1}, type => time, values => [60]
            })
        ),
        ?_assertError(
            {badarg, _},
            thinwrap_location:geocode(#{provider => osrm, base_url => <<"https://o">>}, #{
                address => <<"x">>
            })
        )
    ].

badarg_never_echoes_the_secret_test() ->
    try
        thinwrap_location:route(#{provider => google, api_key => <<"supersecret">>, apikey => 1}, #{
            waypoints => two()
        })
    of
        _ -> ?assert(false)
    catch
        error:Reason:Stack ->
            ?assertEqual(nomatch, binary:match(term_to_binary({Reason, Stack}), <<"supersecret">>))
    end.

secret_fun_is_resolved_at_use_test() ->
    {C, P} = ?F:config(#{provider => google, api_key => fun() -> <<"from-fun">> end}, [
        ?F:resp(200, <<"{\"status\":\"OK\",\"results\":[]}">>)
    ]),
    {ok, _} = thinwrap_location:geocode(C, #{address => <<"x">>}),
    ?assertEqual(<<"from-fun">>, ?F:qget(?F:last(P), <<"key">>)).

supports_test() ->
    ?assert(thinwrap_location:supports(osrm, route)),
    ?assertNot(thinwrap_location:supports(osrm, geocode)),
    ?assertNot(thinwrap_location:supports(google, isochrone)),
    ?assert(thinwrap_location:supports(tomtom, isochrone)).

%% ---------------------------------------------------------------------------
%% Transport failure normalization

transport_error_redacts_and_normalizes_test() ->
    {C, _} = ?F:config(#{provider => google, api_key => <<"supersecret">>}, [
        {error,
            {failed_connect,
                "Get \"https://api.example.com/x?key=supersecret\": connection refused"}}
    ]),
    {error, E} = thinwrap_location:route(C, #{waypoints => two()}),
    ?assertMatch(#{code := provider_unavailable, cause := _}, E),
    ?assertNot(maps:is_key(status, E)),
    ?assertEqual(nomatch, binary:match(term_to_binary(E), <<"supersecret">>)),
    ?assertNotEqual(nomatch, binary:match(maps:get(message, E), <<"[REDACTED]">>)).

transport_timeouts_are_timeout_test_() ->
    [
        ?_test(begin
            {C, _} = ?F:config(google(), [{error, Reason}]),
            ?assertMatch(
                {error, #{code := timeout}}, thinwrap_location:route(C, #{waypoints => two()})
            )
        end)
     || Reason <- [timeout, {failed_connect, [{to_address, {"h", 443}}, {inet, [inet], timeout}]}]
    ].

%% A transport that crashes, or breaks its return contract.
request(_Req, crash) ->
    erlang:error({boom, <<"https://h/x?key=supersecret">>});
request(_Req, bad_return) ->
    {ok, not_a_map};
request(_Req, typed) ->
    {error, {connector_error, thinwrap_location_error:invalid_request(<<"nope">>)}}.

crashing_transport_is_provider_unavailable_test() ->
    C = (google())#{transport => {?MODULE, crash}},
    {error, E} = thinwrap_location:route(C, #{waypoints => two()}),
    ?assertMatch(#{code := provider_unavailable}, E),
    ?assertEqual(nomatch, binary:match(term_to_binary(E), <<"supersecret">>)).

contract_breaking_transport_is_an_error_not_an_outage_test() ->
    C = (google())#{transport => {?MODULE, bad_return}},
    ?assertError(
        {bad_transport_return, ?MODULE, _}, thinwrap_location:route(C, #{waypoints => two()})
    ).

typed_transport_error_passes_through_test() ->
    C = (google())#{transport => {?MODULE, typed}},
    ?assertMatch(
        {error, #{code := invalid_request, message := <<"nope">>}},
        thinwrap_location:route(C, #{waypoints => two()})
    ).

%% uri_string:quote/1 throws on non-UTF-8; a path-segment value is request
%% data, so it must surface as invalid_request before any HTTP.
non_utf8_path_segment_is_invalid_request_test_() ->
    Bad = <<255, "x">>,
    [
        ?_test(begin
            {C, P} = thinwrap_location_fake_transport:config(Config, []),
            ?assertMatch({error, #{code := invalid_request}}, Call(C)),
            ?assertEqual([], thinwrap_location_fake_transport:calls(P))
        end)
     || {Config, Call} <- [
            {#{provider => google, api_key => <<"k">>}, fun(C) ->
                thinwrap_location:place_details(C, #{place_id => Bad})
            end},
            {#{provider => tomtom, api_key => <<"k">>}, fun(C) ->
                thinwrap_location:geocode(C, #{address => Bad})
            end}
        ]
    ].
