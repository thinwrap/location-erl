-module(thinwrap_location_tomtom_tests).

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_location_fake_transport).
-define(TWO, [#{lat => 1, lng => 1}, #{lat => 2, lng => 2}]).
-define(FOUR, [
    #{lat => 1, lng => 1}, #{lat => 2, lng => 2}, #{lat => 3, lng => 3}, #{lat => 4, lng => 4}
]).
%% 2026-09-28T21:30:00Z
-define(WHEN, 1790631000).
-define(WHEN_ISO, <<"2026-09-28T21:30:00.000Z">>).
-define(ROUTE_OK,
    <<"{\"routes\":[{\"summary\":{\"lengthInMeters\":1000,\"travelTimeInSeconds\":600},\"legs\":[{\"summary\":{\"lengthInMeters\":1000,\"travelTimeInSeconds\":600},\"points\":[{\"latitude\":40,\"longitude\":-74}]}]}]}">>
).
-define(DOWNLOAD_URL, <<"https://storage.example.net/matrix/job1?sig=abc">>).

cfg(Responses) -> ?F:config(#{provider => tomtom, api_key => <<"k">>}, Responses).

ll(Lat, Lng) -> #{lat => Lat, lng => Lng}.

enc(Term) -> iolist_to_binary(json:encode(Term)).

with_time(Input, undefined) -> Input;
with_time(Input, When) -> Input#{departure_time => When}.

%% The first request a call sends; the transport fails it, so only the wire
%% shape is under test.
first(Op, Input) ->
    {C, P} = cfg([{error, captured}]),
    {error, _} = thinwrap_location:Op(C, Input),
    hd(?F:calls(P)).

%% A connector error raised before any request.
expect_ce(Op, Input, Code) ->
    {C, P} = cfg([]),
    {error, E} = thinwrap_location:Op(C, Input),
    ?assertMatch(#{code := Code}, E),
    ?assertNot(maps:is_key(status, E)),
    ?assertEqual([], ?F:calls(P)),
    E.

matrix_options(Input) ->
    Req = first(matrix, Input#{origins => [ll(1, 1)], destinations => [ll(2, 2)]}),
    maps:get(<<"options">>, ?F:body_json(Req)).

%% ---------------------------------------------------------------------------
%% Routing

routing_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"routes\":[{\"summary\":{\"lengthInMeters\":1000,\"travelTimeInSeconds\":600},\"legs\":[{\"summary\":{\"lengthInMeters\":1000,\"travelTimeInSeconds\":600},\"points\":[{\"latitude\":40,\"longitude\":-74},{\"latitude\":41,\"longitude\":-73}]}]}]}">>
        )
    ]),
    {ok, R} = thinwrap_location:route(C, #{waypoints => [ll(40, -74), ll(41, -73)]}),
    ?assertEqual(1000.0, maps:get(total_distance_meters, R)),
    ?assertEqual(600.0, maps:get(total_duration_seconds, R)),
    ?assertEqual(
        thinwrap_location_polyline:encode([ll(40.0, -74.0), ll(41.0, -73.0)]), maps:get(polyline, R)
    ),
    ?assertEqual([#{distance_meters => 1000.0, duration_seconds => 600.0}], maps:get(legs, R)),
    ?assertNot(maps:is_key(waypoint_order, R)),
    Last = ?F:last(P),
    ?assertEqual(<<"/routing/1/calculateRoute/40,-74:41,-73/json">>, ?F:path_of(Last)),
    ?assertEqual(<<"car">>, ?F:qget(Last, <<"travelMode">>)),
    ?assertEqual(<<"k">>, ?F:qget(Last, <<"key">>)),
    ?assertEqual(<<"fastest">>, ?F:qget(Last, <<"routeType">>)),
    ?assertEqual(<<"polyline">>, ?F:qget(Last, <<"routeRepresentation">>)),
    ?assertEqual(<<>>, ?F:qget(Last, <<"computeBestOrder">>)).

routing_travel_mode_test_() ->
    [
        ?_assertEqual(
            Want, ?F:qget(first(route, #{waypoints => ?TWO, travel_mode => Mode}), <<"travelMode">>)
        )
     || {Mode, Want} <- [{walking, <<"pedestrian">>}, {cycling, <<"bicycle">>}]
    ].

routing_optimized_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"routes\":[{\"summary\":{\"lengthInMeters\":1,\"travelTimeInSeconds\":1},\"legs\":[{\"summary\":{\"lengthInMeters\":1,\"travelTimeInSeconds\":1},\"points\":[{\"latitude\":1,\"longitude\":1}]}]}],\"optimizedWaypoints\":[{\"providedIndex\":0,\"optimizedIndex\":0},{\"providedIndex\":2,\"optimizedIndex\":1},{\"providedIndex\":1,\"optimizedIndex\":2}]}">>
        )
    ]),
    %% Input [A,B,C,D,E]; origin(0)/destination(4) fixed, 3 intermediates
    %% (providedIndex 0,1,2). optimizedWaypoints is intermediate-relative;
    %% projected to input indices + bracketed by origin/dest -> [0,1,3,2,4].
    {ok, R} = thinwrap_location:route(C, #{
        waypoints => [ll(1, 1), ll(2, 2), ll(3, 3), ll(4, 4), ll(5, 5)], optimize => true
    }),
    ?assertEqual([0, 1, 3, 2, 4], maps:get(waypoint_order, R)),
    ?assertEqual(<<"true">>, ?F:qget(?F:last(P), <<"computeBestOrder">>)).

%% computeBestOrder keeps both ends fixed, so a single fixed-endpoint flag
%% still requests it.
a_fixed_endpoint_flag_alone_requests_best_order_test_() ->
    Body =
        <<"{\"routes\":[{\"summary\":{\"lengthInMeters\":1,\"travelTimeInSeconds\":1},\"legs\":[{\"summary\":{\"lengthInMeters\":1,\"travelTimeInSeconds\":1},\"points\":[]}]}],\"optimizedWaypoints\":[{\"providedIndex\":1,\"optimizedIndex\":0},{\"providedIndex\":0,\"optimizedIndex\":1}]}">>,
    [
        ?_test(begin
            {C, P} = cfg([?F:resp(200, Body)]),
            {ok, R} = thinwrap_location:route(C, #{waypoints => ?FOUR, Flag => true}),
            ?assertEqual(<<"true">>, ?F:qget(?F:last(P), <<"computeBestOrder">>)),
            ?assertEqual([0, 2, 1, 3], maps:get(waypoint_order, R))
        end)
     || Flag <- [optimize_fixed_origin, optimize_fixed_destination]
    ].

two_waypoints_never_request_best_order_test() ->
    ?assertEqual(
        <<>>, ?F:qget(first(route, #{waypoints => ?TWO, optimize => true}), <<"computeBestOrder">>)
    ).

omits_corrupt_waypoint_order_test_() ->
    [
        ?_test(begin
            Body = iolist_to_binary([
                <<"{\"routes\":[{\"summary\":{\"lengthInMeters\":8000,\"travelTimeInSeconds\":480},\"legs\":[{\"summary\":{\"lengthInMeters\":5000,\"travelTimeInSeconds\":300},\"points\":[{\"latitude\":1,\"longitude\":1}]}]}],\"optimizedWaypoints\":">>,
                Optimized,
                <<"}">>
            ]),
            {C, _} = cfg([?F:resp(200, Body)]),
            {ok, R} = thinwrap_location:route(C, #{waypoints => ?FOUR, optimize => true}),
            ?assertNot(maps:is_key(waypoint_order, R)),
            ?assertEqual(8000.0, maps:get(total_distance_meters, R))
        end)
     || Optimized <- [
            %% short
            <<"[{\"providedIndex\":0,\"optimizedIndex\":0}]">>,
            %% duplicate
            <<"[{\"providedIndex\":0,\"optimizedIndex\":0},{\"providedIndex\":0,\"optimizedIndex\":1}]">>,
            %% out of range
            <<"[{\"providedIndex\":9,\"optimizedIndex\":0},{\"providedIndex\":0,\"optimizedIndex\":1}]">>,
            %% sentinel
            <<"[{\"providedIndex\":-1,\"optimizedIndex\":0},{\"providedIndex\":0,\"optimizedIndex\":1}]">>
        ]
    ].

round_trip_is_unsupported_test() ->
    expect_ce(route, #{waypoints => ?FOUR, is_round_trip => true}, unsupported_option).

%% Live: avoid=tollRoads,motorways -> 400 "Invalid avoid value:
%% [tollRoads,motorways]"; avoid=tollRoads&avoid=motorways -> 200.
avoid_flags_are_sent_as_repeated_params_test() ->
    {C, P} = cfg([?F:resp(200, ?ROUTE_OK)]),
    {ok, _} = thinwrap_location:route(C, #{
        waypoints => [ll(40, -74), ll(41, -73)],
        avoid_tolls => true,
        avoid_ferries => true,
        avoid_highways => true
    }),
    Last = ?F:last(P),
    ?assertEqual([<<"tollRoads">>, <<"ferries">>, <<"motorways">>], ?F:qall(Last, <<"avoid">>)),
    ?assertEqual(nomatch, binary:match(maps:get(url, Last), <<"%2C">>)).

single_avoid_flag_is_one_param_test() ->
    Req = first(route, #{waypoints => [ll(40, -74), ll(41, -73)], avoid_tolls => true}),
    ?assertEqual([<<"tollRoads">>], ?F:qall(Req, <<"avoid">>)).

%% TomTom's own default is traffic ON, so it is sent in both directions.
sends_traffic_explicitly_in_both_directions_test() ->
    ?assertEqual(<<"false">>, ?F:qget(first(route, #{waypoints => ?TWO}), <<"traffic">>)),
    ?assertEqual(
        <<"true">>, ?F:qget(first(route, #{waypoints => ?TWO, traffic_mode => live}), <<"traffic">>)
    ).

%% No time-independent routing mode exists (departAt=any is rejected), so
%% none keeps the caller's time and only switches live traffic off.
routing_traffic_and_departure_test_() ->
    [
        ?_test(begin
            Req = first(route, with_time(#{waypoints => ?TWO, traffic_mode => Mode}, When)),
            ?assertEqual(Traffic, ?F:qget(Req, <<"traffic">>)),
            ?assertEqual(Want, ?F:qget(Req, <<"departAt">>))
        end)
     || {Mode, Traffic} <- [{none, <<"false">>}, {traffic, <<"true">>}, {live, <<"true">>}],
        {When, Want} <- [{undefined, <<>>}, {?WHEN, ?WHEN_ISO}]
    ].

routing_passthrough_traffic_still_wins_test() ->
    Req = first(route, #{
        waypoints => ?TWO, passthrough => #{query => #{<<"traffic">> => <<"true">>}}
    }),
    ?assertEqual([<<"true">>], ?F:qall(Req, <<"traffic">>)).

routing_ignores_polyline_quality_test() ->
    Req = first(route, #{waypoints => ?TWO, polyline_quality => detailed}),
    ?assertEqual(<<>>, ?F:qget(Req, <<"overview">>)),
    ?assertEqual(<<>>, ?F:qget(Req, <<"polylineQuality">>)).

-define(NO_TRAFFIC_BODY,
    <<"{\"routes\":[{\"summary\":{\"lengthInMeters\":5000,\"travelTimeInSeconds\":300,\"noTrafficTravelTimeInSeconds\":280},\"legs\":[{\"summary\":{\"lengthInMeters\":5000,\"travelTimeInSeconds\":300,\"noTrafficTravelTimeInSeconds\":280},\"points\":[{\"latitude\":0,\"longitude\":0}]}]}]}">>
).

%% computeTravelTimeFor=all asks TomTom for extra computed values, so it
%% follows the opt-in.
gates_compute_travel_time_for_behind_the_opt_in_test() ->
    {C1, P1} = cfg([?F:resp(200, ?NO_TRAFFIC_BODY)]),
    {ok, R1} = thinwrap_location:route(C1, #{waypoints => ?TWO}),
    ?assertEqual(<<>>, ?F:qget(?F:last(P1), <<"computeTravelTimeFor">>)),
    ?assertNot(maps:is_key(duration_without_traffic_seconds, hd(maps:get(legs, R1)))),
    ?assertNot(maps:is_key(total_duration_without_traffic_seconds, R1)),
    {C2, P2} = cfg([?F:resp(200, ?NO_TRAFFIC_BODY)]),
    {ok, R2} = thinwrap_location:route(C2, #{
        waypoints => ?TWO, include => [durationWithoutTraffic]
    }),
    ?assertEqual(<<"all">>, ?F:qget(?F:last(P2), <<"computeTravelTimeFor">>)),
    ?assertMatch([#{duration_without_traffic_seconds := 280.0}], maps:get(legs, R2)),
    ?assertEqual(280.0, maps:get(total_duration_without_traffic_seconds, R2)).

routing_no_route_is_a_400_with_a_detailed_error_code_test_() ->
    [
        ?_test(begin
            Body = enc(#{detailedError => #{code => Code, message => <<"Engine error">>}}),
            {C, _} = cfg([?F:resp(400, Body)]),
            ?assertMatch(
                {error, #{code := no_route, status := 400, provider_message := <<"Engine error">>}},
                thinwrap_location:route(C, #{waypoints => ?TWO})
            )
        end)
     || Code <- [<<"MAP_MATCHING_FAILURE">>, <<"NO_ROUTE_FOUND">>]
    ].

routing_keeps_auth_failures_ahead_of_no_route_test() ->
    {C, _} = cfg([?F:resp(403, <<"{\"detailedError\":{\"code\":\"MAP_MATCHING_FAILURE\"}}">>)]),
    ?assertMatch(
        {error, #{code := auth_failed}}, thinwrap_location:route(C, #{waypoints => ?TWO})
    ).

routing_error_mapping_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(Status, Body)]),
            ?assertMatch(
                {error, #{code := Want, status := Status, provider_message := Msg}},
                thinwrap_location:route(C, #{waypoints => ?TWO})
            )
        end)
     || {Status, Body, Want, Msg} <- [
            {400, <<"{\"error\":{\"description\":\"bad\"}}">>, invalid_request, <<"bad">>},
            %% Routing maps a 404 to invalid_request (an invalid path).
            {404, <<"{\"error\":{\"message\":\"nf\"}}">>, invalid_request, <<"nf">>},
            {401, <<"{\"error\":\"nope\"}">>, auth_failed, <<"nope">>},
            {429, <<"{\"message\":\"slow\"}">>, rate_limited, <<"slow">>},
            {502, <<"{\"errorText\":\"down\"}">>, provider_unavailable, <<"down">>},
            {418, <<"{\"error\":\"teapot\"}">>, unknown, <<"teapot">>}
        ]
    ].

routing_retry_after_is_surfaced_test() ->
    {C, _} = cfg([?F:resp(429, <<"{\"message\":\"slow\"}">>, #{<<"Retry-After">> => <<"3">>})]),
    {error, E} = thinwrap_location:route(C, #{waypoints => ?TWO}),
    ?assertMatch(
        #{
            code := rate_limited,
            provider_message := <<"slow; retry after 3 seconds">>,
            cause := #{<<"retryAfter">> := <<"3">>}
        },
        E
    ).

-define(LEG,
    <<"{\"summary\":{\"lengthInMeters\":1,\"travelTimeInSeconds\":1},\"points\":[{\"latitude\":1,\"longitude\":1}]}">>
).

routing_malformed_route_is_unknown_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(200, Body)]),
            ?assertMatch(
                {error, #{code := unknown}}, thinwrap_location:route(C, #{waypoints => ?TWO})
            )
        end)
     || Body <- [
            <<"{\"routes\":[null]}">>,
            <<"{\"routes\":[{\"summary\":{\"lengthInMeters\":1,\"travelTimeInSeconds\":1},\"legs\":[null]}]}">>,
            <<"{\"routes\":[{\"summary\":{\"lengthInMeters\":1},\"legs\":[", ?LEG/binary, "]}]}">>,
            <<"{\"routes\":[{\"summary\":{\"lengthInMeters\":1,\"travelTimeInSeconds\":1},\"legs\":[{\"summary\":{\"travelTimeInSeconds\":1}}]}]}">>,
            <<"{\"routes\":[{\"summary\":{\"lengthInMeters\":1,\"travelTimeInSeconds\":1},\"legs\":[{\"summary\":{\"lengthInMeters\":1,\"travelTimeInSeconds\":1},\"points\":[{\"latitude\":1}]}]}]}">>,
            <<"{\"routes\":\"yes\"}">>
        ]
    ].

routing_route_without_legs_is_no_route_test() ->
    {C, _} = cfg([
        ?F:resp(
            200,
            <<"{\"routes\":[{\"summary\":{\"lengthInMeters\":1,\"travelTimeInSeconds\":1},\"legs\":[]}]}">>
        )
    ]),
    ?assertMatch({error, #{code := no_route}}, thinwrap_location:route(C, #{waypoints => ?TWO})).

routing_no_routes_is_no_route_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(200, Body)]),
            ?assertMatch(
                {error, #{code := no_route, status := 200}},
                thinwrap_location:route(C, #{waypoints => ?TWO})
            )
        end)
     || Body <- [<<"{}">>, <<"{\"routes\":[]}">>, <<>>]
    ].

%% ---------------------------------------------------------------------------
%% Matrix

matrix_sync_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"data\":[{\"originIndex\":0,\"destinationIndex\":0,\"routeSummary\":{\"lengthInMeters\":0,\"travelTimeInSeconds\":0}},{\"originIndex\":0,\"destinationIndex\":1,\"routeSummary\":{\"lengthInMeters\":1000,\"travelTimeInSeconds\":60}}]}">>
        )
    ]),
    {ok, #{cells := Cells}} = thinwrap_location:matrix(C, #{
        origins => [ll(1, 1)], destinations => [ll(2, 2), ll(3, 3)], avoid_tolls => true
    }),
    ?assertEqual(
        [
            #{
                origin_index => 0,
                destination_index => 0,
                distance_meters => 0.0,
                duration_seconds => 0.0
            },
            #{
                origin_index => 0,
                destination_index => 1,
                distance_meters => 1000.0,
                duration_seconds => 60.0
            }
        ],
        Cells
    ),
    Last = ?F:last(P),
    ?assertEqual(<<"/routing/matrix/2">>, ?F:path_of(Last)),
    ?assertEqual(<<"k">>, ?F:qget(Last, <<"key">>)),
    B = ?F:body_json(Last),
    ?assertEqual(
        [#{<<"point">> => #{<<"latitude">> => 1, <<"longitude">> => 1}}], maps:get(<<"origins">>, B)
    ),
    ?assertMatch(
        #{<<"travelMode">> := <<"car">>, <<"avoid">> := [<<"tollRoads">>]},
        maps:get(<<"options">>, B)
    ).

matrix_walking_is_pedestrian_test() ->
    ?assertMatch(
        #{<<"travelMode">> := <<"pedestrian">>}, matrix_options(#{travel_mode => walking})
    ).

matrix_rejects_cycling_test() ->
    expect_ce(
        matrix,
        #{origins => [ll(1, 1)], destinations => [ll(2, 2)], travel_mode => cycling},
        unsupported_travel_mode
    ).

matrix_async_test() ->
    %% 2550 cells > 100 -> async.
    No = 51,
    Nd = 50,
    Data = enc(#{
        data => [
            #{
                originIndex => I,
                destinationIndex => J,
                routeSummary => #{lengthInMeters => 100, travelTimeInSeconds => 60}
            }
         || I <- lists:seq(0, No - 1), J <- lists:seq(0, Nd - 1)
        ]
    }),
    {C, P} = cfg([
        ?F:resp(200, <<"{\"jobId\":\"job1\"}">>),
        ?F:resp(200, <<"{\"state\":\"Completed\"}">>),
        ?F:resp(200, Data)
    ]),
    {ok, #{cells := Cells}} = thinwrap_location:matrix(C, #{
        origins => [ll(I, 1) || I <- lists:seq(0, No - 1)],
        destinations => [ll(J, 2) || J <- lists:seq(0, Nd - 1)]
    }),
    ?assertEqual(No * Nd, length(Cells)),
    [Submit, Poll, Result] = ?F:calls(P),
    ?assertEqual(<<"/routing/matrix/2/async">>, ?F:path_of(Submit)),
    ?assertEqual(<<"/routing/matrix/2/async/job1">>, ?F:path_of(Poll)),
    ?assertEqual(<<"k">>, ?F:qget(Poll, <<"key">>)),
    ?assertEqual(<<"/routing/matrix/2/async/job1/result">>, ?F:path_of(Result)).

%% The synchronous Matrix v2 caps a standard request at 100 cells; the async
%% endpoint takes up to 2500.
matrix_sync_async_boundary_is_100_cells_test_() ->
    Data =
        <<"{\"data\":[{\"originIndex\":0,\"destinationIndex\":0,\"routeSummary\":{\"lengthInMeters\":1,\"travelTimeInSeconds\":1}}]}">>,
    [
        ?_test(begin
            Responses =
                case Async of
                    true ->
                        [
                            ?F:resp(200, <<"{\"jobId\":\"job1\"}">>),
                            ?F:resp(200, <<"{\"state\":\"Completed\"}">>),
                            ?F:resp(200, Data)
                        ];
                    false ->
                        [?F:resp(200, Data)]
                end,
            {C, P} = cfg(Responses),
            {ok, _} = thinwrap_location:matrix(C, #{
                origins => [ll(I, 1) || I <- lists:seq(1, No)],
                destinations => [ll(J, 2) || J <- lists:seq(1, Nd)]
            }),
            Calls = ?F:calls(P),
            case Async of
                true ->
                    ?assertEqual(<<"/routing/matrix/2/async">>, ?F:path_of(hd(Calls))),
                    ?assertEqual(3, length(Calls));
                false ->
                    ?assertEqual(<<"/routing/matrix/2">>, ?F:path_of(hd(Calls))),
                    ?assertEqual(1, length(Calls))
            end
        end)
     || {No, Nd, Async} <- [{10, 10, false}, {1, 100, false}, {101, 1, true}, {11, 10, true}]
    ].

matrix_sends_options_traffic_test_() ->
    [
        ?_assertEqual(Want, maps:get(<<"traffic">>, matrix_options(Extra)))
     || {Extra, Want} <- [
            {#{}, <<"historical">>},
            {#{traffic_mode => live}, <<"live">>},
            {#{traffic_mode => none}, <<"historical">>}
        ]
    ].

%% "historical" + a real departAt is typical traffic for that time; "any" is
%% TomTom's time-independent average, which is what none promises.
matrix_none_is_historical_any_test_() ->
    [
        ?_test(begin
            Options = matrix_options(with_time(#{}, When)),
            ?assertEqual(
                {<<"historical">>, <<"any">>},
                {maps:get(<<"traffic">>, Options), maps:get(<<"departAt">>, Options)}
            )
        end)
     || When <- [undefined, ?WHEN]
    ].

%% Live: traffic "live" with TomTom's default departAt=any is an HTTP 400.
matrix_traffic_is_live_test_() ->
    [
        ?_test(begin
            Options = matrix_options(with_time(#{traffic_mode => Mode}, When)),
            ?assertEqual(
                {<<"live">>, Want},
                {maps:get(<<"traffic">>, Options), maps:get(<<"departAt">>, Options)}
            )
        end)
     || Mode <- [traffic, live], {When, Want} <- [{undefined, <<"now">>}, {?WHEN, ?WHEN_ISO}]
    ].

matrix_departure_datetime_with_traffic_test() ->
    Options = matrix_options(#{traffic_mode => traffic, departure_time => {{2026, 9, 1}, {8, 0, 0}}}),
    ?assertEqual(<<"2026-09-01T08:00:00.000Z">>, maps:get(<<"departAt">>, Options)).

matrix_live_alias_sends_the_same_request_as_traffic_test_() ->
    Wire = fun(Mode, When) ->
        R = first(route, with_time(#{waypoints => ?TWO, traffic_mode => Mode}, When)),
        M = first(
            matrix,
            with_time(
                #{origins => [ll(1, 1)], destinations => [ll(2, 2)], traffic_mode => Mode}, When
            )
        ),
        {maps:with([method, url, body], R), maps:with([method, url, body], M)}
    end,
    [?_assertEqual(Wire(live, When), Wire(traffic, When)) || When <- [undefined, ?WHEN]].

matrix_without_a_data_array_is_unknown_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(200, Body)]),
            ?assertMatch(
                {error, #{code := unknown, status := 200}},
                thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]})
            )
        end)
     || Body <- [<<"{}">>, <<"{\"data\":null}">>, <<"{\"data\":{}}">>, <<"[]">>]
    ].

matrix_cell_without_valid_indexes_is_unknown_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(200, <<"{\"data\":[", Entry/binary, "]}">>)]),
            ?assertMatch(
                {error, #{code := unknown}},
                thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]})
            )
        end)
     || Entry <- [
            <<"{\"destinationIndex\":0,\"routeSummary\":{\"lengthInMeters\":1,\"travelTimeInSeconds\":1}}">>,
            <<"{\"originIndex\":0,\"destinationIndex\":5,\"routeSummary\":{\"lengthInMeters\":1,\"travelTimeInSeconds\":1}}">>,
            <<"{\"originIndex\":0.0,\"destinationIndex\":0,\"routeSummary\":{\"lengthInMeters\":1,\"travelTimeInSeconds\":1}}">>,
            <<"null">>
        ]
    ].

matrix_cell_missing_a_value_is_omitted_test() ->
    Body =
        <<"{\"data\":[{\"originIndex\":0,\"destinationIndex\":0,\"routeSummary\":{\"lengthInMeters\":100}},{\"originIndex\":0,\"destinationIndex\":1,\"detailedError\":{\"code\":\"NO_ROUTE_FOUND\"}}]}">>,
    {C, _} = cfg([?F:resp(200, Body)]),
    ?assertMatch(
        {ok, #{cells := []}},
        thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2), ll(3, 3)]})
    ).

matrix_http_error_is_mapped_test() ->
    {C, _} = cfg([?F:resp(403, <<"{\"detailedError\":{\"message\":\"Forbidden\"}}">>)]),
    ?assertMatch(
        {error, #{code := auth_failed, status := 403, provider_message := <<"Forbidden">>}},
        thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]})
    ).

matrix_timeout_ms_rejects_anything_but_a_positive_number_test_() ->
    [
        ?_test(
            expect_ce(
                matrix,
                #{
                    origins => [ll(1, 1), ll(1, 2)],
                    destinations => [ll(2, 1), ll(2, 2)],
                    passthrough => #{body => #{timeoutMs => Bad}}
                },
                invalid_request
            )
        )
     || Bad <- [<<"5000">>, 0, -1, true, null, [1]]
    ].

matrix_timeout_ms_is_stripped_from_the_sync_wire_test() ->
    Req = first(matrix, #{
        origins => [ll(1, 1)],
        destinations => [ll(2, 2)],
        passthrough => #{body => #{timeoutMs => 1500.5, <<"keep">> => 1}}
    }),
    B = ?F:body_json(Req),
    ?assertNot(maps:is_key(<<"timeoutMs">>, B)),
    ?assertEqual(1, maps:get(<<"keep">>, B)).

-define(ASYNC_ORIGINS, [#{lat => I, lng => 1} || I <- lists:seq(0, 10)]).
%% 11 x 10 = 110 cells -> async.
-define(ASYNC_DESTS, [#{lat => I, lng => 2} || I <- lists:seq(0, 9)]).
-define(ASYNC_DATA,
    <<"{\"data\":[{\"originIndex\":0,\"destinationIndex\":0,\"routeSummary\":{\"lengthInMeters\":100,\"travelTimeInSeconds\":60}}]}">>
).

async_matrix(ResultResponses) ->
    {C, P} = cfg(
        [?F:resp(200, <<"{\"jobId\":\"job1\"}">>), ?F:resp(200, <<"{\"state\":\"Completed\"}">>)] ++
            ResultResponses
    ),
    {P, thinwrap_location:matrix(C, #{origins => ?ASYNC_ORIGINS, destinations => ?ASYNC_DESTS})}.

async_result_302_is_followed_once_without_the_api_key_test() ->
    {P, Res} = async_matrix([
        ?F:resp(302, <<>>, #{<<"Location">> => ?DOWNLOAD_URL}), ?F:resp(200, ?ASYNC_DATA)
    ]),
    ?assertMatch({ok, #{cells := [_]}}, Res),
    Calls = ?F:calls(P),
    ?assertEqual(4, length(Calls)),
    ?assertEqual(<<"k">>, ?F:qget(lists:nth(3, Calls), <<"key">>)),
    Download = lists:nth(4, Calls),
    ?assertEqual(?DOWNLOAD_URL, maps:get(url, Download)),
    ?assertEqual(nomatch, binary:match(maps:get(url, Download), <<"key=">>)),
    ?assertEqual(
        [],
        [
            K
         || K := _ <- maps:get(headers, Download),
            binary:match(string:lowercase(K), <<"key">>) =/= nomatch
        ]
    ).

async_result_302_without_location_is_unknown_test() ->
    {P, Res} = async_matrix([?F:resp(302, <<>>)]),
    ?assertMatch({error, #{code := unknown, status := 302}}, Res),
    ?assertEqual(3, length(?F:calls(P))).

async_result_302_to_a_non_https_location_is_unknown_test() ->
    {P, Res} = async_matrix([
        ?F:resp(302, <<>>, #{<<"Location">> => <<"http://storage.example.net/matrix/job1">>})
    ]),
    ?assertMatch({error, #{code := unknown}}, Res),
    ?assertEqual(3, length(?F:calls(P))).

async_result_download_failure_is_mapped_test() ->
    {_, Res} = async_matrix([
        ?F:resp(302, <<>>, #{<<"Location">> => ?DOWNLOAD_URL}), ?F:resp(503, <<>>)
    ]),
    ?assertMatch({error, #{code := provider_unavailable}}, Res).

async_job_failed_is_provider_unavailable_test() ->
    {C, _} = cfg([
        ?F:resp(200, <<"{\"jobId\":\"job1\"}">>), ?F:resp(200, <<"{\"state\":\"Failed\"}">>)
    ]),
    ?assertMatch(
        {error, #{
            code := provider_unavailable,
            status := 200,
            provider_message := <<"TomTom Matrix job failed">>,
            cause := #{<<"state">> := <<"Failed">>}
        }},
        thinwrap_location:matrix(C, #{origins => ?ASYNC_ORIGINS, destinations => ?ASYNC_DESTS})
    ).

async_submit_without_job_id_is_unknown_test() ->
    {C, P} = cfg([?F:resp(200, <<"{}">>)]),
    ?assertMatch(
        {error, #{code := unknown, status := 200}},
        thinwrap_location:matrix(C, #{origins => ?ASYNC_ORIGINS, destinations => ?ASYNC_DESTS})
    ),
    ?assertEqual(1, length(?F:calls(P))).

async_job_id_is_path_escaped_test() ->
    {C, P} = cfg([
        ?F:resp(200, <<"{\"jobId\":\"a/b c\"}">>),
        ?F:resp(200, <<"{\"state\":\"Completed\"}">>),
        ?F:resp(200, ?ASYNC_DATA)
    ]),
    {ok, _} = thinwrap_location:matrix(C, #{origins => ?ASYNC_ORIGINS, destinations => ?ASYNC_DESTS}),
    ?assertEqual(<<"/routing/matrix/2/async/a%2Fb%20c">>, ?F:path_of(lists:nth(2, ?F:calls(P)))).

async_polling_timeout_test() ->
    {C0, _} = cfg([
        ?F:resp(200, <<"{\"jobId\":\"job1\"}">>), ?F:resp(200, <<"{\"state\":\"Submitted\"}">>)
    ]),
    %% Real sleep with a 1 ms deadline.
    C = C0#{sleep => fun timer:sleep/1},
    {error, E} = thinwrap_location:matrix(C, #{
        origins => ?ASYNC_ORIGINS,
        destinations => ?ASYNC_DESTS,
        passthrough => #{body => #{<<"timeoutMs">> => 1}}
    }),
    ?assertMatch(
        #{
            code := matrix_polling_timeout,
            provider_message := <<"jobId: job1">>,
            cause := #{<<"jobId">> := <<"job1">>}
        },
        E
    ).

async_poll_backoff_is_1s_x1_5_capped_at_5s_test() ->
    Self = self(),
    Pending = ?F:resp(200, <<"{\"state\":\"Validated\"}">>),
    {C0, P} = cfg(
        [?F:resp(200, <<"{\"jobId\":\"job1\"}">>)] ++
            lists:duplicate(5, Pending) ++
            [?F:resp(200, <<"{\"state\":\"Completed\"}">>), ?F:resp(200, ?ASYNC_DATA)]
    ),
    C = C0#{sleep => fun(Ms) -> Self ! {slept, Ms} end},
    {ok, _} = thinwrap_location:matrix(C, #{
        origins => ?ASYNC_ORIGINS,
        destinations => ?ASYNC_DESTS,
        passthrough => #{body => #{timeoutMs => 600000}}
    }),
    ?assertEqual([1000, 1500, 2250, 3375, 5000, 5000], collect_sleeps()),
    ?assertNot(maps:is_key(<<"timeoutMs">>, ?F:body_json(hd(?F:calls(P))))).

collect_sleeps() ->
    receive
        {slept, Ms} -> [Ms | collect_sleeps()]
    after 0 -> []
    end.

%% ---------------------------------------------------------------------------
%% Geocoding

geocode_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"results\":[{\"id\":\"g1\",\"address\":{\"freeformAddress\":\"New York, NY\"},\"position\":{\"lat\":40.7,\"lon\":-74.0},\"viewport\":{\"topLeftPoint\":{\"lat\":40.9,\"lon\":-74.3},\"btmRightPoint\":{\"lat\":40.4,\"lon\":-73.7}}}]}">>
        )
    ]),
    {ok, #{candidates := [Cand]}} = thinwrap_location:geocode(C, #{
        address => <<"NYC">>, country_filter => [<<"US">>], language => <<"en-US">>
    }),
    ?assertEqual(
        #{
            formatted_address => <<"New York, NY">>,
            location => #{lat => 40.7, lng => -74.0},
            place_id => <<"g1">>,
            viewport => #{
                southwest => #{lat => 40.4, lng => -74.3}, northeast => #{lat => 40.9, lng => -73.7}
            }
        },
        Cand
    ),
    Last = ?F:last(P),
    ?assertEqual(<<"/search/2/geocode/NYC.json">>, ?F:path_of(Last)),
    ?assertEqual(<<"US">>, ?F:qget(Last, <<"countrySet">>)),
    ?assertEqual(<<"en-US">>, ?F:qget(Last, <<"language">>)).

geocode_address_is_path_escaped_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"results\":[]}">>)]),
    {ok, _} = thinwrap_location:geocode(C, #{address => <<"1 Main St/Apt 2">>}),
    ?assertEqual(<<"/search/2/geocode/1%20Main%20St%2FApt%202.json">>, ?F:path_of(?F:last(P))).

geocode_empty_address_is_invalid_request_test() ->
    expect_ce(geocode, #{address => <<>>}, invalid_request).

geocode_skips_results_without_position_test() ->
    {C, _} = cfg([
        ?F:resp(
            200,
            <<"{\"results\":[{\"id\":\"a\",\"address\":{\"freeformAddress\":\"no position\"}},{\"id\":\"b\",\"address\":{\"freeformAddress\":\"good\"},\"position\":{\"lat\":1.5,\"lon\":2.5}}]}">>
        )
    ]),
    {ok, #{candidates := Cands}} = thinwrap_location:geocode(C, #{address => <<"x">>}),
    ?assertMatch([#{place_id := <<"b">>, location := #{lat := 1.5, lng := 2.5}}], Cands).

geocode_partial_viewport_is_omitted_test() ->
    {C, _} = cfg([
        ?F:resp(
            200,
            <<"{\"results\":[{\"address\":{\"freeformAddress\":\"a\"},\"position\":{\"lat\":1,\"lon\":2},\"viewport\":{\"topLeftPoint\":{\"lat\":3},\"btmRightPoint\":{\"lat\":1,\"lon\":4}}}]}">>
        )
    ]),
    {ok, #{candidates := [Cand]}} = thinwrap_location:geocode(C, #{address => <<"x">>}),
    ?assertNot(maps:is_key(viewport, Cand)).

geocode_uninterpretable_2xx_body_is_unknown_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(200, Body)]),
            ?assertMatch(
                {error, #{code := unknown, status := 200}},
                thinwrap_location:geocode(C, #{address => <<"x">>})
            )
        end)
     || Body <- [<<>>, <<"<html>busy</html>">>, <<"[]">>, <<"{\"unexpected\": true}">>]
    ].

geocode_well_formed_zero_results_stays_empty_test() ->
    {C, _} = cfg([?F:resp(200, <<"{\"results\":[]}">>)]),
    ?assertMatch({ok, #{candidates := []}}, thinwrap_location:geocode(C, #{address => <<"x">>})).

%% Search maps a 404 by status alone: unlike routing it is not invalid_request.
geocode_404_is_unknown_test() ->
    {C, _} = cfg([?F:resp(404, <<"{\"errorText\":\"nf\"}">>)]),
    ?assertMatch(
        {error, #{code := unknown, status := 404, provider_message := <<"nf">>}},
        thinwrap_location:geocode(C, #{address => <<"x">>})
    ).

reverse_geocode_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"addresses\":[{\"address\":{\"freeformAddress\":\"123 Main St\"},\"position\":\"40.7,-74.0\",\"id\":\"r1\"},{\"position\":\"garbage\"},{\"position\":\"1,x\"}]}">>
        )
    ]),
    {ok, #{candidates := Cands}} = thinwrap_location:reverse_geocode(C, #{
        location => ll(40.7, -74.0)
    }),
    ?assertEqual(
        [
            #{
                formatted_address => <<"123 Main St">>,
                location => #{lat => 40.7, lng => -74.0},
                place_id => <<"r1">>
            }
        ],
        Cands
    ),
    ?assertEqual(<<"/search/2/reverseGeocode/40.7,-74.json">>, ?F:path_of(?F:last(P))).

reverse_geocode_without_addresses_is_unknown_test() ->
    {C, _} = cfg([?F:resp(200, <<"{\"results\":[]}">>)]),
    ?assertMatch(
        {error, #{code := unknown}},
        thinwrap_location:reverse_geocode(C, #{location => ll(1, 1)})
    ).

%% ---------------------------------------------------------------------------
%% Autocomplete (fuzzy search, typeahead)

autocomplete_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"results\":[{\"id\":\"a1\",\"address\":{\"freeformAddress\":\"New York, NY\"},\"poi\":{\"name\":\"Statue of Liberty\"}}]}">>
        )
    ]),
    {ok, #{predictions := [Pred]}} = thinwrap_location:autocomplete(C, #{
        input => <<"Statue">>, location => ll(40.5, -74), radius => 1000
    }),
    ?assertEqual(
        #{
            description => <<"Statue of Liberty, New York, NY">>,
            place_id => <<"a1">>,
            structured_format => #{
                main_text => <<"Statue of Liberty">>, secondary_text => <<"New York, NY">>
            }
        },
        Pred
    ),
    Last = ?F:last(P),
    ?assertEqual(<<"/search/2/search/Statue.json">>, ?F:path_of(Last)),
    ?assertEqual(<<"true">>, ?F:qget(Last, <<"typeahead">>)),
    ?assertEqual(<<"5">>, ?F:qget(Last, <<"limit">>)),
    ?assertEqual(<<"40.5">>, ?F:qget(Last, <<"lat">>)),
    ?assertEqual(<<"-74">>, ?F:qget(Last, <<"lon">>)),
    ?assertEqual(<<"1000">>, ?F:qget(Last, <<"radius">>)).

%% Live-verified: street/address results have no poi.name. Splitting
%% freeformAddress on a comma to invent a main part would be a guess.
autocomplete_omits_structured_format_for_a_street_result_test() ->
    {C, _} = cfg([
        ?F:resp(
            200,
            <<"{\"results\":[{\"id\":\"tt2\",\"address\":{\"freeformAddress\":\"Museumstraat 1, Amsterdam\"},\"position\":{\"lat\":1,\"lon\":2}}]}">>
        )
    ]),
    {ok, #{predictions := [Pred]}} = thinwrap_location:autocomplete(C, #{
        input => <<"museumstraat">>
    }),
    ?assertNot(maps:is_key(structured_format, Pred)),
    ?assertEqual(<<"Museumstraat 1, Amsterdam">>, maps:get(description, Pred)).

autocomplete_maps_country_filter_to_country_set_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"results\":[]}">>)]),
    {ok, _} = thinwrap_location:autocomplete(C, #{
        input => <<"Empire">>, country_filter => [<<"IL">>, <<"PS">>]
    }),
    ?assertEqual(<<"IL,PS">>, ?F:qget(?F:last(P), <<"countrySet">>)).

autocomplete_empty_input_is_invalid_request_test() ->
    expect_ce(autocomplete, #{input => <<>>}, invalid_request).

autocomplete_uninterpretable_2xx_body_is_unknown_test() ->
    {C, _} = cfg([?F:resp(200, <<"<html/>">>)]),
    ?assertMatch(
        {error, #{code := unknown}},
        thinwrap_location:autocomplete(C, #{input => <<"x">>, location => ll(1, 1)})
    ).

non_numeric_radius_is_badarg_test_() ->
    [
        ?_test(begin
            {C, P} = cfg([]),
            ?assertError(
                {badarg, _},
                thinwrap_location:autocomplete(C, #{
                    input => <<"pizza">>, location => ll(1, 1), radius => R
                })
            ),
            ?assertEqual([], ?F:calls(P))
        end)
     || R <- [<<"500">>, true]
    ].

%% ---------------------------------------------------------------------------
%% Place details

-define(PLACE_BODY,
    <<"{\"results\":[{\"id\":\"tt1\",\"address\":{\"freeformAddress\":\"Museumstraat 1\"},\"position\":{\"lat\":52.36,\"lon\":4.885}}]}">>
).

place_details_gets_place_by_entity_id_test() ->
    {C, P} = cfg([?F:resp(200, ?PLACE_BODY)]),
    {ok, R} = thinwrap_location:place_details(C, #{place_id => <<"tt1">>, language => <<"nl">>}),
    Last = ?F:last(P),
    ?assertEqual(<<"/search/2/place.json">>, ?F:path_of(Last)),
    ?assertEqual(<<"tt1">>, ?F:qget(Last, <<"entityId">>)),
    ?assertEqual(<<"nl">>, ?F:qget(Last, <<"language">>)),
    ?assertMatch(
        #{location := #{lat := 52.36}, formatted_address := <<"Museumstraat 1">>},
        maps:get(candidate, R)
    ),
    ?assertNot(maps:is_key(name, R)).

place_details_surfaces_name_when_included_test() ->
    Body = enc(#{
        results => [
            #{
                id => <<"tt1">>,
                poi => #{name => <<"Rijksmuseum">>},
                address => #{freeformAddress => <<"Amsterdam">>},
                position => #{lat => 1, lon => 2}
            }
        ]
    }),
    {C, _} = cfg([?F:resp(200, Body)]),
    {ok, R} = thinwrap_location:place_details(C, #{place_id => <<"x">>, include => [name]}),
    ?assertEqual(<<"Rijksmuseum">>, maps:get(name, R)).

%% An id that resolves to nothing is an answer, like geocoding's zero results.
place_details_unusable_result_returns_no_candidate_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(200, Body)]),
            ?assertEqual(
                {ok, #{raw => json:decode(Body)}},
                thinwrap_location:place_details(C, #{place_id => <<"x">>, include => [name]})
            )
        end)
     || Body <- [<<"{\"results\":[]}">>, <<"{\"results\":[null]}">>]
    ].

place_details_unparseable_2xx_body_is_unknown_test() ->
    {C, _} = cfg([?F:resp(200, <<"<html>oops</html>">>)]),
    ?assertMatch(
        {error, #{code := unknown}}, thinwrap_location:place_details(C, #{place_id => <<"x">>})
    ).

place_details_404_is_invalid_request_test() ->
    {C, _} = cfg([?F:resp(404, <<"{\"errorText\":\"nf\"}">>)]),
    ?assertMatch(
        {error, #{code := invalid_request, status := 404}},
        thinwrap_location:place_details(C, #{place_id => <<"x">>})
    ).

%% ---------------------------------------------------------------------------
%% Isochrone

isochrone_single_band_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"reachableRange\":{\"boundary\":[{\"latitude\":40,\"longitude\":-74},{\"latitude\":41,\"longitude\":-74},{\"latitude\":41,\"longitude\":-73}]}}">>
        )
    ]),
    {ok, R} = thinwrap_location:isochrone(C, #{center => ll(40, -74), type => time, values => [600]}),
    [#{value := 600.0, geometry := #{type := <<"Polygon">>, coordinates := [Ring]}}] = maps:get(
        contours, R
    ),
    %% Closed ring.
    ?assertEqual(4, length(Ring)),
    ?assertNot(maps:is_key(meta, R)),
    ?assertMatch([#{<<"reachableRange">> := _}], maps:get(raw, R)),
    Last = ?F:last(P),
    ?assertEqual(<<"/routing/1/calculateReachableRange/40,-74/json">>, ?F:path_of(Last)),
    ?assertEqual(<<"600">>, ?F:qget(Last, <<"timeBudgetInSec">>)),
    ?assertEqual(<<"car">>, ?F:qget(Last, <<"travelMode">>)).

isochrone_multi_band_test() ->
    Band =
        <<"{\"reachableRange\":{\"boundary\":[{\"latitude\":40,\"longitude\":-74},{\"latitude\":41,\"longitude\":-74}]}}">>,
    {C, P} = cfg([?F:resp(200, Band), ?F:resp(200, Band)]),
    {ok, R} = thinwrap_location:isochrone(C, #{
        center => ll(40, -74), type => distance, values => [600, 300]
    }),
    Calls = ?F:calls(P),
    ?assertEqual(2, length(Calls)),
    ?assertEqual(
        [<<"600">>, <<"300">>], [?F:qget(Req, <<"distanceBudgetInMeters">>) || Req <- Calls]
    ),
    ?assertEqual(#{request_count => 2}, maps:get(meta, R)),
    ?assertEqual([300.0, 600.0], [V || #{value := V} <- maps:get(contours, R)]).

%% calculateReachableRange: "the values bicycle and pedestrian must not be used".
isochrone_rejects_walking_and_cycling_before_any_request_test_() ->
    [
        ?_test(begin
            E = expect_ce(
                isochrone,
                #{center => ll(40, -74), type => time, values => [600], travel_mode => Mode},
                unsupported_travel_mode
            ),
            ?assertEqual(
                <<"TomTom isochrone does not support travelMode \"", (atom_to_binary(Mode))/binary,
                    "\"">>,
                maps:get(message, E)
            )
        end)
     || Mode <- [walking, cycling]
    ].

isochrone_without_a_usable_boundary_is_unknown_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(200, Body)]),
            ?assertMatch(
                {error, #{code := unknown}},
                thinwrap_location:isochrone(C, #{center => ll(52, 4), type => time, values => [600]})
            )
        end)
     || Body <- [
            <<"{\"reachableRange\":{\"boundary\":[]}}">>,
            <<"{\"reachableRange\":{\"boundary\":[{\"latitude\":1}]}}">>,
            <<"{\"reachableRange\":{}}">>
        ]
    ].

isochrone_departure_time_is_validated_before_any_request_test_() ->
    [
        ?_test(
            expect_ce(
                isochrone,
                #{center => ll(52, 4), type => time, values => [600, 900], departure_time => V},
                invalid_request
            )
        )
     || V <- [<<"soon">>, <<"tomorrow">>, <<"2026-13-01T00:00">>]
    ].

isochrone_departure_is_sent_on_every_band_test() ->
    Band =
        <<"{\"reachableRange\":{\"boundary\":[{\"latitude\":40,\"longitude\":-74},{\"latitude\":41,\"longitude\":-74}]}}">>,
    {C, P} = cfg([?F:resp(200, Band)]),
    {ok, _} = thinwrap_location:isochrone(C, #{
        center => ll(40, -74), type => time, values => [300, 600], departure_time => ?WHEN
    }),
    ?assertEqual(
        [<<"2026-09-28T21:30:00Z">>, <<"2026-09-28T21:30:00Z">>],
        [?F:qget(Req, <<"departAt">>) || Req <- ?F:calls(P)]
    ).

bad_isochrone_breaks_are_invalid_request_test_() ->
    [
        ?_test(
            expect_ce(
                isochrone, #{center => ll(1, 1), type => time, values => Values}, invalid_request
            )
        )
     || Values <- [[], [0], [1, 2, 3, 4, 5]]
    ].

tomtom_geometry(Ring) ->
    Boundary = [#{longitude => Lng, latitude => Lat} || [Lng, Lat] <- Ring],
    {C, _} = cfg([?F:resp(200, enc(#{reachableRange => #{boundary => Boundary}}))]),
    {ok, #{contours := [#{geometry := G}]}} = thinwrap_location:isochrone(C, #{
        center => ll(1, 1), type => time, values => [600]
    }),
    G.

boundary_is_closed_and_counter_clockwise_test() ->
    %% Clockwise square from the vendor.
    G = tomtom_geometry(lists:reverse([[0, 0], [4, 0], [4, 4], [0, 4]])),
    #{type := <<"Polygon">>, coordinates := [Ring]} = G,
    ?assertEqual(5, length(Ring)),
    ?assertEqual(hd(Ring), lists:last(Ring)),
    ?assert(thinwrap_location_isochrone:signed_area(Ring) > 0).

already_closed_boundary_is_not_closed_twice_test() ->
    #{coordinates := [Ring]} = tomtom_geometry([[0, 0], [4, 0], [4, 4], [0, 4], [0, 0]]),
    ?assertEqual(5, length(Ring)).

%% ---------------------------------------------------------------------------
%% Error contract

%% An RFC 3339 binary is a valid departure_time in Erlang (Python accepts only
%% a datetime there); one that does not parse is request data the vendor
%% would reject, so invalid_request before any request.
unparseable_departure_time_is_invalid_request_test_() ->
    [
        ?_test(expect_ce(Op, Input#{departure_time => <<"next tuesday">>}, invalid_request))
     || {Op, Input} <- [
            {route, #{waypoints => ?TWO}},
            {matrix, #{origins => [ll(1, 1)], destinations => [ll(2, 2)], traffic_mode => traffic}}
        ]
    ].

rfc3339_departure_time_is_accepted_test() ->
    Req = first(route, #{waypoints => ?TWO, departure_time => <<"2026-09-28T23:30:00+02:00">>}),
    ?assertEqual(?WHEN_ISO, ?F:qget(Req, <<"departAt">>)).

fewer_than_two_waypoints_is_invalid_request_test_() ->
    [
        ?_test(expect_ce(route, #{waypoints => Wps, optimize => Opt}, invalid_request))
     || Wps <- [[], [ll(1, 1)]], Opt <- [false, true]
    ].

empty_matrix_is_invalid_request_test_() ->
    [
        ?_test(expect_ce(matrix, #{origins => Os, destinations => Ds}, invalid_request))
     || {Os, Ds} <- [{[], [ll(1, 1)]}, {[ll(1, 1)], []}]
    ].
