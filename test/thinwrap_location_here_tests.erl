-module(thinwrap_location_here_tests).

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_location_fake_transport).
-define(FLEX, <<"BFoz5xJ67i1B1B7PzIhaxL7Y">>).
-define(TWO, [#{lat => 1, lng => 1}, #{lat => 2, lng => 2}]).
-define(THREE, [#{lat => 1, lng => 1}, #{lat => 2, lng => 2}, #{lat => 3, lng => 3}]).
-define(STATUS_URL, <<"https://matrix.router.hereapi.com/v8/matrix/mid/status">>).
-define(RESULT_URL, <<"https://aws-eu-west-1.matrix.router.hereapi.com/v8/matrix/mid/result">>).
-define(S3_URL,
    <<"https://s3.eu-west-1.amazonaws.com/here-matrix-results/mid.json.gz?X-Amz-Signature=deadbeef&X-Amz-Expires=60">>
).
%% 2026-09-27T08:30:00Z
-define(DEPART, {{2026, 9, 27}, {8, 30, 0}}).
-define(DEPART_ISO, <<"2026-09-27T08:30:00.000Z">>).
%% 2026-09-28T21:30:00Z
-define(WHEN, 1790631000).
-define(WHEN_ISO, <<"2026-09-28T21:30:00.000Z">>).
-define(WHEN_ISO_S, <<"2026-09-28T21:30:00Z">>).

cfg(Responses) -> ?F:config(#{provider => here, api_key => <<"k">>}, Responses).

ll(Lat, Lng) -> #{lat => Lat, lng => Lng}.

enc(Term) -> iolist_to_binary(json:encode(Term)).

routes_body(Length, Duration) ->
    enc(#{
        routes => [
            #{
                sections => [
                    #{polyline => ?FLEX, summary => #{length => Length, duration => Duration}}
                ]
            }
        ]
    }).

routes_ok() -> ?F:resp(200, routes_body(1, 1)).

findseq_ok() ->
    ?F:resp(
        200,
        <<"{\"results\":[{\"waypoints\":[{\"id\":\"start\",\"sequence\":0},{\"id\":\"end\",\"sequence\":1},{\"id\":\"destination1\",\"sequence\":2}]}]}">>
    ).

findseq_in_order() ->
    ?F:resp(
        200,
        <<"{\"results\":[{\"waypoints\":[{\"id\":\"start\",\"sequence\":0},{\"id\":\"destination1\",\"sequence\":1},{\"id\":\"end\",\"sequence\":2}]}]}">>
    ).

submit_ok() ->
    ?F:resp(200, enc(#{matrixId => <<"mid">>, statusUrl => ?STATUS_URL})).

poll_completed() ->
    ?F:resp(
        200, enc(#{matrixId => <<"mid">>, status => <<"completed">>, resultUrl => ?RESULT_URL})
    ).

retrieve_1x1() ->
    ?F:resp(
        200,
        <<"{\"matrixId\":\"mid\",\"matrix\":{\"numOrigins\":1,\"numDestinations\":1,\"travelTimes\":[1],\"distances\":[1]}}">>
    ).

%% Calls the route and returns the parsed query of the last request.
route_query(Input) ->
    {C, P} = cfg([routes_ok()]),
    {ok, _} = thinwrap_location:route(C, Input#{waypoints => ?TWO}),
    ?F:last(P).

%% Calls the 1x1 matrix and returns the submitted body.
matrix_body(Input) ->
    {C, P} = cfg([submit_ok(), poll_completed(), retrieve_1x1()]),
    {ok, _} = thinwrap_location:matrix(
        C, Input#{origins => [ll(1, 1)], destinations => [ll(2, 2)]}
    ),
    ?F:body_json(hd(?F:calls(P))).

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

%% ---------------------------------------------------------------------------
%% Routing

routing_plain_test() ->
    {C, P} = cfg([?F:resp(200, routes_body(1000, 600))]),
    {ok, R} = thinwrap_location:route(C, #{waypoints => [ll(50.1, 8.6), ll(50.0, 8.7)]}),
    ?assertEqual(1000.0, maps:get(total_distance_meters, R)),
    ?assertEqual(600.0, maps:get(total_duration_seconds, R)),
    ?assertNotEqual(<<>>, maps:get(polyline, R)),
    ?assertNot(maps:is_key(waypoint_order, R)),
    Last = ?F:last(P),
    ?assertEqual(<<"/v8/routes">>, ?F:path_of(Last)),
    ?assertEqual(<<"car">>, ?F:qget(Last, <<"transportMode">>)),
    ?assertEqual(<<"k">>, ?F:qget(Last, <<"apiKey">>)),
    ?assertEqual(<<"fast">>, ?F:qget(Last, <<"routingMode">>)),
    ?assertEqual(<<"50.1,8.6">>, ?F:qget(Last, <<"origin">>)).

routing_travel_mode_mapping_test_() ->
    [
        ?_test(
            ?assertEqual(Want, ?F:qget(route_query(#{travel_mode => Mode}), <<"transportMode">>))
        )
     || {Mode, Want} <- [
            {walking, <<"pedestrian">>}, {cycling, <<"bicycle">>}, {driving, <<"car">>}
        ]
    ].

routing_transport_mode_override_test() ->
    ?assertEqual(
        <<"truck">>, ?F:qget(route_query(#{transport_mode => truck}), <<"transportMode">>)
    ).

%% bus and privateBus are distinct HERE modes, not synonyms: bus may use
%% bus-exclusive streets, privateBus only where a waypoint sits on one.
routing_bus_transport_modes_test_() ->
    [
        ?_assertEqual(Want, ?F:qget(route_query(#{transport_mode => Mode}), <<"transportMode">>))
     || {Mode, Want} <- [{bus, <<"bus">>}, {privateBus, <<"privateBus">>}, {<<"bus">>, <<"bus">>}]
    ].

%% The mode is forwarded verbatim into the findsequence2 mode grammar. bus is
%% accepted there; privateBus is not, which is why it is documented as
%% incompatible with optimize rather than silently rewritten.
routing_optimized_bus_mode_test() ->
    {C, P} = cfg([findseq_ok(), routes_ok()]),
    {ok, _} = thinwrap_location:route(C, #{
        waypoints => ?THREE, optimize => true, transport_mode => bus
    }),
    ?assertEqual(<<"fastest;bus;traffic:disabled">>, ?F:qget(hd(?F:calls(P)), <<"mode">>)).

routing_optimized_test() ->
    {C, P} = cfg([findseq_ok(), ?F:resp(200, routes_body(10, 20))]),
    {ok, R} = thinwrap_location:route(C, #{waypoints => ?THREE, optimize => true}),
    ?assertEqual([0, 2, 1], maps:get(waypoint_order, R)),
    [Seq, Routes] = ?F:calls(P),
    ?assertEqual(<<"/v8/findsequence2">>, ?F:path_of(Seq)),
    ?assertEqual(<<"1,1">>, ?F:qget(Seq, <<"start">>)),
    ?assertEqual(<<"3,3">>, ?F:qget(Seq, <<"end">>)),
    ?assertEqual(<<"2,2">>, ?F:qget(Seq, <<"destination1">>)),
    %% The follow-up /routes call visits the stops in the optimized order.
    ?assertEqual(<<"1,1">>, ?F:qget(Routes, <<"origin">>)),
    ?assertEqual(<<"2,2">>, ?F:qget(Routes, <<"destination">>)),
    ?assertEqual([<<"3,3">>], ?F:qall(Routes, <<"via">>)).

%% Live-verified wire grammar of the legacy WPS endpoint: findsequence2
%% answers 400 'Bad Format for Date and Time' to '2026-08-07T03:06:00.000Z'
%% and 200 to '2026-08-07T03:06:00Z'. /v8/routes keeps the fractional form.
findsequence_departure_has_no_milliseconds_test() ->
    {C, P} = cfg([findseq_ok(), ?F:resp(200, routes_body(10, 20))]),
    {ok, _} = thinwrap_location:route(C, #{
        waypoints => ?THREE,
        optimize => true,
        departure_time => <<"2026-08-07T03:06:00.999Z">>
    }),
    [Seq, Routes] = ?F:calls(P),
    ?assertEqual(<<"2026-08-07T03:06:00Z">>, ?F:qget(Seq, <<"departure">>)),
    ?assertEqual(<<"2026-08-07T03:06:00.999Z">>, ?F:qget(Routes, <<"departureTime">>)).

findsequence_surfaces_errors_array_test_() ->
    Body =
        <<"{\"results\":null,\"errors\":[\"Bad Format for Date and Time: 2026-08-07T03:06:00.000Z.\"],\"responseCode\":\"400\"}">>,
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(Status, Body)]),
            {error, E} = thinwrap_location:route(C, #{waypoints => ?THREE, optimize => true}),
            ?assertMatch(#{code := Code, status := Status}, E),
            ?assertNotEqual(nomatch, binary:match(maps:get(provider_message, E), Expected))
        end)
     || {Status, Code, Expected} <- [
            {400, invalid_request, <<"Bad Format for Date and Time">>},
            %% The legacy endpoint also reports a rejection as HTTP 200 + responseCode.
            {200, unknown, <<"returned no sequence: Bad Format for Date and Time">>}
        ]
    ].

findsequence_non_object_entry_is_unknown_test() ->
    {C, _} = cfg([?F:resp(200, <<"{\"results\":[{\"waypoints\":[null]}]}">>)]),
    ?assertMatch(
        {error, #{code := unknown}},
        thinwrap_location:route(C, #{waypoints => ?THREE, optimize => true})
    ).

findsequence_incomplete_ordering_is_unknown_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"results\":[{\"waypoints\":[{\"id\":\"start\",\"sequence\":0},{\"id\":\"end\",\"sequence\":1}]}]}">>
        )
    ]),
    {error, E} = thinwrap_location:route(C, #{waypoints => ?THREE, optimize => true}),
    ?assertMatch(#{code := unknown, status := 200, cause := #{<<"sequence">> := [0, 2]}}, E),
    ?assertEqual(1, length(?F:calls(P))).

transport_failure_without_a_status_stays_provider_unavailable_test() ->
    {C, _} = cfg([{error, econnreset}]),
    {error, E} = thinwrap_location:route(C, #{waypoints => ?TWO}),
    ?assertMatch(#{code := provider_unavailable}, E),
    ?assertNot(maps:is_key(status, E)).

round_trip_is_unsupported_test() ->
    expect_ce(route, #{waypoints => ?THREE, is_round_trip => true}, unsupported_option).

routing_error_mapping_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(Status, <<"{\"title\":\"Bad\",\"cause\":\"why\"}">>)]),
            {error, E} = thinwrap_location:route(C, #{waypoints => ?TWO}),
            ?assertMatch(#{code := Want, status := Status, provider_message := <<"Bad: why">>}, E)
        end)
     || {Status, Want} <- [
            {400, invalid_request},
            {401, auth_failed},
            {403, auth_failed},
            {429, rate_limited},
            {503, provider_unavailable},
            {418, unknown}
        ]
    ].

routing_retry_after_is_surfaced_test() ->
    {C, _} = cfg([
        ?F:resp(429, <<"{\"title\":\"Too Many Requests\"}">>, #{<<"Retry-After">> => <<"7">>})
    ]),
    {error, E} = thinwrap_location:route(C, #{waypoints => ?TWO}),
    ?assertMatch(#{code := rate_limited, cause := #{<<"retryAfter">> := <<"7">>}}, E),
    ?assertEqual(
        <<"Too Many Requests; retry after 7 seconds">>, maps:get(provider_message, E)
    ).

here_section(Kind, Mode, Length, Duration, Opts) ->
    Place0 = #{type => <<"place">>, location => #{lat => 50.0, lng => 8.6}},
    Place =
        case maps:find(waypoint, Opts) of
            {ok, W} -> Place0#{waypoint => W};
            error -> Place0
        end,
    Summary0 = #{length => Length, duration => Duration},
    Summary =
        case maps:find(base, Opts) of
            {ok, B} -> Summary0#{baseDuration => B};
            error -> Summary0
        end,
    #{
        type => Kind,
        transport => #{mode => Mode},
        departure => #{place => #{type => <<"place">>, location => #{lat => 50.1, lng => 8.5}}},
        arrival => #{place => Place},
        summary => Summary,
        polyline => ?FLEX
    }.

legs(R) -> [{D, T} || #{distance_meters := D, duration_seconds := T} <- maps:get(legs, R)].

routing_ferry_sections_fold_into_one_leg_between_two_waypoints_test() ->
    Body = enc(#{
        routes => [
            #{
                sections => [
                    here_section(<<"vehicle">>, <<"car">>, 1000, 60, #{}),
                    here_section(<<"transit">>, <<"ferry">>, 5000, 1800, #{}),
                    here_section(<<"vehicle">>, <<"car">>, 2000, 120, #{})
                ]
            }
        ]
    }),
    {C, _} = cfg([?F:resp(200, Body)]),
    {ok, R} = thinwrap_location:route(C, #{waypoints => [ll(50.1, 8.5), ll(50.0, 8.6)]}),
    ?assertEqual([{8000.0, 1980.0}], legs(R)),
    ?assertEqual(8000.0, maps:get(total_distance_meters, R)),
    ?assertEqual(1980.0, maps:get(total_duration_seconds, R)).

routing_legs_close_at_via_waypoints_not_at_mode_changes_test() ->
    Body = enc(#{
        routes => [
            #{
                sections => [
                    here_section(<<"vehicle">>, <<"car">>, 1000, 60, #{base => 50}),
                    here_section(<<"transit">>, <<"ferry">>, 5000, 1800, #{base => 1800}),
                    here_section(<<"vehicle">>, <<"car">>, 2000, 120, #{waypoint => 0, base => 100}),
                    here_section(<<"vehicle">>, <<"car">>, 3000, 180, #{base => 170})
                ]
            }
        ]
    }),
    {C, _} = cfg([?F:resp(200, Body)]),
    {ok, R} = thinwrap_location:route(C, #{
        waypoints => [ll(50.1, 8.5), ll(50.2, 8.6), ll(50.0, 8.7)],
        include => [durationWithoutTraffic]
    }),
    ?assertEqual([{8000.0, 1980.0}, {3000.0, 180.0}], legs(R)),
    ?assertEqual(
        [1950.0, 170.0], [B || #{duration_without_traffic_seconds := B} <- maps:get(legs, R)]
    ),
    ?assertEqual(2120.0, maps:get(total_duration_without_traffic_seconds, R)),
    ?assertEqual(11000.0, maps:get(total_distance_meters, R)).

routing_sections_without_waypoint_markers_stay_one_to_one_test() ->
    Body = enc(#{
        routes => [
            #{
                sections => [
                    #{polyline => ?FLEX, summary => #{length => 10, duration => 1}},
                    #{polyline => ?FLEX, summary => #{length => 20, duration => 2}}
                ]
            }
        ]
    }),
    {C, _} = cfg([?F:resp(200, Body)]),
    {ok, R} = thinwrap_location:route(C, #{waypoints => ?THREE}),
    ?assertEqual([{10.0, 1.0}, {20.0, 2.0}], legs(R)).

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
            <<"{\"routes\":[{\"sections\":[null]}]}">>,
            <<"{\"routes\":{\"a\":1}}">>,
            %% A malformed flexible polyline is a body the connector cannot read.
            <<"{\"routes\":[{\"sections\":[{\"polyline\":\"!!\",\"summary\":{}}]}]}">>
        ]
    ].

routing_route_without_sections_is_no_route_test() ->
    {C, _} = cfg([?F:resp(200, <<"{\"routes\":[{\"sections\":[]}]}">>)]),
    ?assertMatch({error, #{code := no_route}}, thinwrap_location:route(C, #{waypoints => ?TWO})).

routing_no_route_surfaces_the_critical_notice_test() ->
    Body = enc(#{
        notices => [
            #{
                title => <<"Route calculation failed: Couldn't match origin.">>,
                code => <<"couldNotMatchOrigin">>,
                severity => <<"critical">>
            }
        ],
        routes => []
    }),
    {C, _} = cfg([?F:resp(200, Body)]),
    {error, E} = thinwrap_location:route(C, #{waypoints => ?TWO}),
    ?assertMatch(#{code := no_route, status := 200}, E),
    ?assertNotEqual(
        nomatch, binary:match(maps:get(provider_message, E), <<"couldNotMatchOrigin">>)
    ).

routing_no_routes_without_notice_test() ->
    {C, _} = cfg([?F:resp(200, <<"{}">>)]),
    ?assertMatch(
        {error, #{code := no_route, provider_message := <<"HERE Routing returned no routes">>}},
        thinwrap_location:route(C, #{waypoints => ?TWO})
    ).

%% ---------------------------------------------------------------------------
%% Routing: traffic is off unless traffic_mode is traffic/live. HERE applies
%% live traffic whenever departureTime is omitted and bills /v8/routes as
%% Time-Aware Routing unless the request carries departureTime=any or
%% traffic[mode]=disabled.

routing_default_sends_departure_time_any_without_traffic_mode_test() ->
    Q = route_query(#{}),
    ?assertEqual([<<"any">>], ?F:qall(Q, <<"departureTime">>)),
    ?assertEqual([], ?F:qall(Q, <<"traffic[mode]">>)).

routing_none_with_departure_time_keeps_the_time_and_disables_traffic_test() ->
    Q = route_query(#{traffic_mode => none, departure_time => ?DEPART}),
    ?assertEqual([?DEPART_ISO], ?F:qall(Q, <<"departureTime">>)),
    ?assertEqual([<<"disabled">>], ?F:qall(Q, <<"traffic[mode]">>)).

routing_live_sends_neither_switch_test() ->
    Q = route_query(#{traffic_mode => live}),
    ?assertEqual([], ?F:qall(Q, <<"departureTime">>)),
    ?assertEqual([], ?F:qall(Q, <<"traffic[mode]">>)).

routing_live_with_departure_time_sends_only_the_time_test() ->
    Q = route_query(#{traffic_mode => live, departure_time => ?DEPART}),
    ?assertEqual([?DEPART_ISO], ?F:qall(Q, <<"departureTime">>)),
    ?assertEqual([], ?F:qall(Q, <<"traffic[mode]">>)).

routing_optimized_routes_call_gets_the_same_traffic_default_test() ->
    {C, P} = cfg([findseq_in_order(), routes_ok()]),
    {ok, _} = thinwrap_location:route(C, #{waypoints => ?THREE, optimize => true}),
    [Seq, Routes] = ?F:calls(P),
    ?assertEqual(<<"/v8/routes">>, ?F:path_of(Routes)),
    ?assertEqual([<<"any">>], ?F:qall(Routes, <<"departureTime">>)),
    ?assertEqual([], ?F:qall(Routes, <<"traffic[mode]">>)),
    %% findsequence2 carries traffic in its own `mode` grammar, not departureTime.
    ?assertEqual(<<"fastest;car;traffic:disabled">>, ?F:qget(Seq, <<"mode">>)),
    ?assertEqual(<<>>, ?F:qget(Seq, <<"departureTime">>)).

routing_passthrough_overrides_the_traffic_default_test() ->
    Q = route_query(#{
        departure_time => ?DEPART,
        passthrough => #{query => #{<<"traffic[mode]">> => <<"default">>}}
    }),
    ?assertEqual([<<"default">>], ?F:qall(Q, <<"traffic[mode]">>)),
    ?assertEqual([?DEPART_ISO], ?F:qall(Q, <<"departureTime">>)).

%% A time field arriving through passthrough switches the none default from
%% departureTime=any to traffic disabled: HERE answers `any` + arrivalTime
%% with 400 on both endpoints, and a passthrough departureTime would replace
%% `any` and put the request back on the Time-Aware SKU.
routing_passthrough_arrival_time_disables_traffic_instead_of_any_test() ->
    Q = route_query(#{passthrough => #{query => #{<<"arrivalTime">> => ?DEPART_ISO}}}),
    ?assertEqual([], ?F:qall(Q, <<"departureTime">>)),
    ?assertEqual([?DEPART_ISO], ?F:qall(Q, <<"arrivalTime">>)),
    ?assertEqual([<<"disabled">>], ?F:qall(Q, <<"traffic[mode]">>)).

routing_passthrough_departure_time_disables_traffic_test() ->
    %% An atom passthrough key works the same as a binary one.
    Q = route_query(#{passthrough => #{query => #{departureTime => ?DEPART_ISO}}}),
    ?assertEqual([?DEPART_ISO], ?F:qall(Q, <<"departureTime">>)),
    ?assertEqual([<<"disabled">>], ?F:qall(Q, <<"traffic[mode]">>)).

%% `disabled` would also drop long-term closures, which `any` keeps.
routing_passthrough_departure_time_any_keeps_the_default_test() ->
    Q = route_query(#{passthrough => #{query => #{<<"departureTime">> => <<"any">>}}}),
    ?assertEqual([<<"any">>], ?F:qall(Q, <<"departureTime">>)),
    ?assertEqual([], ?F:qall(Q, <<"traffic[mode]">>)).

routing_traffic_uses_the_vendor_default_test_() ->
    [
        ?_test(begin
            Input0 = #{waypoints => ?TWO, traffic_mode => Mode},
            Input =
                case When of
                    undefined -> Input0;
                    _ -> Input0#{departure_time => When}
                end,
            Q = first(route, Input),
            ?assertEqual(Want, ?F:qall(Q, <<"departureTime">>)),
            ?assertEqual([], ?F:qall(Q, <<"traffic[mode]">>))
        end)
     || Mode <- [traffic, live], {When, Want} <- [{undefined, []}, {?WHEN, [?WHEN_ISO]}]
    ].

routing_none_with_unix_seconds_test() ->
    Q = first(route, #{waypoints => ?TWO, departure_time => ?WHEN}),
    ?assertEqual(?WHEN_ISO, ?F:qget(Q, <<"departureTime">>)),
    ?assertEqual(<<"disabled">>, ?F:qget(Q, <<"traffic[mode]">>)).

findsequence_traffic_segment_test_() ->
    [
        ?_test(begin
            Input0 = #{waypoints => ?THREE, optimize => true, traffic_mode => Mode},
            Input =
                case When of
                    undefined -> Input0;
                    _ -> Input0#{departure_time => When}
                end,
            Seq = first(route, Input),
            ?assertNotEqual(
                nomatch, binary:match(?F:qget(Seq, <<"mode">>), <<";traffic:", Traffic/binary>>)
            ),
            ?assertEqual(Want, ?F:qget(Seq, <<"departure">>))
        end)
     || {Mode, Traffic} <- [
            {none, <<"disabled">>}, {traffic, <<"enabled">>}, {live, <<"enabled">>}
        ],
        {When, Want} <- [{undefined, <<>>}, {?WHEN, ?WHEN_ISO_S}]
    ].

%% Enabling traffic on findsequence2 is billable so it follows the opt-in;
%% the avoids share one comma-delimited feature segment.
findsequence_mode_carries_every_avoid_in_one_feature_segment_test_() ->
    [
        ?_test(begin
            {C, P} = cfg([findseq_in_order(), ?F:resp(200, routes_body(10, 20))]),
            {ok, _} = thinwrap_location:route(C, Flags#{waypoints => ?THREE, optimize => true}),
            ?assertEqual(Expected, ?F:qget(hd(?F:calls(P)), <<"mode">>))
        end)
     || {Flags, Expected} <- [
            {#{avoid_highways => true}, <<"fastest;car;traffic:disabled;motorway:-3">>},
            {
                #{avoid_ferries => true},
                <<"fastest;car;traffic:disabled;boatFerry:-3,railFerry:-3">>
            },
            {
                #{avoid_tolls => true, avoid_highways => true, avoid_ferries => true},
                <<"fastest;car;traffic:disabled;tollroad:-3,motorway:-3,boatFerry:-3,railFerry:-3">>
            },
            {#{}, <<"fastest;car;traffic:disabled">>},
            {#{traffic_mode => live}, <<"fastest;car;traffic:enabled">>},
            {#{avoid_tolls => true}, <<"fastest;car;traffic:disabled;tollroad:-3">>},
            {
                #{avoid_tolls => true, traffic_mode => live},
                <<"fastest;car;traffic:enabled;tollroad:-3">>
            }
        ]
    ].

routing_avoid_features_test() ->
    Q = route_query(#{avoid_tolls => true, avoid_ferries => true, avoid_highways => true}),
    ?assertEqual(<<"tollRoad,ferry,controlledAccessHighway">>, ?F:qget(Q, <<"avoid[features]">>)).

%% LIVE is byte-identical to TRAFFIC on the wire.
live_alias_sends_the_same_request_as_traffic_test_() ->
    Wire = fun(Mode, When) ->
        Extra =
            case When of
                undefined -> #{};
                _ -> #{departure_time => When}
            end,
        R = first(route, Extra#{waypoints => ?TWO, traffic_mode => Mode}),
        M = first(matrix, Extra#{
            origins => [ll(1, 1)], destinations => [ll(2, 2)], traffic_mode => Mode
        }),
        {maps:with([method, url, body], R), maps:with([method, url, body], M)}
    end,
    [?_assertEqual(Wire(live, When), Wire(traffic, When)) || When <- [undefined, ?WHEN]].

%% Silently ignoring is the documented contract: fidelity is cosmetic.
routing_ignores_polyline_quality_test() ->
    Q = route_query(#{polyline_quality => detailed}),
    ?assertEqual(<<>>, ?F:qget(Q, <<"overview">>)),
    ?assertEqual(<<>>, ?F:qget(Q, <<"polylineQuality">>)).

%% HERE ships baseDuration inside the summary already requested.
routing_surfaces_base_duration_with_no_extra_request_param_test() ->
    Body = enc(#{
        routes => [
            #{
                sections => [
                    #{
                        polyline => <<"BGwl_lgDo-6-T">>,
                        summary => #{length => 5000, duration => 300, baseDuration => 280}
                    }
                ]
            }
        ]
    }),
    {C1, P1} = cfg([?F:resp(200, Body)]),
    {ok, R1} = thinwrap_location:route(C1, #{waypoints => ?TWO}),
    ?assertNot(maps:is_key(duration_without_traffic_seconds, hd(maps:get(legs, R1)))),
    ?assertNot(maps:is_key(total_duration_without_traffic_seconds, R1)),
    ?assertEqual(<<"polyline,summary">>, ?F:qget(?F:last(P1), <<"return">>)),
    {C2, P2} = cfg([?F:resp(200, Body)]),
    {ok, R2} = thinwrap_location:route(C2, #{
        waypoints => ?TWO, include => [durationWithoutTraffic]
    }),
    ?assertMatch([#{duration_without_traffic_seconds := 280.0}], maps:get(legs, R2)),
    ?assertEqual(280.0, maps:get(total_duration_without_traffic_seconds, R2)),
    ?assertEqual(<<"polyline,summary">>, ?F:qget(?F:last(P2), <<"return">>)).

%% Under-reporting a total is worse than omitting it.
routing_omits_the_total_when_only_some_sections_carry_base_duration_test() ->
    Body = enc(#{
        routes => [
            #{
                sections => [
                    #{
                        polyline => <<"BGwl_lgDo-6-T">>,
                        summary => #{length => 100, duration => 10, baseDuration => 9},
                        arrival => #{
                            place => #{
                                type => <<"place">>,
                                location => #{lat => 1, lng => 1},
                                waypoint => 0
                            }
                        }
                    },
                    #{
                        polyline => <<"BGwl_lgDo-6-T">>,
                        summary => #{length => 100, duration => 10},
                        arrival => #{
                            place => #{type => <<"place">>, location => #{lat => 2, lng => 2}}
                        }
                    }
                ]
            }
        ]
    }),
    {C, _} = cfg([?F:resp(200, Body)]),
    {ok, R} = thinwrap_location:route(C, #{
        waypoints => [ll(0, 0), ll(1, 1), ll(2, 2)], include => [durationWithoutTraffic]
    }),
    ?assertNot(maps:is_key(total_duration_without_traffic_seconds, R)),
    [L1, L2] = maps:get(legs, R),
    ?assertEqual(9.0, maps:get(duration_without_traffic_seconds, L1)),
    ?assertNot(maps:is_key(duration_without_traffic_seconds, L2)).

%% ---------------------------------------------------------------------------
%% Default lists: a passthrough REPLACES a list-valued parameter wholesale.

routing_return_is_the_constant_test() ->
    Q = route_query(#{}),
    ?assertEqual(
        iolist_to_binary(lists:join(<<",">>, thinwrap_location_defaults:here_routing_return())),
        ?F:qget(Q, <<"return">>)
    ).

routing_append_via_constant_test() ->
    Ret = iolist_to_binary(
        lists:join(
            <<",">>, thinwrap_location_defaults:here_routing_return() ++ [<<"turnByTurnActions">>]
        )
    ),
    {C, P} = cfg([?F:resp(200, routes_body(5000, 300))]),
    {ok, R} = thinwrap_location:route(C, #{
        waypoints => ?TWO, passthrough => #{query => #{<<"return">> => Ret}}
    }),
    ?assertEqual([Ret], ?F:qall(?F:last(P), <<"return">>)),
    ?assertEqual(5000.0, maps:get(total_distance_meters, R)).

routing_caller_return_replaces_the_default_test() ->
    Q = route_query(#{passthrough => #{query => #{return => <<"summary">>}}}),
    ?assertEqual([<<"summary">>], ?F:qall(Q, <<"return">>)).

%% ---------------------------------------------------------------------------
%% Matrix (async)

matrix_async_cycle_test() ->
    %% Real HERE v8 async flow: poll completes with a 303 (Location + body),
    %% retrieve resultUrl 303-redirects to a pre-signed S3 URL, and the final
    %% body is gzip-compressed.
    Poll = ?F:resp(
        303,
        enc(#{matrixId => <<"mid">>, status => <<"completed">>, resultUrl => ?RESULT_URL}),
        #{<<"Location">> => ?RESULT_URL}
    ),
    Redirect = ?F:resp(303, <<>>, #{<<"Location">> => ?S3_URL}),
    Body = ?F:gzip_resp(
        200,
        <<"{\"matrixId\":\"mid\",\"matrix\":{\"numOrigins\":2,\"numDestinations\":2,\"travelTimes\":[0,60,60,0],\"distances\":[0,1000,1000,0]}}">>
    ),
    {C, P} = cfg([submit_ok(), Poll, Redirect, Body]),
    {ok, #{cells := Cells}} = thinwrap_location:matrix(C, #{
        origins => [ll(1, 1), ll(2, 2)], destinations => [ll(3, 3), ll(4, 4)]
    }),
    ?assertEqual(4, length(Cells)),
    ?assertMatch(
        #{
            origin_index := 0,
            destination_index := 1,
            distance_meters := 1000.0,
            duration_seconds := 60.0
        },
        lists:nth(2, Cells)
    ),
    [Submit, Status, ResultCall, S3Call] = ?F:calls(P),
    ?assertEqual(post, maps:get(method, Submit)),
    ?assertEqual(<<"true">>, ?F:qget(Submit, <<"async">>)),
    ?assertEqual(<<"k">>, ?F:qget(Submit, <<"apiKey">>)),
    ?assertEqual(<<"k">>, ?F:qget(Status, <<"apiKey">>)),
    %% The resultUrl hop (HERE host) carries the apiKey + Accept-Encoding: gzip.
    ?assertEqual(<<"k">>, ?F:qget(ResultCall, <<"apiKey">>)),
    ?assertEqual(<<"gzip">>, ?F:header(ResultCall, <<"Accept-Encoding">>)),
    %% The S3 hop must NOT leak the HERE apiKey — neither query nor header.
    S3Url = maps:get(url, S3Call),
    ?assertMatch(<<"https://s3.eu-west-1.amazonaws.com/", _/binary>>, S3Url),
    ?assertEqual(nomatch, binary:match(string:lowercase(S3Url), <<"apikey">>)),
    ?assertEqual(
        [],
        [
            K
         || K := _ <- maps:get(headers, S3Call),
            binary:match(string:lowercase(K), [<<"key">>, <<"auth">>]) =/= nomatch
        ]
    ),
    ?assertEqual(<<"gzip">>, ?F:header(S3Call, <<"Accept-Encoding">>)).

matrix_submit_body_test() ->
    B = matrix_body(#{avoid_tolls => true}),
    ?assertEqual([#{<<"lat">> => 1, <<"lng">> => 1}], maps:get(<<"origins">>, B)),
    ?assertEqual(#{<<"type">> => <<"autoCircle">>}, maps:get(<<"regionDefinition">>, B)),
    ?assertEqual(#{<<"features">> => [<<"tollRoad">>]}, maps:get(<<"avoid">>, B)),
    %% car is HERE's default and is not sent.
    ?assertNot(maps:is_key(<<"transportMode">>, B)).

%% Some responses return the 200 body directly without the S3 hop, and a 200
%% poll body with status "completed" is honoured too (belt-and-braces).
matrix_retrieve_direct_plain_body_test() ->
    Retrieve = ?F:resp(
        200,
        <<"{\"matrixId\":\"mid\",\"matrix\":{\"numOrigins\":1,\"numDestinations\":1,\"travelTimes\":[5427],\"distances\":[109144]}}">>
    ),
    {C, P} = cfg([submit_ok(), poll_completed(), Retrieve]),
    {ok, #{cells := [Cell]}} = thinwrap_location:matrix(C, #{
        origins => [ll(40.7484, -73.9857)], destinations => [ll(41.1792, -73.1952)]
    }),
    ?assertMatch(#{distance_meters := 109144.0, duration_seconds := 5427.0}, Cell),
    ?assertEqual(3, length(?F:calls(P))).

%% Matrix v8 accepts the same eight transport modes as Routing v8 — verified
%% live for bus and privateBus, both HTTP 200.
matrix_transport_mode_test_() ->
    [
        ?_assertEqual(
            Want, maps:get(<<"transportMode">>, matrix_body(#{transport_mode => Mode}))
        )
     || {Mode, Want} <- [{taxi, <<"taxi">>}, {bus, <<"bus">>}, {privateBus, <<"privateBus">>}]
    ].

matrix_travel_mode_test() ->
    ?assertEqual(
        <<"pedestrian">>, maps:get(<<"transportMode">>, matrix_body(#{travel_mode => walking}))
    ).

matrix_rejects_foreign_host_test_() ->
    [
        ?_test(begin
            {C, P} = cfg([?F:resp(200, enc(#{matrixId => <<"mid">>, statusUrl => Url}))]),
            ?assertMatch(
                {error, #{code := invalid_request, cause := #{<<"url">> := Url}}},
                thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]})
            ),
            %% The key never reached the foreign host.
            ?assertEqual(1, length(?F:calls(P)))
        end)
     || Url <- [
            <<"https://evil.example.com/steal">>,
            <<"http://matrix.router.hereapi.com/v8/matrix/mid/status">>,
            <<"https://hereapi.com.evil.example/x">>,
            <<"not a url">>
        ]
    ].

matrix_rejects_foreign_result_url_test() ->
    Poll = ?F:resp(
        200, enc(#{status => <<"completed">>, resultUrl => <<"https://evil.example/r">>})
    ),
    {C, P} = cfg([submit_ok(), Poll]),
    ?assertMatch(
        {error, #{code := invalid_request}},
        thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]})
    ),
    ?assertEqual(2, length(?F:calls(P))).

matrix_polling_timeout_test() ->
    Pending = ?F:resp(200, <<"{\"status\":\"inProgress\"}">>),
    {C0, _} = cfg([submit_ok(), Pending]),
    %% Real sleep with a 1 ms deadline.
    C = C0#{sleep => fun timer:sleep/1},
    {error, E} = thinwrap_location:matrix(C, #{
        origins => [ll(1, 1)],
        destinations => [ll(2, 2)],
        passthrough => #{body => #{timeoutMs => 1}}
    }),
    ?assertMatch(
        #{
            code := matrix_polling_timeout,
            provider_message := <<"matrixId: mid">>,
            cause := #{<<"matrixId">> := <<"mid">>, <<"statusUrl">> := ?STATUS_URL}
        },
        E
    ).

matrix_poll_backoff_is_1s_x1_5_capped_at_5s_test() ->
    Self = self(),
    Pending = ?F:resp(200, <<"{\"status\":\"inProgress\"}">>),
    {C0, P} = cfg(
        [submit_ok()] ++ lists:duplicate(6, Pending) ++ [poll_completed(), retrieve_1x1()]
    ),
    C = C0#{sleep => fun(Ms) -> Self ! {slept, Ms} end},
    {ok, _} = thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]}),
    ?assertEqual([1000, 1500, 2250, 3375, 5000, 5000, 5000], collect_sleeps()),
    ?assertEqual(9, length(?F:calls(P))).

collect_sleeps() ->
    receive
        {slept, Ms} -> [Ms | collect_sleeps()]
    after 0 -> []
    end.

matrix_timeout_ms_is_stripped_from_the_wire_test() ->
    B = matrix_body(#{passthrough => #{body => #{timeoutMs => 5000, <<"keep">> => 1}}}),
    ?assertNot(maps:is_key(<<"timeoutMs">>, B)),
    ?assertEqual(1, maps:get(<<"keep">>, B)).

matrix_timeout_ms_rejects_anything_but_a_positive_number_test_() ->
    [
        ?_test(
            expect_ce(
                matrix,
                #{
                    origins => [ll(1, 1), ll(1, 2)],
                    destinations => [ll(2, 1), ll(2, 2)],
                    passthrough => #{body => #{<<"timeoutMs">> => Bad}}
                },
                invalid_request
            )
        )
     || Bad <- [<<"5000">>, 0, -1, true, null, [1]]
    ].

matrix_job_failed_is_provider_unavailable_test() ->
    {C, _} = cfg([submit_ok(), ?F:resp(200, <<"{\"status\":\"failed\"}">>)]),
    ?assertMatch(
        {error, #{
            code := provider_unavailable,
            status := 200,
            provider_message := <<"HERE Matrix job failed">>
        }},
        thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]})
    ).

matrix_submit_missing_status_url_is_unknown_test() ->
    {C, _} = cfg([?F:resp(200, <<"{\"matrixId\":\"mid\"}">>)]),
    ?assertMatch(
        {error, #{code := unknown}},
        thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]})
    ).

matrix_poll_without_result_url_is_unknown_test() ->
    {C, _} = cfg([submit_ok(), ?F:resp(303, <<>>)]),
    ?assertMatch(
        {error, #{code := unknown, status := 303}},
        thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]})
    ).

matrix_retrieve_redirect_guards_test_() ->
    [
        ?_test(begin
            {C, P} = cfg([submit_ok(), poll_completed(), Redirect]),
            ?assertMatch(
                {error, #{code := unknown, status := 303}},
                thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]})
            ),
            ?assertEqual(3, length(?F:calls(P)))
        end)
     || Redirect <- [
            ?F:resp(303, <<>>),
            ?F:resp(303, <<>>, #{<<"Location">> => <<"http://s3.example.com/x">>})
        ]
    ].

matrix_submit_http_error_is_mapped_test() ->
    {C, _} = cfg([?F:resp(401, <<"{\"error\":\"Unauthorized\",\"error_description\":\"bad\"}">>)]),
    ?assertMatch(
        {error, #{code := auth_failed, status := 401, provider_message := <<"Unauthorized">>}},
        thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]})
    ).

matrix_null_value_is_a_failed_cell_not_zero_test() ->
    Body = ?F:resp(
        200,
        <<"{\"matrix\":{\"numOrigins\":1,\"numDestinations\":2,\"travelTimes\":[60,null],\"distances\":[1000,500]}}">>
    ),
    {C, _} = cfg([submit_ok(), poll_completed(), Body]),
    {ok, #{cells := Cells}} = thinwrap_location:matrix(C, #{
        origins => [ll(1, 1)], destinations => [ll(3, 3), ll(4, 4)]
    }),
    ?assertEqual([{0, 60.0}], [{D, T} || #{destination_index := D, duration_seconds := T} <- Cells]).

matrix_error_codes_mark_failed_cells_test() ->
    Body = ?F:resp(
        200,
        <<"{\"matrix\":{\"numOrigins\":1,\"numDestinations\":3,\"travelTimes\":[1,2,3],\"distances\":[1,2,3],\"errorCodes\":[0,3,4]}}">>
    ),
    {C, _} = cfg([submit_ok(), poll_completed(), Body]),
    {ok, #{cells := Cells}} = thinwrap_location:matrix(C, #{
        origins => [ll(1, 1)], destinations => [ll(3, 3), ll(4, 4), ll(5, 5)]
    }),
    ?assertEqual([0, 1], [D || #{destination_index := D} <- Cells]).

matrix_short_or_missing_arrays_are_unknown_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([submit_ok(), poll_completed(), ?F:resp(200, Body)]),
            ?assertMatch(
                {error, #{code := unknown}},
                thinwrap_location:matrix(C, #{
                    origins => [ll(1, 1)], destinations => [ll(3, 3), ll(4, 4)]
                })
            )
        end)
     || Body <- [
            <<"{\"matrix\":{\"travelTimes\":[1],\"distances\":[1]}}">>,
            <<"{\"matrix\":{\"travelTimes\":[1,2]}}">>,
            <<"{\"nomatrix\":true}">>,
            <<>>
        ]
    ].

matrix_attributes_are_the_constant_test() ->
    ?assertEqual(
        thinwrap_location_defaults:here_matrix_attributes(),
        maps:get(<<"matrixAttributes">>, matrix_body(#{}))
    ).

matrix_caller_attributes_replace_the_default_test() ->
    Retrieve = ?F:resp(
        200,
        <<"{\"matrixId\":\"mid\",\"matrix\":{\"numOrigins\":2,\"numDestinations\":2,\"travelTimes\":[0,60,60,0]}}">>
    ),
    {C, P} = cfg([submit_ok(), poll_completed(), Retrieve]),
    %% Replaced, and the decoder needs distances too: an error, never
    %% zero-distance cells.
    ?assertMatch(
        {error, #{code := unknown}},
        thinwrap_location:matrix(C, #{
            origins => [ll(1, 1), ll(2, 2)],
            destinations => [ll(3, 3), ll(4, 4)],
            passthrough => #{body => #{matrixAttributes => [<<"travelTimes">>]}}
        })
    ),
    ?assertEqual(
        [<<"travelTimes">>], maps:get(<<"matrixAttributes">>, ?F:body_json(hd(?F:calls(P))))
    ).

%% Matrix traffic: the same switches as routing, in body form.
matrix_default_sends_departure_time_any_without_traffic_test() ->
    B = matrix_body(#{}),
    ?assertEqual(<<"any">>, maps:get(<<"departureTime">>, B)),
    ?assertNot(maps:is_key(<<"traffic">>, B)).

matrix_none_with_departure_time_keeps_the_time_and_disables_traffic_test() ->
    B = matrix_body(#{traffic_mode => none, departure_time => ?DEPART}),
    ?assertEqual(?DEPART_ISO, maps:get(<<"departureTime">>, B)),
    ?assertEqual(#{<<"mode">> => <<"disabled">>}, maps:get(<<"traffic">>, B)).

matrix_live_sends_neither_switch_test() ->
    B = matrix_body(#{traffic_mode => live}),
    ?assertNot(maps:is_key(<<"departureTime">>, B)),
    ?assertNot(maps:is_key(<<"traffic">>, B)).

matrix_live_with_departure_time_sends_only_the_time_test() ->
    B = matrix_body(#{traffic_mode => traffic, departure_time => ?DEPART}),
    ?assertEqual(?DEPART_ISO, maps:get(<<"departureTime">>, B)),
    ?assertNot(maps:is_key(<<"traffic">>, B)).

matrix_passthrough_overrides_the_traffic_default_test() ->
    B = matrix_body(#{
        departure_time => ?DEPART,
        passthrough => #{body => #{traffic => #{mode => <<"default">>}}}
    }),
    ?assertEqual(#{<<"mode">> => <<"default">>}, maps:get(<<"traffic">>, B)),
    ?assertEqual(?DEPART_ISO, maps:get(<<"departureTime">>, B)).

matrix_passthrough_arrival_time_disables_traffic_instead_of_any_test() ->
    B = matrix_body(#{passthrough => #{body => #{<<"arrivalTime">> => ?DEPART_ISO}}}),
    ?assertNot(maps:is_key(<<"departureTime">>, B)),
    ?assertEqual(?DEPART_ISO, maps:get(<<"arrivalTime">>, B)),
    ?assertEqual(#{<<"mode">> => <<"disabled">>}, maps:get(<<"traffic">>, B)).

matrix_passthrough_departure_time_disables_traffic_test() ->
    B = matrix_body(#{passthrough => #{body => #{departureTime => ?DEPART_ISO}}}),
    ?assertEqual(?DEPART_ISO, maps:get(<<"departureTime">>, B)),
    ?assertEqual(#{<<"mode">> => <<"disabled">>}, maps:get(<<"traffic">>, B)).

matrix_passthrough_departure_time_any_keeps_the_default_test() ->
    B = matrix_body(#{passthrough => #{body => #{<<"departureTime">> => <<"any">>}}}),
    ?assertEqual(<<"any">>, maps:get(<<"departureTime">>, B)),
    ?assertNot(maps:is_key(<<"traffic">>, B)).

matrix_api_key_fun_is_resolved_on_every_hop_test() ->
    {C0, P} = cfg([submit_ok(), poll_completed(), retrieve_1x1()]),
    C = C0#{api_key => fun() -> <<"fun-key">> end},
    {ok, _} = thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]}),
    ?assertEqual(
        [<<"fun-key">>, <<"fun-key">>, <<"fun-key">>],
        [?F:qget(R, <<"apiKey">>) || R <- ?F:calls(P)]
    ).

%% ---------------------------------------------------------------------------
%% Geocoding

geocode_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"items\":[{\"title\":\"New York\",\"position\":{\"lat\":40.7,\"lng\":-74.0},\"id\":\"here:123\",\"mapView\":{\"south\":40.4,\"west\":-74.3,\"north\":40.9,\"east\":-73.7}}]}">>
        )
    ]),
    {ok, #{candidates := [Cand]}} = thinwrap_location:geocode(C, #{
        address => <<"NYC">>, country_filter => [<<"US">>], language => <<"en">>
    }),
    ?assertMatch(
        #{
            formatted_address := <<"New York">>,
            place_id := <<"here:123">>,
            location := #{lat := 40.7, lng := -74.0},
            viewport := #{southwest := #{lat := 40.4, lng := -74.3}, northeast := #{lat := 40.9}}
        },
        Cand
    ),
    Last = ?F:last(P),
    ?assertEqual(<<"/v1/geocode">>, ?F:path_of(Last)),
    ?assertEqual(<<"countryCode:USA">>, ?F:qget(Last, <<"in">>)),
    ?assertEqual(<<"en">>, ?F:qget(Last, <<"lang">>)),
    ?assertEqual(<<"NYC">>, ?F:qget(Last, <<"q">>)).

geocode_lowercase_country_is_mapped_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"items\":[]}">>)]),
    {ok, _} = thinwrap_location:geocode(C, #{
        address => <<"x">>, country_filter => [<<"gb">>, <<"de">>]
    }),
    ?assertEqual(<<"countryCode:GBR,DEU">>, ?F:qget(?F:last(P), <<"in">>)).

geocode_unmapped_country_test() ->
    expect_ce(geocode, #{address => <<"x">>, country_filter => [<<"ZZ">>]}, invalid_request).

-define(ESB_ITEM, #{
    title => <<"Empire State Building">>,
    id => <<"here:pds:place:840dr5ru-esb">>,
    resultType => <<"place">>,
    address => #{
        label => <<"Empire State Building, 20 W 34th St, New York, NY 10118, United States">>
    },
    position => #{lat => 40.74844, lng => -73.98566}
}).

geocode_formatted_address_is_the_address_label_not_the_title_test() ->
    {C, _} = cfg([?F:resp(200, enc(#{items => [?ESB_ITEM]}))]),
    {ok, #{candidates := [Cand]}} = thinwrap_location:geocode(C, #{
        address => <<"Empire State Building, New York">>
    }),
    ?assertEqual(
        <<"Empire State Building, 20 W 34th St, New York, NY 10118, United States">>,
        maps:get(formatted_address, Cand)
    ),
    ?assertNot(maps:is_key(viewport, Cand)).

reverse_geocode_formatted_address_is_the_address_label_test() ->
    {C, P} = cfg([?F:resp(200, enc(#{items => [maps:put(title, <<"20 W 34th St">>, ?ESB_ITEM)]}))]),
    {ok, #{candidates := [Cand]}} = thinwrap_location:reverse_geocode(C, #{
        location => ll(40.74844, -73.98566), language => <<"de">>
    }),
    ?assertMatch(
        <<"Empire State Building, 20 W 34th St", _/binary>>, maps:get(formatted_address, Cand)
    ),
    Last = ?F:last(P),
    ?assertEqual(<<"/v1/revgeocode">>, ?F:path_of(Last)),
    ?assertEqual(<<"40.74844,-73.98566">>, ?F:qget(Last, <<"at">>)),
    ?assertEqual(<<"de">>, ?F:qget(Last, <<"lang">>)).

geocode_falls_back_to_the_title_without_a_label_test() ->
    {C, _} = cfg([
        ?F:resp(
            200, enc(#{items => [#{title => <<"Somewhere">>, position => #{lat => 1, lng => 2}}]})
        )
    ]),
    {ok, #{candidates := [Cand]}} = thinwrap_location:geocode(C, #{address => <<"x">>}),
    ?assertEqual(<<"Somewhere">>, maps:get(formatted_address, Cand)),
    ?assertNot(maps:is_key(place_id, Cand)).

geocode_skips_items_without_position_test() ->
    {C, _} = cfg([
        ?F:resp(
            200,
            <<"{\"items\":[{\"title\":\"no position\",\"id\":\"a\"},{\"title\":\"good\",\"id\":\"b\",\"position\":{\"lat\":1.5,\"lng\":2.5}}]}">>
        )
    ]),
    {ok, #{candidates := Cands}} = thinwrap_location:geocode(C, #{address => <<"x">>}),
    ?assertMatch([#{place_id := <<"b">>, location := #{lat := 1.5, lng := 2.5}}], Cands).

geocode_partial_viewport_is_omitted_test() ->
    {C, _} = cfg([
        ?F:resp(
            200,
            <<"{\"items\":[{\"address\":{\"label\":\"a\"},\"position\":{\"lat\":1,\"lng\":2},\"mapView\":{\"south\":1,\"west\":2,\"north\":3}}]}">>
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
    {C, _} = cfg([?F:resp(200, <<"{\"items\":[]}">>)]),
    ?assertMatch({ok, #{candidates := []}}, thinwrap_location:geocode(C, #{address => <<"x">>})).

geocode_http_error_is_mapped_test() ->
    {C, _} = cfg([?F:resp(403, <<"{\"error\":\"Forbidden\",\"error_description\":\"no\"}">>)]),
    ?assertMatch(
        {error, #{code := auth_failed, status := 403}},
        thinwrap_location:geocode(C, #{address => <<"x">>})
    ).

%% ---------------------------------------------------------------------------
%% Autocomplete (Autosuggest)

autocomplete_test() ->
    {C, P} = cfg([
        ?F:resp(200, <<"{\"items\":[{\"title\":\"New York, NY\",\"id\":\"here:abc\"}]}">>)
    ]),
    %% Autosuggest mandates a search context; incidental to what this asserts.
    {ok, #{predictions := [Pred]}} = thinwrap_location:autocomplete(C, #{
        input => <<"New">>, location => ll(40.7128, -74.006)
    }),
    ?assertMatch(#{description := <<"New York, NY">>, place_id := <<"here:abc">>}, Pred),
    Last = ?F:last(P),
    ?assertEqual(<<"/v1/autosuggest">>, ?F:path_of(Last)),
    ?assertEqual(<<"10">>, ?F:qget(Last, <<"limit">>)),
    ?assertEqual(<<"40.7128,-74.006">>, ?F:qget(Last, <<"at">>)).

autocomplete_radius_is_a_circle_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"items\":[]}">>)]),
    {ok, _} = thinwrap_location:autocomplete(C, #{
        input => <<"x">>, location => ll(1.5, 2), radius => 500
    }),
    ?assertEqual([<<"circle:1.5,2;r=500">>], ?F:qall(?F:last(P), <<"in">>)),
    ?assertEqual(<<>>, ?F:qget(?F:last(P), <<"at">>)).

%% HERE's query-type suggestions have a title but no address at all.
autocomplete_emits_main_text_only_when_the_item_has_no_address_test() ->
    {C, _} = cfg([?F:resp(200, <<"{\"items\":[{\"title\":\"pizza\",\"id\":\"here:q:1\"}]}">>)]),
    {ok, #{predictions := [Pred]}} = thinwrap_location:autocomplete(C, #{
        input => <<"pizza">>, location => ll(52.52, 13.405)
    }),
    ?assertEqual(#{main_text => <<"pizza">>}, maps:get(structured_format, Pred)).

autocomplete_structured_format_with_address_test() ->
    {C, _} = cfg([
        ?F:resp(
            200,
            <<"{\"items\":[{\"title\":\"Cafe\",\"address\":{\"label\":\"Cafe, Main St\"}},{\"id\":\"x\"}]}">>
        )
    ]),
    {ok, #{predictions := [P1, P2]}} = thinwrap_location:autocomplete(C, #{
        input => <<"c">>, location => ll(1, 1)
    }),
    ?assertEqual(
        #{main_text => <<"Cafe">>, secondary_text => <<"Cafe, Main St">>},
        maps:get(structured_format, P1)
    ),
    ?assertEqual(#{description => <<>>, place_id => <<"x">>}, P2).

autocomplete_translates_country_filter_to_alpha3_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"items\":[]}">>)]),
    {ok, _} = thinwrap_location:autocomplete(C, #{
        input => <<"Tel">>, location => ll(32.08, 34.78), country_filter => [<<"IL">>, <<"PS">>]
    }),
    ?assertEqual(<<"countryCode:ISR,PSE">>, ?F:qget(?F:last(P), <<"in">>)),
    %% The spatial context must survive alongside the country filter.
    ?assertNotEqual(<<>>, ?F:qget(?F:last(P), <<"at">>)).

%% HERE requires the country filter to accompany the spatial filter and
%% spells both `in`, so the pair survives as a repeated key.
autocomplete_emits_both_in_values_when_country_filter_meets_radius_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"items\":[]}">>)]),
    {ok, _} = thinwrap_location:autocomplete(C, #{
        input => <<"Tel">>,
        location => ll(32.08, 34.78),
        radius => 5000,
        country_filter => [<<"IL">>]
    }),
    Values = ?F:qall(?F:last(P), <<"in">>),
    ?assertEqual(2, length(Values)),
    ?assert(lists:any(fun(V) -> binary:match(V, <<"circle:">>) =:= {0, 7} end, Values)),
    ?assert(lists:member(<<"countryCode:ISR">>, Values)).

autocomplete_unmapped_country_code_fails_before_any_request_test() ->
    expect_ce(
        autocomplete,
        #{input => <<"Tel">>, location => ll(32.08, 34.78), country_filter => [<<"ZZ">>]},
        invalid_request
    ).

%% HERE documents exactly one of at / in=circle / in=bbox as mandatory on
%% Autosuggest; without one it only earns a vendor 400.
autocomplete_requires_a_search_context_test() ->
    E = expect_ce(autocomplete, #{input => <<"Tel">>}, invalid_request),
    ?assertNotEqual(nomatch, binary:match(maps:get(message, E), <<"search context">>)).

autocomplete_accepts_a_passthrough_supplied_search_context_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"items\":[]}">>)]),
    {ok, _} = thinwrap_location:autocomplete(C, #{
        input => <<"Tel">>, passthrough => #{query => #{in => <<"bbox:34.0,31.0,35.0,33.0">>}}
    }),
    ?assertMatch(<<"bbox:", _/binary>>, ?F:qget(?F:last(P), <<"in">>)).

%% An all-blank filter reads as "no filter" rather than `countryCode:`.
autocomplete_country_code_filter_skips_blank_entries_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"items\":[]}">>)]),
    {ok, _} = thinwrap_location:autocomplete(C, #{
        input => <<"Tel">>, location => ll(32.08, 34.78), country_filter => [<<" ">>, <<>>]
    }),
    ?assertEqual(<<>>, ?F:qget(?F:last(P), <<"in">>)),
    ?assertNotEqual(<<>>, ?F:qget(?F:last(P), <<"at">>)).

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
%% Place details (Lookup)

-define(PLACE_BODY,
    <<"{\"title\":\"Brandenburger Tor\",\"id\":\"here:pds:place:1\",\"address\":{\"label\":\"Pariser Platz, Berlin\"},\"position\":{\"lat\":52.5163,\"lng\":13.3777}}">>
).

place_details_gets_lookup_by_id_test() ->
    {C, P} = cfg([?F:resp(200, ?PLACE_BODY)]),
    {ok, R} = thinwrap_location:place_details(C, #{place_id => <<"here:pds:place:1">>}),
    Last = ?F:last(P),
    ?assertMatch(<<"https://lookup.search.hereapi.com/v1/lookup?", _/binary>>, maps:get(url, Last)),
    ?assertEqual(<<"here:pds:place:1">>, ?F:qget(Last, <<"id">>)),
    ?assertMatch(
        #{
            location := #{lat := 52.5163},
            formatted_address := <<"Pariser Platz, Berlin">>,
            place_id := <<"here:pds:place:1">>
        },
        maps:get(candidate, R)
    ),
    ?assertNot(maps:is_key(name, R)).

place_details_surfaces_name_when_included_test() ->
    {C, _} = cfg([?F:resp(200, ?PLACE_BODY)]),
    {ok, R} = thinwrap_location:place_details(C, #{place_id => <<"x">>, include => [name]}),
    ?assertEqual(<<"Brandenburger Tor">>, maps:get(name, R)).

place_details_address_is_the_label_and_name_is_the_title_test() ->
    {C, _} = cfg([?F:resp(200, enc(?ESB_ITEM))]),
    {ok, R} = thinwrap_location:place_details(C, #{
        place_id => <<"here:pds:place:840dr5ru-esb">>, include => [name]
    }),
    ?assertEqual(
        <<"Empire State Building, 20 W 34th St, New York, NY 10118, United States">>,
        maps:get(formatted_address, maps:get(candidate, R))
    ),
    ?assertEqual(<<"Empire State Building">>, maps:get(name, R)).

%% An id that resolves to nothing is an answer, like geocoding's zero results.
place_details_unusable_result_returns_no_candidate_test() ->
    Body = <<"{\"title\":\"x\",\"id\":\"h\"}">>,
    {C, _} = cfg([?F:resp(200, Body)]),
    {ok, R} = thinwrap_location:place_details(C, #{place_id => <<"x">>, include => [name]}),
    ?assertEqual(#{raw => json:decode(Body)}, R).

place_details_vendor_404_returns_no_candidate_test() ->
    Body = <<"{\"status\":404,\"title\":\"Unknown Location ID\"}">>,
    {C, _} = cfg([?F:resp(404, Body)]),
    ?assertEqual(
        {ok, #{raw => json:decode(Body)}},
        thinwrap_location:place_details(C, #{place_id => <<"x">>})
    ).

place_details_unparseable_2xx_body_is_unknown_test() ->
    {C, _} = cfg([?F:resp(200, <<"<html>oops</html>">>)]),
    ?assertMatch(
        {error, #{code := unknown}}, thinwrap_location:place_details(C, #{place_id => <<"x">>})
    ).

%% Live: HERE answers a malformed id with 400 — it stays an error.
place_details_vendor_400_for_the_id_stays_invalid_request_test() ->
    {C, _} = cfg([
        ?F:resp(400, <<"{\"status\":400,\"title\":\"Illegal input for parameter 'id'\"}">>)
    ]),
    ?assertMatch(
        {error, #{code := invalid_request}},
        thinwrap_location:place_details(C, #{place_id => <<"x">>})
    ).

%% ---------------------------------------------------------------------------
%% Isochrone

isochrone_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            enc(#{
                isolines => [
                    #{range => #{type => <<"time">>, value => 600}, polygons => [#{outer => ?FLEX}]}
                ]
            })
        )
    ]),
    {ok, #{contours := [Contour]}} = thinwrap_location:isochrone(C, #{
        center => ll(50.1, 8.6), type => time, values => [600]
    }),
    ?assertEqual(600.0, maps:get(value, Contour)),
    #{type := <<"Polygon">>, coordinates := [Ring]} = maps:get(geometry, Contour),
    %% Closed ring.
    ?assert(length(Ring) >= 5),
    ?assertEqual(hd(Ring), lists:last(Ring)),
    Last = ?F:last(P),
    ?assertEqual(<<"600">>, ?F:qget(Last, <<"range[values]">>)),
    ?assertEqual(<<"time">>, ?F:qget(Last, <<"range[type]">>)),
    ?assertEqual(<<"car">>, ?F:qget(Last, <<"transportMode">>)),
    ?assertEqual(<<"50.1,8.6">>, ?F:qget(Last, <<"origin">>)),
    ?assertNot(
        maps:is_key(
            meta,
            element(
                2,
                thinwrap_location:isochrone(C, #{
                    center => ll(50.1, 8.6), type => time, values => [600]
                })
            )
        )
    ).

isochrone_contours_are_sorted_by_value_test() ->
    Iso = fun(V) -> #{range => #{value => V}, polygons => [#{outer => ?FLEX}]} end,
    {C, P} = cfg([?F:resp(200, enc(#{isolines => [Iso(900), Iso(300)]}))]),
    {ok, #{contours := Contours}} = thinwrap_location:isochrone(C, #{
        center => ll(1, 1), type => distance, values => [900, 300], travel_mode => walking
    }),
    ?assertEqual([300.0, 900.0], [V || #{value := V} <- Contours]),
    ?assertEqual(<<"900,300">>, ?F:qget(?F:last(P), <<"range[values]">>)),
    ?assertEqual(<<"distance">>, ?F:qget(?F:last(P), <<"range[type]">>)),
    ?assertEqual(<<"pedestrian">>, ?F:qget(?F:last(P), <<"transportMode">>)).

isochrone_rejects_cycling_test() ->
    expect_ce(
        isochrone,
        #{center => ll(1, 1), type => time, values => [600], travel_mode => cycling},
        unsupported_travel_mode
    ).

isochrone_without_a_usable_polygon_is_unknown_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(200, Body)]),
            ?assertMatch(
                {error, #{code := unknown}},
                thinwrap_location:isochrone(C, #{
                    center => ll(52.5, 13.4), type => time, values => [600]
                })
            )
        end)
     || Body <- [
            <<>>,
            <<"{\"isolines\":[]}">>,
            <<"{\"isolines\":[{\"range\":{\"value\":600},\"polygons\":[]}]}">>,
            <<"{\"isolines\":[{\"range\":{},\"polygons\":[{\"outer\":\"BFoz5xJ67i1B1B7PzIhaxL7Y\"}]}]}">>
        ]
    ].

isochrone_departure_time_is_validated_test_() ->
    [
        ?_test(
            expect_ce(
                isochrone,
                #{center => ll(52.5, 13.4), type => time, values => [600], departure_time => V},
                invalid_request
            )
        )
     || V <- [<<"noon">>, <<"tomorrow">>, <<"2026-13-01T00:00">>]
    ].

isochrone_departure_datetime_is_sent_as_utc_iso_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"isolines\":[{\"range\":{\"value\":600},\"polygons\":[{\"outer\":\"BFoz5xJ67i1B1B7PzIhaxL7Y\"}]}]}">>
        )
    ]),
    {ok, _} = thinwrap_location:isochrone(C, #{
        center => ll(52.5, 13.4),
        type => time,
        values => [600],
        departure_time => {{2026, 9, 1}, {8, 0, 0}}
    }),
    ?assertEqual(<<"2026-09-01T08:00:00Z">>, ?F:qget(?F:last(P), <<"departureTime">>)).

isochrone_departure_binary_is_sent_verbatim_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"isolines\":[{\"range\":{\"value\":600},\"polygons\":[{\"outer\":\"BFoz5xJ67i1B1B7PzIhaxL7Y\"}]}]}">>
        )
    ]),
    {ok, _} = thinwrap_location:isochrone(C, #{
        center => ll(52.5, 13.4),
        type => time,
        values => [600],
        departure_time => <<"2026-09-01T10:00:00+02:00">>
    }),
    ?assertEqual(<<"2026-09-01T10:00:00+02:00">>, ?F:qget(?F:last(P), <<"departureTime">>)).

bad_isochrone_breaks_are_invalid_request_test_() ->
    [
        ?_test(
            expect_ce(
                isochrone, #{center => ll(1, 1), type => time, values => Values}, invalid_request
            )
        )
     || Values <- [[], [0], [1, 2, 3, 4, 5]]
    ].

%% Isochrone geometry: every part and hole kept, RFC 7946 winding.

-define(FLEX_CHARS, <<"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_">>).

flex_unsigned(V) when V > 16#1F ->
    <<(binary:at(?FLEX_CHARS, (V band 16#1F) bor 16#20)), (flex_unsigned(V bsr 5))/binary>>;
flex_unsigned(V) ->
    <<(binary:at(?FLEX_CHARS, V))>>.

flex_signed(D) when D < 0 -> flex_unsigned(bnot (D bsl 1));
flex_signed(D) -> flex_unsigned(D bsl 1).

%% Encode [lng, lat] points as a precision-5, 2D HERE flexible polyline.
flex(Ring) ->
    {Out, _, _} = lists:foldl(
        fun([Lng, Lat], {Acc, LastLat, LastLng}) ->
            ILat = round(Lat * 100000),
            ILng = round(Lng * 100000),
            {
                <<Acc/binary, (flex_signed(ILat - LastLat))/binary,
                    (flex_signed(ILng - LastLng))/binary>>,
                ILat,
                ILng
            }
        end,
        {<<(flex_unsigned(1))/binary, (flex_unsigned(5))/binary>>, 0, 0},
        Ring
    ),
    Out.

square(X0, Y0, X1, Y1, true) -> [[X0, Y0], [X1, Y0], [X1, Y1], [X0, Y1]];
square(X0, Y0, X1, Y1, false) -> lists:reverse(square(X0, Y0, X1, Y1, true)).

area(Ring) -> thinwrap_location_isochrone:signed_area(Ring).

assert_rfc7946([Ext | Holes]) ->
    [?assertEqual(hd(R), lists:last(R)) || R <- [Ext | Holes]],
    ?assert(area(Ext) > 0),
    [?assert(area(H) < 0) || H <- Holes],
    ok.

bbox(Ring) ->
    Xs = [X || [X, _] <- Ring],
    Ys = [Y || [_, Y] <- Ring],
    {lists:min(Xs), lists:min(Ys), lists:max(Xs), lists:max(Ys)}.

within(Inner, Outer) ->
    {Ix0, Iy0, Ix1, Iy1} = bbox(Inner),
    {Ox0, Oy0, Ox1, Oy1} = bbox(Outer),
    Ox0 =< Ix0 andalso Oy0 =< Iy0 andalso Ix1 =< Ox1 andalso Iy1 =< Oy1.

here_geometry(Polygons) ->
    {C, _} = cfg([
        ?F:resp(200, enc(#{isolines => [#{range => #{value => 600}, polygons => Polygons}]}))
    ]),
    {ok, #{contours := [#{geometry := G}]}} = thinwrap_location:isochrone(C, #{
        center => ll(1, 1), type => time, values => [600]
    }),
    G.

flex_encoder_round_trips_test() ->
    Ring = square(0, 0, 4, 4, true),
    {ok, Decoded} = thinwrap_location_polyline:decode_flex(flex(Ring)),
    ?assertEqual(
        [[float(X), float(Y)] || [X, Y] <- Ring],
        [[Lng, Lat] || #{lat := Lat, lng := Lng} <- Decoded]
    ).

multi_part_isoline_keeps_every_part_and_hole_test() ->
    %% Vendor winding deliberately inverted (clockwise outer, counter-clockwise hole).
    G = here_geometry([
        #{outer => flex(square(0, 0, 4, 4, false)), inner => [flex(square(1, 1, 2, 2, true))]},
        #{outer => flex(square(10, 0, 12, 2, true))}
    ]),
    #{type := <<"MultiPolygon">>, coordinates := [First, Second]} = G,
    ?assertEqual(2, length(First)),
    ?assertEqual(1, length(Second)),
    ?assert(within(lists:nth(2, First), hd(First))),
    ok = assert_rfc7946(First),
    ok = assert_rfc7946(Second).

single_part_with_hole_stays_polygon_test() ->
    G = here_geometry([
        #{outer => flex(square(0, 0, 4, 4, true)), inner => [flex(square(1, 1, 2, 2, true))]}
    ]),
    #{type := <<"Polygon">>, coordinates := Coords} = G,
    ?assertEqual(2, length(Coords)),
    ok = assert_rfc7946(Coords).

part_without_outer_is_skipped_not_fatal_test() ->
    G = here_geometry([
        #{outer => <<>>},
        #{outer => flex(square(0, 0, 4, 4, true)), inner => [<<>>, flex(square(1, 1, 2, 2, true))]}
    ]),
    ?assertMatch(#{type := <<"Polygon">>, coordinates := [_, _]}, G).

%% ---------------------------------------------------------------------------
%% Error contract

%% HERE judges transport_mode: the library does not translate it, so a local
%% check would change the error type the caller gets from the vendor.
transport_mode_is_forwarded_verbatim_not_validated_test() ->
    {C, P} = cfg([?F:resp(400, <<"{\"title\":\"Unknown transport mode\"}">>)]),
    {error, E} = thinwrap_location:route(C, #{
        waypoints => ?TWO, transport_mode => <<"hovercraft">>
    }),
    ?assertMatch(#{code := invalid_request, status := 400}, E),
    ?assertNotEqual(
        nomatch, binary:match(maps:get(url, ?F:last(P)), <<"transportMode=hovercraft">>)
    ).

%% An RFC 3339 binary is a valid departure_time in Erlang (Python accepts only
%% a datetime there); one that does not parse is request data the vendor
%% would reject, so invalid_request before any request.
unparseable_departure_time_is_invalid_request_test_() ->
    [
        ?_test(expect_ce(Op, Input#{departure_time => <<"next tuesday">>}, invalid_request))
     || {Op, Input} <- [
            {route, #{waypoints => ?TWO}},
            {route, #{waypoints => ?THREE, optimize => true}},
            {matrix, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]}}
        ]
    ].

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
