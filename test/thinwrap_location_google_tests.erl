-module(thinwrap_location_google_tests).

-include_lib("eunit/include/eunit.hrl").

-define(F, thinwrap_location_fake_transport).
-define(TWO, [#{lat => 40.7, lng => -74.0}, #{lat => 41.4, lng => -73.0}]).

cfg(Responses) -> ?F:config(#{provider => google, api_key => <<"k">>}, Responses).

ll(Lat, Lng) -> #{lat => Lat, lng => Lng}.

routing_complete_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"routes\":[{\"legs\":[{\"distanceMeters\":1000,\"duration\":\"600s\"}],\"distanceMeters\":1000,\"duration\":\"600s\",\"polyline\":{\"encodedPolyline\":\"abc\"}}]}">>
        )
    ]),
    {ok, R} = thinwrap_location:route(C, #{waypoints => ?TWO}),
    ?assertEqual(1000.0, maps:get(total_distance_meters, R)),
    ?assertEqual(600.0, maps:get(total_duration_seconds, R)),
    ?assertEqual(<<"abc">>, maps:get(polyline, R)),
    ?assertMatch([#{distance_meters := 1000.0}], maps:get(legs, R)),
    ?assertNot(maps:is_key(waypoint_order, R)),
    Last = ?F:last(P),
    ?assertEqual(
        <<"https://routes.googleapis.com/directions/v2:computeRoutes">>, maps:get(url, Last)
    ),
    ?assertEqual(<<"k">>, ?F:header(Last, <<"X-Goog-Api-Key">>)),
    ?assertMatch(#{<<"travelMode">> := <<"DRIVE">>}, ?F:body_json(Last)).

routing_waypoint_order_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"routes\":[{\"legs\":[{\"distanceMeters\":1,\"duration\":\"1s\"}],\"distanceMeters\":1,\"duration\":\"1s\",\"polyline\":{\"encodedPolyline\":\"x\"},\"optimizedIntermediateWaypointIndex\":[1,0]}]}">>
        )
    ]),
    {ok, R} = thinwrap_location:route(C, #{
        waypoints => [ll(1, 1), ll(2, 2), ll(3, 3), ll(4, 4)], optimize => true
    }),
    ?assertEqual([0, 2, 1, 3], maps:get(waypoint_order, R)),
    ?assertMatch(#{<<"optimizeWaypointOrder">> := true}, ?F:body_json(?F:last(P))).

routing_declined_optimization_is_omitted_test() ->
    {C, _} = cfg([
        ?F:resp(
            200,
            <<"{\"routes\":[{\"legs\":[{\"distanceMeters\":1,\"duration\":\"1s\"}],\"distanceMeters\":1,\"duration\":\"1s\",\"polyline\":{\"encodedPolyline\":\"x\"},\"optimizedIntermediateWaypointIndex\":[-1]}]}">>
        )
    ]),
    {ok, R} = thinwrap_location:route(C, #{
        waypoints => [ll(1, 1), ll(2, 2), ll(3, 3)], optimize => true
    }),
    ?assertNot(maps:is_key(waypoint_order, R)).

routing_too_few_test() ->
    {C, P} = cfg([]),
    ?assertMatch(
        {error, #{code := invalid_request}}, thinwrap_location:route(C, #{waypoints => [ll(1, 1)]})
    ),
    ?assertEqual([], ?F:calls(P)).

routing_error_mapping_test_() ->
    Cases = [
        {401, <<"{\"error\":{\"message\":\"no\"}}">>, #{}, auth_failed},
        {403, <<"{\"error\":{\"status\":\"QUOTA_EXCEEDED\"}}">>, #{}, rate_limited},
        {403, <<"{\"error\":{\"message\":\"denied\"}}">>, #{}, auth_failed},
        {400, <<"{\"error\":{\"message\":\"bad\"}}">>, #{}, invalid_request},
        {503, <<"{}">>, #{}, provider_unavailable},
        {429, <<"{\"error\":{\"message\":\"slow\"}}">>, #{<<"Retry-After">> => <<"12">>},
            rate_limited}
    ],
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(Status, Body, Headers)]),
            {error, E} = thinwrap_location:route(C, #{waypoints => ?TWO}),
            ?assertMatch(#{code := Want, status := Status}, E),
            case map_size(Headers) of
                0 ->
                    ok;
                _ ->
                    ?assertMatch(#{<<"retryAfter">> := <<"12">>}, maps:get(cause, E)),
                    ?assertNotEqual(
                        nomatch, binary:match(maps:get(provider_message, E), <<"12 seconds">>)
                    )
            end
        end)
     || {Status, Body, Headers, Want} <- Cases
    ].

reason_based_auth_mapping_test() ->
    BadKey =
        <<"{\"error\":{\"code\":400,\"status\":\"INVALID_ARGUMENT\",\"message\":\"API key not valid. Please pass a valid API key.\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"API_KEY_INVALID\",\"domain\":\"googleapis.com\",\"metadata\":{\"service\":\"routes.googleapis.com\"}}]}}">>,
    {C1, _} = cfg([?F:resp(400, BadKey)]),
    ?assertMatch(
        {error, #{code := auth_failed}},
        thinwrap_location:route(C1, #{waypoints => [ll(1, 1), ll(2, 2)]})
    ),
    {C2, _} = cfg([?F:resp(400, BadKey)]),
    ?assertMatch(
        {error, #{code := auth_failed}},
        thinwrap_location:matrix(C2, #{origins => [ll(1, 1)], destinations => [ll(2, 2)]})
    ),
    Quota =
        <<"{\"error\":{\"code\":400,\"status\":\"INVALID_ARGUMENT\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"RATE_LIMIT_EXCEEDED\",\"domain\":\"googleapis.com\"}]}}">>,
    {C3, _} = cfg([?F:resp(400, Quota)]),
    ?assertMatch(
        {error, #{code := rate_limited}},
        thinwrap_location:route(C3, #{waypoints => [ll(1, 1), ll(2, 2)]})
    ),
    {C4, _} = cfg([
        ?F:resp(400, <<"{\"error\":{\"message\":\"Origin and destination must be set.\"}}">>)
    ]),
    ?assertMatch(
        {error, #{code := invalid_request}},
        thinwrap_location:route(C4, #{waypoints => [ll(1, 1), ll(2, 2)]})
    ).

matrix_ndjson_test() ->
    Nd = <<
        "{\"originIndex\":0,\"destinationIndex\":0,\"distanceMeters\":1000,\"duration\":\"600s\",\"status\":{},\"condition\":\"ROUTE_EXISTS\"}\n"
        "{\"originIndex\":0,\"destinationIndex\":1,\"status\":{\"code\":3}}\n"
        "{\"originIndex\":1,\"destinationIndex\":0,\"distanceMeters\":2000,\"duration\":\"1200s\",\"status\":{},\"condition\":\"ROUTE_EXISTS\"}"
    >>,
    {C, _} = cfg([?F:resp(200, Nd)]),
    {ok, #{cells := Cells}} = thinwrap_location:matrix(C, #{
        origins => [ll(1, 1), ll(2, 2)], destinations => [ll(3, 3), ll(4, 4)]
    }),
    ?assertEqual(2, length(Cells)),
    ?assertMatch([#{distance_meters := 1000.0, duration_seconds := 600.0} | _], Cells).

matrix_element_without_status_or_condition_is_a_failed_cell_test() ->
    Nd = <<
        "{\"originIndex\":0,\"destinationIndex\":0,\"distanceMeters\":5,\"duration\":\"5s\",\"condition\":\"ROUTE_EXISTS\"}\n"
        "{\"originIndex\":0,\"destinationIndex\":1}"
    >>,
    {C, _} = cfg([?F:resp(200, Nd)]),
    {ok, #{cells := Cells}} = thinwrap_location:matrix(C, #{
        origins => [ll(1, 1)], destinations => [ll(3, 3), ll(4, 4)]
    }),
    ?assertEqual([{0, 0}], [{O, D} || #{origin_index := O, destination_index := D} <- Cells]).

matrix_with_no_elements_is_unknown_test_() ->
    [
        ?_test(begin
            {C, _} = cfg([?F:resp(200, Body)]),
            ?assertMatch(
                {error, #{code := unknown, status := 200}},
                thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(3, 3)]})
            )
        end)
     || Body <- [<<>>, <<"   \n">>, <<"[]">>]
    ].

matrix_non_finite_ndjson_token_is_unknown_with_status_test() ->
    {C, _} = cfg([?F:resp(200, <<"{\"originIndex\":0,\"distanceMeters\":NaN}">>)]),
    ?assertMatch(
        {error, #{code := unknown, status := 200}},
        thinwrap_location:matrix(C, #{origins => [ll(1, 1)], destinations => [ll(3, 3)]})
    ).

geocode_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"status\":\"OK\",\"results\":[{\"formatted_address\":\"New York, NY\",\"geometry\":{\"location\":{\"lat\":40.7,\"lng\":-74.0},\"viewport\":{\"southwest\":{\"lat\":40.4,\"lng\":-74.3},\"northeast\":{\"lat\":40.9,\"lng\":-73.7}}},\"place_id\":\"pid\"}]}">>
        )
    ]),
    {ok, #{candidates := [Cand]}} = thinwrap_location:geocode(C, #{
        address => <<"NYC">>, country_filter => [<<"US">>], language => <<"en">>
    }),
    ?assertMatch(
        #{
            formatted_address := <<"New York, NY">>,
            location := #{lat := 40.7},
            place_id := <<"pid">>,
            viewport := #{northeast := #{lat := 40.9}}
        },
        Cand
    ),
    ?assertEqual(<<"country:US">>, ?F:qget(?F:last(P), <<"components">>)),
    ?assertEqual(<<"en">>, ?F:qget(?F:last(P), <<"language">>)).

geocode_more_than_one_country_refused_before_any_request_test_() ->
    [
        ?_test(begin
            {C, P} = cfg([]),
            ?assertMatch(
                {error, #{code := unsupported_option}},
                thinwrap_location:geocode(C, #{
                    address => <<"Windsor">>, country_filter => Countries
                })
            ),
            ?assertEqual([], ?F:calls(P))
        end)
     || Countries <- [[<<"US">>, <<"CA">>], [<<"CA">>, <<"US">>]]
    ].

autocomplete_bad_key_is_auth_failed_test() ->
    Body =
        <<"{\"error\":{\"code\":400,\"message\":\"API key not valid. Please pass a valid API key.\",\"status\":\"INVALID_ARGUMENT\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"API_KEY_INVALID\",\"domain\":\"googleapis.com\",\"metadata\":{\"service\":\"places.googleapis.com\"}}]}}">>,
    {C, _} = cfg([?F:resp(400, Body)]),
    ?assertMatch(
        {error, #{
            code := auth_failed,
            status := 400,
            provider_message := <<"API key not valid. Please pass a valid API key.">>
        }},
        thinwrap_location:autocomplete(C, #{input => <<"Dizengoff">>})
    ).

autocomplete_plain_invalid_argument_stays_invalid_request_test() ->
    {C, _} = cfg([
        ?F:resp(
            400,
            <<"{\"error\":{\"code\":400,\"message\":\"Invalid input.\",\"status\":\"INVALID_ARGUMENT\"}}">>
        )
    ]),
    ?assertMatch(
        {error, #{code := invalid_request}}, thinwrap_location:autocomplete(C, #{input => <<"x">>})
    ).

geocode_http_error_honours_an_error_info_reason_test() ->
    Body =
        <<"{\"error\":{\"code\":400,\"message\":\"API key not valid.\",\"status\":\"INVALID_ARGUMENT\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"API_KEY_INVALID\",\"domain\":\"googleapis.com\"}]}}">>,
    {C, _} = cfg([?F:resp(400, Body)]),
    ?assertMatch(
        {error, #{code := auth_failed}}, thinwrap_location:geocode(C, #{address => <<"x">>})
    ).

geocode_in_body_status_error_test() ->
    {C, _} = cfg([?F:resp(200, <<"{\"status\":\"REQUEST_DENIED\",\"error_message\":\"bad key\"}">>)]),
    ?assertMatch(
        {error, #{code := auth_failed, provider_message := <<"bad key">>}},
        thinwrap_location:geocode(C, #{address => <<"x">>})
    ).

geocode_invalid_country_test() ->
    {C, _} = cfg([]),
    ?assertMatch(
        {error, #{code := invalid_request}},
        thinwrap_location:geocode(C, #{address => <<"x">>, country_filter => [<<"USA">>]})
    ).

reverse_geocode_test() ->
    {C, P} = cfg([
        ?F:resp(
            200,
            <<"{\"status\":\"OK\",\"results\":[{\"formatted_address\":\"Somewhere\",\"geometry\":{\"location\":{\"lat\":1,\"lng\":2}}}]}">>
        )
    ]),
    {ok, #{candidates := [#{formatted_address := <<"Somewhere">>}]}} =
        thinwrap_location:reverse_geocode(C, #{location => ll(1, 2)}),
    ?assertEqual(<<"1,2">>, ?F:qget(?F:last(P), <<"latlng">>)).

autocomplete_test() ->
    {C, _} = cfg([
        ?F:resp(
            200,
            <<"{\"suggestions\":[{\"placePrediction\":{\"placeId\":\"pid\",\"text\":{\"text\":\"New York\"}}},{\"placePrediction\":{\"text\":{\"text\":\"Newark\"}}}]}">>
        )
    ]),
    {ok, #{predictions := [P1, P2]}} = thinwrap_location:autocomplete(C, #{input => <<"New">>}),
    ?assertEqual(#{description => <<"New York">>, place_id => <<"pid">>}, P1),
    ?assertEqual(#{description => <<"Newark">>}, P2).

autocomplete_empty_proto3_body_is_no_predictions_test() ->
    {C, _} = cfg([?F:resp(200, <<"{}">>)]),
    ?assertMatch(
        {ok, #{predictions := []}}, thinwrap_location:autocomplete(C, #{input => <<"zzz">>})
    ).

%% Google spells one concept two ways: a body field on autocomplete, a query
%% param on place details (both verified live). Without them Autocomplete is
%% billed per keystroke instead of per session.
session_token_wire_spelling_test() ->
    Token = <<"3f2a1c58-9b4e-4d7a-8e21-6c5f0b7d9a34">>,
    {C1, P1} = cfg([
        ?F:resp(
            200,
            <<"{\"suggestions\":[{\"placePrediction\":{\"placeId\":\"p1\",\"text\":{\"text\":\"Diz\"}}}]}">>
        )
    ]),
    {ok, _} = thinwrap_location:autocomplete(C1, #{input => <<"Diz">>, session_token => Token}),
    ?assertMatch(#{<<"sessionToken">> := Token}, ?F:body_json(?F:last(P1))),
    ?assertEqual(<<>>, ?F:qget(?F:last(P1), <<"sessionToken">>)),
    {C2, P2} = cfg([
        ?F:resp(
            200,
            <<"{\"id\":\"p1\",\"formattedAddress\":\"Dizengoff St 50\",\"location\":{\"latitude\":32.0797,\"longitude\":34.7738}}">>
        )
    ]),
    {ok, #{candidate := #{place_id := <<"p1">>}}} =
        thinwrap_location:place_details(C2, #{place_id => <<"p1">>, session_token => Token}),
    ?assertEqual(Token, ?F:qget(?F:last(P2), <<"sessionToken">>)),
    {C3, P3} = cfg([?F:resp(200, <<"{\"suggestions\":[]}">>)]),
    {ok, _} = thinwrap_location:autocomplete(C3, #{input => <<"Diz">>}),
    ?assertNot(maps:is_key(<<"sessionToken">>, ?F:body_json(?F:last(P3)))).

place_details_unknown_place_omits_candidate_test() ->
    {C, _} = cfg([?F:resp(404, <<"{\"error\":{\"status\":\"NOT_FOUND\"}}">>)]),
    {ok, R} = thinwrap_location:place_details(C, #{place_id => <<"nope">>}),
    ?assertNot(maps:is_key(candidate, R)).

place_details_name_is_opt_in_test() ->
    Body =
        <<"{\"id\":\"p1\",\"formattedAddress\":\"A\",\"location\":{\"latitude\":1,\"longitude\":2},\"displayName\":{\"text\":\"Cafe\"}}">>,
    {C1, P1} = cfg([?F:resp(200, Body)]),
    {ok, R1} = thinwrap_location:place_details(C1, #{place_id => <<"p1">>}),
    ?assertNot(maps:is_key(name, R1)),
    ?assertEqual(
        nomatch, binary:match(?F:header(?F:last(P1), <<"X-Goog-FieldMask">>), <<"displayName">>)
    ),
    {C2, P2} = cfg([?F:resp(200, Body)]),
    {ok, R2} = thinwrap_location:place_details(C2, #{place_id => <<"p1">>, include => [name]}),
    ?assertEqual(<<"Cafe">>, maps:get(name, R2)),
    ?assertNotEqual(
        nomatch, binary:match(?F:header(?F:last(P2), <<"X-Goog-FieldMask">>), <<"displayName">>)
    ).

place_details_id_is_path_escaped_test() ->
    {C, P} = cfg([?F:resp(404, <<>>)]),
    {ok, _} = thinwrap_location:place_details(C, #{place_id => <<"a/b c">>}),
    ?assertEqual(<<"/v1/places/a%2Fb%20c">>, ?F:path_of(?F:last(P))).

geocoding_body_status_mapping_test_() ->
    [
        ?_test(begin
            Body = iolist_to_binary(
                json:encode(#{status => S, results => [], error_message => <<"m">>})
            ),
            {C, _} = cfg([?F:resp(200, Body)]),
            ?assertMatch(
                {error, #{code := Want, status := 200}},
                thinwrap_location:geocode(C, #{address => <<"x">>})
            )
        end)
     || {S, Want} <- [
            {<<"OVER_DAILY_LIMIT">>, auth_failed},
            {<<"UNKNOWN_ERROR">>, provider_unavailable},
            {<<"OVER_QUERY_LIMIT">>, rate_limited},
            {<<"REQUEST_DENIED">>, auth_failed}
        ]
    ].

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
            <<"{\"routes\":[{\"distanceMeters\":1,\"duration\":\"1s\",\"legs\":[null]}]}">>
        ]
    ].

routing_route_without_legs_is_an_error_test() ->
    {C, _} = cfg([?F:resp(200, <<"{\"routes\":[{\"distanceMeters\":1,\"duration\":\"1s\"}]}">>)]),
    ?assertMatch({error, #{code := no_route}}, thinwrap_location:route(C, #{waypoints => ?TWO})).

routing_no_routes_is_no_route_test() ->
    {C, _} = cfg([?F:resp(200, <<"{}">>)]),
    ?assertMatch(
        {error, #{code := no_route, status := 200}},
        thinwrap_location:route(C, #{waypoints => ?TWO})
    ).

traffic_is_opt_in_test() ->
    Ok = ?F:resp(
        200,
        <<"{\"routes\":[{\"legs\":[{\"distanceMeters\":1,\"duration\":\"1s\"}],\"distanceMeters\":1,\"duration\":\"1s\",\"polyline\":{\"encodedPolyline\":\"x\"}}]}">>
    ),
    {C1, P1} = cfg([Ok]),
    {ok, _} = thinwrap_location:route(C1, #{waypoints => ?TWO, departure_time => 1800000000}),
    B1 = ?F:body_json(?F:last(P1)),
    ?assertEqual(<<"TRAFFIC_UNAWARE">>, maps:get(<<"routingPreference">>, B1)),
    ?assertNot(maps:is_key(<<"departureTime">>, B1)),
    {C2, P2} = cfg([Ok]),
    {ok, _} = thinwrap_location:route(C2, #{
        waypoints => ?TWO, departure_time => 1800000000, traffic_mode => traffic
    }),
    B2 = ?F:body_json(?F:last(P2)),
    ?assertEqual(<<"TRAFFIC_AWARE">>, maps:get(<<"routingPreference">>, B2)),
    ?assertEqual(<<"2027-01-15T08:00:00.000Z">>, maps:get(<<"departureTime">>, B2)).

passthrough_overrides_field_mask_case_insensitively_test() ->
    {C, P} = cfg([?F:resp(200, <<"{\"routes\":[]}">>)]),
    _ = thinwrap_location:route(C, #{
        waypoints => ?TWO,
        passthrough => #{headers => #{<<"x-goog-fieldmask">> => <<"routes.duration">>}}
    }),
    Hs = maps:get(headers, ?F:last(P)),
    ?assertEqual([<<"routes.duration">>], [
        V
     || K := V <- Hs, string:lowercase(K) =:= <<"x-goog-fieldmask">>
    ]).
