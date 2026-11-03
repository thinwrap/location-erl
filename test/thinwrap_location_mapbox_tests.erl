-module(thinwrap_location_mapbox_tests).

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_location_fake_transport).
-define(TWO, [#{lat => 1, lng => 1}, #{lat => 2, lng => 2}]).
-define(THREE, [#{lat => 1, lng => 1}, #{lat => 2, lng => 2}, #{lat => 3, lng => 3}]).
%% 2026-09-28T21:30:00Z
-define(WHEN, {{2026, 9, 28}, {21, 30, 0}}).
-define(WHEN_ISO_S, <<"2026-09-28T21:30:00Z">>).
-define(DIRECTIONS_OK,
    <<"{\"code\":\"Ok\",\"routes\":[{\"geometry\":\"\",\"legs\":[{\"distance\":5,\"duration\":6}],\"distance\":5,\"duration\":6}]}">>
).
-define(TRIPS_OK2,
    <<"{\"code\":\"Ok\",\"trips\":[{\"geometry\":\"\",\"legs\":[{\"distance\":5,\"duration\":6}],\"distance\":5,\"duration\":6}],\"waypoints\":[{\"waypoint_index\":0},{\"waypoint_index\":1}]}">>
).
-define(TRIPS_OK3,
    <<"{\"code\":\"Ok\",\"trips\":[{\"geometry\":\"\",\"legs\":[{\"distance\":5,\"duration\":6}],\"distance\":5,\"duration\":6}],\"waypoints\":[{\"waypoint_index\":0},{\"waypoint_index\":1},{\"waypoint_index\":2}]}">>
).
-define(MATRIX_OK, <<"{\"code\":\"Ok\",\"durations\":[[60]],\"distances\":[[1000]]}">>).

cfg(Responses) -> ?F:config(#{provider => mapbox, access_token => <<"tok">>}, Responses).

ll(Lat, Lng) -> #{lat => Lat, lng => Lng}.

j(Term) -> iolist_to_binary(json:encode(Term)).

has_query(Req, Key) -> ?F:qall(Req, Key) =/= [].

starts_with(Bin, Prefix) ->
    byte_size(Bin) >= byte_size(Prefix) andalso
        binary:part(Bin, 0, byte_size(Prefix)) =:= Prefix.

contains(Bin, Part) -> binary:match(Bin, Part) =/= nomatch.

route(Input, Responses) ->
    {C, P} = cfg(Responses),
    {thinwrap_location:route(C, Input), P}.

%% The first request of an operation whose transport fails it, so only the
%% wire shape is tested. Anything other than a transport failure means the
%% connector refused the options before sending.
capture(Op, Input) ->
    {C, P} = cfg([{error, captured}]),
    {error, #{code := provider_unavailable}} = thinwrap_location:Op(C, Input),
    hd(?F:calls(P)).

capture_route(Input) -> capture(route, Input).

capture_matrix(Extra) ->
    capture(matrix, maps:merge(#{origins => [ll(1, 1)], destinations => [ll(2, 2)]}, Extra)).

%% A precision-6 polyline, independent of the connector's decoder.
encode_p6(Coords) ->
    {Out, _, _} = lists:foldl(
        fun(#{lat := La, lng := Ln}, {Acc, PLat, PLng}) ->
            Lat = floor(La * 1.0e6 + 0.5),
            Lng = floor(Ln * 1.0e6 + 0.5),
            {[Acc, enc6(Lat - PLat), enc6(Lng - PLng)], Lat, Lng}
        end,
        {[], 0, 0},
        Coords
    ),
    iolist_to_binary(Out).

enc6(V) ->
    X =
        case V < 0 of
            true -> bnot (V bsl 1);
            false -> V bsl 1
        end,
    chunks6(X).

chunks6(X) when X >= 16#20 -> [(16#20 bor (X band 16#1F)) + 63 | chunks6(X bsr 5)];
chunks6(X) -> [X + 63].

close_to(A, B) -> abs(A - B) < 1.0e-5.

uuid_v4(B) ->
    re:run(
        B, "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", [
            {capture, none}
        ]
    ) =:= match.

%% ---------------------------------------------------------------------------
%% Routing

routing_directions_test() ->
    Pts = [ll(38.5, -120.2), ll(40.7, -120.95)],
    Geom = encode_p6(Pts),
    {{ok, R}, P} = route(#{waypoints => Pts}, [
        ?F:resp(
            200,
            j(#{
                code => <<"Ok">>,
                routes => [
                    #{
                        geometry => Geom,
                        legs => [#{distance => 1000, duration => 600}],
                        distance => 1000,
                        duration => 600
                    }
                ]
            })
        )
    ]),
    ?assertEqual(1000.0, maps:get(total_distance_meters, R)),
    ?assertEqual(600.0, maps:get(total_duration_seconds, R)),
    {ok, Dec} = thinwrap_location_polyline:decode(maps:get(polyline, R)),
    ?assert(
        lists:all(
            fun({#{lat := A, lng := B}, #{lat := C, lng := D}}) ->
                close_to(A, C) andalso close_to(B, D)
            end,
            lists:zip(Dec, Pts)
        )
    ),
    ?assertNot(maps:is_key(waypoint_order, R)),
    Last = ?F:last(P),
    ?assert(starts_with(?F:path_of(Last), <<"/directions/v5/mapbox/driving/">>)),
    ?assertEqual(<<"tok">>, ?F:qget(Last, <<"access_token">>)),
    ?assertEqual(<<"polyline6">>, ?F:qget(Last, <<"geometries">>)).

routing_optimized_test() ->
    Geom = encode_p6(?THREE),
    {{ok, R}, P} = route(#{waypoints => ?THREE, optimize => true}, [
        ?F:resp(
            200,
            j(#{
                code => <<"Ok">>,
                trips => [
                    #{
                        geometry => Geom,
                        legs => [#{distance => 5, duration => 6}],
                        distance => 5,
                        duration => 6
                    }
                ],
                waypoints => [
                    #{waypoint_index => 0}, #{waypoint_index => 2}, #{waypoint_index => 1}
                ]
            })
        )
    ]),
    ?assertEqual([0, 2, 1], maps:get(waypoint_order, R)),
    %% GET /optimized-trips/v1/mapbox/{profile}/{coords}; plain optimize keeps
    %% both endpoints (v1 rejects any/any + roundtrip=false).
    Last = ?F:last(P),
    ?assert(starts_with(?F:path_of(Last), <<"/optimized-trips/v1/mapbox/driving/">>)),
    ?assertEqual(<<"false">>, ?F:qget(Last, <<"roundtrip">>)),
    ?assertEqual(<<"first">>, ?F:qget(Last, <<"source">>)),
    ?assertEqual(<<"last">>, ?F:qget(Last, <<"destination">>)).

%% Mapbox enumerates exactly three accepted ISO 8601 forms for depart_at
%% (YYYY-MM-DDThh:mm:ssZ, ...±hh:mm, YYYY-MM-DDThh:mm); the millisecond form
%% is not one of them.
depart_at_uses_a_documented_iso_form_test() ->
    {{ok, _}, P} = route(
        #{
            waypoints => ?THREE,
            departure_time => <<"2026-08-07T03:06:00.750Z">>,
            traffic_mode => traffic
        },
        [?F:resp(200, ?DIRECTIONS_OK)]
    ),
    Last = ?F:last(P),
    ?assert(starts_with(?F:path_of(Last), <<"/directions/v5/mapbox/driving-traffic/">>)),
    ?assertEqual(<<"2026-08-07T03:06:00Z">>, ?F:qget(Last, <<"depart_at">>)).

%% Directions documents depart_at for the driving profiles only.
depart_at_is_not_sent_for_walking_or_cycling_test_() ->
    [
        ?_test(begin
            {{ok, _}, P} = route(
                #{waypoints => ?TWO, travel_mode => Mode, departure_time => ?WHEN},
                [?F:resp(200, ?DIRECTIONS_OK)]
            ),
            Last = ?F:last(P),
            ?assert(
                starts_with(
                    ?F:path_of(Last),
                    <<"/directions/v5/mapbox/", (atom_to_binary(Mode))/binary, "/">>
                )
            ),
            ?assertNot(has_query(Last, <<"depart_at">>))
        end)
     || Mode <- [walking, cycling]
    ].

%% Optimization v1's documented query parameters are annotations, approaches,
%% bearings, destination, distributions, geometries, language, overview,
%% radiuses, source, steps, roundtrip — unrecognized ones are InvalidInput.
optimized_path_refuses_parameters_v1_does_not_accept_test_() ->
    [
        ?_test(begin
            {Res, P} = route(maps:merge(#{waypoints => ?THREE, optimize => true}, Extra), []),
            ?assertMatch({error, #{code := Want}}, Res),
            ?assertEqual([], ?F:calls(P))
        end)
     || {Extra, Want} <- [
            %% A time under `none` is dropped instead (no effect by definition).
            {#{departure_time => ?WHEN, traffic_mode => traffic}, unsupported_field},
            {#{avoid_tolls => true}, unsupported_option},
            {#{avoid_ferries => true}, unsupported_option},
            {#{avoid_highways => true}, unsupported_option}
        ]
    ].

%% Optimization v1 supports roundtrip=false only as source=first +
%% destination=last: first/any and any/last live-return 200 NotImplemented.
open_trip_with_a_single_fixed_endpoint_is_refused_test_() ->
    [
        ?_test(begin
            {Res, P} = route(Input#{waypoints => ?THREE}, []),
            ?assertMatch({error, #{code := unsupported_option}}, Res),
            ?assertEqual([], ?F:calls(P))
        end)
     || Input <- [#{optimize_fixed_origin => true}, #{optimize_fixed_destination => true}]
    ].

round_trip_with_a_fixed_origin_is_still_allowed_test() ->
    {{ok, _}, P} = route(
        #{waypoints => ?THREE, is_round_trip => true, optimize_fixed_origin => true},
        [?F:resp(200, ?TRIPS_OK3)]
    ),
    Last = ?F:last(P),
    ?assert(starts_with(?F:path_of(Last), <<"/optimized-trips/v1/">>)),
    ?assertEqual(<<"true">>, ?F:qget(Last, <<"roundtrip">>)),
    ?assertEqual(<<"first">>, ?F:qget(Last, <<"source">>)),
    ?assertNot(has_query(Last, <<"exclude">>)),
    ?assertNot(has_query(Last, <<"depart_at">>)).

routing_errors_test() ->
    %% The envelope code, not the status, is the no-route signal —
    %% live-verified that Mapbox serves it on 200 as well as 422.
    {Res1, _} = route(#{waypoints => ?TWO}, [
        ?F:resp(422, <<"{\"code\":\"NoRoute\",\"message\":\"no route found\"}">>)
    ]),
    ?assertMatch({error, #{code := no_route, provider_message := <<"no route found">>}}, Res1),
    %% NoSegment = no road near a coordinate to snap to.
    {Res2, _} = route(#{waypoints => ?TWO}, [?F:resp(200, <<"{\"code\":\"NoSegment\"}">>)]),
    ?assertMatch({error, #{code := no_route}}, Res2).

%% Live: Optimization v1 roundtrip=true&source=any&destination=last → 200 Ok.
round_trip_with_a_fixed_destination_sends_destination_last_test() ->
    {{ok, _}, P} = route(
        #{waypoints => ?THREE, is_round_trip => true, optimize_fixed_destination => true},
        [?F:resp(200, ?TRIPS_OK3)]
    ),
    Last = ?F:last(P),
    ?assertEqual(<<"true">>, ?F:qget(Last, <<"roundtrip">>)),
    ?assertEqual(<<"first">>, ?F:qget(Last, <<"source">>)),
    ?assertEqual(<<"last">>, ?F:qget(Last, <<"destination">>)).

plain_round_trip_leaves_destination_unset_test() ->
    {{ok, _}, P} = route(#{waypoints => ?TWO, is_round_trip => true}, [?F:resp(200, ?TRIPS_OK2)]),
    ?assertNot(has_query(?F:last(P), <<"destination">>)).

%% Live: cycling exclude=toll → 422 with an InvalidInput envelope.
status_422_invalid_input_is_invalid_request_test() ->
    Body =
        <<"{\"code\":\"InvalidInput\",\"message\":\"exclude value must be one of: ferry, cash_only_tolls, unpaved, tunnel\"}">>,
    {{error, E}, _} = route(#{waypoints => ?TWO}, [?F:resp(422, Body)]),
    ?assertMatch(#{code := invalid_request, status := 422}, E),
    ?assert(starts_with(maps:get(provider_message, E), <<"exclude value must be one of">>)).

status_422_processing_error_stays_unknown_test() ->
    {Res, _} = route(#{waypoints => ?TWO}, [?F:resp(422, <<"{\"code\":\"ProcessingError\"}">>)]),
    ?assertMatch(
        {error, #{code := unknown, provider_message := <<"Mapbox returned code: ProcessingError">>}},
        Res
    ).

%% Live: Optimization v1 roundtrip=false&source=first&destination=any →
%% HTTP 200 {"code":"NotImplemented","message":"This request is not supported"}.
status_200_not_implemented_is_unsupported_option_test() ->
    Body = <<"{\"code\":\"NotImplemented\",\"message\":\"This request is not supported\"}">>,
    {Res, _} = route(#{waypoints => ?TWO, optimize => true}, [?F:resp(200, Body)]),
    ?assertMatch({error, #{code := unsupported_option, status := 200}}, Res).

status_422_no_segment_stays_no_route_test() ->
    {Res, _} = route(#{waypoints => ?TWO}, [
        ?F:resp(422, <<"{\"code\":\"NoSegment\",\"message\":\"x\"}">>)
    ]),
    ?assertMatch({error, #{code := no_route}}, Res).

routing_http_status_mapping_test_() ->
    [
        ?_test(begin
            {{error, E}, _} = route(#{waypoints => ?TWO}, [?F:resp(Status, Body, Headers)]),
            ?assertMatch(#{code := Want, status := Status}, E),
            case map_size(Headers) of
                0 ->
                    ok;
                _ ->
                    ?assertMatch(#{<<"retryAfter">> := <<"7">>}, maps:get(cause, E)),
                    ?assert(contains(maps:get(provider_message, E), <<"retry after 7 seconds">>))
            end
        end)
     || {Status, Body, Headers, Want} <- [
            {401, <<"{\"message\":\"Not Authorized - Invalid Token\"}">>, #{}, auth_failed},
            {403, <<"{\"message\":\"Forbidden\"}">>, #{}, auth_failed},
            {429, <<"{\"message\":\"Too Many Requests\"}">>, #{<<"Retry-After">> => <<"7">>},
                rate_limited},
            {400, <<"{}">>, #{}, invalid_request},
            {503, <<>>, #{}, provider_unavailable},
            {404, <<"{\"message\":\"Not Found\"}">>, #{}, unknown}
        ]
    ].

routing_error_without_a_vendor_message_names_the_status_test() ->
    {Res, _} = route(#{waypoints => ?TWO}, [?F:resp(418, <<>>)]),
    ?assertMatch(
        {error, #{code := unknown, provider_message := <<"Mapbox request failed: HTTP 418">>}}, Res
    ).

%% Live: walking toll/motorway → 422 "one of: ferry, cash_only_tolls,
%% border_crossing, ..."; cycling toll → 422 "one of: ferry, cash_only_tolls,
%% unpaved, tunnel"; ferry → 200 on both.
walking_and_cycling_send_only_ferry_exclude_test_() ->
    [
        ?_test(begin
            {{ok, _}, P} = route(
                #{
                    waypoints => ?TWO,
                    travel_mode => Mode,
                    avoid_tolls => true,
                    avoid_highways => true,
                    avoid_ferries => true
                },
                [?F:resp(200, ?DIRECTIONS_OK)]
            ),
            ?assertEqual(<<"ferry">>, ?F:qget(?F:last(P), <<"exclude">>))
        end)
     || Mode <- [walking, cycling]
    ].

walking_and_cycling_without_ferry_send_no_exclude_test_() ->
    [
        ?_test(begin
            {{ok, _}, P} = route(
                #{
                    waypoints => ?TWO,
                    travel_mode => Mode,
                    avoid_tolls => true,
                    avoid_highways => true
                },
                [?F:resp(200, ?DIRECTIONS_OK)]
            ),
            ?assertNot(has_query(?F:last(P), <<"exclude">>))
        end)
     || Mode <- [walking, cycling]
    ].

driving_sends_every_exclude_class_test() ->
    {{ok, _}, P} = route(
        #{waypoints => ?TWO, avoid_tolls => true, avoid_highways => true, avoid_ferries => true},
        [?F:resp(200, ?DIRECTIONS_OK)]
    ),
    ?assertEqual(<<"toll,ferry,motorway">>, ?F:qget(?F:last(P), <<"exclude">>)).

live_traffic_selects_the_driving_traffic_profile_test() ->
    {{ok, _}, P} = route(
        #{waypoints => ?TWO, traffic_mode => live, departure_time => ?WHEN, avoid_tolls => true},
        [?F:resp(200, ?DIRECTIONS_OK)]
    ),
    Last = ?F:last(P),
    ?assert(starts_with(?F:path_of(Last), <<"/directions/v5/mapbox/driving-traffic/">>)),
    %% driving-traffic is a driving profile: depart_at and the full exclude set apply.
    ?assertEqual(?WHEN_ISO_S, ?F:qget(Last, <<"depart_at">>)),
    ?assertEqual(<<"toll">>, ?F:qget(Last, <<"exclude">>)).

live_traffic_does_not_change_walking_or_cycling_test_() ->
    [
        ?_test(begin
            {{ok, _}, P} = route(
                #{waypoints => ?TWO, travel_mode => Mode, traffic_mode => live},
                [?F:resp(200, ?DIRECTIONS_OK)]
            ),
            ?assert(
                starts_with(
                    ?F:path_of(?F:last(P)),
                    <<"/directions/v5/mapbox/", (atom_to_binary(Mode))/binary, "/">>
                )
            )
        end)
     || Mode <- [walking, cycling]
    ].

%% Optimization v1 has no driving-traffic profile.
live_traffic_on_the_optimized_path_stays_on_driving_test() ->
    {{ok, _}, P} = route(
        #{waypoints => ?TWO, optimize => true, traffic_mode => live}, [?F:resp(200, ?TRIPS_OK2)]
    ),
    ?assert(starts_with(?F:path_of(?F:last(P)), <<"/optimized-trips/v1/mapbox/driving/">>)).

routing_malformed_route_is_unknown_test_() ->
    [
        ?_test(begin
            {Res, _} = route(#{waypoints => ?TWO}, [?F:resp(200, Body)]),
            ?assertMatch({error, #{code := unknown}}, Res)
        end)
     || Body <- [
            <<"{\"code\":\"Ok\",\"routes\":[null]}">>,
            <<"{\"code\":\"Ok\",\"routes\":[{\"distance\":1,\"duration\":1,\"geometry\":\"\",\"legs\":[null]}]}">>,
            <<"{\"code\":\"Ok\",\"routes\":[{\"distance\":1,\"geometry\":\"\",\"legs\":[{\"distance\":1,\"duration\":1}]}]}">>,
            <<"{\"code\":\"Ok\",\"routes\":[{\"distance\":1,\"duration\":1,\"geometry\":\"\",\"legs\":[{\"duration\":1}]}]}">>,
            <<"[]">>,
            <<"<html>busy</html>">>
        ]
    ].

routing_ok_with_no_routes_is_no_route_test_() ->
    [
        ?_test(begin
            {Res, _} = route(#{waypoints => ?TWO}, [?F:resp(200, Body)]),
            ?assertMatch({error, #{code := no_route, status := 200}}, Res)
        end)
     || Body <- [<<"{\"code\":\"Ok\",\"routes\":[]}">>, <<"{\"code\":\"Ok\"}">>]
    ].

malformed_polyline6_geometry_is_unknown_test() ->
    Body =
        <<"{\"code\":\"Ok\",\"routes\":[{\"geometry\":\"_\",\"legs\":[{\"distance\":1,\"duration\":1}],\"distance\":1,\"duration\":1}]}">>,
    {Res, _} = route(#{waypoints => ?TWO}, [?F:resp(200, Body)]),
    ?assertMatch(
        {error, #{
            code := unknown, status := 200, message := <<"Malformed Mapbox polyline6 geometry">>
        }},
        Res
    ).

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
    ?assertEqual(<<"/directions-matrix/v1/mapbox/driving/1,1;2,2;3,3;4,4">>, ?F:path_of(Last)).

matrix_live_traffic_selects_the_driving_traffic_profile_test() ->
    {C, P} = cfg([?F:resp(200, ?MATRIX_OK)]),
    {ok, _} = thinwrap_location:matrix(C, #{
        origins => [ll(1, 1)], destinations => [ll(2, 2)], traffic_mode => live
    }),
    ?assert(
        starts_with(?F:path_of(?F:last(P)), <<"/directions-matrix/v1/mapbox/driving-traffic/">>)
    ).

matrix_refuses_options_it_cannot_honour_before_any_request_test_() ->
    [
        ?_test(begin
            {C, P} = cfg([]),
            ?assertMatch(
                {error, #{code := Want}},
                thinwrap_location:matrix(
                    C, maps:merge(#{origins => [ll(1, 1)], destinations => [ll(2, 2)]}, Extra)
                )
            ),
            ?assertEqual([], ?F:calls(P))
        end)
     || {Extra, Want} <- [
            %% Live: Matrix with exclude=toll or depart_at → 422 "Request too
            %% large for custom parameters".
            {#{avoid_tolls => true}, unsupported_option},
            %% Only traffic at a given time is refused; a time under none is dropped.
            {#{departure_time => ?WHEN, traffic_mode => traffic}, unsupported_field}
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

matrix_body_code_mapping_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(Status, j(#{code => Code, message => <<"m">>}))]),
            ?assertMatch(
                {error, #{code := Want, status := Status}},
                thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]})
            )
        end)
     || {Status, Code, Want} <- [
            {422, <<"NoRoute">>, no_route},
            {422, <<"NoSegment">>, no_route},
            {422, <<"InvalidInput">>, invalid_request},
            {200, <<"NoRoute">>, no_route},
            {200, <<"NoSegment">>, no_route}
        ]
    ].

matrix_malformed_grid_is_unknown_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(200, Body)]),
            ?assertMatch(
                {error, #{code := unknown}},
                thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]})
            )
        end)
     || Body <- [
            <<"{\"code\":\"Ok\",\"durations\":[null],\"distances\":[[1]]}">>,
            <<"{\"code\":\"Ok\",\"durations\":[[1]]}">>,
            <<"<html/>">>
        ]
    ].

matrix_non_numeric_entry_is_omitted_not_zero_test() ->
    {C, _} = cfg([
        ?F:resp(200, <<"{\"code\":\"Ok\",\"durations\":[[5,\"x\"]],\"distances\":[[7,8]]}">>)
    ]),
    {ok, #{cells := Cells}} = thinwrap_location:matrix(C, #{
        origins => [ll(1, 1)], destinations => [ll(2, 2), ll(3, 3)]
    }),
    ?assertEqual(
        [{0, 7.0, 5.0}],
        [
            {D, Dist, Dur}
         || #{destination_index := D, distance_meters := Dist, duration_seconds := Dur} <- Cells
        ]
    ).

%% ---------------------------------------------------------------------------
%% Geocoding

geocode_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"features\":[{\"geometry\":{\"coordinates\":[-74.0,40.7]},\"properties\":{\"mapbox_id\":\"mid\",\"full_address\":\"New York, NY\",\"bbox\":[-74.3,40.4,-73.7,40.9]}}]}">>
        )
    ]),
    {ok, #{candidates := [Cand]}} = thinwrap_location:geocode(C, #{
        address => <<"NYC">>, country_filter => [<<"US">>], language => <<"en">>
    }),
    ?assertEqual(
        #{
            formatted_address => <<"New York, NY">>,
            location => #{lat => 40.7, lng => -74.0},
            place_id => <<"mid">>,
            viewport => #{
                southwest => #{lat => 40.4, lng => -74.3}, northeast => #{lat => 40.9, lng => -73.7}
            }
        },
        Cand
    ),
    Last = ?F:last(P),
    ?assertEqual(<<"/search/geocode/v6/forward">>, ?F:path_of(Last)),
    ?assertEqual(<<"NYC">>, ?F:qget(Last, <<"q">>)),
    ?assertEqual(<<"us">>, ?F:qget(Last, <<"country">>)),
    ?assertEqual(<<"en">>, ?F:qget(Last, <<"language">>)),
    ?assertEqual(<<"tok">>, ?F:qget(Last, <<"access_token">>)).

geocode_falls_back_to_place_name_test() ->
    {C, _} = cfg([
        ?F:resp(
            200,
            <<"{\"features\":[{\"geometry\":{\"coordinates\":[2,1]},\"place_name\":\"Old\"}]}">>
        )
    ]),
    ?assertMatch(
        {ok, #{candidates := [#{formatted_address := <<"Old">>, location := #{lat := 1.0}}]}},
        thinwrap_location:geocode(C, #{address => <<"x">>})
    ).

reverse_geocode_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"features\":[{\"geometry\":{\"coordinates\":[2.5,1.25]},\"properties\":{\"full_address\":\"Somewhere\"}}]}">>
        )
    ]),
    {ok, #{candidates := [Cand]}} = thinwrap_location:reverse_geocode(C, #{
        location => ll(1.25, 2.5), language => <<"de">>
    }),
    ?assertEqual(
        #{formatted_address => <<"Somewhere">>, location => #{lat => 1.25, lng => 2.5}}, Cand
    ),
    Last = ?F:last(P),
    ?assertEqual(<<"/search/geocode/v6/reverse">>, ?F:path_of(Last)),
    ?assertEqual(<<"2.5">>, ?F:qget(Last, <<"longitude">>)),
    ?assertEqual(<<"1.25">>, ?F:qget(Last, <<"latitude">>)),
    ?assertEqual(<<"de">>, ?F:qget(Last, <<"language">>)).

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
    {C, _} = cfg([?F:resp(200, <<"{\"type\":\"FeatureCollection\",\"features\":[]}">>)]),
    ?assertMatch({ok, #{candidates := []}}, thinwrap_location:geocode(C, #{address => <<"x">>})).

geocode_http_error_mapping_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(Status, Body)]),
            ?assertMatch(
                {error, #{code := Want, status := Status, provider_message := Msg}},
                thinwrap_location:geocode(C, #{address => <<"x">>})
            )
        end)
     || {Status, Body, Want, Msg} <- [
            {401, <<"{\"message\":\"Not Authorized\"}">>, auth_failed, <<"Not Authorized">>},
            {422, <<"{\"error\":\"bad query\"}">>, invalid_request, <<"bad query">>},
            {429, <<"{\"message\":\"slow\"}">>, rate_limited, <<"slow">>},
            {502, <<"{\"message\":\"down\"}">>, provider_unavailable, <<"down">>}
        ]
    ].

%% A partial viewport is omitted, never 0-filled.
partial_viewport_is_omitted_test() ->
    {C, _} = cfg([
        ?F:resp(
            200,
            <<"{\"features\":[{\"geometry\":{\"coordinates\":[2,1]},\"properties\":{\"full_address\":\"a\",\"bbox\":[1,1,null,3]}}]}">>
        )
    ]),
    {ok, #{candidates := [Cand]}} = thinwrap_location:geocode(C, #{address => <<"x">>}),
    ?assertNot(maps:is_key(viewport, Cand)).

feature_with_non_numeric_coordinates_is_skipped_test() ->
    {C, _} = cfg([
        ?F:resp(
            200,
            <<"{\"features\":[{\"geometry\":{\"coordinates\":[\"2\",1]},\"properties\":{\"full_address\":\"a\"}}]}">>
        )
    ]),
    ?assertMatch({ok, #{candidates := []}}, thinwrap_location:geocode(C, #{address => <<"x">>})).

%% ---------------------------------------------------------------------------
%% Autocomplete

autocomplete_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"suggestions\":[{\"name\":\"NY\",\"full_address\":\"New York, NY\",\"mapbox_id\":\"mid\"}]}">>
        )
    ]),
    {ok, #{predictions := [Pred]}} = thinwrap_location:autocomplete(C, #{input => <<"New">>}),
    ?assertEqual(
        #{
            description => <<"New York, NY">>,
            place_id => <<"mid">>,
            structured_format => #{main_text => <<"NY">>}
        },
        Pred
    ),
    Last = ?F:last(P),
    ?assertEqual(<<"/search/searchbox/v1/suggest">>, ?F:path_of(Last)),
    %% session_token is required on /suggest: without a caller token a UUIDv4 is generated.
    ?assert(uuid_v4(?F:qget(Last, <<"session_token">>))).

autocomplete_generates_a_fresh_token_per_call_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"suggestions\":[]}">>)]),
    {ok, _} = thinwrap_location:autocomplete(C, #{input => <<"a">>}),
    {ok, _} = thinwrap_location:autocomplete(C, #{input => <<"a">>, session_token => <<>>}),
    [T1, T2] = [?F:qget(R, <<"session_token">>) || R <- ?F:calls(P)],
    ?assert(uuid_v4(T2)),
    ?assertNotEqual(T1, T2).

%% Search Box groups every /suggest sharing a session_token into one billable
%% session, closed by the /retrieve carrying the same value — so the caller's
%% token must reach the wire on both calls, never a per-call random one.
autocomplete_forwards_the_callers_session_token_test() ->
    {C, P} = cfg([
        ?F:resp(200, <<"{\"suggestions\":[{\"name\":\"NY\",\"mapbox_id\":\"mid\"}]}">>),
        ?F:resp(
            200,
            <<"{\"features\":[{\"geometry\":{\"coordinates\":[-74.0,40.7]},\"properties\":{\"mapbox_id\":\"mid\",\"full_address\":\"New York, NY\"}}]}">>
        )
    ]),
    Token = <<"0f8fad5b-d9cb-469f-a165-70867728950e">>,
    {ok, _} = thinwrap_location:autocomplete(C, #{input => <<"Ne">>, session_token => Token}),
    {ok, _} = thinwrap_location:place_details(C, #{place_id => <<"mid">>, session_token => Token}),
    [Suggest, Retrieve] = ?F:calls(P),
    ?assertEqual(<<"/search/searchbox/v1/suggest">>, ?F:path_of(Suggest)),
    ?assertEqual(Token, ?F:qget(Suggest, <<"session_token">>)),
    ?assert(contains(?F:path_of(Retrieve), <<"/retrieve/">>)),
    ?assertEqual(Token, ?F:qget(Retrieve, <<"session_token">>)).

autocomplete_reads_name_and_place_formatted_test() ->
    Body = j(#{
        suggestions => [
            #{
                name => <<"Blue Bottle Coffee">>,
                place_formatted => <<"66 Mint St">>,
                full_address => <<"Blue Bottle Coffee, 66 Mint St">>,
                mapbox_id => <<"id1">>
            }
        ]
    }),
    {C, _} = cfg([?F:resp(200, Body)]),
    {ok, #{predictions := [Pred]}} = thinwrap_location:autocomplete(C, #{input => <<"blue">>}),
    ?assertEqual(
        #{main_text => <<"Blue Bottle Coffee">>, secondary_text => <<"66 Mint St">>},
        maps:get(structured_format, Pred)
    ).

autocomplete_without_a_name_has_no_structured_format_test() ->
    {C, _} = cfg([?F:resp(200, <<"{\"suggestions\":[{\"full_address\":\"A St\"}]}">>)]),
    ?assertMatch(
        {ok, #{predictions := [#{description := <<"A St">>} = Pred]}} when
            map_size(Pred) =:= 1,
        thinwrap_location:autocomplete(C, #{input => <<"a">>})
    ).

autocomplete_maps_country_filter_to_lowercased_csv_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"suggestions\":[]}">>)]),
    {ok, _} = thinwrap_location:autocomplete(C, #{
        input => <<"coffee">>, country_filter => [<<"IL">>, <<"PS">>]
    }),
    ?assertEqual(<<"il,ps">>, ?F:qget(?F:last(P), <<"country">>)).

autocomplete_uninterpretable_2xx_body_is_unknown_test() ->
    {C, _} = cfg([?F:resp(200, <<"<html/>">>)]),
    ?assertMatch(
        {error, #{code := unknown}},
        thinwrap_location:autocomplete(C, #{input => <<"x">>, location => ll(1, 1)})
    ).

%% ---------------------------------------------------------------------------
%% Place details

-define(PLACE_BODY,
    <<"{\"features\":[{\"geometry\":{\"coordinates\":[-122.4059,37.7825]},\"properties\":{\"mapbox_id\":\"mb1\",\"full_address\":\"66 Mint St\",\"name\":\"Blue Bottle\"}}]}">>
).

place_details_gets_searchbox_retrieve_test() ->
    {C, P} = cfg([?F:resp(200, ?PLACE_BODY)]),
    {ok, R} = thinwrap_location:place_details(C, #{place_id => <<"mb1">>}),
    ?assertEqual(<<"/search/searchbox/v1/retrieve/mb1">>, ?F:path_of(?F:last(P))),
    ?assertMatch(
        #{candidate := #{location := #{lat := 37.7825}, place_id := <<"mb1">>}}, R
    ),
    %% `name` is opt-in.
    ?assertNot(maps:is_key(name, R)).

place_details_surfaces_name_when_included_test() ->
    {C, _} = cfg([?F:resp(200, ?PLACE_BODY)]),
    ?assertMatch(
        {ok, #{name := <<"Blue Bottle">>}},
        thinwrap_location:place_details(C, #{place_id => <<"x">>, include => [name]})
    ).

place_details_id_is_path_escaped_test() ->
    {C, P} = cfg([?F:resp(200, ?PLACE_BODY)]),
    {ok, _} = thinwrap_location:place_details(C, #{place_id => <<"a/b c">>}),
    ?assertEqual(<<"/search/searchbox/v1/retrieve/a%2Fb%20c">>, ?F:path_of(?F:last(P))).

%% Search Box bills per SESSION: suggest + retrieve with the SAME token is one
%% billable session, a missing or fresh token makes it two.
place_details_forwards_session_token_test() ->
    {C, P} = cfg([?F:resp(200, ?PLACE_BODY)]),
    {ok, _} = thinwrap_location:place_details(C, #{
        place_id => <<"mb1">>, session_token => <<"sess-123">>, language => <<"fr">>
    }),
    ?assertEqual(<<"sess-123">>, ?F:qget(?F:last(P), <<"session_token">>)),
    ?assertEqual(<<"fr">>, ?F:qget(?F:last(P), <<"language">>)).

place_details_generates_a_session_token_when_none_is_given_test() ->
    {C, P} = cfg([?F:resp(200, ?PLACE_BODY)]),
    {ok, _} = thinwrap_location:place_details(C, #{place_id => <<"mb1">>}),
    %% session_token is REQUIRED on /retrieve; Mapbox recommends a UUIDv4.
    ?assert(uuid_v4(?F:qget(?F:last(P), <<"session_token">>))).

%% An id that resolves to nothing is an answer, like geocoding's zero results.
place_details_unusable_result_returns_no_candidate_test() ->
    {C, _} = cfg([?F:resp(200, <<"{\"features\":[]}">>)]),
    {ok, R} = thinwrap_location:place_details(C, #{place_id => <<"x">>, include => [name]}),
    ?assertEqual(#{raw => #{<<"features">> => []}}, R).

place_details_vendor_404_returns_no_candidate_test() ->
    Body = <<"{\"message\":{\"error\":\"No data found for requested ID\"}}">>,
    {C, _} = cfg([?F:resp(404, Body)]),
    {ok, R} = thinwrap_location:place_details(C, #{place_id => <<"x">>}),
    ?assertEqual(#{raw => json:decode(Body)}, R).

place_details_unparseable_2xx_body_is_unknown_test() ->
    {C, _} = cfg([?F:resp(200, <<"<html>oops</html>">>)]),
    ?assertMatch(
        {error, #{code := unknown}}, thinwrap_location:place_details(C, #{place_id => <<"x">>})
    ).

place_details_other_error_status_stays_an_error_test() ->
    {C, _} = cfg([?F:resp(401, <<"{\"message\":\"Invalid Token\"}">>)]),
    ?assertMatch(
        {error, #{code := auth_failed, status := 401}},
        thinwrap_location:place_details(C, #{place_id => <<"x">>})
    ).

%% ---------------------------------------------------------------------------
%% Isochrone

-define(RING, [[0, 0], [1, 0], [1, 1], [0, 0]]).

iso(Input) -> maps:merge(#{center => ll(40, -74), type => time, values => [600]}, Input).

iso_features(Contours) ->
    j(#{
        features => [
            #{properties => #{contour => C}, geometry => #{coordinates => [?RING]}}
         || C <- Contours
        ]
    }).

isochrone_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"features\":[{\"properties\":{\"contour\":10},\"geometry\":{\"coordinates\":[[[0,0],[1,0],[1,1],[0,0]]]}}]}">>
        )
    ]),
    {ok, #{contours := [Contour]}} = thinwrap_location:isochrone(C, iso(#{})),
    ?assertMatch(#{value := 600.0, geometry := #{type := <<"Polygon">>}}, Contour),
    Last = ?F:last(P),
    ?assertEqual(<<"/isochrone/v1/mapbox/driving/-74,40">>, ?F:path_of(Last)),
    ?assertEqual(<<"true">>, ?F:qget(Last, <<"polygons">>)),
    ?assertEqual(<<"10">>, ?F:qget(Last, <<"contours_minutes">>)),
    ?assertNot(has_query(Last, <<"depart_at">>)).

isochrone_profile_follows_travel_mode_test() ->
    {C, P} = cfg([?F:resp(200, iso_features([10]))]),
    {ok, _} = thinwrap_location:isochrone(C, iso(#{travel_mode => cycling})),
    ?assert(starts_with(?F:path_of(?F:last(P)), <<"/isochrone/v1/mapbox/cycling/">>)).

isochrone_time_breaks_sent_ascending_and_read_back_as_caller_values_test() ->
    {C, P} = cfg([?F:resp(200, iso_features([2, 10]))]),
    {ok, #{contours := Cs}} = thinwrap_location:isochrone(C, iso(#{values => [600, 90]})),
    ?assertEqual(<<"2,10">>, ?F:qget(?F:last(P), <<"contours_minutes">>)),
    %% 90 s was sent as 2 min, and comes back as the caller's 90 s — not 120 s.
    ?assertEqual([90.0, 600.0], [V || #{value := V} <- Cs]).

isochrone_distance_breaks_are_sent_as_integers_and_read_back_test() ->
    {C, P} = cfg([?F:resp(200, iso_features([1500, 250]))]),
    {ok, #{contours := Cs}} = thinwrap_location:isochrone(
        C, iso(#{type => distance, values => [1500.4, 249.6]})
    ),
    ?assertEqual(<<"250,1500">>, ?F:qget(?F:last(P), <<"contours_meters">>)),
    ?assertEqual([249.6, 1500.4], [V || #{value := V} <- Cs]).

isochrone_unsent_contour_falls_back_to_a_unit_conversion_test() ->
    {C, _} = cfg([?F:resp(200, iso_features([10, 7.5]))]),
    {ok, #{contours := Cs}} = thinwrap_location:isochrone(C, iso(#{})),
    ?assertEqual([450.0, 600.0], [V || #{value := V} <- Cs]).

isochrone_breaks_mapbox_cannot_express_are_rejected_before_sending_test_() ->
    [
        ?_test(begin
            {C, P} = cfg([]),
            ?assertMatch(
                {error, #{code := invalid_request}},
                thinwrap_location:isochrone(C, iso(#{type => Type, values => Values}))
            ),
            ?assertEqual([], ?F:calls(P))
        end)
     || {Type, Values} <- [
            {time, [29]},
            {time, [59.9]},
            %% both round to 10 min
            {time, [600, 620]},
            {distance, [0.4]},
            {distance, [100.2, 100.4]}
        ]
    ].

isochrone_break_messages_test() ->
    {C, _} = cfg([]),
    ?assertMatch(
        {error, #{
            message :=
                <<"Mapbox isochrone time breaks are whole minutes; 59.9 s is under the 60 s minimum">>
        }},
        thinwrap_location:isochrone(C, iso(#{values => [59.9]}))
    ),
    ?assertMatch(
        {error, #{
            message := <<"Mapbox isochrone breaks 600 and 620 round to the same minute (10)">>
        }},
        thinwrap_location:isochrone(C, iso(#{values => [620, 600]}))
    ).

isochrone_without_a_usable_polygon_is_unknown_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(200, Body)]),
            ?assertMatch({error, #{code := unknown}}, thinwrap_location:isochrone(C, iso(#{})))
        end)
     || Body <- [
            <<"{\"features\":[]}">>,
            <<"{\"features\":[{\"properties\":{},\"geometry\":{\"coordinates\":[[[0,0],[1,1],[0,0]]]}}]}">>,
            <<"{\"features\":[{\"properties\":{\"contour\":10},\"geometry\":{\"coordinates\":[]}}]}">>,
            <<"{\"features\":[{\"properties\":{\"contour\":10},\"geometry\":{\"coordinates\":[[[0,null]]]}}]}">>,
            <<"[]">>
        ]
    ].

isochrone_http_error_test() ->
    {C, _} = cfg([?F:resp(422, <<"{\"message\":\"Times must be in increasing order\"}">>)]),
    ?assertMatch(
        {error, #{
            code := invalid_request,
            status := 422,
            provider_message := <<"Times must be in increasing order">>
        }},
        thinwrap_location:isochrone(C, iso(#{}))
    ).

isochrone_departure_time_is_validated_test_() ->
    [
        ?_test(begin
            {C, P} = cfg([]),
            ?assertMatch(
                {error, #{code := invalid_request}},
                thinwrap_location:isochrone(C, iso(#{departure_time => Bad}))
            ),
            ?assertEqual([], ?F:calls(P))
        end)
     || Bad <- [<<"tomorrow">>, <<"2026-13-01T00:00">>, <<"2026-01-01">>]
    ].

isochrone_departure_time_string_is_sent_verbatim_test() ->
    {C, P} = cfg([?F:resp(200, iso_features([10]))]),
    {ok, _} = thinwrap_location:isochrone(C, iso(#{departure_time => <<"2026-09-01T08:00">>})),
    ?assertEqual(<<"2026-09-01T08:00">>, ?F:qget(?F:last(P), <<"depart_at">>)).

isochrone_departure_time_datetime_is_utc_seconds_test() ->
    {C, P} = cfg([?F:resp(200, iso_features([10]))]),
    {ok, _} = thinwrap_location:isochrone(C, iso(#{departure_time => ?WHEN})),
    ?assertEqual(?WHEN_ISO_S, ?F:qget(?F:last(P), <<"depart_at">>)).

isochrone_bad_breaks_are_invalid_request_test_() ->
    [
        ?_test(begin
            {C, P} = cfg([]),
            ?assertMatch(
                {error, #{code := invalid_request}},
                thinwrap_location:isochrone(C, iso(#{values => Values}))
            ),
            ?assertEqual([], ?F:calls(P))
        end)
     || Values <- [[], [0], [60, 120, 180, 240, 300]]
    ].

%% --- isochrone geometry: parts, holes, RFC 7946 winding -----------------------

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

assert_rfc7946([Ext | Holes]) ->
    [?assertEqual(hd(R), lists:last(R)) || R <- [Ext | Holes]],
    ?assert(area(Ext) > 0),
    [?assert(area(H) < 0) || H <- Holes],
    ok.

iso_geometry(Geometry) ->
    {C, _} = cfg([
        ?F:resp(200, j(#{features => [#{properties => #{contour => 10}, geometry => Geometry}]}))
    ]),
    thinwrap_location:isochrone(C, iso(#{center => ll(1, 1)})).

geometry_of(Geometry) ->
    {ok, #{contours := [#{geometry := G}]}} = iso_geometry(Geometry),
    G.

multipolygon_feature_keeps_every_part_test() ->
    G = geometry_of(#{
        type => <<"MultiPolygon">>,
        coordinates => [
            [closed(square(0, 0, 4, 4, false)), closed(square(1, 1, 2, 2, true))],
            [closed(square(10, 0, 12, 2, true))]
        ]
    }),
    ?assertMatch(#{type := <<"MultiPolygon">>, coordinates := [[_, _], [_]]}, G),
    [assert_rfc7946(Part) || Part <- maps:get(coordinates, G)].

polygon_hole_is_kept_and_rewound_test() ->
    G = geometry_of(#{
        type => <<"Polygon">>,
        coordinates => [closed(square(0, 0, 4, 4, false)), closed(square(1, 1, 2, 2, true))]
    }),
    ?assertMatch(#{type := <<"Polygon">>, coordinates := [_, _]}, G),
    assert_rfc7946(maps:get(coordinates, G)).

unusable_hole_is_dropped_from_its_polygon_test() ->
    G = geometry_of(#{
        type => <<"Polygon">>,
        coordinates => [
            closed(square(0, 0, 4, 4, true)), [[1, null]], closed(square(1, 1, 2, 2, false))
        ]
    }),
    #{type := <<"Polygon">>, coordinates := [_, Hole] = Coords} = G,
    ?assertEqual({1, 1, 2, 2}, bbox(Hole)),
    assert_rfc7946(Coords).

multipolygon_part_with_unusable_exterior_is_dropped_test() ->
    G = geometry_of(#{
        type => <<"MultiPolygon">>,
        coordinates => [
            [[[0, null]], closed(square(1, 1, 2, 2, false))],
            [closed(square(10, 0, 12, 2, true))],
            [closed(square(20, 0, 22, 2, true))]
        ]
    }),
    #{type := <<"MultiPolygon">>, coordinates := Parts} = G,
    ?assertEqual([{10, 0, 12, 2}, {20, 0, 22, 2}], lists:sort([bbox(hd(P)) || P <- Parts])),
    ?assert(
        lists:all(
            fun
                ([_]) -> true;
                (_) -> false
            end,
            Parts
        )
    ).

multipolygon_with_one_usable_part_is_a_polygon_test() ->
    G = geometry_of(#{
        type => <<"MultiPolygon">>,
        coordinates => [[[[0, null]]], [closed(square(10, 0, 12, 2, true))]]
    }),
    #{type := <<"Polygon">>, coordinates := [Ext]} = G,
    ?assertEqual({10, 0, 12, 2}, bbox(Ext)).

nothing_usable_is_unknown_with_raw_and_status_test_() ->
    [
        ?_test(begin
            {error, E} = iso_geometry(Geometry),
            ?assertMatch(#{code := unknown, status := 200}, E),
            Want = json:decode(
                j(#{features => [#{properties => #{contour => 10}, geometry => Geometry}]})
            ),
            ?assertEqual(Want, maps:get(cause, E))
        end)
     || Geometry <- [
            #{type => <<"MultiPolygon">>, coordinates => []},
            #{type => <<"MultiPolygon">>, coordinates => [[[[0, null]]]]},
            #{
                type => <<"MultiPolygon">>,
                coordinates => [
                    [[[0, null]]],
                    [[]],
                    <<"x">>,
                    [[[<<"a">>, 1]], closed(square(1, 1, 2, 2, true))]
                ]
            },
            #{type => <<"MultiPolygon">>, coordinates => <<"x">>},
            #{type => <<"LineString">>, coordinates => [[0, 0], [1, 1]]}
        ]
    ].

%% ---------------------------------------------------------------------------
%% traffic_mode × departure time → exact wire parameters

directions_none_is_driving_without_depart_at_test_() ->
    [
        ?_test(begin
            Req = capture_route(maps:merge(#{waypoints => ?TWO}, When)),
            ?assert(starts_with(?F:path_of(Req), <<"/directions/v5/mapbox/driving/">>)),
            ?assertNot(has_query(Req, <<"depart_at">>))
        end)
     || When <- [#{}, #{departure_time => ?WHEN}]
    ].

directions_traffic_is_driving_traffic_test_() ->
    [
        ?_test(begin
            Req = capture_route(maps:merge(#{waypoints => ?TWO, traffic_mode => Mode}, When)),
            ?assert(starts_with(?F:path_of(Req), <<"/directions/v5/mapbox/driving-traffic/">>)),
            ?assertEqual(Want, ?F:qget(Req, <<"depart_at">>))
        end)
     || Mode <- [traffic, live],
        {When, Want} <- [{#{}, <<>>}, {#{departure_time => ?WHEN}, ?WHEN_ISO_S}]
    ].

directions_ignores_traffic_for_walking_and_cycling_test_() ->
    [
        ?_test(begin
            Req = capture_route(#{
                waypoints => ?TWO,
                departure_time => ?WHEN,
                traffic_mode => Mode,
                travel_mode => Travel
            }),
            ?assert(
                starts_with(
                    ?F:path_of(Req),
                    <<"/directions/v5/mapbox/", (atom_to_binary(Travel))/binary, "/">>
                )
            ),
            ?assertNot(has_query(Req, <<"depart_at">>))
        end)
     || Mode <- [traffic, live], Travel <- [walking, cycling]
    ].

directions_passthrough_depart_at_still_wins_test() ->
    Req = capture_route(#{
        waypoints => ?TWO, passthrough => #{query => #{<<"depart_at">> => ?WHEN_ISO_S}}
    }),
    ?assertEqual(?WHEN_ISO_S, ?F:qget(Req, <<"depart_at">>)).

matrix_none_is_driving_and_drops_the_time_test_() ->
    [
        ?_test(begin
            Req = capture_matrix(When),
            ?assert(starts_with(?F:path_of(Req), <<"/directions-matrix/v1/mapbox/driving/">>)),
            ?assertNot(has_query(Req, <<"depart_at">>))
        end)
     || When <- [#{}, #{departure_time => ?WHEN}]
    ].

matrix_traffic_without_time_is_driving_traffic_test_() ->
    [
        ?_assert(
            starts_with(
                ?F:path_of(capture_matrix(#{traffic_mode => Mode})),
                <<"/directions-matrix/v1/mapbox/driving-traffic/">>
            )
        )
     || Mode <- [traffic, live]
    ].

matrix_and_optimization_refuse_traffic_at_a_time_test_() ->
    [
        ?_test(begin
            {C, P} = cfg([{error, captured}]),
            ?assertMatch(
                {error, #{code := unsupported_field}},
                thinwrap_location:matrix(C, #{
                    origins => [ll(1, 1)],
                    destinations => [ll(2, 2)],
                    departure_time => ?WHEN,
                    traffic_mode => Mode
                })
            ),
            ?assertMatch(
                {error, #{code := unsupported_field}},
                thinwrap_location:route(C, #{
                    waypoints => ?THREE,
                    optimize => true,
                    departure_time => ?WHEN,
                    traffic_mode => Mode
                })
            ),
            ?assertEqual([], ?F:calls(P))
        end)
     || Mode <- [traffic, live]
    ].

%% No traffic variant exists there, so traffic + time is treated exactly like none.
matrix_and_optimization_drop_the_time_for_walking_and_cycling_test_() ->
    [
        ?_test(begin
            Travel = atom_to_binary(TravelMode),
            M = capture_matrix(#{
                departure_time => ?WHEN, traffic_mode => Mode, travel_mode => TravelMode
            }),
            ?assert(
                starts_with(?F:path_of(M), <<"/directions-matrix/v1/mapbox/", Travel/binary, "/">>)
            ),
            ?assertNot(has_query(M, <<"depart_at">>)),
            R = capture_route(#{
                waypoints => ?THREE,
                optimize => true,
                departure_time => ?WHEN,
                traffic_mode => Mode,
                travel_mode => TravelMode
            }),
            ?assert(
                starts_with(?F:path_of(R), <<"/optimized-trips/v1/mapbox/", Travel/binary, "/">>)
            ),
            ?assertNot(has_query(R, <<"depart_at">>))
        end)
     || Mode <- [traffic, live], TravelMode <- [walking, cycling]
    ].

%% Optimization v1 has no driving-traffic profile: traffic is ignored, and a
%% time under none is dropped.
optimization_is_plain_driving_test_() ->
    [
        ?_test(begin
            Req = capture_route(
                maps:merge(#{waypoints => ?THREE, optimize => true, traffic_mode => Mode}, When)
            ),
            ?assert(starts_with(?F:path_of(Req), <<"/optimized-trips/v1/mapbox/driving/">>)),
            ?assertNot(has_query(Req, <<"depart_at">>))
        end)
     || {Mode, When} <- [
            {none, #{departure_time => ?WHEN}}, {traffic, #{}}, {live, #{}}
        ]
    ].

live_alias_sends_the_same_request_as_traffic_test_() ->
    Wire = fun(Mode, When) ->
        R = capture_route(maps:merge(#{waypoints => ?TWO, traffic_mode => Mode}, When)),
        M =
            case When of
                %% Mapbox Matrix refuses traffic at a time (covered above).
                #{departure_time := _} ->
                    undefined;
                _ ->
                    maps:with([method, url, body], capture_matrix(#{traffic_mode => Mode}))
            end,
        {maps:with([method, url, body], R), M}
    end,
    [
        ?_assertEqual(Wire(live, When), Wire(traffic, When))
     || When <- [#{}, #{departure_time => ?WHEN}]
    ].

%% ---------------------------------------------------------------------------
%% polyline_quality, steps/annotations, include, no-route and no-legs

-define(V120_BODY,
    <<"{\"code\":\"Ok\",\"routes\":[{\"geometry\":\"\",\"legs\":[{\"distance\":5000,\"duration\":300}],\"distance\":5000,\"duration\":300}],\"waypoints\":[{\"waypoint_index\":0},{\"waypoint_index\":1}]}">>
).

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

optimized_overview_follows_polyline_quality_test() ->
    {{ok, _}, P} = route(
        #{waypoints => ?TWO, optimize => true, polyline_quality => detailed},
        [?F:resp(200, ?TRIPS_OK2)]
    ),
    ?assertEqual(<<"full">>, ?F:qget(?F:last(P), <<"overview">>)).

%% Neither is read by any normalized field, and steps are the largest part of
%% a Mapbox response.
requests_neither_steps_nor_annotations_test() ->
    {{ok, _}, P} = route(#{waypoints => ?TWO}, [?F:resp(200, ?V120_BODY)]),
    ?assertNot(has_query(?F:last(P), <<"steps">>)),
    ?assertNot(has_query(?F:last(P), <<"annotations">>)).

%% The never-synthesized rule: if the provider does not return the value, the
%% key stays absent even though it was asked for. Absence is information.
duration_without_traffic_is_left_absent_test() ->
    {{ok, R}, _} = route(
        #{waypoints => ?TWO, include => [durationWithoutTraffic]}, [?F:resp(200, ?V120_BODY)]
    ),
    [Leg] = maps:get(legs, R),
    ?assertNot(maps:is_key(duration_without_traffic_seconds, Leg)),
    ?assertNot(maps:is_key(total_duration_without_traffic_seconds, R)),
    ?assertEqual(300.0, maps:get(duration_seconds, Leg)).

no_route_is_driven_by_the_envelope_code_test_() ->
    [
        ?_test(begin
            {Res, _} = route(#{waypoints => ?TWO}, [?F:resp(Status, j(#{code => Code}))]),
            ?assertMatch({error, #{code := no_route}}, Res)
        end)
     || {Status, Code} <- [{200, <<"NoRoute">>}, {422, <<"NoRoute">>}, {200, <<"NoSegment">>}]
    ].

a_route_with_no_legs_raises_no_route_with_the_status_test() ->
    Body =
        <<"{\"code\":\"Ok\",\"routes\":[{\"geometry\":\"\",\"legs\":[],\"distance\":5000,\"duration\":300}],\"waypoints\":[{\"waypoint_index\":0},{\"waypoint_index\":1}]}">>,
    {{error, E}, _} = route(#{waypoints => ?TWO}, [?F:resp(200, Body)]),
    ?assertMatch(#{code := no_route, status := 200}, E),
    %% Totals looked plausible; there was simply nothing to iterate.
    ?assert(contains(maps:get(provider_message, E), <<"no legs">>)).

%% ---------------------------------------------------------------------------
%% geometries / decoder coupling

-define(GEOM_TWO, [#{lat => 38.5, lng => -120.2}, #{lat => 40.7, lng => -120.95}]).

treats_overridden_polyline_as_precision5_test() ->
    P5 = thinwrap_location_polyline:encode(?GEOM_TWO),
    Body = j(#{
        code => <<"Ok">>,
        routes => [
            #{
                geometry => P5,
                legs => [#{distance => 1, duration => 1}],
                distance => 1,
                duration => 1
            }
        ]
    }),
    {{ok, R}, _} = route(
        #{waypoints => ?GEOM_TWO, passthrough => #{query => #{geometries => <<"polyline">>}}},
        [?F:resp(200, Body)]
    ),
    %% Emitted verbatim — NOT run through the precision-6 decoder, which would
    %% have divided every coordinate by 10.
    ?assertEqual(P5, maps:get(polyline, R)),
    {ok, [#{lat := Lat} | _]} = thinwrap_location_polyline:decode(maps:get(polyline, R)),
    ?assert(abs(Lat - 38.5) < 5.0e-5).

encodes_geojson_geometry_test() ->
    Body =
        <<"{\"code\":\"Ok\",\"routes\":[{\"geometry\":{\"type\":\"LineString\",\"coordinates\":[[-120.2,38.5],[-120.95,40.7]]},\"legs\":[{\"distance\":1,\"duration\":1}],\"distance\":1,\"duration\":1}]}">>,
    {{ok, R}, _} = route(
        #{waypoints => ?GEOM_TWO, passthrough => #{query => #{<<"geometries">> => <<"geojson">>}}},
        [?F:resp(200, Body)]
    ),
    ?assertEqual(thinwrap_location_polyline:encode(?GEOM_TWO), maps:get(polyline, R)).

malformed_geojson_yields_empty_polyline_test() ->
    Body =
        <<"{\"code\":\"Ok\",\"routes\":[{\"geometry\":{\"type\":\"LineString\",\"coordinates\":[[\"x\",\"y\"]]},\"legs\":[{\"distance\":1,\"duration\":1}],\"distance\":5000,\"duration\":1}]}">>,
    {{ok, R}, _} = route(
        #{waypoints => ?GEOM_TWO, passthrough => #{query => #{geometries => <<"geojson">>}}},
        [?F:resp(200, Body)]
    ),
    ?assertEqual(<<>>, maps:get(polyline, R)),
    %% The route itself is still returned.
    ?assertEqual(5000.0, maps:get(total_distance_meters, R)).

%% ---------------------------------------------------------------------------
%% Default lists

matrix_annotations_are_the_constant_test() ->
    {C, P} = cfg([?F:resp(200, ?MATRIX_OK)]),
    {ok, _} = thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]}),
    ?assertEqual(
        iolist_to_binary(lists:join(",", thinwrap_location_defaults:mapbox_matrix_annotations())),
        ?F:qget(?F:last(P), <<"annotations">>)
    ).

%% Mapbox documents only `duration` and `distance`, so there is nothing to
%% append; replacement is what passthrough offers here.
matrix_caller_annotations_replace_the_default_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"code\":\"Ok\",\"durations\":[[60]]}">>)]),
    ?assertMatch(
        {error, #{code := unknown}},
        thinwrap_location:matrix(C, #{
            origins => [ll(1, 1)],
            destinations => [ll(2, 2)],
            passthrough => #{query => #{annotations => <<"duration">>}}
        })
    ),
    ?assertEqual(<<"duration">>, ?F:qget(?F:last(P), <<"annotations">>)).

%% ---------------------------------------------------------------------------
%% Error contract: misuse raises badarg; request data is a connector error

vocabulary_misuse_is_badarg_test_() ->
    {C, _} = cfg([]),
    Iso = #{center => ll(1, 1), type => time, values => [600]},
    [
        ?_assertError({badarg, _}, thinwrap_location:route(C, #{waypoints => ?TWO, K => V}))
     || {K, V} <- [
            {travel_mode, flying},
            {travel_mode, <<"walking">>},
            {traffic_mode, 'rush-hour'},
            {traffic_mode, true},
            {polyline_quality, ultra},
            {include, [bogus]},
            {include, durationWithoutTraffic},
            {departure_time, 1.5}
        ]
    ] ++
        [
            ?_assertError(
                {badarg, _},
                thinwrap_location:matrix(C, #{
                    origins => [ll(1, 1)], destinations => [ll(2, 2)], K => V
                })
            )
         || {K, V} <- [{travel_mode, flying}, {traffic_mode, 0}]
        ] ++
        [
            ?_assertError({badarg, _}, thinwrap_location:isochrone(C, Iso#{K => V}))
         || {K, V} <- [{type, bogus}, {travel_mode, 2}, {values, [<<"600">>]}]
        ] ++
        [
            ?_assertError(
                {badarg, _},
                thinwrap_location:place_details(C, #{place_id => <<"p">>, include => V})
            )
         || V <- [[bogus], name, 5]
        ] ++
        [
            ?_assertError(
                {badarg, _}, thinwrap_location:route(#{provider => mapbox}, #{waypoints => ?TWO})
            ),
            ?_assertError(
                {badarg, _},
                thinwrap_location:route(#{provider => mapbox, api_key => <<"k">>}, #{
                    waypoints => ?TWO
                })
            )
        ].

fewer_than_two_waypoints_is_invalid_request_test_() ->
    [
        ?_test(begin
            {C, P} = cfg([]),
            ?assertMatch(
                {error, #{code := invalid_request}},
                thinwrap_location:route(C, #{waypoints => Wps, optimize => Optimize})
            ),
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

access_token_fun_is_resolved_at_the_point_of_use_test() ->
    {C, P} = ?F:config(
        #{provider => mapbox, access_token => fun() -> <<"from-fun">> end},
        [?F:resp(200, ?DIRECTIONS_OK)]
    ),
    {ok, _} = thinwrap_location:route(C, #{waypoints => ?TWO}),
    ?assertEqual(<<"from-fun">>, ?F:qget(?F:last(P), <<"access_token">>)).
