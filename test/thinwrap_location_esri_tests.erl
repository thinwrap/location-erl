-module(thinwrap_location_esri_tests).

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_location_fake_transport).
-define(L, thinwrap_location).
-define(TWO, [#{lat => 1, lng => 1}, #{lat => 2, lng => 2}]).
-define(FOUR, [ll(0, 0), ll(1, 1), ll(2, 2), ll(3, 3)]).

%% A minimal valid service-area answer, for tests that only inspect the request.
-define(SA_OK,
    <<"{\"saPolygons\":{\"features\":[{\"attributes\":{\"ToBreak\":10},\"geometry\":{\"rings\":[[[-74,40],[-73,40],[-74,40]]]}}]}}">>
).
-define(ROUTE_BODY,
    <<"{\"routes\":{\"features\":[{\"attributes\":{\"Total_TravelTime\":1,\"Total_Kilometers\":1},\"geometry\":{\"paths\":[[[0,0],[1,1]]]}}]}}">>
).
-define(MATRIX_OK,
    <<"{\"odCostMatrix\":{\"costAttributeNames\":[\"TravelTime\",\"Kilometers\"],\"1\":{\"1\":[1,1]}}}">>
).
%% 2026-08-07T03:06:00Z
-define(DEPARTURE, {{2026, 8, 7}, {3, 6, 0}}).
-define(DEPARTURE_MS, <<"1786071960000">>).
%% 2026-09-28T21:30:00Z
-define(WHEN, {{2026, 9, 28}, {21, 30, 0}}).
-define(WHEN_MS, <<"1790631000000">>).

cfg(Responses) -> ?F:config(#{provider => esri, api_key => <<"k">>}, Responses).

ll(Lat, Lng) -> #{lat => Lat, lng => Lng}.

form(P) -> ?F:body_form(?F:last(P)).

j(Term) -> iolist_to_binary(json:encode(Term)).

%% JSON with the object key order spelled out: `{obj, [{K, V}]}`.
oj(Term) -> iolist_to_binary(enc(Term)).
enc({obj, KVs}) -> ["{", lists:join(",", [[json:encode(K), ":", enc(V)] || {K, V} <- KVs]), "}"];
enc(L) when is_list(L) -> ["[", lists:join(",", [enc(V) || V <- L]), "]"];
enc(V) -> json:encode(V).

route(Body, Input) ->
    {C, P} = cfg([?F:resp(200, Body)]),
    {?L:route(C, maps:merge(#{waypoints => ?TWO}, Input)), P}.

matrix(Body, Input) ->
    {C, P} = cfg([?F:resp(200, Body)]),
    {?L:matrix(C, maps:merge(#{origins => [ll(1, 1)], destinations => [ll(2, 2)]}, Input)), P}.

iso(Body, Input) ->
    {C, P} = cfg([?F:resp(200, Body)]),
    {
        ?L:isochrone(C, maps:merge(#{center => ll(40, -74), type => time, values => [600]}, Input)),
        P
    }.

%% A solve response whose `stops` carry the given 1-based Sequence per INPUT stop.
seq_route_body(Seqs) ->
    N = length(Seqs),
    j(#{
        <<"routes">> => #{
            <<"features">> => [
                #{
                    <<"attributes">> => #{<<"Total_TravelTime">> => N, <<"Total_Kilometers">> => N},
                    <<"geometry">> => #{<<"paths">> => [[[0, 0], [1, 1]]]}
                }
            ]
        },
        <<"stops">> => #{
            <<"features">> => [
                #{
                    <<"attributes">> => #{
                        <<"Sequence">> => S,
                        <<"Status">> => 0,
                        <<"Cumul_TravelTime">> => S - 1,
                        <<"Cumul_Kilometers">> => S - 1
                    }
                }
             || S <- Seqs
            ]
        }
    }).

%% ---------------------------------------------------------------------------
%% Routing

routing_test() ->
    %% `stops` FeatureSet in INPUT order; Sequence is the 1-based visiting
    %% position. Legs come from the stops' cumulative costs.
    Body = j(#{
        <<"routes">> => #{
            <<"features">> => [
                #{
                    <<"attributes">> => #{
                        <<"Total_TravelTime">> => 10, <<"Total_Kilometers">> => 1
                    },
                    <<"geometry">> => #{<<"paths">> => [[[-74, 40], [-73, 41]]]}
                }
            ]
        },
        <<"stops">> => #{
            <<"features">> => [
                #{
                    <<"attributes">> => #{
                        <<"Sequence">> => 1,
                        <<"Status">> => 0,
                        <<"Cumul_TravelTime">> => 0,
                        <<"Cumul_Kilometers">> => 0
                    }
                },
                #{
                    <<"attributes">> => #{
                        <<"Sequence">> => 2,
                        <<"Status">> => 0,
                        <<"Cumul_TravelTime">> => 10,
                        <<"Cumul_Kilometers">> => 1
                    }
                }
            ]
        }
    }),
    {C, P} = ?F:config(#{provider => esri, api_key => <<"apikey">>}, [?F:resp(200, Body)]),
    {ok, R} = ?L:route(C, #{waypoints => [ll(40, -74), ll(41, -73)]}),
    ?assertEqual(1000.0, maps:get(total_distance_meters, R)),
    ?assertEqual(600.0, maps:get(total_duration_seconds, R)),
    ?assertEqual([#{distance_meters => 1000.0, duration_seconds => 600.0}], maps:get(legs, R)),
    %% waypoint_order is surfaced for OPTIMIZED routes only.
    ?assertNotEqual(<<>>, maps:get(polyline, R)),
    ?assertEqual(
        thinwrap_location_polyline:encode([ll(40, -74), ll(41, -73)]), maps:get(polyline, R)
    ),
    ?assertNot(maps:is_key(waypoint_order, R)),
    Last = ?F:last(P),
    ?assertEqual(
        <<"https://route-api.arcgis.com/arcgis/rest/services/World/Route/NAServer/Route_World/solve">>,
        maps:get(url, Last)
    ),
    ?assertEqual(post, maps:get(method, Last)),
    ?assertEqual(
        <<"application/x-www-form-urlencoded">>, ?F:header(Last, <<"Content-Type">>)
    ),
    F = ?F:body_form(Last),
    ?assertEqual(<<"apikey">>, maps:get(<<"token">>, F)),
    ?assertEqual(<<"json">>, maps:get(<<"f">>, F)),
    ?assertEqual(<<"4326">>, maps:get(<<"outSR">>, F)),
    ?assertEqual(<<"true">>, maps:get(<<"returnRoutes">>, F)),
    ?assertMatch(
        #{
            <<"features">> := [
                #{
                    <<"geometry">> := #{
                        <<"x">> := -74,
                        <<"y">> := 40,
                        <<"spatialReference">> := #{<<"wkid">> := 4326}
                    }
                },
                #{<<"geometry">> := #{<<"x">> := -73, <<"y">> := 41}}
            ]
        },
        json:decode(maps:get(<<"stops">>, F))
    ).

routing_body_error_test() ->
    {{error, E}, _} = route(<<"{\"error\":{\"code\":498,\"message\":\"Invalid token\"}}">>, #{}),
    ?assertMatch(#{code := auth_failed, provider_message := <<"Invalid token">>, status := 200}, E).

dual_auth_test() ->
    {C1, P1} = ?F:config(
        #{provider => esri, api_key => <<"a">>, arcgis_token => <<"b">>}, []
    ),
    {error, E1} = ?L:route(C1, #{waypoints => ?TWO}),
    ?assertMatch(#{code := invalid_request}, E1),
    ?assertNot(maps:is_key(status, E1)),
    ?assertEqual([], ?F:calls(P1)),
    {C2, P2} = ?F:config(#{provider => esri}, []),
    {error, E2} = ?L:route(C2, #{waypoints => ?TWO}),
    ?assertMatch(#{code := auth_failed}, E2),
    ?assertNot(maps:is_key(status, E2)),
    ?assertEqual([], ?F:calls(P2)),
    %% An empty binary counts as unset.
    {C3, _} = ?F:config(#{provider => esri, api_key => <<>>}, []),
    ?assertMatch({error, #{code := auth_failed}}, ?L:route(C3, #{waypoints => ?TWO})).

arcgis_token_fun_is_resolved_at_call_time_test() ->
    {C, P} = ?F:config(
        #{provider => esri, arcgis_token => fun() -> <<"oauth-tok">> end},
        [?F:resp(200, ?ROUTE_BODY)]
    ),
    {ok, _} = ?L:route(C, #{waypoints => ?TWO}),
    ?assertEqual(<<"oauth-tok">>, maps:get(<<"token">>, form(P))).

esri_credentials_are_checked_at_call_time_for_every_operation_test_() ->
    Calls = [
        fun(C) -> ?L:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]}) end,
        fun(C) -> ?L:geocode(C, #{address => <<"x">>}) end,
        fun(C) -> ?L:reverse_geocode(C, #{location => ll(1, 1)}) end,
        fun(C) -> ?L:autocomplete(C, #{input => <<"x">>}) end,
        fun(C) -> ?L:place_details(C, #{place_id => <<"x">>}) end,
        fun(C) -> ?L:isochrone(C, #{center => ll(1, 1), type => time, values => [600]}) end
    ],
    [
        ?_test(begin
            {C, P} = ?F:config(Cfg, []),
            ?assertMatch({error, #{code := Code}}, Call(C)),
            ?assertEqual([], ?F:calls(P))
        end)
     || Call <- Calls,
        {Cfg, Code} <- [
            {#{provider => esri}, auth_failed},
            {#{provider => esri, api_key => <<"k">>, arcgis_token => <<"t">>}, invalid_request}
        ]
    ].

routing_rejects_cycling_test() ->
    {C, P} = cfg([]),
    ?assertMatch(
        {error, #{code := unsupported_travel_mode}},
        ?L:route(C, #{waypoints => ?TWO, travel_mode => cycling})
    ),
    ?assertEqual([], ?F:calls(P)).

routing_rejects_round_trip_test() ->
    {C, P} = cfg([]),
    ?assertMatch(
        {error, #{code := unsupported_option}},
        ?L:route(C, #{waypoints => ?TWO, is_round_trip => true, optimize => true})
    ),
    ?assertEqual([], ?F:calls(P)).

routing_walking_sends_full_travel_mode_object_test() ->
    Body =
        <<"{\"routes\":{\"features\":[{\"attributes\":{\"Total_Length\":1,\"Total_Time\":1},\"geometry\":{\"paths\":[[[-74,40],[-73,41]]]}}]}}">>,
    {{ok, R}, P} = route(Body, #{waypoints => [ll(40, -74), ll(41, -73)], travel_mode => walking}),
    %% ArcGIS requires a full travel-mode JSON object, not a name string.
    Tm = json:decode(maps:get(<<"travelMode">>, form(P))),
    ?assertMatch(
        #{
            <<"type">> := <<"WALK">>,
            <<"impedanceAttributeName">> := <<"WalkTime">>,
            <<"name">> := <<"Walking Time">>
        },
        Tm
    ),
    %% Total_Length is meters, Total_Time minutes.
    ?assertEqual(1.0, maps:get(total_distance_meters, R)),
    ?assertEqual(60.0, maps:get(total_duration_seconds, R)).

routing_walking_totals_from_cumulative_walk_time_test() ->
    %% Real ArcGIS walking response: no Total_Time / Total_Length; the
    %% impedance attribute is WalkTime. Live values (2026-07-21).
    Body =
        <<"{\"routes\":{\"features\":[{\"attributes\":{\"Total_WalkTime\":13.094903051108146,\"Total_Kilometers\":1.091226960340165,\"Total_Miles\":0.678},\"geometry\":{\"paths\":[[[-74,40],[-73,41]]]}}]},\"stops\":{\"features\":[{\"attributes\":{\"Sequence\":1,\"Status\":0,\"Cumul_WalkTime\":0,\"Cumul_Kilometers\":0}},{\"attributes\":{\"Sequence\":2,\"Status\":0,\"Cumul_WalkTime\":13.094903051108146,\"Cumul_Kilometers\":1.091226960340165}}]}}">>,
    {{ok, R}, _} = route(Body, #{waypoints => [ll(40, -74), ll(41, -73)], travel_mode => walking}),
    ?assert(abs(maps:get(total_distance_meters, R) - 1091.226960340165) < 0.1),
    ?assert(abs(maps:get(total_duration_seconds, R) - 13.094903051108146 * 60) < 0.001).

routing_derives_legs_and_totals_from_cumulative_stop_costs_test() ->
    %% Legs AND totals from one source, so they cannot disagree.
    Body = oj(
        {obj, [
            {<<"routes">>,
                {obj, [
                    {<<"features">>, [
                        {obj, [
                            {<<"attributes">>,
                                {obj, [{<<"Total_TravelTime">>, 30}, {<<"Total_Kilometers">>, 12}]}},
                            {<<"geometry">>, {obj, [{<<"paths">>, [[[0, 0], [1, 1]]]}]}}
                        ]}
                    ]}
                ]}},
            {<<"stops">>,
                {obj, [
                    {<<"features">>, [
                        stop(1, 0, 0, 0),
                        stop(2, 0, 10, 4),
                        stop(3, 0, 30, 12)
                    ]}
                ]}}
        ]}
    ),
    {{ok, R}, P} = route(Body, #{waypoints => [ll(0, 0), ll(1, 1), ll(2, 2)]}),
    ?assertEqual(
        [
            #{distance_meters => 4000.0, duration_seconds => 600.0},
            #{distance_meters => 8000.0, duration_seconds => 1200.0}
        ],
        maps:get(legs, R)
    ),
    ?assertEqual(12000.0, maps:get(total_distance_meters, R)),
    ?assertEqual(1800.0, maps:get(total_duration_seconds, R)),
    F = form(P),
    ?assertEqual(<<"true">>, maps:get(<<"returnStops">>, F)),
    %% Explicit false is load-bearing: the SERVICE DEFAULT is true.
    ?assertEqual(<<"false">>, maps:get(<<"returnDirections">>, F)),
    ?assertEqual(<<"TravelTime,Kilometers">>, maps:get(<<"accumulateAttributeNames">>, F)),
    ?assertEqual(<<"esriNAOutputLineTrueShape">>, maps:get(<<"outputLines">>, F)),
    ?assertNot(maps:is_key(<<"directionsOutputType">>, F)).

stop(Seq, Status, Time, Km) ->
    {obj, [
        {<<"attributes">>,
            {obj, [
                {<<"Sequence">>, Seq},
                {<<"Status">>, Status},
                {<<"Cumul_TravelTime">>, Time},
                {<<"Cumul_Kilometers">>, Km}
            ]}}
    ]}.

routing_differences_stops_in_visit_order_test() ->
    %% Stops come back in INPUT order while cumulative costs run along the
    %% route; skipping the sort yields negative legs.
    Body = oj(
        {obj, [
            {<<"routes">>,
                {obj, [
                    {<<"features">>, [
                        {obj, [
                            {<<"attributes">>,
                                {obj, [{<<"Total_TravelTime">>, 30}, {<<"Total_Kilometers">>, 12}]}},
                            {<<"geometry">>, {obj, [{<<"paths">>, [[[0, 0], [1, 1]]]}]}}
                        ]}
                    ]}
                ]}},
            {<<"stops">>,
                {obj, [{<<"features">>, [stop(1, 0, 0, 0), stop(3, 0, 30, 12), stop(2, 0, 10, 4)]}]}}
        ]}
    ),
    {{ok, R}, _} = route(Body, #{waypoints => [ll(0, 0), ll(1, 1), ll(2, 2)], optimize => true}),
    ?assertEqual([4000.0, 8000.0], [D || #{distance_meters := D} <- maps:get(legs, R)]),
    ?assertEqual([0, 2, 1], maps:get(waypoint_order, R)).

routing_falls_back_when_a_stop_failed_to_locate_test() ->
    %% A non-zero Status carries no usable cumulative cost; the route's own
    %% totals plus an even split are used instead.
    Body = oj(
        {obj, [
            {<<"routes">>,
                {obj, [
                    {<<"features">>, [
                        {obj, [
                            {<<"attributes">>,
                                {obj, [{<<"Total_TravelTime">>, 20}, {<<"Total_Kilometers">>, 1}]}},
                            {<<"geometry">>, {obj, [{<<"paths">>, [[[0, 0], [1, 1]]]}]}}
                        ]}
                    ]}
                ]}},
            {<<"stops">>, {obj, [{<<"features">>, [stop(1, 0, 0, 0), stop(2, 7, 20, 1)]}]}}
        ]}
    ),
    {{ok, R}, _} = route(Body, #{}),
    ?assertEqual(1000.0, maps:get(total_distance_meters, R)),
    ?assertEqual(1200.0, maps:get(total_duration_seconds, R)),
    ?assertMatch([#{distance_meters := 1000.0}], maps:get(legs, R)).

routing_unusable_cumulative_costs_fall_back_to_route_totals_test_() ->
    Stops = [
        %% A stop without a Sequence.
        [{obj, [{<<"attributes">>, {obj, [{<<"Cumul_TravelTime">>, 0}]}}]}, stop(2, 0, 20, 1)],
        %% Cumulative costs that decrease along the route.
        [stop(1, 0, 20, 1), stop(2, 0, 0, 0)],
        %% No Cumul_* attributes at all.
        [
            {obj, [{<<"attributes">>, {obj, [{<<"Sequence">>, 1}]}}]},
            {obj, [{<<"attributes">>, {obj, [{<<"Sequence">>, 2}]}}]}
        ],
        %% A missing cost on one stop; attributes that are not an object.
        [stop(1, 0, 0, 0), {obj, [{<<"attributes">>, [1]}]}]
    ],
    [
        ?_test(begin
            Body = oj(
                {obj, [
                    {<<"routes">>,
                        {obj, [
                            {<<"features">>, [
                                {obj, [
                                    {<<"attributes">>,
                                        {obj, [
                                            {<<"Total_TravelTime">>, 20},
                                            {<<"Total_Kilometers">>, 1}
                                        ]}},
                                    {<<"geometry">>, {obj, [{<<"paths">>, [[[0, 0], [1, 1]]]}]}}
                                ]}
                            ]}
                        ]}},
                    {<<"stops">>, {obj, [{<<"features">>, S}]}}
                ]}
            ),
            {{ok, R}, _} = route(Body, #{}),
            ?assertEqual(
                [#{distance_meters => 1000.0, duration_seconds => 1200.0}], maps:get(legs, R)
            )
        end)
     || S <- Stops
    ].

routing_route_attributes_that_are_not_an_object_are_unknown_test() ->
    ?assertMatch(
        {{error, #{code := unknown}}, _},
        route(
            <<"{\"routes\":{\"features\":[{\"attributes\":[1],\"geometry\":{\"paths\":[]}}]}}">>,
            #{}
        )
    ).

routing_even_split_over_three_waypoints_test() ->
    {{ok, R}, _} = route(
        <<"{\"routes\":{\"features\":[{\"attributes\":{\"Total_Miles\":2,\"Total_TravelTime\":4},\"geometry\":{\"paths\":[]}}]}}">>,
        #{waypoints => [ll(0, 0), ll(1, 1), ll(2, 2)]}
    ),
    ?assertEqual(2 * 1609.344, maps:get(total_distance_meters, R)),
    ?assertEqual(
        [
            #{distance_meters => 1609.344, duration_seconds => 120.0},
            #{distance_meters => 1609.344, duration_seconds => 120.0}
        ],
        maps:get(legs, R)
    ),
    ?assertEqual(<<>>, maps:get(polyline, R)).

routing_shape_fallback_reads_the_first_cost_column_in_response_order_test() ->
    %% Neither Cumul_Kilometers nor Cumul_TravelTime: the keys are matched by
    %% shape, in the order Esri listed them.
    Body = oj(
        {obj, [
            {<<"routes">>,
                {obj, [
                    {<<"features">>, [
                        {obj, [
                            {<<"attributes">>, {obj, [{<<"Name">>, <<"x">>}]}},
                            {<<"geometry">>, {obj, [{<<"paths">>, [[[0, 0], [1, 1]]]}]}}
                        ]}
                    ]}
                ]}},
            {<<"stops">>,
                {obj, [
                    {<<"features">>, [
                        {obj, [
                            {<<"attributes">>,
                                {obj, [
                                    {<<"Sequence">>, 1},
                                    {<<"Cumul_Miles">>, 0},
                                    {<<"Cumul_ZTime">>, 0},
                                    {<<"Cumul_ATime">>, 0}
                                ]}}
                        ]},
                        {obj, [
                            {<<"attributes">>,
                                {obj, [
                                    {<<"Sequence">>, 2},
                                    {<<"Cumul_Miles">>, 1},
                                    {<<"Cumul_ZTime">>, 3},
                                    {<<"Cumul_ATime">>, 99}
                                ]}}
                        ]}
                    ]}
                ]}}
        ]}
    ),
    {{ok, R}, _} = route(Body, #{}),
    ?assertEqual(1609.344, maps:get(total_distance_meters, R)),
    ?assertEqual(180.0, maps:get(total_duration_seconds, R)).

routing_route_totals_shape_scan_uses_response_order_test() ->
    Body = oj(
        {obj, [
            {<<"routes">>,
                {obj, [
                    {<<"features">>, [
                        {obj, [
                            {<<"attributes">>,
                                {obj, [
                                    {<<"Total_Kilometers">>, 2},
                                    {<<"Total_ZTime">>, 5},
                                    {<<"Total_ATime">>, 50}
                                ]}},
                            {<<"geometry">>, {obj, [{<<"paths">>, [[[0, 0], [1, 1]]]}]}}
                        ]}
                    ]}
                ]}}
        ]}
    ),
    {{ok, R}, _} = route(Body, #{}),
    ?assertEqual(300.0, maps:get(total_duration_seconds, R)).

routing_without_routes_is_no_route_test() ->
    {{error, E}, _} = route(<<"{\"routes\":{\"features\":[]}}">>, #{}),
    ?assertMatch(#{code := no_route, status := 200}, E).

routing_non_json_body_is_unknown_test() ->
    ?assertMatch({{error, #{code := unknown, status := 200}}, _}, route(<<"<html>">>, #{})).

routing_unreadable_totals_or_path_points_are_unknown_test_() ->
    Cases = [
        {#{<<"Name">> => <<"x">>}, [[[0, 0], [1, 1]]]},
        {#{<<"Total_TravelTime">> => 1, <<"Total_Kilometers">> => 1}, [[[0, null], [1, 1]]]},
        {#{<<"Total_TravelTime">> => 1, <<"Total_Kilometers">> => 1}, [[[0]]]}
    ],
    [
        ?_assertMatch(
            {{error, #{code := unknown}}, _},
            route(
                j(#{
                    <<"routes">> => #{
                        <<"features">> => [
                            #{<<"attributes">> => A, <<"geometry">> => #{<<"paths">> => Paths}}
                        ]
                    }
                }),
                #{}
            )
        )
     || {A, Paths} <- Cases
    ].

%% ---- departure time (Route startTime / OD + ServiceArea timeOfDay) --------

routing_start_time_is_flagged_as_utc_test() ->
    %% startTimeIsUTC defaults to false, which reads startTime in the first
    %% stop's local time zone — wrong for an absolute epoch instant.
    {{ok, _}, P} = route(?ROUTE_BODY, #{departure_time => ?DEPARTURE, traffic_mode => traffic}),
    F = form(P),
    ?assertEqual(?DEPARTURE_MS, maps:get(<<"startTime">>, F)),
    ?assertEqual(<<"true">>, maps:get(<<"startTimeIsUTC">>, F)).

routing_departure_time_input_forms_test_() ->
    [
        ?_test(begin
            {{ok, _}, P} = route(?ROUTE_BODY, #{departure_time => DT, traffic_mode => traffic}),
            ?assertEqual(?DEPARTURE_MS, maps:get(<<"startTime">>, form(P)))
        end)
     || DT <- [
            1786071960,
            ?DEPARTURE,
            <<"2026-08-07T03:06:00Z">>,
            <<"2026-08-07T03:06:00.000Z">>,
            <<"2026-08-07T03:06:00+00:00">>,
            <<"2026-08-07T05:06:00+02:00">>,
            %% A string without an offset is read as UTC, never host-local.
            <<"2026-08-07T03:06:00">>,
            <<"2026-08-07T03:06">>,
            <<"2026-08-07 03:06:00">>
        ]
    ].

routing_departure_fraction_is_kept_to_the_millisecond_test() ->
    {{ok, _}, P} = route(?ROUTE_BODY, #{
        departure_time => <<"2026-08-07T03:06:00.5Z">>, traffic_mode => traffic
    }),
    ?assertEqual(<<"1786071960500">>, maps:get(<<"startTime">>, form(P))).

routing_departure_offsets_test_() ->
    [
        ?_test(begin
            {{ok, _}, P} = route(?ROUTE_BODY, #{departure_time => DT, traffic_mode => traffic}),
            ?assertEqual(?DEPARTURE_MS, maps:get(<<"startTime">>, form(P)))
        end)
     || DT <- [
            <<"2026-08-07T08:06:00+05">>,
            <<"2026-08-07T00:06:00-03:00">>,
            <<"2026-08-07T00:06:00-0300">>
        ]
    ].

routing_departure_with_an_impossible_offset_is_invalid_request_test() ->
    {C, P} = cfg([]),
    ?assertMatch(
        {error, #{code := invalid_request}},
        ?L:route(C, #{waypoints => ?TWO, departure_time => <<"2026-08-07T03:06:00+25:00">>})
    ),
    ?assertEqual([], ?F:calls(P)).

routing_without_departure_sends_no_time_fields_test() ->
    {{ok, _}, P} = route(?ROUTE_BODY, #{}),
    F = form(P),
    ?assertNot(maps:is_key(<<"startTime">>, F)),
    ?assertNot(maps:is_key(<<"startTimeIsUTC">>, F)).

matrix_departure_is_time_of_day_not_start_time_test() ->
    %% solveODCostMatrix has no startTime parameter; it takes timeOfDay +
    %% timeOfDayIsUTC (default false).
    {{ok, _}, P} = matrix(?MATRIX_OK, #{departure_time => ?DEPARTURE, traffic_mode => traffic}),
    F = form(P),
    ?assertEqual(?DEPARTURE_MS, maps:get(<<"timeOfDay">>, F)),
    ?assertEqual(<<"true">>, maps:get(<<"timeOfDayIsUTC">>, F)),
    ?assertNot(maps:is_key(<<"startTime">>, F)).

isochrone_time_of_day_is_flagged_as_utc_test() ->
    {{ok, _}, P} = iso(?SA_OK, #{departure_time => <<"2026-08-07T03:06:00Z">>}),
    F = form(P),
    ?assertEqual(?DEPARTURE_MS, maps:get(<<"timeOfDay">>, F)),
    ?assertEqual(<<"true">>, maps:get(<<"timeOfDayIsUTC">>, F)).

unparseable_departure_is_invalid_request_before_any_request_test_() ->
    Calls = [
        fun(C) -> ?L:route(C, #{waypoints => ?TWO, departure_time => <<"not-a-date">>}) end,
        %% Refused even under traffic_mode none: a caller bug either way.
        fun(C) -> ?L:route(C, #{waypoints => ?TWO, departure_time => <<"next tuesday">>}) end,
        fun(C) ->
            ?L:matrix(C, #{
                origins => [ll(1, 1)],
                destinations => [ll(2, 2)],
                departure_time => <<"next tuesday">>
            })
        end,
        fun(C) ->
            ?L:isochrone(C, #{
                center => ll(1, 1), type => time, values => [600], departure_time => <<"tomorrow">>
            })
        end,
        fun(C) ->
            ?L:isochrone(C, #{
                center => ll(1, 1),
                type => time,
                values => [600],
                departure_time => <<"2026-13-01T00:00">>
            })
        end,
        fun(C) ->
            ?L:route(C, #{waypoints => ?TWO, departure_time => <<"2026-08-07T25:00:00Z">>})
        end
    ],
    [
        ?_test(begin
            {C, P} = cfg([]),
            {error, E} = Call(C),
            ?assertMatch(#{code := invalid_request}, E),
            ?assertNot(maps:is_key(status, E)),
            ?assertEqual([], ?F:calls(P))
        end)
     || Call <- Calls
    ].

esri_keeps_accepting_an_iso_string_departure_time_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"routes\":{\"features\":[]}}">>)]),
    %% The body is not a usable route; the point is it was SENT.
    ?assertMatch(
        {error, _},
        ?L:route(C, #{waypoints => ?TWO, departure_time => <<"2026-09-28T12:00:00Z">>})
    ),
    ?assertEqual(1, length(?F:calls(P))).

%% ---- traffic_mode ----------------------------------------------------------

esri_none_never_sends_a_time_test_() ->
    [
        ?_test(begin
            In = maps:from_list([{departure_time, W} || W <- [When], W =/= undefined]),
            {_, P1} = route(?ROUTE_BODY, In),
            F1 = form(P1),
            ?assertNot(maps:is_key(<<"startTime">>, F1)),
            ?assertNot(maps:is_key(<<"startTimeIsUTC">>, F1)),
            {_, P2} = matrix(?MATRIX_OK, In),
            F2 = form(P2),
            ?assertNot(maps:is_key(<<"timeOfDay">>, F2)),
            ?assertNot(maps:is_key(<<"timeOfDayIsUTC">>, F2))
        end)
     || When <- [undefined, ?WHEN]
    ].

esri_traffic_without_time_is_now_test_() ->
    [
        ?_test(begin
            {_, P1} = route(?ROUTE_BODY, #{traffic_mode => Mode}),
            F1 = form(P1),
            ?assertEqual(<<"now">>, maps:get(<<"startTime">>, F1)),
            ?assertNot(maps:is_key(<<"startTimeIsUTC">>, F1)),
            {_, P2} = matrix(?MATRIX_OK, #{traffic_mode => Mode}),
            F2 = form(P2),
            ?assertEqual(<<"now">>, maps:get(<<"timeOfDay">>, F2)),
            ?assertNot(maps:is_key(<<"timeOfDayIsUTC">>, F2))
        end)
     || Mode <- [traffic, live]
    ].

esri_traffic_with_time_is_utc_epoch_test_() ->
    [
        ?_test(begin
            In = #{departure_time => ?WHEN, traffic_mode => Mode},
            {_, P1} = route(?ROUTE_BODY, In),
            ?assertMatch(
                #{<<"startTime">> := ?WHEN_MS, <<"startTimeIsUTC">> := <<"true">>}, form(P1)
            ),
            {_, P2} = matrix(?MATRIX_OK, In),
            ?assertMatch(
                #{<<"timeOfDay">> := ?WHEN_MS, <<"timeOfDayIsUTC">> := <<"true">>}, form(P2)
            )
        end)
     || Mode <- [traffic, live]
    ].

esri_passthrough_time_still_wins_under_none_test() ->
    {_, P1} = route(?ROUTE_BODY, #{
        departure_time => ?WHEN, passthrough => #{body => #{<<"startTime">> => <<"now">>}}
    }),
    ?assertEqual(<<"now">>, maps:get(<<"startTime">>, form(P1))),
    {_, P2} = matrix(?MATRIX_OK, #{passthrough => #{body => #{timeOfDay => ?WHEN_MS}}}),
    ?assertEqual(?WHEN_MS, maps:get(<<"timeOfDay">>, form(P2))).

live_alias_sends_the_same_request_as_traffic_test_() ->
    Wire = fun(Mode, When) ->
        In = maps:from_list(
            [{traffic_mode, Mode}] ++ [{departure_time, W} || W <- [When], W =/= undefined]
        ),
        {_, P1} = route(?ROUTE_BODY, In),
        {_, P2} = matrix(?MATRIX_OK, In),
        [maps:with([method, url, body], ?F:last(P)) || P <- [P1, P2]]
    end,
    [?_assertEqual(Wire(traffic, W), Wire(live, W)) || W <- [undefined, ?WHEN]].

%% ---- unlocatable stops -----------------------------------------------------

routing_fails_on_invalid_locations_instead_of_skipping_them_test() ->
    %% ignoreInvalidLocations defaults to true ("unlocated will be ignored"),
    %% which returns a route that silently skips a requested stop.
    {_, P} = route(?ROUTE_BODY, #{}),
    ?assertEqual(<<"false">>, maps:get(<<"ignoreInvalidLocations">>, form(P))).

routing_unlocated_stop_failure_is_no_route_test() ->
    Body =
        <<"{\"error\":{\"code\":400,\"message\":\"Unable to complete operation.\",\"details\":[\"Location \\\"Location 2\\\" in \\\"Stops\\\" is unlocated.\",\"Need at least 2 valid stops.\"]}}">>,
    {{error, E}, _} = route(Body, #{}),
    ?assertMatch(#{code := no_route, provider_message := <<"Unable to complete operation.">>}, E),
    %% The cause is the error object itself.
    ?assertMatch(#{<<"code">> := 400}, maps:get(cause, E)).

esri_no_route_is_an_in_body_400_naming_an_unlocated_stop_test() ->
    Body = j(#{
        <<"error">> => #{
            <<"code">> => 400,
            <<"message">> => <<"Unable to complete operation.">>,
            <<"details">> => [
                <<"Location \"Location 1\" in \"Stops\" is unlocated.  Need at least 2 valid stops.">>
            ]
        }
    }),
    ?assertMatch({{error, #{code := no_route}}, _}, route(Body, #{})).

esri_in_body_400_without_an_unlocated_stop_stays_invalid_request_test() ->
    %% The guard against over-reaching: a genuine 400 must NOT become no_route
    %% just because it shares Esri's in-body error code.
    Body = j(#{
        <<"error">> => #{
            <<"code">> => 400,
            <<"message">> => <<"Unable to complete operation.">>,
            <<"details">> => [<<"Invalid value for parameter travelMode.">>]
        }
    }),
    ?assertMatch({{error, #{code := invalid_request}}, _}, route(Body, #{})).

matrix_and_isochrone_do_not_send_ignore_invalid_locations_test() ->
    {_, P1} = matrix(?MATRIX_OK, #{}),
    ?assertNot(maps:is_key(<<"ignoreInvalidLocations">>, form(P1))),
    {_, P2} = iso(?SA_OK, #{center => ll(1, 1)}),
    ?assertNot(maps:is_key(<<"ignoreInvalidLocations">>, form(P2))).

%% ---- error mapping ---------------------------------------------------------

in_body_error_code_mapping_test_() ->
    Cases = [
        {<<"{\"error\":{\"code\":499,\"message\":\"Token Required\"}}">>, auth_failed},
        {<<"{\"error\":{\"code\":403,\"message\":\"denied\"}}">>, auth_failed},
        {<<"{\"error\":{\"code\":\"498\",\"message\":\"Invalid token\"}}">>, auth_failed},
        {<<"{\"error\":{\"code\":429,\"message\":\"slow\"}}">>, rate_limited},
        {<<"{\"error\":{\"code\":404,\"message\":\"nope\"}}">>, invalid_request},
        {<<"{\"error\":{\"code\":500,\"message\":\"boom\"}}">>, provider_unavailable},
        {<<"{\"error\":{\"code\":418,\"message\":\"teapot\"}}">>, unknown},
        {<<"{\"error\":{\"message\":\"no code\"}}">>, unknown}
    ],
    [
        ?_assertMatch({{error, #{code := Code, status := 200}}, _}, route(Body, #{}))
     || {Body, Code} <- Cases
    ].

in_body_error_message_fallbacks_test_() ->
    Cases = [
        {<<"{\"error\":{\"code\":498}}">>, <<"498">>},
        {<<"{\"error\":{\"code\":\"E42\"}}">>, <<"E42">>},
        {<<"{\"error\":\"plain\"}">>, <<"plain">>},
        {<<"{\"error\":{},\"message\":\"top\"}">>, <<"top">>}
    ],
    [
        ?_test(begin
            {{error, E}, _} = route(Body, #{}),
            ?assertEqual(Msg, maps:get(provider_message, E))
        end)
     || {Body, Msg} <- Cases
    ].

http_error_mapping_test_() ->
    Cases = [
        {401, <<"{}">>, #{}, auth_failed},
        {403, <<"<html>">>, #{}, auth_failed},
        {400, <<"{}">>, #{}, invalid_request},
        {503, <<>>, #{}, provider_unavailable},
        {418, <<>>, #{}, unknown},
        {429, <<"{\"error\":{\"message\":\"slow\"}}">>, #{<<"Retry-After">> => <<"7">>},
            rate_limited},
        %% The in-body code wins over the HTTP status.
        {400, <<"{\"error\":{\"code\":498,\"message\":\"Invalid token\"}}">>, #{}, auth_failed}
    ],
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(Status, Body, Headers)]),
            {error, E} = ?L:geocode(C, #{address => <<"x">>}),
            ?assertMatch(#{code := Code, status := Status}, E),
            case Headers of
                #{} when map_size(Headers) =:= 0 ->
                    ok;
                _ ->
                    ?assertMatch(#{<<"retryAfter">> := <<"7">>}, maps:get(cause, E)),
                    ?assertNotEqual(
                        nomatch, binary:match(maps:get(provider_message, E), <<"7 seconds">>)
                    )
            end
        end)
     || {Status, Body, Headers, Code} <- Cases
    ].

http_error_on_every_operation_test_() ->
    Calls = [
        fun(C) -> ?L:route(C, #{waypoints => ?TWO}) end,
        fun(C) -> ?L:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]}) end,
        fun(C) -> ?L:isochrone(C, #{center => ll(1, 1), type => time, values => [600]}) end
    ],
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(503, <<>>)]),
            ?assertMatch({error, #{code := provider_unavailable, status := 503}}, Call(C))
        end)
     || Call <- Calls
    ].

transport_failure_test() ->
    {C, _} = cfg([{error, timeout}]),
    ?assertMatch({error, #{code := timeout}}, ?L:route(C, #{waypoints => ?TWO})).

%% ---- optimization ----------------------------------------------------------

optimize_flags_map_to_find_best_sequence_and_preserve_stops_test_() ->
    Cases = [
        %% findBestSequence defaults BOTH preserve flags to true (live: order
        %% [0,1,2,3] with defaults, [2,3,0,1] with both false), so each is
        %% sent explicitly.
        {#{optimize => true}, <<"true">>, <<"true">>},
        {#{optimize => true, optimize_fixed_origin => true}, <<"true">>, <<"false">>},
        {#{optimize => true, optimize_fixed_destination => true}, <<"false">>, <<"true">>},
        {
            #{optimize => true, optimize_fixed_origin => true, optimize_fixed_destination => true},
            <<"true">>,
            <<"true">>
        },
        %% A fixed-endpoint flag alone also means "reorder".
        {#{optimize_fixed_origin => true}, <<"true">>, <<"false">>},
        {#{optimize_fixed_destination => true}, <<"false">>, <<"true">>}
    ],
    [
        ?_test(begin
            {{ok, R}, P} = route(seq_route_body([1, 4, 2, 3]), Flags#{waypoints => ?FOUR}),
            F = form(P),
            ?assertEqual(<<"true">>, maps:get(<<"findBestSequence">>, F)),
            ?assertEqual({First, Last}, {
                maps:get(<<"preserveFirstStop">>, F), maps:get(<<"preserveLastStop">>, F)
            }),
            ?assertEqual([0, 2, 3, 1], maps:get(waypoint_order, R))
        end)
     || {Flags, First, Last} <- Cases
    ].

optimized_route_with_non_integer_sequence_omits_waypoint_order_test() ->
    Body = j(#{
        <<"routes">> => #{
            <<"features">> => [
                #{
                    <<"attributes">> => #{<<"Total_TravelTime">> => 1, <<"Total_Kilometers">> => 1},
                    <<"geometry">> => #{<<"paths">> => [[[0, 0], [1, 1]]]}
                }
            ]
        },
        <<"stops">> => #{
            <<"features">> => [
                #{<<"attributes">> => #{<<"Sequence">> => 1.0}},
                #{<<"attributes">> => #{<<"Sequence">> => 2}}
            ]
        }
    }),
    {{ok, R}, _} = route(Body, #{optimize => true}),
    ?assertNot(maps:is_key(waypoint_order, R)).

no_optimize_flag_sends_no_sequence_params_test() ->
    {_, P} = route(seq_route_body([1, 2]), #{}),
    F = form(P),
    [
        ?assertNot(maps:is_key(K, F))
     || K <- [<<"findBestSequence">>, <<"preserveFirstStop">>, <<"preserveLastStop">>]
    ].

%% ---- restrictions ----------------------------------------------------------

walking_avoid_restrictions_go_inside_the_travel_mode_test() ->
    %% Live: walking travelMode + a top-level restrictionAttributeNames=Avoid
    %% Ferries -> Esri reported only the mode's own "Avoid Private Roads" (ours
    %% ignored); appended to the travel mode's own list -> honoured.
    {_, P} = route(seq_route_body([1, 2]), #{
        travel_mode => walking, avoid_ferries => true, avoid_tolls => true
    }),
    F = form(P),
    ?assertNot(maps:is_key(<<"restrictionAttributeNames">>, F)),
    ?assertEqual(
        [
            <<"Avoid Private Roads">>,
            <<"Avoid Roads Unsuitable for Pedestrians">>,
            <<"Preferred for Pedestrians">>,
            <<"Walking">>,
            <<"Avoid Toll Roads">>,
            <<"Avoid Ferries">>
        ],
        maps:get(<<"restrictionAttributeNames">>, json:decode(maps:get(<<"travelMode">>, F)))
    ).

walking_travel_mode_restrictions_are_not_carried_into_the_next_request_test() ->
    {_, P1} = route(seq_route_body([1, 2]), #{travel_mode => walking, avoid_ferries => true}),
    ?assert(
        lists:member(
            <<"Avoid Ferries">>,
            maps:get(
                <<"restrictionAttributeNames">>, json:decode(maps:get(<<"travelMode">>, form(P1)))
            )
        )
    ),
    {_, P2} = route(seq_route_body([1, 2]), #{travel_mode => walking}),
    ?assertNot(
        lists:member(
            <<"Avoid Ferries">>,
            maps:get(
                <<"restrictionAttributeNames">>, json:decode(maps:get(<<"travelMode">>, form(P2)))
            )
        )
    ).

driving_avoid_restrictions_use_the_top_level_parameter_test() ->
    %% Driving sends no travelMode (service default), where the top-level
    %% parameter is honoured (live: the route changes).
    {_, P} = route(seq_route_body([1, 2]), #{
        avoid_tolls => true, avoid_ferries => true, avoid_highways => true
    }),
    F = form(P),
    ?assertNot(maps:is_key(<<"travelMode">>, F)),
    ?assertEqual(
        <<"Avoid Toll Roads,Avoid Ferries,Avoid Limited Access Roads">>,
        maps:get(<<"restrictionAttributeNames">>, F)
    ).

walking_matrix_avoid_tolls_goes_inside_the_travel_mode_test() ->
    Body =
        <<"{\"odCostMatrix\":{\"costAttributeNames\":[\"WalkTime\",\"Kilometers\"],\"1\":{\"1\":[13.0,1.0]}}}">>,
    {{ok, _}, P} = matrix(Body, #{travel_mode => walking, avoid_tolls => true}),
    F = form(P),
    ?assertNot(maps:is_key(<<"restrictionAttributeNames">>, F)),
    ?assert(
        lists:member(
            <<"Avoid Toll Roads">>,
            maps:get(<<"restrictionAttributeNames">>, json:decode(maps:get(<<"travelMode">>, F)))
        )
    ).

driving_matrix_avoid_tolls_uses_the_top_level_parameter_test() ->
    Body =
        <<"{\"odCostMatrix\":{\"costAttributeNames\":[\"TravelTime\",\"Kilometers\"],\"1\":{\"1\":[5,10]}}}">>,
    {{ok, _}, P} = matrix(Body, #{avoid_tolls => true}),
    ?assertEqual(<<"Avoid Toll Roads">>, maps:get(<<"restrictionAttributeNames">>, form(P))).

%% ---------------------------------------------------------------------------
%% Matrix

matrix_sparse_test() ->
    %% Real esriNAODOutputSparseMatrix shape: odCostMatrix keyed by 1-based
    %% origin OID, each mapping 1-based dest OID -> [values in
    %% costAttributeNames order]. Cell (1,1) is the LIVE-verified
    %% NYC->Bridgeport sample.
    Body =
        <<"{\"requestID\":\"abc\",\"odCostMatrix\":{\"costAttributeNames\":[\"TravelTime\",\"Kilometers\"],\"1\":{\"1\":[93.25787017375364,98.94833503121721],\"2\":[10,20]},\"2\":{\"1\":[30,40],\"2\":[5,6]}},\"messages\":[]}">>,
    {C, P} = cfg([?F:resp(200, Body)]),
    {ok, #{cells := Cells}} = ?L:matrix(C, #{
        origins => [ll(1, 1), ll(2, 2)], destinations => [ll(3, 3), ll(4, 4)]
    }),
    ?assertEqual(4, length(Cells)),
    %% Response order.
    ?assertEqual(
        [{0, 0}, {0, 1}, {1, 0}, {1, 1}],
        [{O, D} || #{origin_index := O, destination_index := D} <- Cells]
    ),
    [C00 | _] = Cells,
    ?assertEqual(98.94833503121721 * 1000, maps:get(distance_meters, C00)),
    ?assertEqual(93.25787017375364 * 60, maps:get(duration_seconds, C00)),
    ?assertMatch(#{distance_meters := 6000.0, duration_seconds := 300.0}, lists:last(Cells)),
    Last = ?F:last(P),
    ?assertEqual(
        <<"https://route-api.arcgis.com/arcgis/rest/services/World/OriginDestinationCostMatrix/NAServer/OriginDestinationCostMatrix_World/solveODCostMatrix">>,
        maps:get(url, Last)
    ),
    F = ?F:body_form(Last),
    ?assertEqual(<<"TravelTime">>, maps:get(<<"impedanceAttributeName">>, F)),
    ?assertEqual(<<"Kilometers">>, maps:get(<<"accumulateAttributeNames">>, F)),
    ?assertEqual(<<"esriNAODOutputSparseMatrix">>, maps:get(<<"outputType">>, F)),
    ?assertEqual(<<"k">>, maps:get(<<"token">>, F)),
    ?assertMatch(
        #{<<"features">> := [_, _]}, json:decode(maps:get(<<"origins">>, F))
    ).

matrix_sparse_cells_follow_response_key_order_test() ->
    Body =
        <<"{\"odCostMatrix\":{\"10\":{\"2\":[1,1],\"1\":[1,1]},\"costAttributeNames\":[\"TravelTime\",\"Kilometers\"],\"2\":{\"1\":[1,1]}}}">>,
    {C, _} = cfg([?F:resp(200, Body)]),
    Os = [ll(I, I) || I <- lists:seq(1, 10)],
    {ok, #{cells := Cells}} = ?L:matrix(C, #{origins => Os, destinations => [ll(0, 0), ll(1, 1)]}),
    ?assertEqual(
        [{9, 1}, {9, 0}, {1, 0}],
        [{O, D} || #{origin_index := O, destination_index := D} <- Cells]
    ).

matrix_walking_decodes_walktime_impedance_test() ->
    %% A WALK travel mode makes ArcGIS override the impedance, so
    %% costAttributeNames comes back as ["WalkTime","Kilometers"]. Live values
    %% (2026-07-21).
    Body =
        <<"{\"odCostMatrix\":{\"costAttributeNames\":[\"WalkTime\",\"Kilometers\"],\"1\":{\"1\":[13.094903051108146,1.091226960340165]}}}">>,
    {{ok, #{cells := [Cell]}}, P} = matrix(Body, #{
        origins => [ll(0, 0)], destinations => [ll(1, 1)], travel_mode => walking
    }),
    ?assert(abs(maps:get(duration_seconds, Cell) - 13.094903051108146 * 60) < 1.0e-6),
    ?assert(abs(maps:get(distance_meters, Cell) - 1.091226960340165 * 1000) < 1.0e-6),
    ?assertMatch(
        #{<<"type">> := <<"WALK">>}, json:decode(maps:get(<<"travelMode">>, form(P)))
    ).

matrix_default_cost_columns_when_absent_test() ->
    {{ok, #{cells := [Cell]}}, _} = matrix(<<"{\"odCostMatrix\":{\"1\":{\"1\":[2,3]}}}">>, #{}),
    ?assertMatch(#{duration_seconds := 120.0, distance_meters := 3000.0}, Cell).

matrix_odlines_test() ->
    %% Real esriNAODOutputStraightLines fallback.
    Body =
        <<"{\"odLines\":{\"features\":[{\"attributes\":{\"ObjectID\":1,\"OriginID\":1,\"DestinationID\":1,\"DestinationRank\":1,\"Total_TravelTime\":93.25787017375364,\"Total_Kilometers\":98.94833503121721,\"Shape_Length\":0.9}},{\"attributes\":{\"ObjectID\":2,\"OriginID\":1,\"DestinationID\":2,\"Total_TravelTime\":10,\"Total_Kilometers\":20}},{\"attributes\":{\"ObjectID\":3,\"OriginID\":2,\"DestinationID\":1,\"Total_TravelTime\":30,\"Total_Kilometers\":40}},{\"attributes\":{\"ObjectID\":4,\"OriginID\":2,\"DestinationID\":2,\"Total_TravelTime\":5,\"Total_Kilometers\":6}}]}}">>,
    {{ok, #{cells := Cells}}, _} = matrix(Body, #{
        origins => [ll(1, 1), ll(2, 2)], destinations => [ll(3, 3), ll(4, 4)]
    }),
    ?assertEqual(4, length(Cells)),
    [C00 | _] = [C || C = #{origin_index := 0, destination_index := 0} <- Cells],
    ?assertEqual(98.94833503121721 * 1000, maps:get(distance_meters, C00)),
    ?assertEqual(93.25787017375364 * 60, maps:get(duration_seconds, C00)).

matrix_sparse_omits_unroutable_pairs_test() ->
    %% Origin OID 2 is unroutable and omitted by Esri: a sparse result, not an
    %% error for the whole matrix.
    Body =
        <<"{\"odCostMatrix\":{\"costAttributeNames\":[\"TravelTime\",\"Kilometers\"],\"1\":{\"1\":[5,10]}}}">>,
    {{ok, #{cells := Cells}}, _} = matrix(Body, #{
        origins => [ll(1, 1), ll(2, 2)], destinations => [ll(3, 3)]
    }),
    ?assertMatch([#{origin_index := 0, destination_index := 0}], Cells).

matrix_out_of_range_oid_test_() ->
    Bodies = [
        %% origin OID 3 with only 2 origins requested
        <<"{\"odCostMatrix\":{\"costAttributeNames\":[\"TravelTime\",\"Kilometers\"],\"3\":{\"1\":[5,10]}}}">>,
        <<"{\"odCostMatrix\":{\"costAttributeNames\":[\"TravelTime\",\"Kilometers\"],\"x\":{\"1\":[5,10]}}}">>,
        <<"{\"odCostMatrix\":{\"costAttributeNames\":[\"TravelTime\",\"Kilometers\"],\"1\":[5,10]}}">>,
        <<"{\"odCostMatrix\":{\"costAttributeNames\":[\"TravelTime\",\"Kilometers\"],\"1\":{\"2\":[5,10]}}}">>
    ],
    [
        ?_assertMatch(
            {{error, #{code := unknown}}, _},
            matrix(B, #{origins => [ll(1, 1), ll(2, 2)], destinations => [ll(3, 3)]})
        )
     || B <- Bodies
    ].

matrix_with_an_unrecognised_cost_column_is_unknown_not_zero_test_() ->
    [
        ?_test(begin
            Body = j(#{
                <<"odCostMatrix">> => #{
                    <<"costAttributeNames">> => Cols, <<"1">> => #{<<"1">> => [5, 10]}
                }
            }),
            {{error, E}, _} = matrix(Body, #{}),
            ?assertMatch(#{code := unknown}, E),
            ?assertEqual(#{<<"costAttributeNames">> => Cols}, maps:get(cause, E))
        end)
     || Cols <- [
            [<<"BikeTime">>, <<"Kilometers">>],
            [<<"TravelTime">>, <<"Miles">>],
            [<<"Minutes">>]
        ]
    ].

sparse_matrix_cell_missing_a_cost_is_omitted_test() ->
    Body =
        <<"{\"odCostMatrix\":{\"costAttributeNames\":[\"TravelTime\",\"Kilometers\"],\"1\":{\"1\":[5,2],\"2\":[null,3],\"3\":7}}}">>,
    {{ok, #{cells := Cells}}, _} = matrix(Body, #{
        destinations => [ll(2, 2), ll(3, 3), ll(4, 4)]
    }),
    ?assertEqual([{0, 300.0}], [{D, S} || #{destination_index := D, duration_seconds := S} <- Cells]).

od_lines_walking_reads_total_walk_time_test() ->
    Body =
        <<"{\"odLines\":{\"features\":[{\"attributes\":{\"OriginID\":1,\"DestinationID\":1,\"Total_WalkTime\":12,\"Total_Kilometers\":1}}]}}">>,
    {{ok, #{cells := [Cell]}}, _} = matrix(Body, #{travel_mode => walking}),
    ?assertEqual(720.0, maps:get(duration_seconds, Cell)).

od_lines_sparse_answer_omits_missing_pairs_and_costs_test() ->
    Body =
        <<"{\"odLines\":{\"features\":[{\"attributes\":{\"OriginID\":1,\"DestinationID\":1,\"Total_TravelTime\":1,\"Total_Kilometers\":2}},{\"attributes\":{\"OriginID\":2,\"DestinationID\":1,\"Total_Kilometers\":4}}]}}">>,
    {{ok, #{cells := Cells}}, _} = matrix(Body, #{
        origins => [ll(1, 1), ll(1, 2)], destinations => [ll(2, 2), ll(3, 3)]
    }),
    %% (0,1) and (1,1) absent from the answer, (1,0) without a time: omitted.
    ?assertEqual([{0, 0}], [{O, D} || #{origin_index := O, destination_index := D} <- Cells]).

od_lines_out_of_range_or_non_integer_oid_is_unknown_test_() ->
    [
        ?_assertMatch(
            {{error, #{code := unknown}}, _},
            matrix(
                j(#{
                    <<"odLines">> => #{
                        <<"features">> => [
                            #{
                                <<"attributes">> => #{
                                    <<"OriginID">> => Oid,
                                    <<"DestinationID">> => Did,
                                    <<"Total_TravelTime">> => 1,
                                    <<"Total_Kilometers">> => 1
                                }
                            }
                        ]
                    }
                }),
                #{origins => [ll(1, 1), ll(1, 2)], destinations => [ll(2, 2)]}
            )
        )
     || {Oid, Did} <- [{3, 1}, {1, 9}, {1.5, 1}, {<<"x">>, 1}, {0, 1}]
    ].

matrix_without_a_payload_is_unknown_test_() ->
    [
        ?_assertMatch({{error, #{code := unknown, status := 200}}, _}, matrix(B, #{}))
     || B <- [<<"{}">>, <<"[]">>, <<"nope">>, <<"{\"odCostMatrix\":[]}">>]
    ].

matrix_body_error_test() ->
    ?assertMatch(
        {{error, #{code := auth_failed}}, _},
        matrix(<<"{\"error\":{\"code\":498,\"message\":\"Invalid token\"}}">>, #{})
    ).

%% ---------------------------------------------------------------------------
%% Geocoding

geocode_test() ->
    {C, P} = ?F:config(#{provider => esri, api_key => <<"apikey">>}, [
        ?F:resp(
            200,
            <<"{\"candidates\":[{\"address\":\"New York, NY\",\"location\":{\"x\":-74,\"y\":40},\"extent\":{\"xmin\":-74.3,\"ymin\":40.4,\"xmax\":-73.7,\"ymax\":40.9}}]}">>
        )
    ]),
    {ok, #{candidates := [Cand]}} = ?L:geocode(C, #{address => <<"NYC">>}),
    ?assertEqual(
        #{
            formatted_address => <<"New York, NY">>,
            location => #{lat => 40.0, lng => -74.0},
            viewport => #{
                southwest => #{lat => 40.4, lng => -74.3},
                northeast => #{lat => 40.9, lng => -73.7}
            }
        },
        Cand
    ),
    Last = ?F:last(P),
    ?assertEqual(get, maps:get(method, Last)),
    ?assertEqual(
        <<"/arcgis/rest/services/World/GeocodeServer/findAddressCandidates">>, ?F:path_of(Last)
    ),
    ?assertEqual(<<"apikey">>, ?F:qget(Last, <<"token">>)),
    ?assertEqual(<<"NYC">>, ?F:qget(Last, <<"singleLine">>)),
    ?assertEqual(<<"*">>, ?F:qget(Last, <<"outFields">>)),
    ?assertEqual(<<"json">>, ?F:qget(Last, <<"f">>)),
    ?assertEqual([], ?F:qall(Last, <<"countryCode">>)),
    ?assertEqual([], ?F:qall(Last, <<"langCode">>)).

geocode_country_filter_and_language_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"candidates\":[]}">>)]),
    {ok, _} = ?L:geocode(C, #{
        address => <<"x">>, country_filter => [<<"US">>, <<"CA">>], language => <<"fr">>
    }),
    ?assertEqual(<<"US,CA">>, ?F:qget(?F:last(P), <<"countryCode">>)),
    ?assertEqual(<<"fr">>, ?F:qget(?F:last(P), <<"langCode">>)).

esri_geocode_skips_candidates_without_location_test() ->
    Body =
        <<"{\"candidates\":[{\"address\":\"no location\"},{\"address\":\"empty location\",\"location\":{}},{\"address\":\"good\",\"location\":{\"x\":2.5,\"y\":1.5}}]}">>,
    {C, _} = cfg([?F:resp(200, Body)]),
    {ok, #{candidates := Cands}} = ?L:geocode(C, #{address => <<"x">>}),
    ?assertEqual(
        [#{formatted_address => <<"good">>, location => #{lat => 1.5, lng => 2.5}}], Cands
    ).

geocode_uninterpretable_2xx_body_is_unknown_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(200, Body)]),
            ?assertMatch(
                {error, #{code := unknown, status := 200}}, ?L:geocode(C, #{address => <<"x">>})
            )
        end)
     || Body <- [<<>>, <<"<html>busy</html>">>, <<"[]">>, <<"{\"unexpected\": true}">>]
    ].

geocode_well_formed_zero_results_stays_empty_test() ->
    {C, _} = cfg([?F:resp(200, <<"{\"candidates\":[]}">>)]),
    ?assertMatch({ok, #{candidates := []}}, ?L:geocode(C, #{address => <<"x">>})).

partial_viewport_is_omitted_test() ->
    {C, _} = cfg([
        ?F:resp(
            200,
            <<"{\"candidates\":[{\"address\":\"a\",\"location\":{\"x\":2,\"y\":1},\"extent\":{\"xmin\":1,\"ymin\":1,\"xmax\":3}}]}">>
        )
    ]),
    {ok, #{candidates := [Cand]}} = ?L:geocode(C, #{address => <<"x">>}),
    ?assertNot(maps:is_key(viewport, Cand)).

reverse_geocode_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"address\":{\"LongLabel\":\"123 Main St, NY\"},\"location\":{\"x\":-74,\"y\":40}}">>
        )
    ]),
    {ok, #{candidates := [Cand]}} = ?L:reverse_geocode(C, #{
        location => ll(40, -74), language => <<"en">>
    }),
    ?assertEqual(
        #{formatted_address => <<"123 Main St, NY">>, location => #{lat => 40.0, lng => -74.0}},
        Cand
    ),
    Last = ?F:last(P),
    ?assertEqual(<<"/arcgis/rest/services/World/GeocodeServer/reverseGeocode">>, ?F:path_of(Last)),
    ?assertEqual(<<"-74,40">>, ?F:qget(Last, <<"location">>)),
    ?assertEqual(<<"en">>, ?F:qget(Last, <<"langCode">>)),
    ?assertEqual([], ?F:qall(Last, <<"outFields">>)),
    {C2, _} = cfg([?F:resp(200, <<"{}">>)]),
    ?assertMatch({ok, #{candidates := []}}, ?L:reverse_geocode(C2, #{location => ll(1, 1)})).

reverse_geocode_match_addr_and_missing_parts_test_() ->
    Cases = [
        {<<"{\"address\":{\"Match_addr\":\"M\"},\"location\":{\"x\":1,\"y\":2}}">>, [<<"M">>]},
        {<<"{\"address\":{},\"location\":{\"x\":1,\"y\":2}}">>, []},
        {<<"{\"address\":{\"LongLabel\":\"L\"},\"location\":{\"x\":1}}">>, []},
        {<<"{\"address\":{\"LongLabel\":\"L\"}}">>, []}
    ],
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(200, Body)]),
            {ok, #{candidates := Cands}} = ?L:reverse_geocode(C, #{location => ll(1, 1)}),
            ?assertEqual(Want, [A || #{formatted_address := A} <- Cands])
        end)
     || {Body, Want} <- Cases
    ].

esri_reverse_geocode_unable_to_find_address_returns_empty_test() ->
    Body =
        <<"{\"error\":{\"code\":400,\"message\":\"Cannot perform query. Invalid query parameters.\",\"details\":[\"Unable to find address for the specified location.\"]}}">>,
    {C, _} = cfg([?F:resp(200, Body)]),
    {ok, R} = ?L:reverse_geocode(C, #{location => ll(0, -30)}),
    ?assertEqual([], maps:get(candidates, R)),
    ?assertMatch(#{<<"error">> := #{<<"code">> := 400}}, maps:get(raw, R)).

esri_reverse_geocode_other_400_is_still_invalid_request_test() ->
    {C, _} = cfg([
        ?F:resp(
            200, <<"{\"error\":{\"code\":400,\"message\":\"Invalid location\",\"details\":[]}}">>
        )
    ]),
    ?assertMatch(
        {error, #{code := invalid_request}}, ?L:reverse_geocode(C, #{location => ll(0, -30)})
    ).

autocomplete_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"suggestions\":[{\"text\":\"New York\",\"magicKey\":\"mk1\"},{\"text\":\"No key\"}]}">>
        )
    ]),
    {ok, #{predictions := Preds}} = ?L:autocomplete(C, #{
        input => <<"New">>, location => ll(40.5, -74.25)
    }),
    ?assertEqual(
        [#{description => <<"New York">>, place_id => <<"mk1">>}, #{description => <<"No key">>}],
        Preds
    ),
    Last = ?F:last(P),
    ?assertEqual(<<"/arcgis/rest/services/World/GeocodeServer/suggest">>, ?F:path_of(Last)),
    ?assertEqual(<<"New">>, ?F:qget(Last, <<"text">>)),
    ?assertEqual(<<"-74.25,40.5">>, ?F:qget(Last, <<"location">>)).

esri_forwards_country_filter_as_country_code_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"suggestions\":[]}">>)]),
    {ok, _} = ?L:autocomplete(C, #{input => <<"New York">>, country_filter => [<<"IL">>, <<"PS">>]}),
    ?assertEqual(<<"IL,PS">>, ?F:qget(?F:last(P), <<"countryCode">>)).

esri_never_emits_structured_format_test() ->
    %% Esri returns a single flat `text` field — it must stay absent rather
    %% than be faked by splitting that string.
    Body = j(#{
        <<"suggestions">> => [
            #{
                <<"text">> => <<"Rijksmuseum, Museumstraat 1, Amsterdam">>,
                <<"magicKey">> => <<"mk1">>
            }
        ]
    }),
    {C, _} = cfg([?F:resp(200, Body)]),
    {ok, #{predictions := [Pred]}} = ?L:autocomplete(C, #{input => <<"rijks">>}),
    ?assertNot(maps:is_key(structured_format, Pred)),
    ?assertEqual(<<"Rijksmuseum, Museumstraat 1, Amsterdam">>, maps:get(description, Pred)).

autocomplete_uninterpretable_2xx_body_is_unknown_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(200, Body)]),
            ?assertMatch(
                {error, #{code := unknown}},
                ?L:autocomplete(C, #{input => <<"x">>, location => ll(1, 1)})
            )
        end)
     || Body <- [<<"<html/>">>, <<"{}">>]
    ].

-define(PLACE_BODY,
    <<"{\"candidates\":[{\"address\":\"Museumstraat 1\",\"location\":{\"x\":4.885,\"y\":52.36}}]}">>
).

esri_sends_magic_key_alone_test() ->
    %% Live-verified: magicKey ALONE resolves. The docs pair it with
    %% SingleLine; the probe showed that is unnecessary.
    {C, P} = cfg([?F:resp(200, ?PLACE_BODY)]),
    {ok, #{candidate := Cand}} = ?L:place_details(C, #{place_id => <<"mk-abc">>}),
    Last = ?F:last(P),
    ?assertEqual(<<"mk-abc">>, ?F:qget(Last, <<"magicKey">>)),
    ?assertEqual([], ?F:qall(Last, <<"SingleLine">>)),
    ?assertEqual([], ?F:qall(Last, <<"singleLine">>)),
    ?assertEqual(<<"*">>, ?F:qget(Last, <<"outFields">>)),
    ?assertEqual(
        <<"/arcgis/rest/services/World/GeocodeServer/findAddressCandidates">>, ?F:path_of(Last)
    ),
    ?assertEqual(52.36, maps:get(lat, maps:get(location, Cand))).

esri_leaves_name_absent_even_when_included_test() ->
    %% Esri returns only an address — there is no display name to surface.
    {C, P} = cfg([?F:resp(200, ?PLACE_BODY)]),
    {ok, R} = ?L:place_details(C, #{place_id => <<"mk1">>, include => [name], language => <<"nl">>}),
    ?assertNot(maps:is_key(name, R)),
    ?assertEqual(<<"Museumstraat 1">>, maps:get(formatted_address, maps:get(candidate, R))),
    ?assertEqual(<<"nl">>, ?F:qget(?F:last(P), <<"langCode">>)).

an_unusable_place_details_result_returns_no_candidate_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(200, Body)]),
            {ok, R} = ?L:place_details(C, #{place_id => <<"x">>, include => [name]}),
            ?assertEqual(#{raw => json:decode(Body)}, R)
        end)
     || Body <- [<<"{\"candidates\":[]}">>, <<"{}">>, <<"{\"candidates\":[{\"address\":\"a\"}]}">>]
    ].

place_details_unparseable_2xx_body_is_unknown_test() ->
    {C, _} = cfg([?F:resp(200, <<"<html>oops</html>">>)]),
    ?assertMatch({error, #{code := unknown}}, ?L:place_details(C, #{place_id => <<"x">>})).

esri_stale_magic_key_stays_an_error_test() ->
    %% Live: a stale magicKey is an in-body error 400, not an unknown place.
    Body = j(#{
        <<"error">> => #{
            <<"code">> => 400,
            <<"message">> =>
                <<"MagicKey was not generated from the current release and is no longer valid">>,
            <<"details">> => []
        }
    }),
    {C, _} = cfg([?F:resp(200, Body)]),
    ?assertMatch({error, #{code := invalid_request}}, ?L:place_details(C, #{place_id => <<"mk">>})).

geocode_passthrough_query_body_and_headers_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"candidates\":[]}">>)]),
    {ok, _} = ?L:geocode(C, #{
        address => <<"x">>,
        passthrough => #{
            %% `body` overlays the connector's query params on a GET; `null`
            %% drops one.
            body => #{outFields => null, maxLocations => 3, forStorage => false},
            query => #{<<"category">> => <<"Address">>, <<"f">> => <<"pjson">>},
            headers => #{<<"X-Trace">> => <<"t1">>}
        }
    }),
    Last = ?F:last(P),
    ?assertEqual([], ?F:qall(Last, <<"outFields">>)),
    ?assertEqual(<<"3">>, ?F:qget(Last, <<"maxLocations">>)),
    ?assertEqual(<<"false">>, ?F:qget(Last, <<"forStorage">>)),
    ?assertEqual(<<"Address">>, ?F:qget(Last, <<"category">>)),
    ?assertEqual([<<"pjson">>], ?F:qall(Last, <<"f">>)),
    ?assertEqual(<<"t1">>, ?F:header(Last, <<"X-Trace">>)).

form_passthrough_body_and_query_test() ->
    {_, P} = route(?ROUTE_BODY, #{
        passthrough => #{
            body => #{
                <<"returnDirections">> => true,
                <<"outSR">> => 102100,
                <<"directionsLengthUnits">> => <<"esriNAUKilometers">>,
                <<"barriers">> => #{<<"features">> => []},
                <<"impedanceAttributeName">> => null,
                <<"tolerance">> => 0.5
            },
            query => #{<<"trace">> => <<"1">>}
        }
    }),
    Last = ?F:last(P),
    F = ?F:body_form(Last),
    ?assertEqual(<<"true">>, maps:get(<<"returnDirections">>, F)),
    ?assertEqual(<<"102100">>, maps:get(<<"outSR">>, F)),
    ?assertEqual(<<"esriNAUKilometers">>, maps:get(<<"directionsLengthUnits">>, F)),
    ?assertEqual(<<"{\"features\":[]}">>, maps:get(<<"barriers">>, F)),
    ?assertEqual(<<>>, maps:get(<<"impedanceAttributeName">>, F)),
    ?assertEqual(<<"0.5">>, maps:get(<<"tolerance">>, F)),
    ?assertEqual(<<"1">>, ?F:qget(Last, <<"trace">>)).

%% ---------------------------------------------------------------------------
%% Isochrone

isochrone_test() ->
    Body =
        <<"{\"saPolygons\":{\"features\":[{\"attributes\":{\"FromBreak\":0,\"ToBreak\":10},\"geometry\":{\"rings\":[[[-74,40],[-73,40],[-73,41],[-74,40]]]}}]}}">>,
    {{ok, R}, P} = iso(Body, #{}),
    [Contour] = maps:get(contours, R),
    ?assertEqual(600.0, maps:get(value, Contour)),
    ?assertMatch(
        #{type := <<"Polygon">>, coordinates := [[_, _, _, _]]}, maps:get(geometry, Contour)
    ),
    Last = ?F:last(P),
    ?assertEqual(
        <<"https://route-api.arcgis.com/arcgis/rest/services/World/ServiceAreas/NAServer/ServiceArea_World/solveServiceArea">>,
        maps:get(url, Last)
    ),
    F = ?F:body_form(Last),
    ?assertEqual(<<"10">>, maps:get(<<"defaultBreaks">>, F)),
    ?assertEqual(<<"false">>, maps:get(<<"returnFacilities">>, F)),
    ?assertEqual(<<"esriNATravelDirectionFromFacility">>, maps:get(<<"travelDirection">>, F)),
    ?assertNot(maps:is_key(<<"timeOfDay">>, F)).

isochrone_walking_sends_full_travel_mode_object_test() ->
    {{ok, _}, P} = iso(?SA_OK, #{travel_mode => walking}),
    ?assertMatch(
        #{
            <<"type">> := <<"WALK">>,
            <<"impedanceAttributeName">> := <<"WalkTime">>,
            <<"name">> := <<"Walking Time">>
        },
        json:decode(maps:get(<<"travelMode">>, form(P)))
    ).

isochrone_time_breaks_are_minutes_under_the_default_impedance_test() ->
    {{ok, _}, P} = iso(?SA_OK, #{values => [300, 600]}),
    F = form(P),
    ?assertEqual(<<"5,10">>, maps:get(<<"defaultBreaks">>, F)),
    %% solveServiceArea has no breakUnits parameter; breaks follow the impedance.
    ?assertNot(maps:is_key(<<"breakUnits">>, F)),
    ?assertNot(maps:is_key(<<"impedanceAttributeName">>, F)).

isochrone_duplicate_breaks_are_sent_once_test() ->
    {{ok, _}, P} = iso(?SA_OK, #{values => [600, 600.0]}),
    ?assertEqual(<<"10">>, maps:get(<<"defaultBreaks">>, form(P))).

isochrone_driving_distance_uses_kilometers_impedance_test() ->
    Body =
        <<"{\"saPolygons\":{\"features\":[{\"attributes\":{\"FromBreak\":0,\"ToBreak\":5},\"geometry\":{\"rings\":[[[-74,40],[-73,40],[-73,41],[-74,40]]]}},{\"attributes\":{\"FromBreak\":0,\"ToBreak\":0.3},\"geometry\":{\"rings\":[[[-74,40],[-73,40],[-74,40]]]}}]}}">>,
    {{ok, R}, P} = iso(Body, #{type => distance, values => [5000, 300]}),
    F = form(P),
    ?assertEqual(<<"5,0.3">>, maps:get(<<"defaultBreaks">>, F)),
    ?assertEqual(<<"Kilometers">>, maps:get(<<"impedanceAttributeName">>, F)),
    ?assertNot(maps:is_key(<<"breakUnits">>, F)),
    ?assertNot(maps:is_key(<<"travelMode">>, F)),
    ?assertEqual([300.0, 5000.0], [V || #{value := V} <- maps:get(contours, R)]).

isochrone_walking_distance_sets_kilometers_inside_the_travel_mode_test() ->
    %% A travelMode overrides impedanceAttributeName, so the distance impedance
    %% must live inside the walking travel-mode object.
    {{ok, _}, P} = iso(?SA_OK, #{type => distance, values => [2000], travel_mode => walking}),
    F = form(P),
    ?assertMatch(
        #{
            <<"type">> := <<"WALK">>,
            <<"impedanceAttributeName">> := <<"Kilometers">>,
            <<"distanceAttributeName">> := <<"Kilometers">>,
            <<"name">> := <<"Walking Distance">>,
            <<"id">> := <<"yFuMFwIYblqKEefX">>
        },
        json:decode(maps:get(<<"travelMode">>, F))
    ),
    ?assertEqual(<<"2">>, maps:get(<<"defaultBreaks">>, F)),
    ?assertNot(maps:is_key(<<"breakUnits">>, F)),
    ?assertNot(maps:is_key(<<"impedanceAttributeName">>, F)).

isochrone_detailed_polygons_only_within_the_15_minute_15_mile_cap_test_() ->
    Cases = [
        {time, [600], <<"esriNAOutputPolygonDetailed">>},
        {time, [900], <<"esriNAOutputPolygonDetailed">>},
        {time, [600, 1800], <<"esriNAOutputPolygonSimplified">>},
        {time, [1800], <<"esriNAOutputPolygonSimplified">>},
        {distance, [24140], <<"esriNAOutputPolygonDetailed">>},
        {distance, [30000], <<"esriNAOutputPolygonSimplified">>}
    ],
    [
        ?_test(begin
            {_, P} = iso(?SA_OK, #{type => Type, values => Values}),
            ?assertEqual(Want, maps:get(<<"outputPolygons">>, form(P)))
        end)
     || {Type, Values, Want} <- Cases
    ].

isochrone_contour_value_is_the_callers_not_the_minute_round_trip_test() ->
    Body =
        <<"{\"saPolygons\":{\"features\":[{\"attributes\":{\"ToBreak\":0.116667},\"geometry\":{\"rings\":[[[-74,40],[-73,40],[-74,40]]]}}]}}">>,
    {{ok, R}, P} = iso(Body, #{values => [7]}),
    ?assertEqual(<<"0.116667">>, maps:get(<<"defaultBreaks">>, form(P))),
    ?assertMatch([#{value := 7.0}], maps:get(contours, R)).

isochrone_unsent_break_falls_back_to_a_unit_conversion_test() ->
    Body =
        <<"{\"saPolygons\":{\"features\":[{\"attributes\":{\"ToBreak\":20},\"geometry\":{\"rings\":[[[-74,40],[-73,40],[-74,40]]]}}]}}">>,
    {{ok, R1}, _} = iso(Body, #{}),
    ?assertMatch([#{value := 1200.0}], maps:get(contours, R1)),
    {{ok, R2}, _} = iso(Body, #{type => distance, values => [1000]}),
    ?assertMatch([#{value := 20000.0}], maps:get(contours, R2)).

isochrone_without_a_usable_polygon_is_unknown_test_() ->
    Bodies = [
        <<"{\"saPolygons\":{\"features\":[]}}">>,
        <<"{\"saPolygons\":{\"features\":[{\"attributes\":{},\"geometry\":{\"rings\":[[[-74,40],[-73,40],[-74,40]]]}}]}}">>,
        <<"{\"saPolygons\":{\"features\":[{\"attributes\":{\"ToBreak\":10},\"geometry\":{\"rings\":[]}}]}}">>,
        <<"{\"saPolygons\":{\"features\":[{\"attributes\":{\"ToBreak\":10},\"geometry\":{\"rings\":[[[-74]]]}}]}}">>,
        <<"{}">>,
        <<"oops">>
    ],
    [?_assertMatch({{error, #{code := unknown}}, _}, iso(B, #{})) || B <- Bodies].

isochrone_body_error_test() ->
    ?assertMatch(
        {{error, #{code := auth_failed}}, _},
        iso(<<"{\"error\":{\"code\":498,\"message\":\"Invalid token\"}}">>, #{})
    ).

%% ---- contour geometry ------------------------------------------------------

area(Ring) ->
    N = length(Ring),
    T = list_to_tuple(Ring),
    lists:sum([
        begin
            [X1, Y1] = element(I + 1, T),
            [X2, Y2] = element((I + 1) rem N + 1, T),
            X1 * Y2 - X2 * Y1
        end
     || I <- lists:seq(0, N - 1)
    ]) / 2.

%% Open square ring of [lng, lat] points in the requested winding.
square(X0, Y0, X1, Y1, Ccw) ->
    Ring = [[X0, Y0], [X1, Y0], [X1, Y1], [X0, Y1]],
    case Ccw of
        true -> Ring;
        false -> lists:reverse(Ring)
    end.

closed([F | _] = Ring) -> Ring ++ [F].

bbox(Ring) ->
    Xs = [X || [X, _] <- Ring],
    Ys = [Y || [_, Y] <- Ring],
    {lists:min(Xs), lists:min(Ys), lists:max(Xs), lists:max(Ys)}.

within(Inner, Outer) ->
    {IX0, IY0, IX1, IY1} = bbox(Inner),
    {OX0, OY0, OX1, OY1} = bbox(Outer),
    OX0 =< IX0 andalso OY0 =< IY0 andalso IX1 =< OX1 andalso IY1 =< OY1.

assert_rfc7946(Polygon) ->
    lists:foreach(
        fun({I, Ring}) ->
            ?assertEqual(hd(Ring), lists:last(Ring)),
            case I of
                1 -> ?assert(area(Ring) > 0);
                _ -> ?assert(area(Ring) < 0)
            end
        end,
        lists:zip(lists:seq(1, length(Polygon)), Polygon)
    ).

esri_geometry(Rings) ->
    Body = j(#{
        <<"saPolygons">> => #{
            <<"features">> => [
                #{
                    <<"attributes">> => #{<<"ToBreak">> => 10},
                    <<"geometry">> => #{<<"rings">> => [closed(R) || R <- Rings]}
                }
            ]
        }
    }),
    {{ok, #{contours := [#{geometry := G}]}}, _} = iso(Body, #{center => ll(1, 1)}),
    G.

esri_multi_part_with_holes_and_rings0_being_a_hole_test() ->
    %% Esri convention: exterior clockwise, hole counter-clockwise, any order.
    HoleB = square(10.5, 0.5, 11, 1, true),
    ExtA = square(0, 0, 4, 4, false),
    HoleA = square(1, 1, 2, 2, true),
    ExtB = square(10, 0, 12, 2, false),
    #{type := Type, coordinates := Parts} = esri_geometry([HoleB, ExtA, HoleA, ExtB]),
    ?assertEqual(<<"MultiPolygon">>, Type),
    ?assertEqual(2, length(Parts)),
    lists:foreach(
        fun([Ext, Hole] = Part) ->
            ?assert(within(Hole, Ext)),
            assert_rfc7946(Part)
        end,
        Parts
    ),
    ?assertEqual(
        [{0, 0, 4, 4}, {10, 0, 12, 2}], lists:sort([bbox(Ext) || [Ext | _] <- Parts])
    ).

esri_single_exterior_with_hole_first_is_polygon_test() ->
    #{type := Type, coordinates := [Ext, Hole] = Poly} = esri_geometry([
        square(1, 1, 2, 2, true), square(0, 0, 4, 4, false)
    ]),
    ?assertEqual(<<"Polygon">>, Type),
    ?assertEqual({0, 0, 4, 4}, bbox(Ext)),
    ?assertEqual({1, 1, 2, 2}, bbox(Hole)),
    assert_rfc7946(Poly).

esri_hole_goes_to_the_innermost_containing_exterior_test() ->
    %% An island (exterior) inside a lake (hole) of a bigger part, with its own hole.
    Big = square(0, 0, 10, 10, false),
    Lake = square(2, 2, 8, 8, true),
    Island = square(4, 4, 6, 6, false),
    Pond = square(4.5, 4.5, 5.5, 5.5, true),
    #{type := <<"MultiPolygon">>, coordinates := Parts} = esri_geometry([Pond, Big, Island, Lake]),
    ?assertEqual(
        #{{0, 0, 10, 10} => [{2, 2, 8, 8}], {4, 4, 6, 6} => [{4.5, 4.5, 5.5, 5.5}]},
        maps:from_list([{bbox(E), [bbox(H) || H <- Hs]} || [E | Hs] <- Parts])
    ).

esri_uncontained_hole_goes_to_the_largest_exterior_test() ->
    #{coordinates := Parts} = esri_geometry([
        square(0, 0, 1, 1, false), square(10, 10, 20, 20, false), square(30, 30, 31, 31, true)
    ]),
    ?assertEqual(
        #{{0, 0, 1, 1} => 1, {10, 10, 20, 20} => 2},
        maps:from_list([{bbox(E), length(P)} || [E | _] = P <- Parts])
    ).

esri_without_any_clockwise_ring_reads_every_ring_as_exterior_test() ->
    #{type := Type, coordinates := Parts} = esri_geometry([
        square(0, 0, 1, 1, true), square(5, 5, 6, 6, true)
    ]),
    ?assertEqual(<<"MultiPolygon">>, Type),
    ?assertEqual(2, length(Parts)),
    lists:foreach(fun assert_rfc7946/1, Parts).

esri_malformed_rings_are_ignored_but_none_usable_is_unknown_test() ->
    Body = j(#{
        <<"saPolygons">> => #{
            <<"features">> => [
                #{
                    <<"attributes">> => #{<<"ToBreak">> => 10},
                    <<"geometry">> => #{<<"rings">> => [[[1]], <<"x">>]}
                }
            ]
        }
    }),
    ?assertMatch({{error, #{code := unknown}}, _}, iso(Body, #{center => ll(1, 1)})).

%% ---------------------------------------------------------------------------
%% Default accumulate-attribute lists

%% Stops carry Cumul_<TimeAttr>=10 min and Cumul_Kilometers=5 on the last
%% stop. Extra attributes carry deliberately different values, placed ahead of
%% (`before`) or behind (`after`) the real ones in the JSON, so a shape-based
%% pick would misread them.
default_list_route_body(TimeAttr, Before, After, Stops) ->
    Attrs = fun(Prefix, T, Km) ->
        {obj,
            [{<<Prefix/binary, N/binary>>, T * 7 + 1} || N <- Before] ++
                [
                    {<<Prefix/binary, TimeAttr/binary>>, T},
                    {<<Prefix/binary, "Kilometers">>, Km}
                ] ++
                [{<<Prefix/binary, N/binary>>, T * 3 + 2} || N <- After]}
    end,
    StopAttrs = fun(Seq, T, Km) ->
        {obj, Inner} = Attrs(<<"Cumul_">>, T, Km),
        {obj, [{<<"attributes">>, {obj, [{<<"Sequence">>, Seq}, {<<"Status">>, 0} | Inner]}}]}
    end,
    oj(
        {obj,
            [
                {<<"routes">>,
                    {obj, [
                        {<<"features">>, [
                            {obj, [
                                {<<"attributes">>, Attrs(<<"Total_">>, 10, 5)},
                                {<<"geometry">>, {obj, [{<<"paths">>, [[[0, 0], [1, 1]]]}]}}
                            ]}
                        ]}
                    ]}}
            ] ++
                [
                    {<<"stops">>,
                        {obj, [{<<"features">>, [StopAttrs(1, 0, 0), StopAttrs(2, 10, 5)]}]}}
                 || Stops
                ]}
    ).

esri_routing_accumulate_attributes_are_the_constant_test_() ->
    [
        ?_test(begin
            {{ok, _}, P} = route(default_list_route_body(TimeAttr, [], [], true), #{
                travel_mode => Mode
            }),
            ?assertEqual(
                iolist_to_binary(lists:join(<<",">>, Constant)),
                maps:get(<<"accumulateAttributeNames">>, form(P))
            )
        end)
     || {Mode, TimeAttr, Constant} <- [
            {driving, <<"TravelTime">>,
                thinwrap_location_defaults:esri_routing_accumulate_attributes_driving()},
            {walking, <<"WalkTime">>,
                thinwrap_location_defaults:esri_routing_accumulate_attributes_walking()}
        ]
    ].

esri_routing_append_via_constant_test() ->
    Names = iolist_to_binary(
        lists:join(
            <<",">>,
            thinwrap_location_defaults:esri_routing_accumulate_attributes_driving() ++ [<<"Miles">>]
        )
    ),
    {{ok, R}, P} = route(
        default_list_route_body(<<"TravelTime">>, [], [<<"Miles">>], true),
        #{passthrough => #{body => #{<<"accumulateAttributeNames">> => Names}}}
    ),
    ?assertEqual(Names, maps:get(<<"accumulateAttributeNames">>, form(P))),
    ?assertMatch([#{duration_seconds := 600.0, distance_meters := 5000.0}], maps:get(legs, R)).

esri_routing_reads_the_requested_fields_whatever_else_is_accumulated_test_() ->
    [
        ?_test(begin
            {Before, After} =
                case Placement of
                    before -> {Extra, []};
                    'after' -> {[], Extra}
                end,
            {{ok, R}, _} = route(default_list_route_body(TimeAttr, Before, After, true), #{
                travel_mode => Mode
            }),
            ?assertMatch(
                [#{duration_seconds := 600.0, distance_meters := 5000.0}], maps:get(legs, R)
            ),
            ?assertEqual(600.0, maps:get(total_duration_seconds, R)),
            ?assertEqual(5000.0, maps:get(total_distance_meters, R))
        end)
     || {Mode, TimeAttr, Extra} <- [
            {driving, <<"TravelTime">>, [<<"TruckTravelTime">>, <<"Miles">>]},
            {driving, <<"TravelTime">>, [<<"Miles">>, <<"WalkTime">>]},
            {walking, <<"WalkTime">>, [<<"TravelTime">>, <<"Miles">>]}
        ],
        Placement <- [before, 'after']
    ].

esri_route_totals_fallback_reads_the_requested_time_attribute_test_() ->
    %% No stops -> the even-split fallback over the route's Total_* values.
    [
        ?_test(begin
            {{ok, R}, _} = route(
                default_list_route_body(TimeAttr, [<<"TruckTravelTime">>], [], false),
                #{travel_mode => Mode}
            ),
            ?assertEqual(600.0, maps:get(total_duration_seconds, R)),
            ?assertEqual(5000.0, maps:get(total_distance_meters, R))
        end)
     || {Mode, TimeAttr} <- [{driving, <<"TravelTime">>}, {walking, <<"WalkTime">>}]
    ].

esri_routing_caller_list_replaces_the_default_test() ->
    {_, P} = route(default_list_route_body(<<"TravelTime">>, [], [], true), #{
        passthrough => #{body => #{accumulateAttributeNames => <<"Kilometers">>}}
    }),
    ?assertEqual(<<"Kilometers">>, maps:get(<<"accumulateAttributeNames">>, form(P))).

esri_matrix_accumulate_attributes_are_the_constant_test() ->
    {{ok, _}, P} = matrix(
        <<"{\"odCostMatrix\":{\"costAttributeNames\":[\"TravelTime\",\"Kilometers\"],\"1\":{\"1\":[10,20]}}}">>,
        #{}
    ),
    ?assertEqual(
        iolist_to_binary(
            lists:join(<<",">>, thinwrap_location_defaults:esri_matrix_accumulate_attributes())
        ),
        maps:get(<<"accumulateAttributeNames">>, form(P))
    ).

esri_matrix_append_via_constant_test() ->
    Names = iolist_to_binary(
        lists:join(
            <<",">>, thinwrap_location_defaults:esri_matrix_accumulate_attributes() ++ [<<"Miles">>]
        )
    ),
    Body =
        <<"{\"odCostMatrix\":{\"costAttributeNames\":[\"TravelTime\",\"Kilometers\",\"Miles\"],\"1\":{\"1\":[10,20,12.4]}}}">>,
    {{ok, #{cells := [Cell]}}, P} = matrix(Body, #{
        passthrough => #{body => #{<<"accumulateAttributeNames">> => Names}}
    }),
    ?assertEqual(Names, maps:get(<<"accumulateAttributeNames">>, form(P))),
    ?assertMatch(#{distance_meters := 20000.0, duration_seconds := 600.0}, Cell).

esri_matrix_caller_list_replaces_the_default_test() ->
    Body = <<"{\"odCostMatrix\":{\"costAttributeNames\":[\"TravelTime\"],\"1\":{\"1\":[10]}}}">>,
    {{error, E}, P} = matrix(Body, #{
        passthrough => #{body => #{<<"accumulateAttributeNames">> => <<"TravelTime">>}}
    }),
    ?assertEqual(<<"TravelTime">>, maps:get(<<"accumulateAttributeNames">>, form(P))),
    %% No Kilometers column: an error, never 0 m.
    ?assertMatch(#{code := unknown}, E).

%% ---------------------------------------------------------------------------
%% Error contract: misuse is badarg, request data is a connector error

routing_vocabulary_misuse_is_badarg_test_() ->
    Cases = [
        {travel_mode, flying},
        {travel_mode, undefined},
        {travel_mode, 1},
        {traffic_mode, 'rush-hour'},
        {traffic_mode, true},
        {polyline_quality, ultra},
        {polyline_quality, undefined},
        {include, [bogus]},
        {include, [durationWithoutTraffic, bogus]},
        {include, durationWithoutTraffic},
        {include, undefined},
        {include, [1]}
    ],
    [
        ?_test(begin
            {C, P} = cfg([]),
            ?assertError({badarg, _}, ?L:route(C, #{waypoints => ?TWO, K => V})),
            ?assertEqual([], ?F:calls(P))
        end)
     || {K, V} <- Cases
    ].

matrix_vocabulary_misuse_is_badarg_test_() ->
    Cases = [
        {travel_mode, flying},
        {travel_mode, undefined},
        {traffic_mode, 'rush-hour'},
        {traffic_mode, 0}
    ],
    [
        ?_test(begin
            {C, P} = cfg([]),
            ?assertError(
                {badarg, _},
                ?L:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)], K => V})
            ),
            ?assertEqual([], ?F:calls(P))
        end)
     || {K, V} <- Cases
    ].

isochrone_vocabulary_misuse_is_badarg_test_() ->
    Cases = [{type, bogus}, {type, undefined}, {travel_mode, flying}, {travel_mode, 2}],
    [
        ?_test(begin
            {C, P} = cfg([]),
            ?assertError(
                {badarg, _},
                ?L:isochrone(
                    C, maps:put(K, V, #{center => ll(1, 1), type => time, values => [600]})
                )
            ),
            ?assertEqual([], ?F:calls(P))
        end)
     || {K, V} <- Cases
    ].

place_details_include_misuse_is_badarg_test_() ->
    [
        ?_test(begin
            {C, P} = cfg([]),
            ?assertError({badarg, _}, ?L:place_details(C, #{place_id => <<"p">>, include => V})),
            ?assertEqual([], ?F:calls(P))
        end)
     || V <- [[bogus], name, undefined, 5]
    ].

fewer_than_two_waypoints_is_invalid_request_test_() ->
    [
        ?_test(begin
            {C, P} = cfg([]),
            {error, E} = ?L:route(C, #{waypoints => Wps, optimize => Optimize}),
            ?assertMatch(#{code := invalid_request}, E),
            ?assertNot(maps:is_key(status, E)),
            ?assertEqual([], ?F:calls(P))
        end)
     || Wps <- [[], [ll(1, 1)]], Optimize <- [false, true]
    ].

empty_matrix_is_invalid_request_test_() ->
    [
        ?_test(begin
            {C, P} = cfg([]),
            {error, E} = ?L:matrix(C, #{origins => Os, destinations => Ds}),
            ?assertMatch(#{code := invalid_request}, E),
            ?assertNot(maps:is_key(status, E)),
            ?assertEqual([], ?F:calls(P))
        end)
     || {Os, Ds} <- [{[], [ll(1, 1)]}, {[ll(1, 1)], []}]
    ].

bad_isochrone_breaks_are_invalid_request_test_() ->
    [
        ?_test(begin
            {C, P} = cfg([]),
            {error, E} = ?L:isochrone(C, #{center => ll(1, 1), type => time, values => Values}),
            ?assertMatch(#{code := invalid_request}, E),
            ?assertNot(maps:is_key(status, E)),
            ?assertEqual([], ?F:calls(P))
        end)
     || Values <- [[], [0], [-5], [1, 2, 3, 4, 5]]
    ].

cycling_isochrone_and_matrix_are_unsupported_travel_mode_test_() ->
    Calls = [
        fun(C) ->
            ?L:isochrone(C, #{
                center => ll(1, 1), type => time, values => [600], travel_mode => cycling
            })
        end,
        fun(C) ->
            ?L:matrix(C, #{
                origins => [ll(1, 1)], destinations => [ll(2, 2)], travel_mode => cycling
            })
        end
    ],
    [
        ?_test(begin
            {C, P} = cfg([]),
            {error, E} = Call(C),
            ?assertMatch(#{code := unsupported_travel_mode}, E),
            ?assertNot(maps:is_key(status, E)),
            ?assertEqual([], ?F:calls(P))
        end)
     || Call <- Calls
    ].
