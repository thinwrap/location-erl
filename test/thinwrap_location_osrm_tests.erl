-module(thinwrap_location_osrm_tests).

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_location_fake_transport).
-define(TWO, [#{lat => 40, lng => -74}, #{lat => 41, lng => -73}]).
-define(THREE, [#{lat => 1, lng => 1}, #{lat => 2, lng => 2}, #{lat => 3, lng => 3}]).
-define(WHEN, {{2026, 9, 28}, {21, 30, 0}}).
-define(ROUTE_OK,
    <<"{\"code\":\"Ok\",\"routes\":[{\"geometry\":\"_p~iF~ps|U_ulLnnqC\",\"legs\":[{\"distance\":1000,\"duration\":600}],\"distance\":1000,\"duration\":600}]}">>
).
-define(V120_BODY,
    <<"{\"code\":\"Ok\",\"routes\":[{\"geometry\":\"abc\",\"legs\":[{\"distance\":5000,\"duration\":300}],\"distance\":5000,\"duration\":300}]}">>
).
-define(TRIP_OK2,
    <<"{\"code\":\"Ok\",\"trips\":[{\"geometry\":\"_p~iF~ps|U\",\"legs\":[{\"distance\":5,\"duration\":6}],\"distance\":5,\"duration\":6}],\"waypoints\":[{\"waypoint_index\":0},{\"waypoint_index\":1}]}">>
).
-define(TRIP_OK3,
    <<"{\"code\":\"Ok\",\"trips\":[{\"geometry\":\"_p~iF~ps|U\",\"legs\":[{\"distance\":5,\"duration\":6},{\"distance\":7,\"duration\":8}],\"distance\":12,\"duration\":14}],\"waypoints\":[{\"waypoint_index\":0},{\"waypoint_index\":2},{\"waypoint_index\":1}]}">>
).
-define(TABLE_OK, <<"{\"code\":\"Ok\",\"durations\":[[60]],\"distances\":[[1000]]}">>).

cfg(Responses) -> cfg(<<"http://x">>, Responses).

cfg(BaseUrl, Responses) -> cfg(BaseUrl, [], Responses).

cfg(BaseUrl, Classes, Responses) ->
    ?F:config(
        #{provider => osrm, base_url => BaseUrl, supported_exclude_classes => Classes}, Responses
    ).

ll(Lat, Lng) -> #{lat => Lat, lng => Lng}.

has_query(Req, Key) -> ?F:qall(Req, Key) =/= [].

starts_with(Bin, Prefix) ->
    byte_size(Bin) >= byte_size(Prefix) andalso
        binary:part(Bin, 0, byte_size(Prefix)) =:= Prefix.

contains(Bin, Part) -> binary:match(Bin, Part) =/= nomatch.

route(Input, Responses) -> route(<<"http://x">>, [], Input, Responses).

route(BaseUrl, Classes, Input, Responses) ->
    {C, P} = cfg(BaseUrl, Classes, Responses),
    {thinwrap_location:route(C, Input), P}.

matrix(Input, Responses) -> matrix([], Input, Responses).

matrix(Classes, Input, Responses) ->
    {C, P} = cfg(<<"http://x">>, Classes, Responses),
    {
        thinwrap_location:matrix(
            C, maps:merge(#{origins => [ll(1, 1)], destinations => [ll(2, 2)]}, Input)
        ),
        P
    }.

%% ---------------------------------------------------------------------------
%% Routing

routing_test() ->
    {{ok, R}, P} = route(<<"http://localhost:5000">>, [], #{waypoints => ?TWO}, [
        ?F:resp(200, ?ROUTE_OK)
    ]),
    ?assertEqual(1000.0, maps:get(total_distance_meters, R)),
    ?assertEqual(600.0, maps:get(total_duration_seconds, R)),
    ?assertEqual(<<"_p~iF~ps|U_ulLnnqC">>, maps:get(polyline, R)),
    ?assertEqual([#{distance_meters => 1000.0, duration_seconds => 600.0}], maps:get(legs, R)),
    ?assertNot(maps:is_key(waypoint_order, R)),
    Last = ?F:last(P),
    ?assertEqual(
        <<"http://localhost:5000/route/v1/driving/-74,40;-73,41?overview=simplified&geometries=polyline">>,
        maps:get(url, Last)
    ),
    ?assertEqual(<<"/route/v1/driving/-74,40;-73,41">>, ?F:path_of(Last)).

profile_follows_travel_mode_test_() ->
    [
        ?_test(begin
            {{ok, _}, P} = route(#{waypoints => ?TWO, travel_mode => Mode}, [
                ?F:resp(200, ?ROUTE_OK)
            ]),
            ?assertEqual(
                <<"/route/v1/", (atom_to_binary(Mode))/binary, "/-74,40;-73,41">>,
                ?F:path_of(?F:last(P))
            )
        end)
     || Mode <- [driving, walking, cycling]
    ].

requires_base_url_test() ->
    {Res, P} = route(<<>>, [], #{waypoints => ?TWO}, []),
    ?assertMatch(
        {error, #{code := invalid_request, provider_message := <<"baseUrl is required for OSRM">>}},
        Res
    ),
    {error, E} = Res,
    ?assertNot(maps:is_key(status, E)),
    ?assertEqual([], ?F:calls(P)).

preflight_test_() ->
    [
        ?_test(begin
            {Res, P} = route(Input#{waypoints => ?TWO}, []),
            ?assertMatch({error, #{code := unsupported_option}}, Res),
            ?assertEqual([], ?F:calls(P))
        end)
     || Input <- [#{avoid_tolls => true}, #{avoid_ferries => true}]
    ].

%% Plain optimize would be source=any/destination=any/roundtrip=false — the
%% combo OSRM rejects with HTTP 400. It must be remapped to first/last.
plain_optimize_remaps_to_first_last_test() ->
    {{ok, _}, P} = route(#{waypoints => ?TWO, optimize => true}, [?F:resp(200, ?TRIP_OK2)]),
    Last = ?F:last(P),
    ?assertEqual(<<"first">>, ?F:qget(Last, <<"source">>)),
    ?assertEqual(<<"last">>, ?F:qget(Last, <<"destination">>)),
    ?assertEqual(<<"false">>, ?F:qget(Last, <<"roundtrip">>)).

%% The OSRM Trip service returns route objects under `trips`, not `routes`.
trip_waypoint_order_test() ->
    Body =
        <<"{\"code\":\"Ok\",\"trips\":[{\"geometry\":\"_p~iF~ps|U\",\"legs\":[{\"distance\":5,\"duration\":6}],\"distance\":5,\"duration\":6}],\"waypoints\":[{\"waypoint_index\":0},{\"waypoint_index\":2},{\"waypoint_index\":1}]}">>,
    {{ok, R}, P} = route(#{waypoints => ?THREE, is_round_trip => true}, [?F:resp(200, Body)]),
    ?assertEqual([0, 2, 1], maps:get(waypoint_order, R)),
    Last = ?F:last(P),
    ?assertEqual(<<"/trip/v1/driving/1,1;2,2;3,3">>, ?F:path_of(Last)),
    ?assertEqual(
        [<<"any">>, <<"any">>, <<"true">>],
        [?F:qget(Last, K) || K <- [<<"source">>, <<"destination">>, <<"roundtrip">>]]
    ).

in_body_error_test() ->
    %% The in-body path is only reachable on a 2xx, so it reports the REAL
    %% status: an answered request must not look like a transport failure.
    {Res1, _} = route(#{waypoints => ?TWO}, [
        ?F:resp(
            200, <<"{\"code\":\"NoRoute\",\"message\":\"Impossible route: profile not found\"}">>
        )
    ]),
    ?assertMatch({error, #{code := profile_not_configured, status := 200}}, Res1),
    %% A generic NoRoute is no_route: a missing profile is never inferred from
    %% a bare NoRoute — it must be stated in the message (above).
    {Res2, _} = route(#{waypoints => ?TWO}, [
        ?F:resp(200, <<"{\"code\":\"NoRoute\",\"message\":\"no route\"}">>)
    ]),
    ?assertMatch({error, #{code := no_route, provider_message := <<"no route">>}}, Res2).

in_body_unknown_code_test_() ->
    [
        ?_test(begin
            {Res, _} = route(#{waypoints => ?TWO}, [?F:resp(200, Body)]),
            ?assertMatch({error, #{code := Want, status := 200, provider_message := Msg}}, Res)
        end)
     || {Body, Want, Msg} <- [
            {<<"{\"code\":\"Weird\"}">>, unknown, <<"OSRM returned code: Weird">>},
            {<<"{}">>, unknown, <<"OSRM returned code: unknown">>},
            {<<"[]">>, unknown, <<"OSRM returned code: unknown">>},
            %% NoTrips on a /route dispatch should never occur, so it stays unclassified.
            {<<"{\"code\":\"NoTrips\"}">>, unknown, <<"OSRM returned code: NoTrips">>},
            {<<"{\"code\":\"TooBig\",\"message\":\"too big\"}">>, invalid_request, <<"too big">>}
        ]
    ].

unparseable_2xx_body_is_unknown_test() ->
    {Res, _} = route(#{waypoints => ?TWO}, [?F:resp(200, <<"<html>busy</html>">>)]),
    ?assertMatch(
        {error, #{
            code := unknown,
            status := 200,
            provider_message := <<"OSRM routing returned a malformed response body">>
        }},
        Res
    ).

route_ok_with_empty_routes_is_no_route_test_() ->
    %% An answered request with nothing to return: a consumer branching on
    %% no_route must not need a status heuristic beside it.
    [
        ?_test(begin
            {{error, E}, _} = route(<<"http://localhost:5000">>, [], #{waypoints => ?TWO}, [
                ?F:resp(200, Body)
            ]),
            ?assertMatch(#{code := no_route, status := 200}, E),
            ?assert(contains(maps:get(provider_message, E), <<"no routes">>))
        end)
     || Body <- [
            <<"{\"code\":\"Ok\",\"routes\":[]}">>,
            <<"{\"code\":\"Ok\",\"routes\":[],\"trips\":[]}">>
        ]
    ].

trip_ok_with_empty_trips_names_trips_test() ->
    {{error, E}, _} = route(#{waypoints => ?TWO, optimize => true}, [
        ?F:resp(200, <<"{\"code\":\"Ok\",\"trips\":[]}">>)
    ]),
    ?assertMatch(
        #{code := no_route, provider_message := <<"OSRM returned no trips with envelope code Ok">>},
        E
    ).

%% OSRM >= 5.27 (trip.cpp IsSupportedParameterCombination = roundtrip ||
%% fixed_start || fixed_end) answers first/any and any/last with
%% roundtrip=false — live 200 Ok on router.project-osrm.org — so a single fixed
%% endpoint is sent as asked.
open_trip_with_a_single_fixed_endpoint_is_sent_as_is_test_() ->
    [
        ?_test(begin
            {{ok, R}, P} = route(
                <<"https://x">>, [], Fixed#{waypoints => ?THREE, optimize => true}, [
                    ?F:resp(200, ?TRIP_OK3)
                ]
            ),
            Last = ?F:last(P),
            ?assert(starts_with(?F:path_of(Last), <<"/trip/v1/">>)),
            ?assertEqual(
                [Source, Destination, <<"false">>],
                [?F:qget(Last, K) || K <- [<<"source">>, <<"destination">>, <<"roundtrip">>]]
            ),
            ?assertEqual([0, 2, 1], maps:get(waypoint_order, R))
        end)
     || {Fixed, Source, Destination} <- [
            {#{optimize_fixed_origin => true}, <<"first">>, <<"any">>},
            {#{optimize_fixed_destination => true}, <<"any">>, <<"last">>}
        ]
    ].

open_trip_single_fixed_endpoint_without_plain_optimize_still_uses_trip_test() ->
    {{ok, _}, P} = route(
        <<"https://x">>, [], #{waypoints => ?THREE, optimize_fixed_origin => true}, [
            ?F:resp(200, ?TRIP_OK3)
        ]
    ),
    Last = ?F:last(P),
    ?assert(starts_with(?F:path_of(Last), <<"/trip/v1/">>)),
    ?assertEqual(<<"first">>, ?F:qget(Last, <<"source">>)),
    ?assertEqual(<<"any">>, ?F:qget(Last, <<"destination">>)).

%% A pre-5.27 server (or any/any, were it sent) answers 400 NotImplemented.
not_implemented_from_an_older_server_is_unsupported_option_test() ->
    Body = <<"{\"code\":\"NotImplemented\",\"message\":\"This request is not supported\"}">>,
    {Res, _} = route(<<"https://x">>, [], #{waypoints => ?THREE, optimize_fixed_origin => true}, [
        ?F:resp(400, Body)
    ]),
    ?assertMatch({error, #{code := unsupported_option, status := 400}}, Res).

invalid_base_url_message_does_not_echo_userinfo_test() ->
    {{error, E}, P} = route(<<"alice:s3cret@osrm.internal">>, [], #{waypoints => ?TWO}, []),
    ?assertMatch(#{code := invalid_request}, E),
    Text = iolist_to_binary(io_lib:format("~p", [E])),
    ?assertNot(contains(Text, <<"s3cret">>)),
    ?assertNot(contains(Text, <<"alice">>)),
    ?assert(contains(maps:get(message, E), <<"osrm.internal">>)),
    ?assertEqual([], ?F:calls(P)).

transport_failure_message_does_not_echo_userinfo_test() ->
    Url = "https://alice:s3cret@osrm.invalid/route/v1/driving/-74,40;-73,41",
    {{error, E}, _} = route(<<"https://alice:s3cret@osrm.invalid">>, [], #{waypoints => ?TWO}, [
        {error, {failed_connect, [{to_address, Url}, {inet, [inet], nxdomain}]}}
    ]),
    ?assertMatch(#{code := provider_unavailable}, E),
    ?assertNot(contains(iolist_to_binary(io_lib:format("~p", [E])), <<"s3cret">>)).

default_transport_refuses_http_with_invalid_request_test() ->
    Config = #{provider => osrm, base_url => <<"http://alice:s3cret@localhost:5000">>},
    {error, E} = thinwrap_location:route(Config, #{waypoints => ?TWO}),
    ?assertMatch(#{code := invalid_request}, E),
    Msg = maps:get(message, E),
    ?assert(contains(Msg, <<"HTTPS-only">>)),
    ?assert(contains(Msg, <<"ransport">>)),
    Text = iolist_to_binary(io_lib:format("~p", [E])),
    ?assertNot(contains(Text, <<"s3cret">>)),
    ?assertNot(contains(Text, <<"localhost">>)).

supported_trip_endpoint_combinations_are_sent_test_() ->
    [
        ?_test(begin
            {{ok, _}, P} = route(Input#{waypoints => ?TWO, optimize => true}, [
                ?F:resp(200, ?TRIP_OK2)
            ]),
            Last = ?F:last(P),
            ?assert(starts_with(?F:path_of(Last), <<"/trip/v1/">>)),
            ?assertEqual(
                Want, [?F:qget(Last, K) || K <- [<<"source">>, <<"destination">>, <<"roundtrip">>]]
            )
        end)
     || {Input, Want} <- [
            %% true/first/any — a supported round-trip combination.
            {#{is_round_trip => true, optimize_fixed_origin => true}, [
                <<"first">>, <<"any">>, <<"true">>
            ]},
            %% false/first/last — the only supported open combination.
            {#{optimize_fixed_origin => true, optimize_fixed_destination => true}, [
                <<"first">>, <<"last">>, <<"false">>
            ]}
        ]
    ].

trip_no_trips_on_a_400_is_no_route_test() ->
    {Res, _} = route(#{waypoints => ?THREE, optimize => true}, [
        ?F:resp(
            400,
            <<"{\"code\":\"NoTrips\",\"message\":\"No trip visiting all destinations possible.\"}">>
        )
    ]),
    ?assertMatch({error, #{code := no_route, status := 400}}, Res).

routing_malformed_route_is_unknown_test_() ->
    [
        ?_test(begin
            {Res, _} = route(#{waypoints => ?TWO}, [?F:resp(200, Body)]),
            ?assertMatch({error, #{code := unknown}}, Res)
        end)
     || Body <- [
            <<"{\"code\":\"Ok\",\"routes\":[null]}">>,
            <<"{\"code\":\"Ok\",\"routes\":[{\"distance\":1,\"duration\":1,\"geometry\":\"\",\"legs\":[null]}]}">>,
            <<"{\"code\":\"Ok\",\"routes\":[{\"duration\":1,\"geometry\":\"\",\"legs\":[{\"distance\":1,\"duration\":1}]}]}">>,
            <<"{\"code\":\"Ok\",\"routes\":[{\"distance\":1,\"duration\":1,\"geometry\":\"\",\"legs\":[{\"distance\":1}]}]}">>,
            <<"{\"code\":\"Ok\",\"routes\":{\"a\":1}}">>
        ]
    ].

%% THE path that actually fires in production: OSRM serves every non-Ok
%% envelope code with a 4xx, so the code — not the status — must be read.
classifies_a_400_by_its_envelope_code_test_() ->
    [
        ?_test(begin
            Body = iolist_to_binary(json:encode(#{code => Code, message => <<"vendor text">>})),
            {Res, _} = route(#{waypoints => ?TWO}, [?F:resp(400, Body)]),
            ?assertMatch(
                {error, #{code := Want, status := 400, provider_message := <<"vendor text">>}}, Res
            )
        end)
     || {Code, Want} <- [
            {<<"NoRoute">>, no_route},
            {<<"NoSegment">>, no_route},
            {<<"InvalidOptions">>, invalid_request},
            {<<"InvalidValue">>, invalid_request},
            {<<"InvalidQuery">>, invalid_request},
            {<<"Unrecognised">>, invalid_request}
        ]
    ].

keeps_profile_not_configured_ahead_of_no_route_test() ->
    {Res, _} = route(#{waypoints => ?TWO}, [
        ?F:resp(400, <<"{\"code\":\"NoRoute\",\"message\":\"Profile Not  Found\"}">>)
    ]),
    ?assertMatch({error, #{code := profile_not_configured}}, Res).

%% Proxy-layer statuses win: a 401/429 from a reverse proxy has no OSRM envelope.
http_status_mapping_test_() ->
    [
        ?_test(begin
            {{error, E}, _} = route(#{waypoints => ?TWO}, [?F:resp(Status, Body, Headers)]),
            ?assertMatch(#{code := Want, status := Status}, E),
            case map_size(Headers) of
                0 -> ok;
                _ -> ?assertMatch(#{<<"retryAfter">> := <<"3">>}, maps:get(cause, E))
            end
        end)
     || {Status, Body, Headers, Want} <- [
            {401, <<"{\"code\":\"NoRoute\"}">>, #{}, auth_failed},
            {403, <<>>, #{}, auth_failed},
            {429, <<>>, #{<<"Retry-After">> => <<"3">>}, rate_limited},
            {502, <<"<html>bad gateway</html>">>, #{}, provider_unavailable},
            {404, <<"{\"error\":\"not found\"}">>, #{}, invalid_request},
            {418, <<>>, #{}, unknown}
        ]
    ].

http_error_message_falls_back_to_the_error_field_test() ->
    {Res, _} = route(#{waypoints => ?TWO}, [?F:resp(404, <<"{\"error\":\"not found\"}">>)]),
    ?assertMatch({error, #{provider_message := <<"not found">>}}, Res).

trip_omits_corrupt_waypoint_order_test_() ->
    [
        ?_test(begin
            Body = <<
                "{\"code\":\"Ok\",\"trips\":[{\"geometry\":\"abc\",\"legs\":[{\"distance\":1500,\"duration\":90}],"
                "\"distance\":4000,\"duration\":240}],\"waypoints\":",
                Wps/binary,
                "}"
            >>,
            {{ok, R}, _} = route(
                <<"http://localhost:5000">>,
                [],
                #{
                    waypoints => ?THREE, optimize => true
                },
                [?F:resp(200, Body)]
            ),
            ?assertNot(maps:is_key(waypoint_order, R)),
            ?assertEqual(4000.0, maps:get(total_distance_meters, R))
        end)
     || Wps <- [
            %% duplicate
            <<"[{\"waypoint_index\":0},{\"waypoint_index\":0},{\"waypoint_index\":2}]">>,
            %% truncated
            <<"[{\"waypoint_index\":0},{\"waypoint_index\":1}]">>,
            %% out of range
            <<"[{\"waypoint_index\":0},{\"waypoint_index\":1},{\"waypoint_index\":7}]">>,
            %% missing
            <<"[{\"waypoint_index\":0},{},{\"waypoint_index\":2}]">>
        ]
    ].

%% ---------------------------------------------------------------------------
%% base_url validation

rejects_schemeless_base_url_test_() ->
    [
        ?_test(begin
            {Res, P} = route(BaseUrl, [], #{waypoints => ?THREE}, [?F:resp(200, <<"{}">>)]),
            ?assertMatch(
                {error, #{
                    code := invalid_request,
                    provider_message := <<"OSRM baseUrl must start with http:// or https://">>
                }},
                Res
            ),
            {error, E} = Res,
            ?assertNot(maps:is_key(status, E)),
            %% Rejected before any HTTP work.
            ?assertEqual([], ?F:calls(P))
        end)
     || BaseUrl <- [
            <<"router.example.com">>,
            <<"//router.example.com">>,
            <<"ftp://router.example.com">>,
            <<"/osrm">>,
            <<"osrm.example">>,
            <<"https:/x">>
        ]
    ].

scheme_check_is_case_insensitive_test() ->
    {{ok, _}, P} = route(<<"HTTPS://router.example.com">>, [], #{waypoints => ?TWO}, [
        ?F:resp(200, ?ROUTE_OK)
    ]),
    ?assertEqual(<<"/route/v1/driving/-74,40;-73,41">>, ?F:path_of(?F:last(P))).

allows_path_prefix_and_strips_trailing_slashes_test_() ->
    [
        ?_test(begin
            {{ok, _}, P} = route(BaseUrl, [], #{waypoints => ?TWO}, [?F:resp(200, ?ROUTE_OK)]),
            ?assertEqual(WantPath, ?F:path_of(?F:last(P)))
        end)
     || {BaseUrl, WantPath} <- [
            %% A reverse-proxied OSRM under a path prefix is a normal deployment.
            {<<"https://router.example.com/osrm">>, <<"/osrm/route/v1/driving/-74,40;-73,41">>},
            {<<"https://router.example.com/">>, <<"/route/v1/driving/-74,40;-73,41">>},
            {<<"https://router.example.com///">>, <<"/route/v1/driving/-74,40;-73,41">>}
        ]
    ].

matrix_validates_base_url_too_test() ->
    {C, P} = cfg(<<"osrm.example">>, [?F:resp(200, ?TABLE_OK)]),
    ?assertMatch(
        {error, #{code := invalid_request}},
        thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]})
    ),
    ?assertEqual([], ?F:calls(P)).

%% ---------------------------------------------------------------------------
%% supported_exclude_classes

rejects_an_undeclared_exclude_class_test_() ->
    [
        ?_test(begin
            {{error, E}, P} = route(Input#{waypoints => ?TWO}, [?F:resp(200, ?V120_BODY)]),
            ?assertMatch(#{code := unsupported_option}, E),
            Msg = maps:get(provider_message, E),
            ?assert(contains(Msg, Class)),
            ?assert(contains(Msg, <<"supported_exclude_classes">>)),
            ?assertEqual([], ?F:calls(P))
        end)
     || {Input, Class} <- [
            {#{avoid_tolls => true}, <<"toll">>},
            {#{avoid_ferries => true}, <<"ferry">>},
            {#{avoid_highways => true}, <<"motorway">>}
        ]
    ].

sends_exclude_for_declared_classes_test() ->
    {{ok, _}, P} = route(
        <<"http://x">>,
        [<<"toll">>, <<"ferry">>],
        #{waypoints => ?TWO, avoid_tolls => true, avoid_ferries => true},
        [?F:resp(200, ?V120_BODY)]
    ),
    ?assertEqual(<<"toll,ferry">>, ?F:qget(?F:last(P), <<"exclude">>)).

still_rejects_a_flag_outside_the_declared_classes_test() ->
    {Res, _} = route(<<"http://x">>, [<<"ferry">>], #{waypoints => ?TWO, avoid_tolls => true}, [
        ?F:resp(200, ?V120_BODY)
    ]),
    ?assertMatch({error, #{code := unsupported_option}}, Res).

omits_exclude_when_no_avoid_flag_is_set_test() ->
    {{ok, _}, P} = route(<<"http://x">>, [<<"toll">>], #{waypoints => ?TWO}, [
        ?F:resp(200, ?V120_BODY)
    ]),
    ?assertNot(has_query(?F:last(P), <<"exclude">>)).

%% ---------------------------------------------------------------------------
%% polyline_quality, steps/annotations, include, no legs

overview_follows_polyline_quality_test_() ->
    [
        ?_test(begin
            {{ok, _}, P} = route(
                #{waypoints => ?TWO, polyline_quality => Quality}, [?F:resp(200, ?V120_BODY)]
            ),
            ?assertEqual(Want, ?F:qget(?F:last(P), <<"overview">>))
        end)
     || {Quality, Want} <- [{simplified, <<"simplified">>}, {detailed, <<"full">>}]
    ].

requests_neither_steps_nor_annotations_test() ->
    {{ok, _}, P} = route(#{waypoints => ?TWO}, [?F:resp(200, ?V120_BODY)]),
    ?assertNot(has_query(?F:last(P), <<"steps">>)),
    ?assertNot(has_query(?F:last(P), <<"annotations">>)).

%% The never-synthesized rule: absence is information.
duration_without_traffic_is_left_absent_test() ->
    {{ok, R}, _} = route(
        #{waypoints => ?TWO, include => [durationWithoutTraffic]}, [?F:resp(200, ?V120_BODY)]
    ),
    [Leg] = maps:get(legs, R),
    ?assertNot(maps:is_key(duration_without_traffic_seconds, Leg)),
    ?assertNot(maps:is_key(total_duration_without_traffic_seconds, R)),
    ?assertEqual(300.0, maps:get(duration_seconds, Leg)).

a_route_with_no_legs_raises_no_route_test() ->
    Body =
        <<"{\"code\":\"Ok\",\"routes\":[{\"geometry\":\"abc\",\"legs\":[],\"distance\":5000,\"duration\":300}]}">>,
    {{error, E}, _} = route(#{waypoints => ?TWO}, [?F:resp(200, Body)]),
    ?assertMatch(#{code := no_route, status := 200}, E),
    ?assert(contains(maps:get(provider_message, E), <<"no legs">>)).

%% ---------------------------------------------------------------------------
%% Traffic: OSRM has no time parameter and no request-time traffic

capture(Op, Input) ->
    {C, P} = cfg(<<"http://osrm.test">>, [{error, captured}]),
    {error, #{code := provider_unavailable}} = thinwrap_location:Op(C, Input),
    hd(?F:calls(P)).

ignores_traffic_and_departure_time_test_() ->
    [
        ?_test(begin
            When =
                case WithTime of
                    true -> #{departure_time => ?WHEN};
                    false -> #{}
                end,
            Reqs = [
                capture(route, maps:merge(#{waypoints => ?TWO, traffic_mode => Mode}, When)),
                capture(
                    matrix,
                    maps:merge(
                        #{origins => [ll(1, 1)], destinations => [ll(2, 2)], traffic_mode => Mode},
                        When
                    )
                )
            ],
            [
                begin
                    Url = maps:get(url, Req),
                    ?assertNot(contains(Url, <<"2026">>)),
                    ?assertNot(contains(Url, <<"traffic">>))
                end
             || Req <- Reqs
            ]
        end)
     || Mode <- [none, traffic, live], WithTime <- [false, true]
    ].

live_alias_sends_the_same_request_as_traffic_test_() ->
    Wire = fun(Mode, When) ->
        [
            maps:with(
                [method, url, body],
                capture(route, maps:merge(#{waypoints => ?TWO, traffic_mode => Mode}, When))
            ),
            maps:with(
                [method, url, body],
                capture(
                    matrix,
                    maps:merge(
                        #{origins => [ll(1, 1)], destinations => [ll(2, 2)], traffic_mode => Mode},
                        When
                    )
                )
            )
        ]
    end,
    [
        ?_assertEqual(Wire(live, When), Wire(traffic, When))
     || When <- [#{}, #{departure_time => ?WHEN}]
    ].

%% ---------------------------------------------------------------------------
%% Matrix

matrix_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"code\":\"Ok\",\"durations\":[[0,60],[60,0]],\"distances\":[[0,1000],[1000,0]]}">>
        )
    ]),
    {ok, #{cells := Cells}} = thinwrap_location:matrix(C, #{
        origins => [ll(1, 1), ll(2, 2)], destinations => [ll(3, 3), ll(4, 4)]
    }),
    ?assertEqual(4, length(Cells)),
    ?assertMatch(#{distance_meters := 1000.0, duration_seconds := 60.0}, lists:nth(2, Cells)),
    Last = ?F:last(P),
    ?assertEqual(<<"duration,distance">>, ?F:qget(Last, <<"annotations">>)),
    ?assertEqual(<<"0;1">>, ?F:qget(Last, <<"sources">>)),
    ?assertEqual(<<"2;3">>, ?F:qget(Last, <<"destinations">>)),
    ?assertEqual(<<"/table/v1/driving/1,1;2,2;3,3;4,4">>, ?F:path_of(Last)).

matrix_in_body_error_test() ->
    {Res, _} = matrix(#{}, [?F:resp(200, <<"{\"code\":\"NoTable\",\"message\":\"no table\"}">>)]),
    ?assertMatch(
        {error, #{code := invalid_request, status := 200, provider_message := <<"no table">>}},
        Res
    ).

matrix_in_body_unknown_test_() ->
    [
        ?_test(begin
            {Res, _} = matrix(#{}, [?F:resp(200, Body)]),
            ?assertMatch({error, #{code := unknown, status := 200, provider_message := Msg}}, Res)
        end)
     || {Body, Msg} <- [
            {<<"{\"code\":\"Strange\"}">>, <<"OSRM returned code: Strange">>},
            {<<"<html/>">>, <<"OSRM returned code: unknown">>},
            %% The Table service never produces NoTrips.
            {<<"{\"code\":\"NoTrips\"}">>, <<"OSRM returned code: NoTrips">>}
        ]
    ].

matrix_dimension_mismatch_test() ->
    {C, _} = cfg([
        ?F:resp(200, <<"{\"code\":\"Ok\",\"durations\":[[0,60]],\"distances\":[[0,1000]]}">>)
    ]),
    ?assertMatch(
        {error, #{code := unknown}},
        thinwrap_location:matrix(C, #{
            origins => [ll(1, 1), ll(2, 2)], destinations => [ll(3, 3), ll(4, 4)]
        })
    ).

matrix_non_list_row_is_unknown_test() ->
    {Res, _} = matrix(#{}, [
        ?F:resp(200, <<"{\"code\":\"Ok\",\"durations\":[5],\"distances\":[[1]]}">>)
    ]),
    ?assertMatch({error, #{code := unknown}}, Res).

matrix_null_cell_is_omitted_test() ->
    {{ok, #{cells := Cells}}, _} = matrix(#{destinations => [ll(2, 2), ll(3, 3)]}, [
        ?F:resp(200, <<"{\"code\":\"Ok\",\"durations\":[[null,5]],\"distances\":[[null,7]]}">>)
    ]),
    ?assertEqual([1], [D || #{destination_index := D} <- Cells]).

matrix_avoid_tolls_sends_exclude_when_the_class_is_declared_test() ->
    {{ok, _}, P} = matrix([<<"toll">>], #{avoid_tolls => true}, [?F:resp(200, ?TABLE_OK)]),
    ?assertEqual(<<"toll">>, ?F:qget(?F:last(P), <<"exclude">>)).

matrix_avoid_tolls_without_the_class_is_unsupported_option_test() ->
    {Res, P} = matrix([<<"ferry">>], #{avoid_tolls => true}, []),
    ?assertMatch({error, #{code := unsupported_option}}, Res),
    ?assertEqual([], ?F:calls(P)).

matrix_without_avoid_tolls_sends_no_exclude_test() ->
    {{ok, _}, P} = matrix([<<"toll">>], #{}, [?F:resp(200, ?TABLE_OK)]),
    ?assertNot(has_query(?F:last(P), <<"exclude">>)).

matrix_no_segment_is_no_route_with_status_test_() ->
    [
        ?_test(begin
            {Res, _} = matrix(#{}, [
                ?F:resp(
                    Status,
                    <<"{\"code\":\"NoSegment\",\"message\":\"Could not find a matching segment\"}">>
                )
            ]),
            ?assertMatch({error, #{code := no_route, status := Status}}, Res)
        end)
     || Status <- [200, 400]
    ].

matrix_annotations_are_the_constant_test() ->
    {{ok, _}, P} = matrix(#{}, [?F:resp(200, ?TABLE_OK)]),
    ?assertEqual(
        iolist_to_binary(lists:join(",", thinwrap_location_defaults:osrm_table_annotations())),
        ?F:qget(?F:last(P), <<"annotations">>)
    ).

%% OSRM documents only `duration` and `distance`, so there is nothing to
%% append; replacement is what passthrough offers here.
matrix_caller_annotations_replace_the_default_test() ->
    {Res, P} = matrix(
        #{passthrough => #{query => #{<<"annotations">> => <<"duration">>}}},
        [?F:resp(200, <<"{\"code\":\"Ok\",\"durations\":[[60]]}">>)]
    ),
    ?assertEqual(<<"duration">>, ?F:qget(?F:last(P), <<"annotations">>)),
    ?assertMatch({error, #{code := unknown}}, Res).

%% ---------------------------------------------------------------------------
%% Error contract

vocabulary_misuse_is_badarg_test_() ->
    {C, _} = cfg([]),
    [
        ?_assertError({badarg, _}, thinwrap_location:route(C, #{waypoints => ?TWO, K => V}))
     || {K, V} <- [
            {travel_mode, flying},
            {traffic_mode, 'rush-hour'},
            {polyline_quality, ultra},
            {include, [bogus]}
        ]
    ] ++
        [
            ?_assertError(
                {badarg, _},
                thinwrap_location:matrix(C, #{
                    origins => [ll(1, 1)], destinations => [ll(2, 2)], travel_mode => flying
                })
            ),
            %% OSRM lacks geocoding and isochrone.
            ?_assertError({badarg, _}, thinwrap_location:geocode(C, #{address => <<"x">>})),
            ?_assertError(
                {badarg, _},
                thinwrap_location:isochrone(C, #{center => ll(1, 1), type => time, values => [600]})
            ),
            %% base_url is required and must be a binary.
            ?_assertError(
                {badarg, _}, thinwrap_location:route(#{provider => osrm}, #{waypoints => ?TWO})
            ),
            ?_assertError(
                {badarg, _},
                thinwrap_location:route(#{provider => osrm, base_url => "http://x"}, #{
                    waypoints => ?TWO
                })
            ),
            ?_assertError(
                {badarg, _},
                thinwrap_location:route(
                    #{
                        provider => osrm,
                        base_url => <<"http://x">>,
                        supported_exclude_classes => [toll]
                    },
                    #{waypoints => ?TWO}
                )
            )
        ].

fewer_than_two_waypoints_is_invalid_request_test_() ->
    [
        ?_test(begin
            {Res, P} = route(#{waypoints => Wps, optimize => Optimize}, []),
            ?assertMatch({error, #{code := invalid_request}}, Res),
            ?assertEqual([], ?F:calls(P))
        end)
     || Wps <- [[], [ll(1, 1)]], Optimize <- [false, true]
    ].

empty_matrix_is_invalid_request_test_() ->
    [
        ?_test(begin
            {C, P} = cfg([]),
            ?assertMatch(
                {error, #{code := invalid_request}},
                thinwrap_location:matrix(C, #{origins => Os, destinations => Ds})
            ),
            ?assertEqual([], ?F:calls(P))
        end)
     || {Os, Ds} <- [{[], [ll(1, 1)]}, {[ll(1, 1)], []}]
    ].
