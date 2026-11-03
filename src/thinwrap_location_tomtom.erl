-module(thinwrap_location_tomtom).
-moduledoc false.

%% TomTom: routing (Routing API calculateRoute), matrix (Matrix v2, sync up to
%% 100 cells, async above), geocoding + search + place by id (Search v2),
%% isochrone (calculateReachableRange, one call per break value).

-export([
    route/2, matrix/2, geocode/2, reverse_geocode/2, autocomplete/2, place_details/2, isochrone/2
]).

-define(ROUTE_URL, <<"https://api.tomtom.com/routing/1/calculateRoute">>).
-define(SYNC_MATRIX_URL, <<"https://api.tomtom.com/routing/matrix/2">>).
-define(ASYNC_MATRIX_URL, <<"https://api.tomtom.com/routing/matrix/2/async">>).
-define(GEOCODE_URL, <<"https://api.tomtom.com/search/2/geocode">>).
-define(REVERSE_URL, <<"https://api.tomtom.com/search/2/reverseGeocode">>).
-define(SEARCH_URL, <<"https://api.tomtom.com/search/2/search">>).
-define(PLACE_BY_ID_URL, <<"https://api.tomtom.com/search/2/place.json">>).
-define(REACHABLE_RANGE_URL, <<"https://api.tomtom.com/routing/1/calculateReachableRange">>).

%% TomTom's synchronous Matrix v2 accepts at most 100 cells by default; 200
%% only for a narrow departAt=any/historical/fastest/car-or-truck request with
%% no other parameters, and 2500 only on Enterprise plans. The async endpoint
%% takes up to 2500 on a standard plan, so anything past 100 goes there. The
%% 200 allowance is deliberately not used: it would hold only while traffic
%% stays historical, so a live request (or any extra option) of 101-200 cells
%% would be rejected.
-define(SYNC_CELL_THRESHOLD, 100).

%% ---------------------------------------------------------------------------
%% Routing

-doc false.
-spec route(thinwrap_location:config(), map()) -> thinwrap_location:route_result().
route(Config, #{waypoints := Wps} = I) ->
    length(Wps) >= 2 orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<"TomTom Routing requires at least two waypoints">>
            )
        ),
    %% computeBestOrder reorders intermediate waypoints while keeping the
    %% first/last fixed (an OPEN route); it has no closed round-trip mode.
    (not maps:get(is_round_trip, I)) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:new(unsupported_option, #{
                message =>
                    <<"TomTom route optimization does not support round trips (isRoundTrip)">>,
                provider_message =>
                    <<
                        "TomTom computeBestOrder optimizes an open route "
                        "(fixed first/last waypoint) and cannot return a closed round trip; "
                        "remove isRoundTrip or use a provider that supports it (e.g. Mapbox/OSRM)."
                    >>
            })
        ),
    Url =
        <<?ROUTE_URL/binary, "/", (thinwrap_location_util:join_coords(Wps, latlng, <<":">>))/binary,
            "/json">>,
    %% Any of the three flags means "reorder", as on every other provider.
    %% computeBestOrder always keeps BOTH the first and the last waypoint fixed;
    %% TomTom has no way to free one end, so a single fixed endpoint is
    %% honoured and the other end stays fixed too.
    WantsOrder =
        maps:get(optimize, I) orelse maps:get(optimize_fixed_origin, I) orelse
            maps:get(optimize_fixed_destination, I),
    %% noTrafficTravelTimeInSeconds only appears when computeTravelTimeFor=all
    %% is requested, and that asks TomTom for extra computed values — so unlike
    %% Google/HERE it is a real request change and stays strictly opt-in.
    WantsNoTraffic = lists:member(durationWithoutTraffic, maps:get(include, I)),
    Avoids = avoids(I),
    Query =
        [
            {<<"key">>, key(Config)},
            {<<"travelMode">>, travel_mode(maps:get(travel_mode, I))},
            {<<"routeType">>, <<"fastest">>},
            {<<"routeRepresentation">>, <<"polyline">>}
        ] ++
            [{<<"computeBestOrder">>, <<"true">>} || WantsOrder, length(Wps) > 2] ++
            %% TomTom's `traffic` defaults to ON at the vendor, so leaving it
            %% unset would contradict the normalized default of none; it is
            %% sent in both directions. TomTom routing has no time-independent
            %% mode: "the effect of historic traffic on effective road speeds is
            %% still incorporated" under traffic=false, and departAt=any is
            %% rejected (400 "traffic=false not allowed in combination with
            %% departAt=any"), so none keeps the caller's departAt and is an
            %% approximation here.
            [
                {<<"traffic">>,
                    case thinwrap_location_util:traffic_requested(maps:get(traffic_mode, I)) of
                        true -> <<"true">>;
                        false -> <<"false">>
                    end}
            ] ++
            [{<<"computeTravelTimeFor">>, <<"all">>} || WantsNoTraffic] ++
            [
                {<<"departAt">>, thinwrap_location_util:iso_string(DT, <<"departure_time">>)}
             || DT <- [maps:get(departure_time, I, undefined)], DT =/= undefined
            ] ++
            %% A list, so the key is repeated: calculateRoute rejects a
            %% comma-joined value with 400 "Invalid avoid value:
            %% [tollRoads,motorways]".
            [{<<"avoid">>, Avoids} || Avoids =/= []],
    {Status, Raw} = get_json(Config, Url, Query, I, true),
    Route =
        case thinwrap_location_json:get(Raw, <<"routes">>) of
            [R | _] ->
                R;
            Routes ->
                falsy(Routes) orelse malformed_route(Status, Raw),
                thinwrap_location_error:fail(
                    thinwrap_location_error:classified(
                        no_route, Status, Raw, <<"TomTom Routing returned no routes">>
                    )
                )
        end,
    RawLegs = thinwrap_location_json:get(Route, <<"legs">>),
    (is_map(Route) andalso
        lists:all(fun is_map/1, thinwrap_location_util:list_or_empty(RawLegs))) orelse
        malformed_route(Status, Raw),
    {Legs, PointLists} = lists:unzip([
        leg(L, WantsNoTraffic, Status, Raw)
     || L <- thinwrap_location_util:list_or_empty(RawLegs)
    ]),
    ok = thinwrap_location_util:assert_route_has_legs(
        length(Legs), length(Wps), <<"TomTom Routing">>, Raw, Status
    ),
    Summary = thinwrap_location_json:get(Route, <<"summary">>),
    {TotalLength, TotalTime} = length_and_time(Summary, Status, Raw),
    Result = thinwrap_location_util:put_opt(
        waypoint_order,
        waypoint_order(
            WantsOrder, thinwrap_location_json:get(Raw, <<"optimizedWaypoints">>), length(Wps)
        ),
        #{
            legs => Legs,
            total_distance_meters => TotalLength,
            total_duration_seconds => TotalTime,
            polyline => thinwrap_location_polyline:encode(lists:append(PointLists)),
            raw => Raw
        }
    ),
    thinwrap_location_util:put_opt(
        total_duration_without_traffic_seconds,
        no_traffic(WantsNoTraffic, Summary),
        Result
    ).

leg(L, WantsNoTraffic, Status, Raw) ->
    Summ = thinwrap_location_json:get(L, <<"summary">>),
    {Length, Time} = length_and_time(Summ, Status, Raw),
    Points = [
        case
            {
                thinwrap_location_json:num_opt(thinwrap_location_json:get(P, <<"latitude">>)),
                thinwrap_location_json:num_opt(thinwrap_location_json:get(P, <<"longitude">>))
            }
        of
            {Lat, Lng} when is_float(Lat), is_float(Lng) ->
                #{lat => Lat, lng => Lng};
            %% A 0-filled point would draw the route through (0,0).
            _ ->
                thinwrap_location_error:fail(
                    thinwrap_location_error:unknown(
                        Status, Raw, <<"TomTom Routing returned a route point without coordinates">>
                    )
                )
        end
     || P <- thinwrap_location_util:list_or_empty(thinwrap_location_json:get(L, <<"points">>))
    ],
    Leg = thinwrap_location_util:put_opt(
        duration_without_traffic_seconds,
        no_traffic(WantsNoTraffic, Summ),
        #{distance_meters => Length, duration_seconds => Time}
    ),
    {Leg, Points}.

no_traffic(true, Summary) ->
    thinwrap_location_json:num_opt(
        thinwrap_location_json:get(Summary, <<"noTrafficTravelTimeInSeconds">>)
    );
no_traffic(false, _) ->
    undefined.

%% A route or leg summary's lengthInMeters/travelTimeInSeconds. TomTom always
%% sends both, so a missing one is a malformed response, not a free, instant
%% trip.
length_and_time(Summary, Status, Raw) ->
    case summary_values(Summary) of
        {_, _} = LT ->
            LT;
        undefined ->
            thinwrap_location_error:fail(
                thinwrap_location_error:unknown(
                    Status,
                    Raw,
                    <<
                        "TomTom Routing returned a summary without "
                        "lengthInMeters/travelTimeInSeconds"
                    >>
                )
            )
    end.

%% A summary's `{lengthInMeters, travelTimeInSeconds}`, `undefined` unless
%% both are numbers.
summary_values(Summary) ->
    case
        {
            thinwrap_location_json:num_opt(
                thinwrap_location_json:get(Summary, <<"lengthInMeters">>)
            ),
            thinwrap_location_json:num_opt(
                thinwrap_location_json:get(Summary, <<"travelTimeInSeconds">>)
            )
        }
    of
        {L, T} when is_float(L), is_float(T) -> {L, T};
        _ -> undefined
    end.

%% optimizedWaypoints covers ONLY the intermediate waypoints (providedIndex
%% 0-based over intermediates, origin/destination excluded). Project to full
%% input indices and bracket with the fixed origin (0) and destination (N-1).
%% The projection is kept only if it is a complete permutation: a short,
%% duplicated or sentinel providedIndex list would otherwise silently drop or
%% repeat a waypoint.
waypoint_order(true, Ow, N) when is_list(Ow) ->
    Sorted = [
        W
     || {_, W} <- lists:keysort(1, [
            {thinwrap_location_json:num(thinwrap_location_json:get(W, <<"optimizedIndex">>)), W}
         || W <- Ow
        ])
    ],
    Mid = [
        trunc(thinwrap_location_json:num(thinwrap_location_json:get(W, <<"providedIndex">>))) + 1
     || W <- Sorted
    ],
    Candidate = [0 | Mid] ++ [N - 1],
    case thinwrap_location_util:is_complete_waypoint_order(Candidate, N) of
        true -> Candidate;
        false -> undefined
    end;
waypoint_order(_, _, _) ->
    undefined.

-spec malformed_route(integer(), term()) -> no_return().
malformed_route(Status, Raw) ->
    thinwrap_location_error:fail(
        thinwrap_location_error:unknown(
            Status, Raw, <<"TomTom Routing returned a malformed route">>
        )
    ).

%% ---------------------------------------------------------------------------
%% Matrix

-doc false.
-spec matrix(thinwrap_location:config(), map()) -> thinwrap_location:matrix_result().
matrix(Config, #{origins := Os, destinations := Ds} = I) ->
    (Os =/= [] andalso Ds =/= []) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<"TomTom Matrix requires at least one origin and one destination">>
            )
        ),
    case length(Os) * length(Ds) =< ?SYNC_CELL_THRESHOLD of
        true -> matrix_sync(Config, I);
        false -> matrix_async(Config, I)
    end.

build_request(Config, #{origins := Os, destinations := Ds} = I) ->
    Point = fun(#{lat := Lat, lng := Lng}) ->
        #{<<"point">> => #{<<"latitude">> => Lat, <<"longitude">> => Lng}}
    end,
    Traffic = thinwrap_location_util:traffic_requested(maps:get(traffic_mode, I)),
    TravelMode = matrix_travel_mode(maps:get(travel_mode, I)),
    DepartAt =
        case {Traffic, maps:get(departure_time, I, undefined)} of
            %% "historical" + a real departAt applies typical traffic for that
            %% time; departAt "any" is TomTom's time-independent average
            %% ("tailored to the use case where the time context is
            %% irrelevant"), which is what none promises — so the caller's time
            %% is dropped.
            {false, _} -> <<"any">>;
            %% departAt defaults to "any", which TomTom refuses to combine with
            %% live traffic (HTTP 400); live traffic only means something for
            %% "now".
            {true, undefined} -> <<"now">>;
            {true, DT} -> thinwrap_location_util:iso_string(DT, <<"departure_time">>)
        end,
    Options = maps:merge(
        #{
            <<"travelMode">> => TravelMode,
            %% Sent in both directions so traffic_mode is honoured: "historical"
            %% is TomTom's own default (it has no traffic-free option), "live"
            %% opts in.
            <<"traffic">> =>
                case Traffic of
                    true -> <<"live">>;
                    false -> <<"historical">>
                end,
            <<"departAt">> => DepartAt
        },
        maps:from_list([{<<"avoid">>, [<<"tollRoads">>]} || maps:get(avoid_tolls, I)])
    ),
    Body = #{
        <<"origins">> => [Point(O) || O <- Os],
        <<"destinations">> => [Point(D) || D <- Ds],
        <<"options">> => Options
    },
    {Body, [{<<"key">>, key(Config)}]}.

matrix_sync(Config, #{origins := Os, destinations := Ds} = I) ->
    {Body, Query} = build_request(Config, I),
    %% Validated even though the sync endpoint never polls: a timeoutMs that
    %% cannot be a deadline is a caller mistake either way, and it never goes
    %% on the wire.
    _ = thinwrap_location_matrix:poll_deadline(I),
    {MBody, MHeaders, MQuery} = thinwrap_location_passthrough:merge(
        Body, #{}, Query, thinwrap_location_matrix:strip_timeout(I)
    ),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_location_http:send_post_json(Config, ?SYNC_MATRIX_URL, MBody, MHeaders, MQuery),
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(http_error(Status, RH, RB, true)),
    normalize_cells(Status, RB, length(Os), length(Ds)).

matrix_async(Config, #{origins := Os, destinations := Ds} = I0) ->
    Deadline = thinwrap_location_matrix:poll_deadline(I0),
    I = thinwrap_location_matrix:strip_timeout(I0),
    JobId = submit(Config, I),
    ok = poll(Config, JobId, Deadline),
    retrieve(Config, JobId, length(Os), length(Ds)).

submit(Config, I) ->
    {Body, Query} = build_request(Config, I),
    {MBody, MHeaders, MQuery} = thinwrap_location_passthrough:merge(Body, #{}, Query, I),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_location_http:send_post_json(Config, ?ASYNC_MATRIX_URL, MBody, MHeaders, MQuery),
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(http_error(Status, RH, RB, true)),
    Decoded = thinwrap_location_json:decode(RB),
    case thinwrap_location_json:str(thinwrap_location_json:get(Decoded, <<"jobId">>)) of
        <<>> ->
            thinwrap_location_error:fail(
                thinwrap_location_error:unknown(
                    Status, Decoded, <<"TomTom Matrix submit response missing jobId">>
                )
            );
        JobId ->
            JobId
    end.

job_url(JobId) ->
    <<?ASYNC_MATRIX_URL/binary, "/", (thinwrap_location_util:quote_segment(JobId))/binary>>.

poll(Config, JobId, DeadlineMs) ->
    Sleep = maps:get(sleep, Config, fun timer:sleep/1),
    DeadlineAt = erlang:monotonic_time(millisecond) + DeadlineMs,
    poll_loop(Config, Sleep, JobId, DeadlineAt, thinwrap_location_matrix:poll_initial_delay_ms()).

poll_loop(Config, Sleep, JobId, DeadlineAt, Delay) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= DeadlineAt of
        true ->
            thinwrap_location_error:fail(
                thinwrap_location_error:new(matrix_polling_timeout, #{
                    message => <<"TomTom Matrix polling deadline exceeded">>,
                    provider_message => <<"jobId: ", JobId/binary>>,
                    cause => #{<<"jobId">> => JobId}
                })
            );
        false ->
            _ = Sleep(ceil(min(Delay, DeadlineAt - Now))),
            Next = min(
                thinwrap_location_matrix:poll_max_delay_ms(),
                round(Delay * thinwrap_location_matrix:poll_backoff())
            ),
            #{status := Status, headers := RH, body := RB} =
                thinwrap_location_http:send_get(Config, job_url(JobId), #{}, [
                    {<<"key">>, key(Config)}
                ]),
            thinwrap_location_util:ok_status(Status) orelse
                thinwrap_location_error:fail(http_error(Status, RH, RB, true)),
            Decoded = thinwrap_location_json:decode(RB),
            %% Matrix v2 async job states are Submitted | Validated |
            %% Completed | Failed. Success is "Completed" (there is no
            %% "Succeeded").
            case thinwrap_location_json:str(thinwrap_location_json:get(Decoded, <<"state">>)) of
                <<"Completed">> ->
                    ok;
                <<"Failed">> ->
                    thinwrap_location_error:fail(
                        thinwrap_location_error:new(provider_unavailable, #{
                            status => Status,
                            provider_message => <<"TomTom Matrix job failed">>,
                            cause => Decoded
                        })
                    );
                _ ->
                    poll_loop(Config, Sleep, JobId, DeadlineAt, Next)
            end
    end.

retrieve(Config, JobId, No, Nd) ->
    Resp0 = thinwrap_location_http:send_get(
        Config, <<(job_url(JobId))/binary, "/result">>, #{}, [{<<"key">>, key(Config)}]
    ),
    #{status := Status, headers := RH, body := RB} =
        case Resp0 of
            %% TomTom answers a large result (over 1,000,000 items) with 302
            %% and a temporary Location to download it from. The default
            %% transport never follows redirects, so the hop is taken here —
            %% once, and never cached, since TomTom says the URL may change.
            #{status := 302, headers := H0} ->
                Location =
                    case header(H0, <<"location">>) of
                        <<>> ->
                            thinwrap_location_error:fail(
                                thinwrap_location_error:unknown(
                                    302,
                                    undefined,
                                    <<"TomTom Matrix result redirect missing Location header">>
                                )
                            );
                        L ->
                            L
                    end,
                https(Location) orelse
                    thinwrap_location_error:fail(
                        thinwrap_location_error:unknown(
                            302,
                            undefined,
                            <<"TomTom Matrix result redirect must be an https URL">>
                        )
                    ),
                %% A complete download URL that needs no key and may be on a
                %% storage host outside TomTom, so the key is not forwarded.
                thinwrap_location_http:send_get(Config, Location, #{}, []);
            _ ->
                Resp0
        end,
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(http_error(Status, RH, RB, true)),
    normalize_cells(Status, RB, No, Nd).

normalize_cells(Status, Body, No, Nd) ->
    Raw = thinwrap_location_json:decode(Body),
    Entries = thinwrap_location_error:require_list(Status, Raw, <<"data">>, <<"TomTom Matrix">>),
    Cells = lists:filtermap(
        fun(E) ->
            Oi = thinwrap_location_json:get(E, <<"originIndex">>),
            Di = thinwrap_location_json:get(E, <<"destinationIndex">>),
            %% Without its indexes a cell cannot be placed; defaulting them to
            %% 0 would pin its value onto the first origin/destination.
            (is_index(Oi, No) andalso is_index(Di, Nd)) orelse
                thinwrap_location_error:fail(
                    thinwrap_location_error:unknown(
                        Status,
                        Raw,
                        <<"TomTom Matrix returned a cell without a valid origin/destination index">>
                    )
                ),
            Rs = thinwrap_location_json:get(E, <<"routeSummary">>),
            %% A failed cell carries `detailedError` instead of a summary. Like
            %% one missing either value, it is omitted rather than reported as
            %% 0 m / 0 s; an unroutable pair is not an error for the whole
            %% matrix.
            case summary_values(Rs) of
                {Dist, Dur} ->
                    {true, #{
                        origin_index => Oi,
                        destination_index => Di,
                        distance_meters => Dist,
                        duration_seconds => Dur
                    }};
                undefined ->
                    false
            end
        end,
        Entries
    ),
    #{cells => Cells, raw => Raw}.

is_index(V, Size) -> is_integer(V) andalso V >= 0 andalso V < Size.

%% ---------------------------------------------------------------------------
%% Geocoding (Search v2)

-doc false.
-spec geocode(thinwrap_location:config(), map()) -> thinwrap_location:geocode_result().
geocode(Config, #{address := Address} = I) ->
    Address =/= <<>> orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<"TomTom Geocoding requires a non-empty address">>
            )
        ),
    Url =
        <<?GEOCODE_URL/binary, "/", (thinwrap_location_util:quote_segment(Address))/binary,
            ".json">>,
    Query = [{<<"key">>, key(Config)}] ++ language(I) ++ country_set(I),
    {Raw, Results} = search_get(Config, Url, Query, I, <<"results">>, <<"TomTom Geocoding">>),
    #{
        candidates => [
            C
         || R <- Results,
            C <- [candidate(R)],
            C =/= undefined
        ],
        raw => Raw
    }.

-doc false.
-spec reverse_geocode(thinwrap_location:config(), map()) -> thinwrap_location:geocode_result().
reverse_geocode(Config, #{location := Loc} = I) ->
    Url = <<?REVERSE_URL/binary, "/", (thinwrap_location_util:to_lat_lng(Loc))/binary, ".json">>,
    Query = [{<<"key">>, key(Config)}] ++ language(I),
    {Raw, Addresses} = search_get(
        Config, Url, Query, I, <<"addresses">>, <<"TomTom Reverse Geocoding">>
    ),
    Cands = lists:filtermap(
        fun(A) ->
            %% `position` is a "lat,lon" string here, not an object.
            case
                binary:split(
                    thinwrap_location_json:str(thinwrap_location_json:get(A, <<"position">>)),
                    <<",">>,
                    [global]
                )
            of
                [LatS, LngS] ->
                    case {parse_number(LatS), parse_number(LngS)} of
                        {Lat, Lng} when is_float(Lat), is_float(Lng) ->
                            {true,
                                thinwrap_location_util:put_opt(
                                    place_id,
                                    thinwrap_location_util:nonempty(
                                        thinwrap_location_json:str(
                                            thinwrap_location_json:get(A, <<"id">>)
                                        )
                                    ),
                                    #{
                                        formatted_address =>
                                            thinwrap_location_json:str(
                                                thinwrap_location_json:path(A, [
                                                    <<"address">>, <<"freeformAddress">>
                                                ])
                                            ),
                                        location => #{lat => Lat, lng => Lng}
                                    }
                                )};
                        _ ->
                            false
                    end;
                _ ->
                    false
            end
        end,
        Addresses
    ),
    #{candidates => Cands, raw => Raw}.

-doc false.
-spec autocomplete(thinwrap_location:config(), map()) -> thinwrap_location:autocomplete_result().
autocomplete(Config, #{input := Text} = I) ->
    Text =/= <<>> orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<"TomTom Autocomplete requires a non-empty input">>
            )
        ),
    Url = <<?SEARCH_URL/binary, "/", (thinwrap_location_util:quote_segment(Text))/binary, ".json">>,
    Query =
        [{<<"key">>, key(Config)}, {<<"typeahead">>, <<"true">>}, {<<"limit">>, <<"5">>}] ++
            language(I) ++
            lists:append([
                [
                    {<<"lat">>, thinwrap_location_util:fmt_coord(Lat)},
                    {<<"lon">>, thinwrap_location_util:fmt_coord(Lng)}
                ]
             || #{lat := Lat, lng := Lng} <- [maps:get(location, I, undefined)]
            ]) ++
            [
                {<<"radius">>, thinwrap_location_util:fmt_coord(R)}
             || R <- [maps:get(radius, I, undefined)], R =/= undefined
            ] ++
            %% country_filter (ISO 3166-1 alpha-2) -> countrySet, the same
            %% translation as forward geocode.
            country_set(I),
    {Raw, Results} = search_get(Config, Url, Query, I, <<"results">>, <<"TomTom Search">>),
    #{predictions => [prediction(R) || R <- Results], raw => Raw}.

prediction(R) ->
    Free = thinwrap_location_json:str(
        thinwrap_location_json:path(R, [<<"address">>, <<"freeformAddress">>])
    ),
    PoiName = poi_name(R),
    %% Live-verified: `poi.name` is absent for street/address results,
    %% which have no distinct main part. structured_format is omitted
    %% there rather than guessed by splitting freeformAddress.
    {Desc, Structured} =
        case PoiName of
            <<>> ->
                {Free, undefined};
            _ ->
                {
                    <<PoiName/binary, ", ", Free/binary>>,
                    thinwrap_location_util:put_opt(
                        secondary_text, thinwrap_location_util:nonempty(Free), #{
                            main_text => PoiName
                        }
                    )
                }
        end,
    P0 = thinwrap_location_util:put_opt(
        place_id,
        thinwrap_location_util:nonempty(
            thinwrap_location_json:str(thinwrap_location_json:get(R, <<"id">>))
        ),
        #{description => Desc}
    ),
    thinwrap_location_util:put_opt(structured_format, Structured, P0).

poi_name(R) ->
    thinwrap_location_json:str(thinwrap_location_json:path(R, [<<"poi">>, <<"name">>])).

language(I) ->
    [{<<"language">>, L} || L <- [maps:get(language, I, <<>>)], L =/= <<>>].

country_set(I) ->
    case maps:get(country_filter, I, []) of
        [] -> [];
        Filter -> [{<<"countrySet">>, join(Filter)}]
    end.

%% The decoded body and its result list under `ListKey`, checked present.
search_get(Config, Url, Query, I, ListKey, Label) ->
    with_result_list(get_json(Config, Url, Query, I, false), ListKey, Label).

with_result_list({Status, Raw}, ListKey, Label) ->
    {Raw, thinwrap_location_error:require_list(Status, Raw, ListKey, Label)}.

%% GET with the caller's passthrough merged in. A non-2xx fails through
%% http_error/4; otherwise the status and the decoded body.
get_json(Config, Url, Query, I, With404) ->
    {_, Headers, MQuery} = thinwrap_location_passthrough:merge(#{}, #{}, Query, I),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_location_http:send_get(Config, Url, Headers, MQuery),
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(http_error(Status, RH, RB, With404)),
    {Status, thinwrap_location_json:decode(RB)}.

%% ---------------------------------------------------------------------------
%% Place details (place by id)

-doc false.
-spec place_details(thinwrap_location:config(), map()) -> thinwrap_location:place_details_result().
place_details(Config, #{place_id := PlaceId} = I) ->
    Query = [{<<"key">>, key(Config)}, {<<"entityId">>, PlaceId}] ++ language(I),
    {Status, Raw} = get_json(Config, ?PLACE_BY_ID_URL, Query, I, true),
    Results = thinwrap_location_error:require_list(
        Status, Raw, <<"results">>, <<"TomTom Place Details">>
    ),
    First =
        case Results of
            [F | _] -> F;
            [] -> null
        end,
    case candidate(First) of
        undefined ->
            #{raw => Raw};
        Cand ->
            Name =
                case lists:member(name, maps:get(include, I)) of
                    true ->
                        thinwrap_location_util:nonempty(poi_name(First));
                    false ->
                        undefined
                end,
            thinwrap_location_util:put_opt(name, Name, #{candidate => Cand, raw => Raw})
    end.

%% A search result as a candidate, or `undefined` when it has no real
%% position — never a fabricated (0,0) "Null Island" candidate.
candidate(R) ->
    Pos = thinwrap_location_json:get(R, <<"position">>),
    case
        {
            thinwrap_location_json:num_opt(thinwrap_location_json:get(Pos, <<"lat">>)),
            thinwrap_location_json:num_opt(thinwrap_location_json:get(Pos, <<"lon">>))
        }
    of
        {Lat, Lon} when is_float(Lat), is_float(Lon) ->
            Vp = thinwrap_location_json:get(R, <<"viewport">>),
            Tl = thinwrap_location_json:get(Vp, <<"topLeftPoint">>),
            Br = thinwrap_location_json:get(Vp, <<"btmRightPoint">>),
            %% A partial viewport is dropped whole rather than 0-filled.
            Viewport =
                case
                    {
                        thinwrap_location_json:num_opt(thinwrap_location_json:get(Br, <<"lat">>)),
                        thinwrap_location_json:num_opt(thinwrap_location_json:get(Tl, <<"lon">>)),
                        thinwrap_location_json:num_opt(thinwrap_location_json:get(Tl, <<"lat">>)),
                        thinwrap_location_json:num_opt(thinwrap_location_json:get(Br, <<"lon">>))
                    }
                of
                    {S, W, N, E} when is_float(S), is_float(W), is_float(N), is_float(E) ->
                        #{southwest => #{lat => S, lng => W}, northeast => #{lat => N, lng => E}};
                    _ ->
                        undefined
                end,
            Cand0 = #{
                formatted_address => thinwrap_location_json:str(
                    thinwrap_location_json:path(R, [<<"address">>, <<"freeformAddress">>])
                ),
                location => #{lat => Lat, lng => Lon}
            },
            thinwrap_location_util:put_opt(
                viewport,
                Viewport,
                thinwrap_location_util:put_opt(
                    place_id,
                    thinwrap_location_util:nonempty(
                        thinwrap_location_json:str(thinwrap_location_json:get(R, <<"id">>))
                    ),
                    Cand0
                )
            );
        _ ->
            undefined
    end.

%% ---------------------------------------------------------------------------
%% Isochrone (calculateReachableRange, one request per break value)

-doc false.
-spec isochrone(thinwrap_location:config(), map()) -> thinwrap_location:isochrone_result().
isochrone(Config, #{center := Center, type := Type, values := Values} = I) ->
    ok = thinwrap_location_isochrone:validate_cap(Values),
    %% calculateReachableRange accepts motorized modes only; TomTom states that
    %% "the values bicycle and pedestrian must not be used" there.
    TravelMode = maps:get(travel_mode, I),
    TravelMode =:= driving orelse unsupported_isochrone_mode(TravelMode),
    Url =
        <<?REACHABLE_RANGE_URL/binary, "/", (thinwrap_location_util:to_lat_lng(Center))/binary,
            "/json">>,
    DepartAt =
        case maps:get(departure_time, I, undefined) of
            undefined ->
                [];
            DT ->
                [
                    {<<"departAt">>,
                        thinwrap_location_isochrone:departure(DT, <<"TomTom Isochrone">>)}
                ]
        end,
    BudgetKey =
        case Type of
            time -> <<"timeBudgetInSec">>;
            distance -> <<"distanceBudgetInMeters">>
        end,
    %% The key is read per request, as a fun/0 credential may rotate it.
    Results = [
        reachable_range(
            Config,
            Url,
            [
                {<<"key">>, key(Config)},
                {<<"travelMode">>, travel_mode(TravelMode)},
                {BudgetKey, thinwrap_location_util:fmt_coord(Value)}
            ] ++ DepartAt,
            I,
            Value
        )
     || Value <- Values
    ],
    {Contours, Raws} = lists:unzip(Results),
    Result = #{
        contours => lists:sort(fun(#{value := A}, #{value := B}) -> A =< B end, Contours),
        raw => Raws
    },
    case Values of
        [_, _ | _] -> Result#{meta => #{request_count => length(Values)}};
        _ -> Result
    end.

-spec unsupported_isochrone_mode(atom()) -> no_return().
unsupported_isochrone_mode(TravelMode) ->
    Msg =
        <<"TomTom isochrone does not support travelMode \"", (atom_to_binary(TravelMode))/binary,
            "\"">>,
    thinwrap_location_error:fail(
        thinwrap_location_error:new(unsupported_travel_mode, #{
            message => Msg, provider_message => Msg
        })
    ).

%% One calculateReachableRange request: the contour for `Value` and its raw body.
reachable_range(Config, Url, Query, I, Value) ->
    {Status, Raw} = get_json(Config, Url, Query, I, false),
    Ring = boundary_ring(Raw),
    Ring =/= [] orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status, Raw, <<"TomTom Isochrone returned no usable boundary">>
            )
        ),
    %% One open boundary with no holes; closure and winding come from the
    %% shared contour rules.
    {
        #{
            value => float(Value),
            geometry => thinwrap_location_isochrone:contour_geometry([[Ring]])
        },
        Raw
    }.

%% The reachable-range boundary as `[Lng, Lat]` points, or `[]` when it is
%% empty or any point lacks a numeric position: one bad point makes the whole
%% boundary unusable, not a smaller polygon.
boundary_ring(Raw) ->
    Points = [
        {
            thinwrap_location_json:num_opt(thinwrap_location_json:get(P, <<"longitude">>)),
            thinwrap_location_json:num_opt(thinwrap_location_json:get(P, <<"latitude">>))
        }
     || P <- thinwrap_location_util:list_or_empty(
            thinwrap_location_json:path(Raw, [<<"reachableRange">>, <<"boundary">>])
        )
    ],
    Ring = [[Lng, Lat] || {Lng, Lat} <- Points, is_float(Lng), is_float(Lat)],
    case length(Ring) =:= length(Points) of
        true -> Ring;
        false -> []
    end.

%% ---------------------------------------------------------------------------
%% Vendor error mapping

map_vendor_error(S, _) when S =:= 401; S =:= 403 -> auth_failed;
map_vendor_error(429, _) -> rate_limited;
map_vendor_error(400, _) -> invalid_request;
map_vendor_error(404, true) -> invalid_request;
map_vendor_error(S, _) when S >= 500, S < 600 -> provider_unavailable;
map_vendor_error(_, _) -> unknown.

%% TomTom's machine-readable `detailedError.code` is the only way to tell "no
%% route" from "malformed request" — both arrive as HTTP 400. Live-verified:
%% MAP_MATCHING_FAILURE on a 400. NO_ROUTE_FOUND is TomTom's documented
%% sibling code for the same outcome, mapped too but doc-sourced: every live
%% attempt at a truly unreachable pair returned a route, because TomTom (like
%% every other provider tested) routes via ferries. Proxy/auth statuses win:
%% they carry no routing envelope.
classify(S, _Raw, With404) when S =:= 401; S =:= 403; S =:= 429; S >= 500, S < 600 ->
    map_vendor_error(S, With404);
classify(S, Raw, With404) ->
    case
        thinwrap_location_json:str(
            thinwrap_location_json:path(Raw, [<<"detailedError">>, <<"code">>])
        )
    of
        C when C =:= <<"MAP_MATCHING_FAILURE">>; C =:= <<"NO_ROUTE_FOUND">> -> no_route;
        _ -> map_vendor_error(S, With404)
    end.

error_message(Body) ->
    E = thinwrap_location_json:get(Body, <<"error">>),
    first_nonempty([
        thinwrap_location_json:str(
            thinwrap_location_json:path(Body, [<<"detailedError">>, <<"message">>])
        ),
        thinwrap_location_json:str(thinwrap_location_json:get(E, <<"description">>)),
        thinwrap_location_json:str(thinwrap_location_json:get(E, <<"message">>)),
        thinwrap_location_json:str(E),
        thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"message">>)),
        thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"errorText">>))
    ]).

first_nonempty([]) -> <<>>;
first_nonempty([<<>> | Rest]) -> first_nonempty(Rest);
first_nonempty([V | _]) -> V.

http_error(Status, Headers, Body, With404) ->
    Raw = thinwrap_location_json:decode(Body),
    thinwrap_location_error:provider_error(
        Status, Headers, Raw, classify(Status, Raw, With404), error_message(Raw)
    ).

%% ---------------------------------------------------------------------------
%% Helpers

key(Config) -> thinwrap_location_input:secret(Config, api_key).

travel_mode(walking) -> <<"pedestrian">>;
travel_mode(cycling) -> <<"bicycle">>;
travel_mode(driving) -> <<"car">>.

matrix_travel_mode(walking) ->
    <<"pedestrian">>;
matrix_travel_mode(cycling) ->
    Msg = <<"TomTom Matrix v2 does not support cycling">>,
    thinwrap_location_error:fail(
        thinwrap_location_error:new(unsupported_travel_mode, #{
            message => Msg, provider_message => Msg
        })
    );
matrix_travel_mode(driving) ->
    <<"car">>.

avoids(I) ->
    [<<"tollRoads">> || maps:get(avoid_tolls, I)] ++
        [<<"ferries">> || maps:get(avoid_ferries, I)] ++
        [<<"motorways">> || maps:get(avoid_highways, I)].

%% A decimal from TomTom's "lat,lon" position string; `undefined` when it is
%% not a JSON-style number.
parse_number(Bin) ->
    case thinwrap_location_json:decode(string:trim(Bin)) of
        N when is_number(N) -> float(N);
        _ -> undefined
    end.

%% Python truthiness for a decoded JSON value: absent, null, empty or zero.
falsy(undefined) -> true;
falsy([]) -> true;
falsy(false) -> true;
falsy(<<>>) -> true;
falsy(M) when is_map(M) -> map_size(M) =:= 0;
falsy(N) when is_number(N) -> N == 0;
falsy(_) -> false.

join(List) -> iolist_to_binary(lists:join(<<",">>, List)).

https(Url) ->
    try uri_string:parse(Url) of
        %% `Url` is a binary, so every parsed component is one too.
        #{scheme := S} when is_binary(S) -> string:lowercase(S) =:= <<"https">>;
        _ -> false
    catch
        _:_ -> false
    end.

%% Case-insensitive response-header lookup; the transport contract lower-cases
%% names, but a caller's own transport may not.
header(Headers, Name) ->
    case [V || K := V <- Headers, string:lowercase(thinwrap_location_util:bin(K)) =:= Name] of
        [V | _] -> thinwrap_location_util:bin(V);
        [] -> <<>>
    end.
