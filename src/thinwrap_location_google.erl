-module(thinwrap_location_google).
-moduledoc false.

%% Google: routing (Routes v2 computeRoutes), matrix (computeRouteMatrix,
%% NDJSON), geocoding (Geocoding API), autocomplete + place details (Places
%% API New).

-export([route/2, matrix/2, geocode/2, reverse_geocode/2, autocomplete/2, place_details/2]).

-define(ROUTES_URL, <<"https://routes.googleapis.com/directions/v2:computeRoutes">>).
-define(MATRIX_URL, <<"https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix">>).
-define(GEOCODE_URL, <<"https://maps.googleapis.com/maps/api/geocode/json">>).
-define(AUTOCOMPLETE_URL, <<"https://places.googleapis.com/v1/places:autocomplete">>).
-define(PLACE_DETAILS_URL, <<"https://places.googleapis.com/v1/places">>).

%% ---------------------------------------------------------------------------
%% Routing

-doc false.
-spec route(thinwrap_location:config(), map()) -> thinwrap_location:route_result().
route(Config, #{waypoints := Wps} = I) ->
    length(Wps) >= 2 orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<"Google Routing requires at least two waypoints">>
            )
        ),
    RoundTrip = maps:get(is_round_trip, I),
    First = hd(Wps),
    Last = lists:last(Wps),
    Destination =
        case RoundTrip of
            true -> First;
            false -> Last
        end,
    InterSrc =
        case RoundTrip of
            true -> tl(Wps);
            false -> lists:droplast(tl(Wps))
        end,
    Intermediates = [latlng(W) || W <- InterSrc],
    Reorder =
        maps:get(optimize, I) orelse maps:get(optimize_fixed_origin, I) orelse
            maps:get(optimize_fixed_destination, I) orelse RoundTrip,
    TravelMode = travel_mode(maps:get(travel_mode, I)),
    Traffic = thinwrap_location_util:traffic_requested(maps:get(traffic_mode, I)),
    Body0 = #{
        <<"origin">> => latlng(First),
        <<"destination">> => latlng(Destination),
        <<"travelMode">> => TravelMode,
        <<"polylineEncoding">> => <<"ENCODED_POLYLINE">>,
        %% OVERVIEW is Google's own default; naming it makes the normalized
        %% default visible in the request and lets `detailed` opt up.
        <<"polylineQuality">> =>
            case maps:get(polyline_quality, I) of
                detailed -> <<"HIGH_QUALITY">>;
                simplified -> <<"OVERVIEW">>
            end
    },
    Body = maps:merge(
        Body0,
        maps:from_list(
            %% TRAFFIC_AWARE is a Pro-tier SKU feature, so it follows the
            %% explicit traffic_mode opt-in, never the presence of a departure_time.
            routing_preference_field(TravelMode, Traffic) ++
                [{<<"intermediates">>, Intermediates} || Intermediates =/= []] ++
                [{<<"optimizeWaypointOrder">>, true} || Reorder, Intermediates =/= []] ++
                departure_time_field(Traffic, I) ++
                [
                    {<<"routeModifiers">>, #{
                        <<"avoidTolls">> => maps:get(avoid_tolls, I),
                        <<"avoidFerries">> => maps:get(avoid_ferries, I),
                        <<"avoidHighways">> => maps:get(avoid_highways, I)
                    }}
                 || maps:get(avoid_tolls, I) orelse maps:get(avoid_ferries, I) orelse
                        maps:get(avoid_highways, I)
                ]
        )
    ),
    %% The field mask is mandatory AND governs the response size, so it is built
    %% from what the caller asked for.
    WantsStatic = lists:member(durationWithoutTraffic, maps:get(include, I)),
    Mask =
        thinwrap_location_defaults:google_routes_field_mask() ++
            case WantsStatic of
                true ->
                    thinwrap_location_defaults:google_routes_field_mask_duration_without_traffic();
                false ->
                    []
            end ++
            case Reorder of
                true -> thinwrap_location_defaults:google_routes_field_mask_waypoint_order();
                false -> []
            end,
    Headers = #{
        <<"X-Goog-Api-Key">> => key(Config),
        <<"X-Goog-FieldMask">> => join(Mask)
    },
    #{status := Status, headers := RH, body := RB} =
        post_json(Config, ?ROUTES_URL, Body, Headers, I),
    Raw = thinwrap_location_json:decode(RB),
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(rpc_error(Status, RH, Raw)),
    Route =
        case thinwrap_location_json:get(Raw, <<"routes">>) of
            [R | _] ->
                R;
            %% "No route" is HTTP 200 with routes absent or empty, not an error status.
            _ ->
                thinwrap_location_error:fail(
                    thinwrap_location_error:classified(
                        no_route, Status, Raw, <<"Google Routing returned no routes">>
                    )
                )
        end,
    RawLegs = thinwrap_location_json:get(Route, <<"legs">>),
    (is_map(Route) andalso
        lists:all(fun is_map/1, thinwrap_location_util:list_or_empty(RawLegs))) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status, Raw, <<"Google Routing returned a malformed route">>
            )
        ),
    Legs = [
        thinwrap_location_util:put_opt(
            duration_without_traffic_seconds,
            static_duration(WantsStatic, thinwrap_location_json:get(L, <<"staticDuration">>)),
            #{
                distance_meters => thinwrap_location_json:num(
                    thinwrap_location_json:get(L, <<"distanceMeters">>)
                ),
                duration_seconds => parse_duration(
                    thinwrap_location_json:str(thinwrap_location_json:get(L, <<"duration">>))
                )
            }
        )
     || L <- thinwrap_location_util:list_or_empty(RawLegs)
    ],
    ok = thinwrap_location_util:assert_route_has_legs(
        length(Legs), length(Wps), <<"Google Routing">>, Raw, Status
    ),
    Result0 = #{
        legs => Legs,
        total_distance_meters => thinwrap_location_json:num(
            thinwrap_location_json:get(Route, <<"distanceMeters">>)
        ),
        total_duration_seconds => parse_duration(
            thinwrap_location_json:str(thinwrap_location_json:get(Route, <<"duration">>))
        ),
        polyline => thinwrap_location_json:str(
            thinwrap_location_json:path(Route, [<<"polyline">>, <<"encodedPolyline">>])
        ),
        raw => Raw
    },
    Result1 = thinwrap_location_util:put_opt(
        waypoint_order, waypoint_order(Route, RoundTrip, length(Wps)), Result0
    ),
    thinwrap_location_util:put_opt(
        total_duration_without_traffic_seconds,
        static_duration(WantsStatic, thinwrap_location_json:get(Route, <<"staticDuration">>)),
        Result1
    ).

%% Google rejects routingPreference for WALK/BICYCLE.
routing_preference_field(TravelMode, Traffic) ->
    [
        {<<"routingPreference">>, routing_preference(Traffic)}
     || lists:member(TravelMode, [<<"DRIVE">>, <<"TWO_WHEELER">>])
    ].

%% Google rejects a timestamp on TRAFFIC_UNAWARE requests (400 "Timestamp
%% cannot be set for TRAFFIC_UNAWARE routing mode."), and an unaware duration
%% is time-independent anyway.
departure_time_field(Traffic, I) ->
    [
        {<<"departureTime">>, thinwrap_location_util:iso_string(DT, <<"departure_time">>)}
     || Traffic, DT <- [maps:get(departure_time, I, undefined)], DT =/= undefined
    ].

%% An optional binary input sent under `Name` only when non-empty.
opt_field(Name, Key, I) ->
    [{Name, V} || V <- [maps:get(Key, I, <<>>)], V =/= <<>>].

%% POST a JSON body with the caller's passthrough merged in.
post_json(Config, Url, Body, Headers, I) ->
    {MBody, MHeaders, MQuery} = thinwrap_location_passthrough:merge(Body, Headers, [], I),
    thinwrap_location_http:send_post_json(Config, Url, MBody, MHeaders, MQuery).

%% A non-2xx from the Routes or Places (New) APIs, which share the google.rpc
%% error shape.
rpc_error(Status, RH, Raw) ->
    thinwrap_location_error:provider_error(
        Status, RH, Raw, map_vendor_error(Status, Raw), error_message(Raw)
    ).

%% Only when asked for AND actually returned — never synthesized from
%% `duration`, so absence stays meaningful.
static_duration(true, S) when is_binary(S), S =/= <<>> -> parse_duration(S);
static_duration(_, _) -> undefined.

%% Canonical waypoint_order = the full visiting sequence of INPUT indices.
%% When Google declines to optimize it answers [-1], which projects to
%% [0, 0, N-1] — a corrupt ordering. Omit unless a complete permutation.
waypoint_order(Route, RoundTrip, N) ->
    case thinwrap_location_json:get(Route, <<"optimizedIntermediateWaypointIndex">>) of
        Oiwi when is_list(Oiwi) ->
            Mid = [
                case is_integer(X) of
                    true -> X + 1;
                    false -> X
                end
             || X <- Oiwi
            ],
            Candidate =
                case RoundTrip of
                    true -> [0 | Mid];
                    false -> [0 | Mid] ++ [N - 1]
                end,
            case thinwrap_location_util:is_complete_waypoint_order(Candidate, N) of
                true -> Candidate;
                false -> undefined
            end;
        _ ->
            undefined
    end.

%% ---------------------------------------------------------------------------
%% Matrix

-doc false.
-spec matrix(thinwrap_location:config(), map()) -> thinwrap_location:matrix_result().
matrix(Config, #{origins := Os, destinations := Ds} = I) ->
    (Os =/= [] andalso Ds =/= []) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<"Google Matrix requires at least one origin and one destination">>
            )
        ),
    TravelMode = travel_mode(maps:get(travel_mode, I)),
    Traffic = thinwrap_location_util:traffic_requested(maps:get(traffic_mode, I)),
    Body = maps:merge(
        #{
            <<"origins">> => [#{<<"waypoint">> => latlng(O)} || O <- Os],
            <<"destinations">> => [#{<<"waypoint">> => latlng(D)} || D <- Ds],
            <<"travelMode">> => TravelMode
        },
        maps:from_list(
            %% Route Matrix bills PER ELEMENT, so deriving TRAFFIC_AWARE from a
            %% departure_time would move every element onto Pro pricing at once.
            routing_preference_field(TravelMode, Traffic) ++
                [{<<"routeModifiers">>, #{<<"avoidTolls">> => true}} || maps:get(avoid_tolls, I)] ++
                departure_time_field(Traffic, I)
        )
    ),
    Headers = #{
        <<"X-Goog-Api-Key">> => key(Config),
        <<"X-Goog-FieldMask">> => join(thinwrap_location_defaults:google_matrix_field_mask())
    },
    #{status := Status, headers := RH, body := RB} =
        post_json(Config, ?MATRIX_URL, Body, Headers, I),
    %% The 2xx body is NDJSON, so only an error body is decoded as one document.
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(rpc_error(Status, RH, thinwrap_location_json:decode(RB))),
    Elements = parse_ndjson(Status, RB),
    %% One element per origin x destination pair, so a 2xx with none is a
    %% truncated or empty response — not a matrix with no routes.
    Elements =/= [] orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(Status, RB, <<"Google Matrix returned no elements">>)
        ),
    Cells = [
        #{
            origin_index => trunc(
                thinwrap_location_json:num(thinwrap_location_json:get(E, <<"originIndex">>))
            ),
            destination_index => trunc(
                thinwrap_location_json:num(thinwrap_location_json:get(E, <<"destinationIndex">>))
            ),
            distance_meters => thinwrap_location_json:num(
                thinwrap_location_json:get(E, <<"distanceMeters">>)
            ),
            duration_seconds => parse_duration(
                thinwrap_location_json:str(thinwrap_location_json:get(E, <<"duration">>))
            )
        }
     || E <- Elements, is_map(E), cell_successful(E)
    ],
    #{cells => Cells, raw => Elements}.

parse_ndjson(Status, Bin) ->
    case string:trim(Bin) of
        <<>> ->
            [];
        <<"[", _/binary>> = Trimmed ->
            case thinwrap_location_json:decode(Trimmed) of
                L when is_list(L) -> L;
                _ -> parse_lines(Status, Trimmed)
            end;
        Trimmed ->
            parse_lines(Status, Trimmed)
    end.

parse_lines(Status, Text) ->
    Lines = [string:trim(L) || L <- binary:split(Text, <<"\n">>, [global])],
    [
        case thinwrap_location_json:decode(Line) of
            undefined ->
                thinwrap_location_error:fail(
                    thinwrap_location_error:unknown(
                        Status, Line, <<"Google Matrix returned an unparseable NDJSON line">>
                    )
                );
            El ->
                El
        end
     || Line <- Lines, Line =/= <<>>
    ].

%% A routable element carries at least `condition: ROUTE_EXISTS`; one with
%% neither status nor condition says nothing about reachability, and reading
%% its absent distance/duration would fabricate a 0 m / 0 s cell. `condition`
%% is independent of `status`: status-OK with ROUTE_NOT_FOUND is a failed cell.
cell_successful(E) ->
    Status = thinwrap_location_json:get(E, <<"status">>),
    Condition = thinwrap_location_json:get(E, <<"condition">>),
    StatusOk =
        case Status of
            #{} ->
                case thinwrap_location_json:get(Status, <<"code">>) of
                    undefined -> true;
                    C -> thinwrap_location_json:num(C) == 0
                end;
            _ ->
                true
        end,
    not (Status =:= undefined andalso Condition =:= undefined) andalso StatusOk andalso
        (Condition =:= undefined orelse Condition =:= <<"ROUTE_EXISTS">>).

%% ---------------------------------------------------------------------------
%% Geocoding

-doc false.
-spec geocode(thinwrap_location:config(), map()) -> thinwrap_location:geocode_result().
geocode(Config, #{address := Address} = I) ->
    Filter = maps:get(country_filter, I, []),
    [
        thinwrap_location_error:fail(thinwrap_location_error:invalid_request(invalid_country(C)))
     || C <- Filter, not iso_alpha2(C)
    ],
    %% `components=country:A|country:B` is not an OR: Google applies the first
    %% country only and pads the results with unrelated matches.
    case Filter of
        [_, _ | _] ->
            thinwrap_location_error:fail(
                thinwrap_location_error:unsupported_option(
                    iolist_to_binary([
                        "Google geocoding honours a single countryFilter entry only (received ",
                        integer_to_binary(length(Filter)),
                        "); multiple country components are not OR-ed"
                    ])
                )
            );
        _ ->
            ok
    end,
    Query =
        [{<<"address">>, Address}, {<<"key">>, key(Config)}] ++
            [{<<"components">>, <<"country:", C/binary>>} || C <- Filter] ++
            opt_field(<<"language">>, language, I),
    geocode_get(Config, Query, I).

-doc false.
-spec reverse_geocode(thinwrap_location:config(), map()) -> thinwrap_location:geocode_result().
reverse_geocode(Config, #{location := Loc} = I) ->
    Query =
        [{<<"latlng">>, thinwrap_location_util:to_lat_lng(Loc)}, {<<"key">>, key(Config)}] ++
            opt_field(<<"language">>, language, I),
    geocode_get(Config, Query, I).

geocode_get(Config, Query, I) ->
    {_, MHeaders, MQuery} = thinwrap_location_passthrough:merge(#{}, #{}, Query, I),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_location_http:send_get(Config, ?GEOCODE_URL, MHeaders, MQuery),
    Raw = thinwrap_location_json:decode(RB),
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:provider_error(
                Status,
                RH,
                Raw,
                geo_map_vendor_error(
                    Status,
                    thinwrap_location_json:str(thinwrap_location_json:get(Raw, <<"status">>)),
                    Raw
                ),
                thinwrap_location_json:str(thinwrap_location_json:get(Raw, <<"error_message">>))
            )
        ),
    enforce_status(Status, Raw),
    #{candidates => normalize_candidates(Raw), raw => Raw}.

enforce_status(Status, Raw) ->
    case thinwrap_location_json:str(thinwrap_location_json:get(Raw, <<"status">>)) of
        S when S =:= <<"OK">>; S =:= <<"ZERO_RESULTS">> ->
            ok;
        S ->
            Pm =
                case
                    thinwrap_location_json:str(thinwrap_location_json:get(Raw, <<"error_message">>))
                of
                    <<>> -> S;
                    M -> M
                end,
            thinwrap_location_error:fail(
                thinwrap_location_error:classified(
                    geo_map_vendor_error(Status, S, Raw), Status, Raw, Pm
                )
            )
    end.

normalize_candidates(Raw) ->
    lists:filtermap(
        fun(R) ->
            Geom = thinwrap_location_json:get(R, <<"geometry">>),
            Loc = thinwrap_location_json:get(Geom, <<"location">>),
            %% Skip a row without real coordinates rather than emit a
            %% fabricated (0,0) "Null Island" candidate.
            case
                {
                    thinwrap_location_json:num_opt(thinwrap_location_json:get(Loc, <<"lat">>)),
                    thinwrap_location_json:num_opt(thinwrap_location_json:get(Loc, <<"lng">>))
                }
            of
                {Lat, Lng} when is_float(Lat), is_float(Lng) ->
                    Vp = thinwrap_location_json:get(Geom, <<"viewport">>),
                    Cand0 = thinwrap_location_util:put_opt(
                        place_id,
                        thinwrap_location_util:nonempty(
                            thinwrap_location_json:str(
                                thinwrap_location_json:get(R, <<"place_id">>)
                            )
                        ),
                        #{
                            formatted_address => thinwrap_location_json:str(
                                thinwrap_location_json:get(R, <<"formatted_address">>)
                            ),
                            location => #{lat => Lat, lng => Lng}
                        }
                    ),
                    {true,
                        thinwrap_location_util:put_opt(
                            viewport,
                            viewport(
                                thinwrap_location_json:get(Vp, <<"southwest">>),
                                thinwrap_location_json:get(Vp, <<"northeast">>),
                                <<"lat">>,
                                <<"lng">>
                            ),
                            Cand0
                        )};
                _ ->
                    false
            end
        end,
        thinwrap_location_util:list_or_empty(thinwrap_location_json:get(Raw, <<"results">>))
    ).

%% A partially-populated viewport is dropped whole rather than filled with
%% defaults — a (0,0) corner would distort a consumer's bounds.
viewport(Sw, Ne, LatK, LngK) ->
    case
        {
            thinwrap_location_json:num_opt(thinwrap_location_json:get(Sw, LatK)),
            thinwrap_location_json:num_opt(thinwrap_location_json:get(Sw, LngK)),
            thinwrap_location_json:num_opt(thinwrap_location_json:get(Ne, LatK)),
            thinwrap_location_json:num_opt(thinwrap_location_json:get(Ne, LngK))
        }
    of
        {A, B, C, D} when is_float(A), is_float(B), is_float(C), is_float(D) ->
            #{southwest => #{lat => A, lng => B}, northeast => #{lat => C, lng => D}};
        _ ->
            undefined
    end.

%% ---------------------------------------------------------------------------
%% Autocomplete (Places API New)

-doc false.
-spec autocomplete(thinwrap_location:config(), map()) -> thinwrap_location:autocomplete_result().
autocomplete(Config, #{input := Text} = I) ->
    Region = included_region_codes(maps:get(country_filter, I, [])),
    Bias =
        case maps:get(location, I, undefined) of
            undefined ->
                [];
            #{lat := Lat, lng := Lng} ->
                Circle0 = #{<<"center">> => #{<<"latitude">> => Lat, <<"longitude">> => Lng}},
                Circle =
                    case maps:get(radius, I, undefined) of
                        undefined -> Circle0;
                        R -> Circle0#{<<"radius">> => R}
                    end,
                [{<<"locationBias">>, #{<<"circle">> => Circle}}]
        end,
    Body = maps:from_list(
        [{<<"input">>, Text}] ++
            opt_field(<<"languageCode">>, language, I) ++
            [{<<"includedRegionCodes">>, Region} || Region =/= []] ++
            %% A BODY field here but a QUERY param on place details — both
            %% verified live. Without it every keystroke bills as its own request.
            opt_field(<<"sessionToken">>, session_token, I) ++
            Bias
    ),
    Headers = #{<<"X-Goog-Api-Key">> => key(Config)},
    #{status := Status, headers := RH, body := RB} =
        post_json(Config, ?AUTOCOMPLETE_URL, Body, Headers, I),
    Raw = thinwrap_location_json:decode(RB),
    %% Places (New) speaks the google.rpc error shape: a bad key is 400
    %% INVALID_ARGUMENT with ErrorInfo reason API_KEY_INVALID, so the reason —
    %% not the status — decides auth_failed.
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(rpc_error(Status, RH, Raw)),
    %% proto3 JSON omits an empty repeated field: no predictions arrive as `{}`.
    Suggestions = thinwrap_location_error:require_list(
        Status, Raw, <<"suggestions">>, <<"Google Autocomplete">>, true
    ),
    Preds = lists:filtermap(
        fun(S) ->
            case thinwrap_location_json:get(S, <<"placePrediction">>) of
                undefined ->
                    false;
                Pred ->
                    %% Default-on for Places Autocomplete, so free to surface; only
                    %% emitted when Google gives a non-empty main part.
                    Sf = thinwrap_location_json:get(Pred, <<"structuredFormat">>),
                    Structured =
                        case
                            thinwrap_location_json:str(
                                thinwrap_location_json:path(Sf, [<<"mainText">>, <<"text">>])
                            )
                        of
                            <<>> ->
                                undefined;
                            Main ->
                                thinwrap_location_util:put_opt(
                                    secondary_text,
                                    thinwrap_location_util:nonempty(
                                        thinwrap_location_json:str(
                                            thinwrap_location_json:path(Sf, [
                                                <<"secondaryText">>, <<"text">>
                                            ])
                                        )
                                    ),
                                    #{main_text => Main}
                                )
                        end,
                    P0 = #{
                        description => thinwrap_location_json:str(
                            thinwrap_location_json:path(Pred, [<<"text">>, <<"text">>])
                        )
                    },
                    P1 = thinwrap_location_util:put_opt(
                        place_id,
                        thinwrap_location_util:nonempty(
                            thinwrap_location_json:str(
                                thinwrap_location_json:get(Pred, <<"placeId">>)
                            )
                        ),
                        P0
                    ),
                    {true, thinwrap_location_util:put_opt(structured_format, Structured, P1)}
            end
        end,
        Suggestions
    ),
    #{predictions => Preds, raw => Raw}.

%% `country_filter` (ISO 3166-1 alpha-2) to `includedRegionCodes`. This
%% endpoint documents ccTLD values, which diverge from ISO on the United
%% Kingdom (ISO GB is ccTLD uk), and caps the list at 15 — over that Google
%% rejects the whole request, so say so locally.
included_region_codes(Filter) ->
    Codes = [
        case iso_alpha2(C) of
            true ->
                case string:lowercase(C) of
                    <<"gb">> -> <<"uk">>;
                    Lower -> Lower
                end;
            false ->
                thinwrap_location_error:fail(
                    thinwrap_location_error:invalid_request(invalid_country(C))
                )
        end
     || C <- Filter, string:trim(C) =/= <<>>
    ],
    length(Codes) =< 15 orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                iolist_to_binary([
                    "Google Autocomplete accepts at most 15 countryFilter entries (received ",
                    integer_to_binary(length(Codes)),
                    ")"
                ])
            )
        ),
    Codes.

%% ---------------------------------------------------------------------------
%% Place details (Places API New)

-doc false.
-spec place_details(thinwrap_location:config(), map()) -> thinwrap_location:place_details_result().
place_details(Config, #{place_id := PlaceId} = I) ->
    %% The Place Details field mask is MANDATORY *and* selects the SKU tier:
    %% displayName is Pro, so it is requested only behind `include => [name]`.
    WantsName = lists:member(name, maps:get(include, I)),
    Mask =
        thinwrap_location_defaults:google_place_details_field_mask() ++
            case WantsName of
                true -> thinwrap_location_defaults:google_place_details_field_mask_name();
                false -> []
            end,
    Headers = #{<<"X-Goog-Api-Key">> => key(Config), <<"X-Goog-FieldMask">> => join(Mask)},
    Query =
        opt_field(<<"languageCode">>, language, I) ++
            %% Closes the session autocomplete opened, so it bills once.
            opt_field(<<"sessionToken">>, session_token, I),
    {_, MHeaders, MQuery} = thinwrap_location_passthrough:merge(#{}, Headers, Query, I),
    Url =
        <<?PLACE_DETAILS_URL/binary, "/", (thinwrap_location_util:quote_segment(PlaceId))/binary>>,
    #{status := Status, headers := RH, body := RB} = thinwrap_location_http:send_get(
        Config, Url, MHeaders, MQuery
    ),
    Raw = thinwrap_location_json:decode(RB),
    case Status of
        %% NOT_FOUND is "no such place". Places v1 answers most unknown ids
        %% (live-verified) with 400 INVALID_ARGUMENT, indistinguishable from a
        %% malformed one, so those stay an invalid_request error below.
        404 -> #{raw => Raw};
        _ -> place_details_result(Status, RH, Raw, WantsName)
    end.

place_details_result(Status, RH, Raw, WantsName) ->
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(rpc_error(Status, RH, Raw)),
    is_map(Raw) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status, Raw, <<"Google Place Details returned a malformed response body">>
            )
        ),
    Loc = thinwrap_location_json:get(Raw, <<"location">>),
    case
        {
            thinwrap_location_json:num_opt(thinwrap_location_json:get(Loc, <<"latitude">>)),
            thinwrap_location_json:num_opt(thinwrap_location_json:get(Loc, <<"longitude">>))
        }
    of
        {Lat, Lng} when is_float(Lat), is_float(Lng) ->
            Vp = thinwrap_location_json:get(Raw, <<"viewport">>),
            Cand0 = #{
                formatted_address => thinwrap_location_json:str(
                    thinwrap_location_json:get(Raw, <<"formattedAddress">>)
                ),
                location => #{lat => Lat, lng => Lng}
            },
            Cand1 = thinwrap_location_util:put_opt(
                place_id,
                thinwrap_location_util:nonempty(
                    thinwrap_location_json:str(thinwrap_location_json:get(Raw, <<"id">>))
                ),
                Cand0
            ),
            Cand = thinwrap_location_util:put_opt(
                viewport,
                viewport(
                    thinwrap_location_json:get(Vp, <<"low">>),
                    thinwrap_location_json:get(Vp, <<"high">>),
                    <<"latitude">>,
                    <<"longitude">>
                ),
                Cand1
            ),
            Name =
                case WantsName of
                    true ->
                        thinwrap_location_util:nonempty(
                            thinwrap_location_json:str(
                                thinwrap_location_json:path(Raw, [
                                    <<"displayName">>, <<"text">>
                                ])
                            )
                        );
                    false ->
                        undefined
                end,
            thinwrap_location_util:put_opt(name, Name, #{candidate => Cand, raw => Raw});
        %% Same rule as geocode candidates: never fabricate a (0,0) location.
        _ ->
            #{raw => Raw}
    end.

%% ---------------------------------------------------------------------------
%% Vendor error mapping

-define(AUTH_REASONS, [
    <<"API_KEY_INVALID">>,
    <<"API_KEY_SERVICE_BLOCKED">>,
    <<"API_KEY_HTTP_REFERRER_BLOCKED">>,
    <<"API_KEY_IP_ADDRESS_BLOCKED">>,
    <<"API_KEY_ANDROID_APP_BLOCKED">>,
    <<"API_KEY_IOS_APP_BLOCKED">>,
    <<"CREDENTIALS_MISSING">>,
    <<"ACCESS_TOKEN_EXPIRED">>,
    <<"ACCESS_TOKEN_SCOPE_INSUFFICIENT">>,
    <<"ACCESS_TOKEN_TYPE_UNSUPPORTED">>,
    <<"ACCOUNT_STATE_INVALID">>,
    <<"CONSUMER_INVALID">>,
    <<"CONSUMER_SUSPENDED">>,
    <<"USER_PROJECT_DENIED">>,
    <<"SERVICE_DISABLED">>,
    <<"BILLING_DISABLED">>
]).
-define(RATE_REASONS, [<<"RATE_LIMIT_EXCEEDED">>, <<"RESOURCE_QUOTA_EXCEEDED">>]).

error_message(Body) ->
    thinwrap_location_json:str(thinwrap_location_json:path(Body, [<<"error">>, <<"message">>])).

%% The machine-readable reason from a google.rpc.ErrorInfo entry in
%% error.details[], empty when absent.
error_reason(Body) ->
    Details = thinwrap_location_util:list_or_empty(
        thinwrap_location_json:path(Body, [<<"error">>, <<"details">>])
    ),
    Reasons = [
        R
     || D <- Details,
        thinwrap_location_json:str(thinwrap_location_json:get(D, <<"domain">>)) =:=
            <<"googleapis.com">> orelse
            ends_with(
                thinwrap_location_json:str(thinwrap_location_json:get(D, <<"@type">>)),
                <<"google.rpc.ErrorInfo">>
            ),
        R <- [thinwrap_location_json:str(thinwrap_location_json:get(D, <<"reason">>))],
        R =/= <<>>
    ],
    case Reasons of
        [R | _] -> R;
        [] -> <<>>
    end.

%% Lets a bad or blocked key surface as auth_failed even though Google
%% reports it as HTTP 400 INVALID_ARGUMENT.
reason_code(Reason) ->
    case {lists:member(Reason, ?AUTH_REASONS), lists:member(Reason, ?RATE_REASONS)} of
        {true, _} -> auth_failed;
        {_, true} -> rate_limited;
        _ -> undefined
    end.

map_vendor_error(Status, Body) ->
    case reason_code(error_reason(Body)) of
        undefined ->
            status_code(
                Status,
                thinwrap_location_json:str(
                    thinwrap_location_json:path(Body, [<<"error">>, <<"status">>])
                )
            );
        Code ->
            Code
    end.

status_code(401, _) -> auth_failed;
status_code(403, <<"QUOTA_EXCEEDED">>) -> rate_limited;
status_code(403, _) -> auth_failed;
status_code(429, _) -> rate_limited;
status_code(400, _) -> invalid_request;
status_code(S, _) when S >= 500, S < 600 -> provider_unavailable;
status_code(_, _) -> unknown.

%% The legacy Geocoding API reports `status` strings; should it answer in
%% the google.rpc shape instead, its ErrorInfo reason is honoured the same way.
geo_map_vendor_error(Status, GoogleStatus, Body) ->
    case reason_code(error_reason(Body)) of
        undefined -> geo_status_code(Status, GoogleStatus);
        Code -> Code
    end.

%% OVER_DAILY_LIMIT is an account problem (missing/invalid key, billing,
%% usage cap, payment method), not a burst: retrying does not help.
geo_status_code(_, <<"REQUEST_DENIED">>) -> auth_failed;
geo_status_code(_, <<"OVER_DAILY_LIMIT">>) -> auth_failed;
geo_status_code(_, <<"OVER_QUERY_LIMIT">>) -> rate_limited;
geo_status_code(_, <<"INVALID_REQUEST">>) -> invalid_request;
%% "The request may succeed if you try again."
geo_status_code(_, <<"UNKNOWN_ERROR">>) -> provider_unavailable;
geo_status_code(S, _) when S =:= 401; S =:= 403 -> auth_failed;
geo_status_code(429, _) -> rate_limited;
geo_status_code(400, _) -> invalid_request;
geo_status_code(S, _) when S >= 500, S < 600 -> provider_unavailable;
geo_status_code(_, _) -> unknown.

%% ---------------------------------------------------------------------------
%% Helpers

key(Config) -> thinwrap_location_input:secret(Config, api_key).

travel_mode(walking) -> <<"WALK">>;
travel_mode(cycling) -> <<"BICYCLE">>;
travel_mode(driving) -> <<"DRIVE">>.

routing_preference(true) -> <<"TRAFFIC_AWARE">>;
routing_preference(false) -> <<"TRAFFIC_UNAWARE">>.

latlng(#{lat := Lat, lng := Lng}) ->
    #{<<"location">> => #{<<"latLng">> => #{<<"latitude">> => Lat, <<"longitude">> => Lng}}}.

%% Google durations are `"123s"` (protobuf Duration JSON).
parse_duration(S) ->
    Num =
        case binary:last(<<" ", S/binary>>) of
            $s -> binary:part(S, 0, byte_size(S) - 1);
            _ -> S
        end,
    try
        binary_to_float(Num)
    catch
        error:badarg ->
            try
                float(binary_to_integer(Num))
            catch
                error:badarg -> 0.0
            end
    end.

iso_alpha2(<<A, B>>) -> is_alpha(A) andalso is_alpha(B);
iso_alpha2(_) -> false.

is_alpha(C) -> (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z).

invalid_country(C) ->
    <<"Invalid countryFilter entry: ", C/binary, " (expected ISO 3166-1 alpha-2)">>.

join(List) -> iolist_to_binary(lists:join(<<",">>, List)).

ends_with(Bin, Suffix) ->
    Size = byte_size(Bin) - byte_size(Suffix),
    Size >= 0 andalso binary:part(Bin, Size, byte_size(Suffix)) =:= Suffix.
