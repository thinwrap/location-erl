-module(thinwrap_location_esri).
-moduledoc false.

%% Esri / ArcGIS: routing (Route solve), matrix (OD cost matrix), geocoding
%% (GeocodeServer findAddressCandidates / reverseGeocode / suggest) and
%% isochrone (ServiceArea). Dual auth, form POSTs, and errors reported in the
%% body of an HTTP 200.

-export([
    route/2,
    matrix/2,
    geocode/2,
    reverse_geocode/2,
    autocomplete/2,
    place_details/2,
    isochrone/2
]).

-define(ROUTE_URL,
    <<"https://route-api.arcgis.com/arcgis/rest/services/World/Route/NAServer/Route_World/solve">>
).
-define(MATRIX_URL, <<
    "https://route-api.arcgis.com/arcgis/rest/services/World/OriginDestinationCostMatrix/"
    "NAServer/OriginDestinationCostMatrix_World/solveODCostMatrix"
>>).
-define(GEOCODE_URL, <<
    "https://geocode-api.arcgis.com/arcgis/rest/services/World/GeocodeServer/"
    "findAddressCandidates"
>>).
-define(REVGEOCODE_URL,
    <<"https://geocode-api.arcgis.com/arcgis/rest/services/World/GeocodeServer/reverseGeocode">>
).
-define(SUGGEST_URL,
    <<"https://geocode-api.arcgis.com/arcgis/rest/services/World/GeocodeServer/suggest">>
).
-define(SERVICE_AREA_URL, <<
    "https://route-api.arcgis.com/arcgis/rest/services/World/ServiceAreas/NAServer/"
    "ServiceArea_World/solveServiceArea"
>>).

-define(MIN_TO_SEC, 60).
-define(KM_TO_M, 1000).
%% Only reached if a service reports distance in miles rather than kilometers.
-define(METERS_PER_MILE, 1609.344).

%% Time-impedance column names Esri reports for the travel modes this wrapper
%% requests (driving -> TravelTime, walking -> WalkTime). The OD Cost Matrix
%% names its cost columns after the active impedance, so the matrix decoder
%% locates the time column by trying these in order rather than assuming
%% TravelTime.
-define(TIME_ATTRIBUTE_NAMES, [<<"TravelTime">>, <<"WalkTime">>]).

%% Esri documents service-area breaks as limited to 300 minutes / 300 miles
%% for standard polygons and "reduced to 15 minutes or 15 miles" for detailed
%% ones, so detailed polygons are only requested when every break fits that
%% smaller cap.
-define(DETAILED_MAX_SECONDS, 900).
%% 15 miles.
-define(DETAILED_MAX_METERS, 24140).

%% ---------------------------------------------------------------------------
%% Routing

-doc false.
-spec route(thinwrap_location:config(), map()) -> thinwrap_location:route_result().
route(Config, #{waypoints := Wps} = I) ->
    length(Wps) >= 2 orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<"ESRI Routing requires at least two waypoints">>
            )
        ),
    %% findBestSequence optimizes an OPEN route (optionally preserving the
    %% first/last stop); it has no closed round-trip mode.
    maps:get(is_round_trip, I) andalso
        thinwrap_location_error:fail(
            thinwrap_location_error:new(unsupported_option, #{
                message => <<"ESRI route optimization does not support round trips (isRoundTrip)">>,
                provider_message =>
                    <<
                        "ESRI findBestSequence optimizes an open route and cannot return a closed "
                        "round trip; remove isRoundTrip or use a provider that supports it "
                        "(e.g. Mapbox/OSRM)."
                    >>
            })
        ),
    Token = bearer_token(Config),
    TravelMode = maps:get(travel_mode, I),
    Accumulate = routing_accumulate_attributes(TravelMode),
    Form0 = [
        {<<"f">>, <<"json">>},
        {<<"token">>, Token},
        {<<"stops">>, point_feature_set(Wps)},
        {<<"returnRoutes">>, <<"true">>},
        %% Legs come from the `stops` cumulative costs rather than the
        %% `directions` output: Esri documents that output as superseded, and
        %% its `esriDMT*` maneuver values are not enumerated in the REST
        %% reference.
        {<<"returnStops">>, <<"true">>},
        %% Explicit because the service default is `true`, so omitting this
        %% still ships the whole turn-by-turn payload.
        {<<"returnDirections">>, <<"false">>},
        %% Produces the `Cumul_<attr>` fields; no impedanceAttributeName needed.
        {<<"accumulateAttributeNames">>, join(Accumulate)},
        %% Only `paths` is read; `...WithMeasure` adds an m-value per point.
        {<<"outputLines">>, <<"esriNAOutputLineTrueShape">>},
        {<<"outSR">>, <<"4326">>},
        %% The service default is `true`, which silently drops a stop it
        %% cannot snap to the network and routes the remaining ones — a route
        %% that skips a requested stop. `false` makes Esri fail the request
        %% instead, and that in-body error names the stop as unlocated
        %% (mapped to no_route).
        {<<"ignoreInvalidLocations">>, <<"false">>}
    ],
    WantsOrder = wants_best_sequence(I),
    Form1 =
        case WantsOrder of
            true ->
                %% Both preserve flags default to TRUE once findBestSequence is
                %% on (live: order [0,1,2,3] with defaults, [2,3,0,1] with both
                %% false), so they are always sent explicitly: freeing an end
                %% means sending false.
                {First, Last} = preserve_stops(I),
                Form0 ++
                    [
                        {<<"findBestSequence">>, <<"true">>},
                        {<<"preserveFirstStop">>, bool_bin(First)},
                        {<<"preserveLastStop">>, bool_bin(Last)}
                    ];
            false ->
                Form0
        end,
    Form2 =
        Form1 ++
            travel_mode_and_restrictions(TravelMode, routing_restrictions(I), <<"ESRI Routing">>),
    %% Esri applies traffic whenever a start time is sent (typical, or live
    %% within 4 h of now) and none at all without one, so the time follows
    %% traffic_mode rather than departure_time: none drops it, and traffic with
    %% no time asks for `now` ("live traffic will be used where available";
    %% Esri forces startTimeIsUTC=true itself). A passthrough startTime still
    %% wins, being merged afterwards. A malformed time is still refused under
    %% none: it is a caller bug either way.
    StartMs = departure_ms(maps:get(departure_time, I, undefined), <<"ESRI Routing">>),
    Form = Form2 ++ time_fields(<<"startTime">>, <<"startTimeIsUTC">>, StartMs, I),
    #{status := Status, headers := RH, body := RB} = post_form(Config, ?ROUTE_URL, Form, I),
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(http_error(Status, RH, RB)),
    Raw = thinwrap_location_json:decode(RB),
    ok = check_body_error(Status, Raw),
    Raw =/= undefined orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status, undefined, <<"ESRI Routing returned non-JSON body">>
            )
        ),
    Feature =
        case
            thinwrap_location_util:list_or_empty(
                thinwrap_location_json:path(Raw, [<<"routes">>, <<"features">>])
            )
        of
            [F | _] ->
                F;
            [] ->
                %% Esri's OBSERVED no-route path is the in-body error envelope
                %% (an unlocated stop), not an empty featureset. This branch is
                %% a shape Esri has not been seen to produce — classify it with
                %% the same code as the other providers so a consumer has one
                %% "provider answered, no route" case.
                thinwrap_location_error:fail(
                    thinwrap_location_error:classified(
                        no_route, Status, Raw, <<"ESRI Routing returned no routes">>
                    )
                )
        end,
    Attrs =
        case thinwrap_location_json:get(Feature, <<"attributes">>) of
            #{} = A -> A;
            _ -> #{}
        end,
    %% Legs and totals share one source, so they always reconcile.
    [TimeAttr | _] = Accumulate,
    Ordered = ordered_decode(RB),
    StopFeatures = thinwrap_location_util:list_or_empty(
        thinwrap_location_json:path(Raw, [<<"stops">>, <<"features">>])
    ),
    OrderedStops = thinwrap_location_util:list_or_empty(
        opath(Ordered, [<<"stops">>, <<"features">>])
    ),
    {TotalDist, TotalDur, Legs} =
        case cumulative_stop_costs(StopFeatures, OrderedStops, TimeAttr) of
            {_, _, _} = Cumulative ->
                Cumulative;
            undefined ->
                %% A stop that failed to locate carries no cumulative cost, and
                %% a service configured without the accumulate attributes
                %% returns none. The route's own totals are named after the
                %% active impedance.
                OrderedAttrs = opath(
                    onth(opath(Ordered, [<<"routes">>, <<"features">>]), 0), [<<"attributes">>]
                ),
                Dist = route_total_distance_meters(Attrs),
                Dur = route_total_duration_seconds(
                    Attrs, ordered_keys(OrderedAttrs, Attrs), TimeAttr
                ),
                (Dist =/= undefined andalso Dur =/= undefined) orelse
                    %% Neither the stops nor the route carry a cost this decoder
                    %% can read; a 0 m / 0 s route would be indistinguishable
                    %% from real data.
                    thinwrap_location_error:fail(
                        thinwrap_location_error:unknown(
                            Status,
                            Raw,
                            <<"ESRI Routing returned no readable route distance/duration">>
                        )
                    ),
                {Dist, Dur, even_split_legs(length(Wps), Dist, Dur)}
        end,
    Points = [
        path_point(Point, Status, Raw)
     || P <- thinwrap_location_util:list_or_empty(
            thinwrap_location_json:path(Feature, [<<"geometry">>, <<"paths">>])
        ),
        Point <- thinwrap_location_util:list_or_empty(P)
    ],
    %% Optimized routes only: stops are always fetched, so without this gate an
    %% unoptimized route would report a useless identity permutation. The
    %% `stops` FeatureSet carries each stop's 1-based Sequence (there is no
    %% `Stops` route attribute).
    WaypointOrder =
        case WantsOrder of
            true -> waypoint_order(StopFeatures, length(Wps));
            false -> undefined
        end,
    thinwrap_location_util:put_opt(waypoint_order, WaypointOrder, #{
        legs => Legs,
        total_distance_meters => TotalDist,
        total_duration_seconds => TotalDur,
        polyline => thinwrap_location_polyline:encode(Points),
        raw => Raw
    }).

path_point([X0, Y0 | _], Status, Raw) ->
    case {thinwrap_location_json:num_opt(X0), thinwrap_location_json:num_opt(Y0)} of
        {X, Y} when is_float(X), is_float(Y) -> #{lat => Y, lng => X};
        _ -> bad_path_point(Status, Raw)
    end;
path_point(_, Status, Raw) ->
    bad_path_point(Status, Raw).

-spec bad_path_point(integer(), term()) -> no_return().
bad_path_point(Status, Raw) ->
    thinwrap_location_error:fail(
        thinwrap_location_error:unknown(
            Status, Raw, <<"ESRI Routing returned a route path point without coordinates">>
        )
    ).

%% ---------------------------------------------------------------------------
%% Matrix (OD cost matrix)

-doc false.
-spec matrix(thinwrap_location:config(), map()) -> thinwrap_location:matrix_result().
matrix(Config, #{origins := Os, destinations := Ds} = I) ->
    (Os =/= [] andalso Ds =/= []) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<"ESRI Matrix requires at least one origin and one destination">>
            )
        ),
    Token = bearer_token(Config),
    TravelMode = maps:get(travel_mode, I),
    Form0 = [
        {<<"f">>, <<"json">>},
        {<<"token">>, Token},
        {<<"origins">>, point_feature_set(Os)},
        {<<"destinations">>, point_feature_set(Ds)},
        {<<"outputType">>, <<"esriNAODOutputSparseMatrix">>},
        {<<"impedanceAttributeName">>, <<"TravelTime">>},
        {<<"accumulateAttributeNames">>,
            join(thinwrap_location_defaults:esri_matrix_accumulate_attributes())},
        {<<"outSR">>, <<"4326">>}
    ],
    Restrictions =
        case maps:get(avoid_tolls, I) of
            true -> [<<"Avoid Toll Roads">>];
            false -> []
        end,
    Form1 = Form0 ++ travel_mode_and_restrictions(TravelMode, Restrictions, <<"ESRI Matrix">>),
    %% solveODCostMatrix documents no `startTime` parameter; its departure is
    %% `timeOfDay`. Same traffic rule as routing: a time is what turns traffic
    %% on, so none drops it and traffic with no time sends `now`.
    TimeMs = departure_ms(maps:get(departure_time, I, undefined), <<"ESRI Matrix">>),
    Form = Form1 ++ time_fields(<<"timeOfDay">>, <<"timeOfDayIsUTC">>, TimeMs, I),
    #{status := Status, headers := RH, body := RB} = post_form(Config, ?MATRIX_URL, Form, I),
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(http_error(Status, RH, RB)),
    Raw = thinwrap_location_json:decode(RB),
    ok = check_body_error(Status, Raw),
    Raw =/= undefined orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status, undefined, <<"ESRI Matrix returned non-JSON body">>
            )
        ),
    No = length(Os),
    Nd = length(Ds),
    case
        {
            thinwrap_location_json:get(Raw, <<"odCostMatrix">>),
            thinwrap_location_json:get(Raw, <<"odLines">>)
        }
    of
        {#{} = Odm, _} ->
            %% Iterated in the response's own key order, so cells come back in
            %% the order Esri listed them.
            OrderedOdm = opath(ordered_decode(RB), [<<"odCostMatrix">>]),
            #{cells => sparse_cells(Odm, OrderedOdm, No, Nd, Status, Raw), raw => Raw};
        {_, #{} = Odl} ->
            #{cells => od_lines_cells(Odl, TravelMode, No, Nd, Status, Raw), raw => Raw};
        _ ->
            thinwrap_location_error:fail(
                thinwrap_location_error:unknown(
                    Status, Raw, <<"ESRI Matrix response missing odCostMatrix and odLines payload">>
                )
            )
    end.

sparse_cells(Odm, OrderedOdm, No, Nd, Status, Raw) ->
    AttrOrder =
        case thinwrap_location_json:get(Odm, <<"costAttributeNames">>) of
            [_ | _] = L -> L;
            _ -> [<<"TravelTime">>, <<"Kilometers">>]
        end,
    %% The impedance column is named after the active travel mode: driving
    %% reports TravelTime, walking reports WalkTime (the WALK travelMode object
    %% overrides the requested impedanceAttributeName). Locate it by the known
    %% time-impedance names rather than assuming TravelTime, else a walking
    %% matrix silently decodes every duration as 0.
    TimeIdx = first_index([N || N <- ?TIME_ATTRIBUTE_NAMES, lists:member(N, AttrOrder)], AttrOrder),
    DistIdx = index_of(<<"Kilometers">>, AttrOrder),
    (TimeIdx >= 0 andalso DistIdx >= 0) orelse
        %% A cost column this decoder does not recognise (a travel mode with
        %% another impedance, or a passthrough override) must not read as 0
        %% seconds / 0 metres — that is indistinguishable from "same place".
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status,
                #{<<"costAttributeNames">> => AttrOrder},
                iolist_to_binary([
                    "ESRI Matrix returned cost columns without a recognised time (",
                    lists:join("/", ?TIME_ATTRIBUTE_NAMES),
                    ") and Kilometers column: ",
                    py_repr_list(AttrOrder)
                ])
            )
        ),
    %% A sparse result (fewer routable cells than the requested grid) is
    %% normal: an unroutable origin x destination pair is OMITTED, not an error
    %% for the whole matrix — parity with the other providers' cell omission.
    lists:append([
        origin_cells(OriginKey, DestMap, TimeIdx, DistIdx, No, Nd, Status, Raw)
     || {OriginKey, DestMap} <- ordered_kvs(OrderedOdm, Odm),
        OriginKey =/= <<"costAttributeNames">>
    ]).

%% The cells of one origin row of a sparse odCostMatrix.
origin_cells(OriginKey, DestMap, TimeIdx, DistIdx, No, Nd, Status, Raw) ->
    Oid = matrix_oid(OriginKey),
    (is_integer(Oid) andalso Oid >= 1 andalso Oid =< No andalso
        is_tuple(DestMap)) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status,
                Raw,
                <<
                    "ESRI Matrix sparse response returned an out-of-range or non-numeric "
                    "origin OID"
                >>
            )
        ),
    [
        Cell
     || {DestKey, CellVal} <- okvs(DestMap),
        Cell <- [sparse_cell(Oid, DestKey, CellVal, TimeIdx, DistIdx, Nd, Status, Raw)],
        Cell =/= undefined
    ].

sparse_cell(Oid, DestKey, CellVal, TimeIdx, DistIdx, Nd, Status, Raw) ->
    Did = matrix_oid(DestKey),
    (is_integer(Did) andalso Did >= 1 andalso Did =< Nd) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status,
                Raw,
                <<
                    "ESRI Matrix sparse response returned an out-of-range or non-numeric "
                    "destination OID"
                >>
            )
        ),
    %% A cell missing either cost is a failed cell, omitted rather than
    %% reported as 0 m / 0 s. A bare number is one cost, never both.
    case CellVal of
        L when is_list(L) ->
            case
                {
                    thinwrap_location_json:num_opt(nth0(L, TimeIdx)),
                    thinwrap_location_json:num_opt(nth0(L, DistIdx))
                }
            of
                {T, D} when is_float(T), is_float(D) ->
                    #{
                        origin_index => Oid - 1,
                        destination_index => Did - 1,
                        distance_meters => D * ?KM_TO_M,
                        duration_seconds => T * ?MIN_TO_SEC
                    };
                _ ->
                    undefined
            end;
        _ ->
            undefined
    end.

od_lines_cells(Odl, TravelMode, No, Nd, Status, Raw) ->
    %% The line-feature output names its costs `Total_<attribute>` after the
    %% active impedance, like the sparse matrix's columns: Total_WalkTime when
    %% walking, so reading Total_TravelTime there would report 0 s.
    TimeKey =
        case TravelMode of
            walking -> <<"Total_WalkTime">>;
            _ -> <<"Total_TravelTime">>
        end,
    lists:filtermap(
        fun(F) ->
            A = thinwrap_location_json:get(F, <<"attributes">>),
            Oid = matrix_oid(thinwrap_location_json:get(A, <<"OriginID">>)),
            Did = matrix_oid(thinwrap_location_json:get(A, <<"DestinationID">>)),
            (is_integer(Oid) andalso is_integer(Did) andalso Oid >= 1 andalso Oid =< No andalso
                Did >= 1 andalso Did =< Nd) orelse
                thinwrap_location_error:fail(
                    thinwrap_location_error:unknown(
                        Status,
                        Raw,
                        <<"ESRI Matrix odLines returned an out-of-range or non-integer OID">>
                    )
                ),
            %% Same omission rule as the sparse matrix: an unroutable pair has
            %% no line or no cost, and is left out rather than reported as 0.
            case
                {
                    thinwrap_location_json:num_opt(
                        thinwrap_location_json:get(A, <<"Total_Kilometers">>)
                    ),
                    thinwrap_location_json:num_opt(thinwrap_location_json:get(A, TimeKey))
                }
            of
                {Km, Minutes} when is_float(Km), is_float(Minutes) ->
                    {true, #{
                        origin_index => Oid - 1,
                        destination_index => Did - 1,
                        distance_meters => Km * ?KM_TO_M,
                        duration_seconds => Minutes * ?MIN_TO_SEC
                    }};
                _ ->
                    false
            end
        end,
        thinwrap_location_util:list_or_empty(thinwrap_location_json:get(Odl, <<"features">>))
    ).

%% A 1-based OID from a sparse-matrix key or an odLines attribute;
%% `undefined` if it is not an integer.
matrix_oid(I) when is_integer(I) -> I;
matrix_oid(B) when is_binary(B) ->
    try
        binary_to_integer(string:trim(B))
    catch
        error:badarg -> undefined
    end;
matrix_oid(_) ->
    undefined.

%% ---------------------------------------------------------------------------
%% Geocoding

-doc false.
-spec geocode(thinwrap_location:config(), map()) -> thinwrap_location:geocode_result().
geocode(Config, #{address := Address} = I) ->
    Query =
        [
            {<<"f">>, <<"json">>},
            {<<"token">>, bearer_token(Config)},
            {<<"singleLine">>, Address},
            {<<"outFields">>, <<"*">>}
        ] ++
            country_code(I) ++ lang_code(I),
    Raw = dispatch_get(Config, ?GEOCODE_URL, Query, I, <<"ESRI geocoding failed">>, #{
        list_key => <<"candidates">>
    }),
    #{
        candidates => lists:filtermap(fun candidate/1, maps:get(<<"candidates">>, Raw)),
        raw => Raw
    }.

%% Skip a candidate without real coordinates rather than emitting a
%% fabricated (0,0) "Null Island" position.
candidate(C) ->
    case location(thinwrap_location_json:get(C, <<"location">>)) of
        undefined ->
            false;
        Loc ->
            {true,
                thinwrap_location_util:put_opt(
                    viewport, extent_viewport(thinwrap_location_json:get(C, <<"extent">>)), #{
                        formatted_address => thinwrap_location_json:str(
                            thinwrap_location_json:get(C, <<"address">>)
                        ),
                        location => Loc
                    }
                )}
    end.

-doc false.
-spec reverse_geocode(thinwrap_location:config(), map()) -> thinwrap_location:geocode_result().
reverse_geocode(Config, #{location := Loc} = I) ->
    Query =
        [
            {<<"f">>, <<"json">>},
            {<<"token">>, bearer_token(Config)},
            {<<"location">>, thinwrap_location_util:to_lng_lat(Loc)}
        ] ++ lang_code(I),
    Raw = dispatch_get(Config, ?REVGEOCODE_URL, Query, I, <<"ESRI reverse geocoding failed">>, #{
        no_address_is_empty => true
    }),
    Addr = thinwrap_location_json:get(Raw, <<"address">>),
    Formatted =
        case thinwrap_location_json:str(thinwrap_location_json:get(Addr, <<"LongLabel">>)) of
            <<>> -> thinwrap_location_json:str(thinwrap_location_json:get(Addr, <<"Match_addr">>));
            L -> L
        end,
    %% No address, or no coordinates, means no usable candidate — never a
    %% fabricated (0,0).
    Candidates =
        case {Addr, Formatted, location(thinwrap_location_json:get(Raw, <<"location">>))} of
            {undefined, _, _} -> [];
            {_, <<>>, _} -> [];
            {_, _, undefined} -> [];
            {_, _, Location} -> [#{formatted_address => Formatted, location => Location}]
        end,
    #{candidates => Candidates, raw => Raw}.

-doc false.
-spec autocomplete(thinwrap_location:config(), map()) -> thinwrap_location:autocomplete_result().
autocomplete(Config, #{input := Text} = I) ->
    Query =
        [{<<"f">>, <<"json">>}, {<<"token">>, bearer_token(Config)}, {<<"text">>, Text}] ++
            [
                {<<"location">>, thinwrap_location_util:to_lng_lat(L)}
             || L <- [maps:get(location, I, undefined)], L =/= undefined
            ] ++
            %% `country_filter` -> `countryCode` (comma-joined alpha-2; Esri
            %% uses alpha-2 directly), same translation as forward geocode.
            country_code(I),
    Raw = dispatch_get(Config, ?SUGGEST_URL, Query, I, <<"ESRI autocomplete failed">>, #{
        list_key => <<"suggestions">>
    }),
    %% Esri returns a single flat `text`: there is no distinct main part, so
    %% structured_format is never emitted rather than faked by splitting it.
    Preds = [
        thinwrap_location_util:put_opt(
            place_id,
            thinwrap_location_util:nonempty(
                thinwrap_location_json:str(thinwrap_location_json:get(S, <<"magicKey">>))
            ),
            #{description => thinwrap_location_json:str(thinwrap_location_json:get(S, <<"text">>))}
        )
     || S <- maps:get(<<"suggestions">>, Raw)
    ],
    #{predictions => Preds, raw => Raw}.

-doc false.
%% Resolve an Esri `magicKey` (from autocomplete) to a full candidate via
%% `findAddressCandidates?magicKey=` — the forward-geocode endpoint, so the
%% same normalizer applies. Live-verified that `magicKey` alone is
%% sufficient: Esri's docs pair it with the original SingleLine text, but the
%% key on its own resolves to the byte-identical candidate — which is why
%% place_id needs no companion field.
-spec place_details(thinwrap_location:config(), map()) -> thinwrap_location:place_details_result().
place_details(Config, #{place_id := PlaceId} = I) ->
    Query =
        [
            {<<"f">>, <<"json">>},
            {<<"token">>, bearer_token(Config)},
            {<<"magicKey">>, PlaceId},
            {<<"outFields">>, <<"*">>}
        ] ++ lang_code(I),
    Raw = dispatch_get(Config, ?GEOCODE_URL, Query, I, <<"ESRI place details failed">>, #{}),
    First =
        case
            thinwrap_location_util:list_or_empty(thinwrap_location_json:get(Raw, <<"candidates">>))
        of
            [F | _] -> F;
            [] -> undefined
        end,
    %% Esri returns only an address — there is no separate display name to
    %% surface, so `name` is never emitted even when requested.
    case location(thinwrap_location_json:get(First, <<"location">>)) of
        undefined ->
            #{raw => Raw};
        Loc ->
            #{
                candidate => thinwrap_location_util:put_opt(
                    viewport, extent_viewport(thinwrap_location_json:get(First, <<"extent">>)), #{
                        formatted_address => thinwrap_location_json:str(
                            thinwrap_location_json:get(First, <<"address">>)
                        ),
                        location => Loc
                    }
                ),
                raw => Raw
            }
    end.

dispatch_get(Config, Url, BaseQuery, I, Label, Opts) ->
    {Merged, MHeaders, PtQuery} = merge_passthrough(BaseQuery, I),
    %% A passthrough `null` removes the parameter from the query.
    Query0 = [{K, stringify(V)} || {K, V} <- Merged, V =/= null, V =/= undefined],
    Query = thinwrap_location_util:merge_query(Query0, PtQuery),
    #{status := Status, headers := RH, body := RB} = thinwrap_location_http:send_get(
        Config, Url, MHeaders, Query
    ),
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(http_error(Status, RH, RB)),
    Raw = thinwrap_location_json:decode(RB),
    is_map(Raw) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(Status, Raw, <<Label/binary, ": non-JSON body">>)
        ),
    case thinwrap_location_json:get(Raw, <<"error">>) of
        undefined ->
            _ =
                case Opts of
                    #{list_key := Key} ->
                        thinwrap_location_error:require_list(Status, Raw, Key, Label);
                    _ ->
                        ok
                end,
            Raw;
        _ ->
            %% reverseGeocode reports a location with no address nearby as an
            %% in-body error 400 ("Unable to find address for the specified
            %% location."). That is the zero-results answer, not a bad
            %% request, so the body goes back to the caller, whose
            %% missing-address branch turns it into an empty result.
            case maps:get(no_address_is_empty, Opts, false) andalso is_no_address(Raw) of
                true -> Raw;
                false -> thinwrap_location_error:fail(body_error(Status, Raw))
            end
    end.

country_code(I) ->
    case maps:get(country_filter, I, []) of
        [] -> [];
        Cs -> [{<<"countryCode">>, join(Cs)}]
    end.

lang_code(I) ->
    [{<<"langCode">>, L} || L <- [maps:get(language, I, <<>>)], L =/= <<>>].

location(Loc) ->
    case
        {
            thinwrap_location_json:num_opt(thinwrap_location_json:get(Loc, <<"y">>)),
            thinwrap_location_json:num_opt(thinwrap_location_json:get(Loc, <<"x">>))
        }
    of
        {Y, X} when is_float(Y), is_float(X) -> #{lat => Y, lng => X};
        _ -> undefined
    end.

%% A candidate's `extent` as a viewport, or undefined unless all four corners
%% are numbers — a 0-filled corner would silently stretch a consumer's map
%% bounds.
extent_viewport(Ext) ->
    case
        [
            thinwrap_location_json:num_opt(thinwrap_location_json:get(Ext, K))
         || K <- [<<"ymin">>, <<"xmin">>, <<"ymax">>, <<"xmax">>]
        ]
    of
        [YMin, XMin, YMax, XMax] when
            is_float(YMin), is_float(XMin), is_float(YMax), is_float(XMax)
        ->
            #{southwest => #{lat => YMin, lng => XMin}, northeast => #{lat => YMax, lng => XMax}};
        _ ->
            undefined
    end.

%% ---------------------------------------------------------------------------
%% Isochrone (ServiceArea)

-doc false.
-spec isochrone(thinwrap_location:config(), map()) -> thinwrap_location:isochrone_result().
isochrone(Config, #{center := Center, type := Type, values := Values} = I) ->
    ok = thinwrap_location_isochrone:validate_cap(Values),
    TravelMode = maps:get(travel_mode, I),
    TravelMode =/= cycling orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:new(unsupported_travel_mode, #{
                message => <<"ESRI isochrone does not support cycling">>,
                provider_message => <<"ESRI isochrone does not support cycling">>
            })
        ),
    Token = bearer_token(Config),
    %% solveServiceArea has no break-units parameter: `defaultBreaks` is read
    %% in the units of the active impedance attribute (TravelTime -> minutes by
    %% default). A distance isochrone therefore switches the impedance to
    %% Kilometers and sends kilometres.
    IsTime = Type =:= time,
    %% Esri accepts FRACTIONAL minutes / kilometres, so sub-minute breaks
    %% survive (whole minutes would turn 30 s into 60 s and 20 s into 0). Six
    %% decimals strip float noise; fmt_coord never switches to exponent
    %% notation. `Sent` maps each break as sent back to the caller's value: 7 s
    %% goes out as 0.116667 min and ToBreak echoes that, which x60 would read
    %% as 7.00002 s.
    Sent = lists:foldl(
        fun(V, Acc) ->
            Key =
                case IsTime of
                    true -> round6(V / ?MIN_TO_SEC);
                    false -> round6(V / ?KM_TO_M)
                end,
            lists:keystore(Key, 1, Acc, {Key, V})
        end,
        [],
        Values
    ),
    Breaks = join([thinwrap_location_util:fmt_coord(B) || {B, _} <- Sent]),
    Form0 = [
        {<<"f">>, <<"json">>},
        {<<"token">>, Token},
        {<<"facilities">>, point_feature_set([Center])},
        {<<"defaultBreaks">>, Breaks},
        {<<"outputPolygons">>, output_polygons(IsTime, Values)},
        {<<"returnFacilities">>, <<"false">>},
        {<<"travelDirection">>, <<"esriNATravelDirectionFromFacility">>},
        {<<"outSR">>, <<"4326">>}
    ],
    Form1 =
        case {TravelMode, IsTime} of
            %% ArcGIS requires a full travel-mode JSON object, not a name
            %% string. A travel mode overrides impedanceAttributeName, so the
            %% distance impedance has to be set inside the object itself.
            {walking, true} ->
                Form0 ++ [{<<"travelMode">>, thinwrap_location_json:encode(walking_travel_mode())}];
            {walking, false} ->
                Form0 ++
                    [
                        {<<"travelMode">>,
                            thinwrap_location_json:encode(walking_distance_travel_mode())}
                    ];
            {_, false} ->
                Form0 ++ [{<<"impedanceAttributeName">>, <<"Kilometers">>}];
            {_, true} ->
                Form0
        end,
    %% Isochrones have no traffic_mode, so a departure time is passed through
    %% as given — which makes the service area traffic-aware (typical traffic,
    %% or live within 4 h of now), as documented.
    Form =
        case maps:get(departure_time, I, undefined) of
            Empty when Empty =:= undefined; Empty =:= <<>> ->
                Form1;
            DT ->
                Form1 ++
                    [
                        {<<"timeOfDay">>, integer_to_binary(epoch_ms(DT, <<"ESRI Isochrone">>))},
                        {<<"timeOfDayIsUTC">>, <<"true">>}
                    ]
        end,
    #{status := Status, headers := RH, body := RB} = post_form(
        Config, ?SERVICE_AREA_URL, Form, I
    ),
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(http_error(Status, RH, RB)),
    Raw = thinwrap_location_json:decode(RB),
    Raw =/= undefined orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status, undefined, <<"ESRI Isochrone returned non-JSON body">>
            )
        ),
    ok = check_body_error(Status, Raw),
    Contours = [
        contour(F, IsTime, Sent, Status, Raw)
     || F <- thinwrap_location_util:list_or_empty(
            thinwrap_location_json:path(Raw, [<<"saPolygons">>, <<"features">>])
        )
    ],
    Contours =/= [] orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status, Raw, <<"ESRI Isochrone returned no service-area polygons">>
            )
        ),
    #{
        contours => lists:sort(
            fun(#{value := A}, #{value := B}) -> A =< B end, Contours
        ),
        raw => Raw
    }.

contour(F, IsTime, Sent, Status, Raw) ->
    %% `rings` mixes exterior and hole rings in no guaranteed order (rings[0]
    %% may be a hole), and a service area can have several exteriors.
    Rings = [
        R
     || R <- thinwrap_location_util:list_or_empty(
            thinwrap_location_json:path(F, [<<"geometry">>, <<"rings">>])
        ),
        is_ring(R)
    ],
    ToBreak =
        case
            thinwrap_location_json:num_opt(
                thinwrap_location_json:path(F, [<<"attributes">>, <<"ToBreak">>])
            )
        of
            B when is_float(B), Rings =/= [] ->
                B;
            _ ->
                thinwrap_location_error:fail(
                    thinwrap_location_error:unknown(
                        Status,
                        Raw,
                        <<
                            "ESRI Isochrone returned a polygon without a ToBreak value "
                            "or outer ring"
                        >>
                    )
                )
        end,
    %% A break the connector did not send (a passthrough override) falls back
    %% to a unit conversion, rounded so 0.3 km reads back as 300 m.
    Value =
        case lists:keyfind(round6(ToBreak), 1, Sent) of
            {_, V} -> V;
            false when IsTime -> ToBreak * ?MIN_TO_SEC;
            false -> round6(ToBreak * ?KM_TO_M)
        end,
    #{
        value => float(Value),
        geometry => thinwrap_location_isochrone:contour_geometry(
            thinwrap_location_isochrone:esri_parts(Rings)
        )
    }.

%% Whether `Ring` is a non-empty list of `[x, y]` number pairs.
is_ring([_ | _] = Ring) ->
    lists:all(
        fun
            ([X, Y | _]) -> is_number(X) andalso is_number(Y);
            (_) -> false
        end,
        Ring
    );
is_ring(_) ->
    false.

%% Detailed polygons when every break fits Esri's detailed-polygon cap,
%% otherwise the service's simplified default.
output_polygons(IsTime, Values) ->
    Cap =
        case IsTime of
            true -> ?DETAILED_MAX_SECONDS;
            false -> ?DETAILED_MAX_METERS
        end,
    case lists:all(fun(V) -> V =< Cap end, Values) of
        true -> <<"esriNAOutputPolygonDetailed">>;
        false -> <<"esriNAOutputPolygonSimplified">>
    end.

%% Python's round(X, 6): the nearest float to X rounded at six decimals.
round6(X) ->
    binary_to_float(float_to_binary(float(X), [{decimals, 6}])).

%% ---------------------------------------------------------------------------
%% Travel modes and restrictions

%% Esri's canonical ArcGIS World "Walking Time" travel-mode object.
%%
%% ArcGIS Network Analyst services require `travelMode` to be a full JSON
%% object, not a name string — a bare "Walking" is ignored and the service
%% stays on driving. Setting this object makes the service override its
%% impedance to WalkTime (route summaries carry Total_WalkTime; the OD matrix
%% reports costAttributeNames ["WalkTime", ...]). Verified live against
%% route-api.arcgis.com on 2026-07-21.
walking_travel_mode() ->
    #{
        <<"attributeParameterValues">> => [
            #{
                <<"parameterName">> => <<"Restriction Usage">>,
                <<"attributeName">> => <<"Walking">>,
                <<"value">> => <<"PROHIBITED">>
            },
            #{
                <<"parameterName">> => <<"Restriction Usage">>,
                <<"attributeName">> => <<"Preferred for Pedestrians">>,
                <<"value">> => <<"PREFER_LOW">>
            },
            #{
                <<"parameterName">> => <<"Walking Speed (km/h)">>,
                <<"attributeName">> => <<"WalkTime">>,
                <<"value">> => 5
            }
        ],
        <<"description">> =>
            <<
                "Follows paths and roads that allow pedestrian traffic and finds solutions that "
                "optimize travel time. The walking speed is set to 5 kilometers per hour."
            >>,
        <<"impedanceAttributeName">> => <<"WalkTime">>,
        <<"simplificationToleranceUnits">> => <<"esriMeters">>,
        <<"uturnAtJunctions">> => <<"esriNFSBAllowBacktrack">>,
        <<"restrictionAttributeNames">> => [
            <<"Avoid Private Roads">>,
            <<"Avoid Roads Unsuitable for Pedestrians">>,
            <<"Preferred for Pedestrians">>,
            <<"Walking">>
        ],
        <<"useHierarchy">> => false,
        <<"simplificationTolerance">> => 2,
        <<"timeAttributeName">> => <<"WalkTime">>,
        <<"distanceAttributeName">> => <<"Kilometers">>,
        <<"type">> => <<"WALK">>,
        <<"id">> => <<"caFAgoThrvUpkFBW">>,
        <<"name">> => <<"Walking Time">>
    }.

%% Esri's "Walking Distance" travel mode, for distance isochrones.
%%
%% A travel mode overrides impedanceAttributeName, and service-area breaks are
%% read in the impedance's units — so under "Walking Time" a kilometre break
%% would be interpreted as minutes of walking. This is the object Esri
%% publishes in its "Retrieve travel modes" reference (id yFuMFwIYblqKEefX,
%% Kilometers impedance).
walking_distance_travel_mode() ->
    #{
        <<"attributeParameterValues">> => [
            #{
                <<"parameterName">> => <<"Restriction Usage">>,
                <<"attributeName">> => <<"Avoid Private Roads">>,
                <<"value">> => <<"AVOID_MEDIUM">>
            },
            #{
                <<"parameterName">> => <<"Restriction Usage">>,
                <<"attributeName">> => <<"Walking">>,
                <<"value">> => <<"PROHIBITED">>
            },
            #{
                <<"parameterName">> => <<"Restriction Usage">>,
                <<"attributeName">> => <<"Preferred for Pedestrians">>,
                <<"value">> => <<"PREFER_LOW">>
            },
            #{
                <<"parameterName">> => <<"Walking Speed (km/h)">>,
                <<"attributeName">> => <<"WalkTime">>,
                <<"value">> => 5
            },
            #{
                <<"parameterName">> => <<"Restriction Usage">>,
                <<"attributeName">> => <<"Avoid Roads Unsuitable for Pedestrians">>,
                <<"value">> => <<"AVOID_HIGH">>
            }
        ],
        <<"description">> =>
            <<
                "Follows paths and roads that allow pedestrian traffic and finds solutions that "
                "optimize travel distance."
            >>,
        <<"distanceAttributeName">> => <<"Kilometers">>,
        <<"id">> => <<"yFuMFwIYblqKEefX">>,
        <<"impedanceAttributeName">> => <<"Kilometers">>,
        <<"name">> => <<"Walking Distance">>,
        <<"restrictionAttributeNames">> => [
            <<"Avoid Private Roads">>,
            <<"Avoid Roads Unsuitable for Pedestrians">>,
            <<"Preferred for Pedestrians">>,
            <<"Walking">>
        ],
        <<"simplificationTolerance">> => 2,
        <<"simplificationToleranceUnits">> => <<"esriMeters">>,
        <<"timeAttributeName">> => <<"WalkTime">>,
        <<"type">> => <<"WALK">>,
        <<"useHierarchy">> => false,
        <<"uturnAtJunctions">> => <<"esriNFSBAllowBacktrack">>
    }.

%% The travel-mode object to send, or undefined for the service default
%% (driving).
travel_mode_object(walking, _Label) ->
    walking_travel_mode();
travel_mode_object(cycling, Label) ->
    Msg = <<Label/binary, " does not support travelMode \"cycling\"">>,
    thinwrap_location_error:fail(
        thinwrap_location_error:new(unsupported_travel_mode, #{
            message => Msg, provider_message => Msg
        })
    );
travel_mode_object(driving, _Label) ->
    undefined.

%% The `travelMode` and avoid-restriction form fields.
%%
%% A travel mode carries its own restrictionAttributeNames, and when one is
%% sent Esri applies that list and IGNORES the top-level parameter beside it —
%% live, a walking mode plus restrictionAttributeNames=Avoid Ferries reported
%% only the mode's "Avoid Private Roads" as traversed. So with a mode the
%% restrictions are appended to the mode's own list; without one (driving, the
%% service default) the top-level parameter works and is used.
travel_mode_and_restrictions(Mode, Restrictions, Label) ->
    case travel_mode_object(Mode, Label) of
        undefined when Restrictions =:= [] ->
            [];
        undefined ->
            [{<<"restrictionAttributeNames">>, join(Restrictions)}];
        Tm ->
            Names = lists:foldl(
                fun(R, Acc) ->
                    case lists:member(R, Acc) of
                        true -> Acc;
                        false -> Acc ++ [R]
                    end
                end,
                thinwrap_location_util:list_or_empty(
                    maps:get(<<"restrictionAttributeNames">>, Tm, [])
                ),
                Restrictions
            ),
            Tm1 =
                case Restrictions of
                    [] -> Tm;
                    _ -> Tm#{<<"restrictionAttributeNames">> => Names}
                end,
            [{<<"travelMode">>, thinwrap_location_json:encode(Tm1)}]
    end.

routing_restrictions(I) ->
    [
        R
     || {K, R} <- [
            {avoid_tolls, <<"Avoid Toll Roads">>},
            {avoid_ferries, <<"Avoid Ferries">>},
            {avoid_highways, <<"Avoid Limited Access Roads">>}
        ],
        maps:get(K, I)
    ].

%% Any of the three optimize flags means "reorder the stops", as on every
%% other provider — a fixed endpoint alone implies optimization.
wants_best_sequence(I) ->
    maps:get(optimize, I) orelse maps:get(optimize_fixed_origin, I) orelse
        maps:get(optimize_fixed_destination, I).

%% `{preserveFirstStop, preserveLastStop}` for the normalized flags. Plain
%% optimize keeps both ends fixed (the cross-provider meaning); exactly one
%% fixed-endpoint flag frees the OTHER end; both flags keep both.
preserve_stops(#{optimize_fixed_origin := true, optimize_fixed_destination := false}) ->
    {true, false};
preserve_stops(#{optimize_fixed_origin := false, optimize_fixed_destination := true}) ->
    {false, true};
preserve_stops(_) ->
    {true, true}.

%% The attributes to accumulate; the time one determines the `Cumul_<attr>`
%% field name. Must mirror travel_mode_object/2: requesting an attribute the
%% active impedance does not use yields no cumulative field at all, silently.
routing_accumulate_attributes(walking) ->
    thinwrap_location_defaults:esri_routing_accumulate_attributes_walking();
routing_accumulate_attributes(_) ->
    thinwrap_location_defaults:esri_routing_accumulate_attributes_driving().

%% ---------------------------------------------------------------------------
%% Route cost decoding

%% Per-leg distances/durations and the route totals, from the per-stop
%% cumulative costs.
%%
%% `Cumul_<attribute>` is the cost from the origin *to and including* that
%% stop, so a leg is the difference between consecutive stops and the total is
%% the last value — which is why legs always sum to the totals here.
%%
%% Two things are easy to get wrong:
%%
%% 1. Stops arrive in INPUT order while cumulative costs run along the route,
%%    so they must be sorted by `Sequence`. Without it an optimized route
%%    yields negative legs.
%% 2. The field name carries the active impedance — Cumul_TravelTime driving,
%%    Cumul_WalkTime walking. The connector reads `Cumul_<TimeAttr>` (the time
%%    attribute it requested for the mode) and Cumul_Kilometers by name, so
%%    extra accumulate attributes a caller adds (Miles, TruckTravelTime) can
%%    never change which fields feed the legs. Only when a requested field is
%%    absent — a caller replaced the list, or a custom travel mode with its own
%%    impedance — are the keys discovered by shape instead, in response order.
%%
%% `undefined` when the values are unusable: fewer than two stops, a stop that
%% failed to locate (Status =/= 0 carries no cumulative cost), a
%% non-monotonic sequence, or a service configured without the accumulate
%% attributes.
cumulative_stop_costs(Features, _OrderedFeatures, _TimeAttr) when length(Features) < 2 ->
    undefined;
cumulative_stop_costs(Features, OrderedFeatures, TimeAttr) ->
    Indexed = lists:zip(lists:seq(0, length(Features) - 1), Features),
    Rows0 = [
        {thinwrap_location_json:num_opt(thinwrap_location_json:get(A, <<"Sequence">>)), Idx, A}
     || {Idx, F} <- Indexed,
        A <- [
            case thinwrap_location_json:get(F, <<"attributes">>) of
                #{} = M -> M;
                _ -> #{}
            end
        ]
    ],
    case lists:any(fun({Seq, _, _}) -> Seq =:= undefined end, Rows0) of
        true ->
            undefined;
        false ->
            %% Sequence is 1-based; sorting by it (stably) puts the stops in
            %% route order.
            Rows = [A || {_, _, A} <- lists:keysort(1, Rows0)],
            {_, FirstIdx, FirstAttrs} = hd(lists:keysort(1, Rows0)),
            Keys = ordered_keys(
                opath(onth(OrderedFeatures, FirstIdx), [<<"attributes">>]), FirstAttrs
            ),
            CumulKeys = [K || K <- Keys, is_binary(K), has_prefix(K, <<"Cumul_">>)],
            DistanceKey =
                case lists:member(<<"Cumul_Kilometers">>, CumulKeys) of
                    true ->
                        <<"Cumul_Kilometers">>;
                    false ->
                        first(
                            fun(K) ->
                                contains(K, <<"Kilometers">>) orelse has_suffix(K, <<"Miles">>)
                            end,
                            CumulKeys
                        )
                end,
            WantTime = <<"Cumul_", TimeAttr/binary>>,
            TimeKey =
                case lists:member(WantTime, CumulKeys) of
                    true -> WantTime;
                    false -> first(fun(K) -> K =/= DistanceKey end, CumulKeys)
                end,
            case DistanceKey =:= undefined orelse TimeKey =:= undefined of
                true -> undefined;
                false -> cumulative_legs(Rows, DistanceKey, TimeKey)
            end
    end.

cumulative_legs(Rows, DistanceKey, TimeKey) ->
    ToMeters =
        case has_suffix(DistanceKey, <<"Miles">>) of
            true -> ?METERS_PER_MILE;
            false -> ?KM_TO_M
        end,
    Values = [
        case
            {
                thinwrap_location_json:num_opt(thinwrap_location_json:get(A, DistanceKey)),
                thinwrap_location_json:num_opt(thinwrap_location_json:get(A, TimeKey)),
                thinwrap_location_json:num_opt(thinwrap_location_json:get(A, <<"Status">>))
            }
        of
            {D, T, St} when
                is_float(D) andalso is_float(T) andalso (St =:= undefined orelse St == 0)
            ->
                {D * ToMeters, T * ?MIN_TO_SEC};
            %% Not located / not reached: no cumulative cost, so later diffs
            %% are wrong.
            _ ->
                undefined
        end
     || A <- Rows
    ],
    case lists:member(undefined, Values) of
        true ->
            undefined;
        false ->
            Legs = [
                #{distance_meters => D2 - D1, duration_seconds => T2 - T1}
             || {{D1, T1}, {D2, T2}} <- lists:zip(lists:droplast(Values), tl(Values))
            ],
            %% Cumulative costs never decrease, so a negative diff means wrong
            %% order.
            case
                lists:all(
                    fun(#{distance_meters := Dm, duration_seconds := Ds}) ->
                        Dm >= 0 andalso Ds >= 0
                    end,
                    Legs
                )
            of
                true ->
                    {LastD, LastT} = lists:last(Values),
                    {LastD, LastT, Legs};
                false ->
                    undefined
            end
    end.

%% The route's total distance in meters, matched by shape: the attribute is
%% suffixed with the active distance attribute and this service emits no
%% Total_Length. `undefined` when no distance attribute is present.
route_total_distance_meters(Attrs) ->
    case
        {
            thinwrap_location_json:num_opt(thinwrap_location_json:get(Attrs, <<"Total_Length">>)),
            thinwrap_location_json:num_opt(
                thinwrap_location_json:get(Attrs, <<"Total_Kilometers">>)
            ),
            thinwrap_location_json:num_opt(thinwrap_location_json:get(Attrs, <<"Total_Miles">>))
        }
    of
        {L, _, _} when is_float(L) -> L;
        {_, Km, _} when is_float(Km) -> Km * ?KM_TO_M;
        {_, _, Mi} when is_float(Mi) -> Mi * ?METERS_PER_MILE;
        _ -> undefined
    end.

%% The route's total duration in seconds: `Total_<TimeAttr>` when present,
%% else a shape-based match — the first `Total_*` (in response order) that is
%% not a distance attribute, in minutes. `undefined` when none is present.
route_total_duration_seconds(Attrs, Keys, TimeAttr) ->
    case
        {
            thinwrap_location_json:num_opt(thinwrap_location_json:get(Attrs, <<"Total_Time">>)),
            %% The requested time attribute before the shape scan, so an extra
            %% accumulated cost attribute is never read as minutes.
            thinwrap_location_json:num_opt(
                thinwrap_location_json:get(Attrs, <<"Total_", TimeAttr/binary>>)
            )
        }
    of
        {T, _} when is_float(T) ->
            T * ?MIN_TO_SEC;
        {_, T} when is_float(T) ->
            T * ?MIN_TO_SEC;
        _ ->
            Candidates = [
                V
             || K <- Keys,
                is_binary(K),
                has_prefix(K, <<"Total_">>),
                not (contains(K, <<"Kilometers">>) orelse contains(K, <<"Miles">>) orelse
                    contains(K, <<"Length">>)),
                V <- [thinwrap_location_json:num_opt(thinwrap_location_json:get(Attrs, K))],
                is_float(V)
            ],
            case Candidates of
                [V | _] -> V * ?MIN_TO_SEC;
                [] -> undefined
            end
    end.

%% Even split of the totals, used when per-stop cumulative costs are
%% unavailable.
even_split_legs(WaypointCount, TotalDist, TotalDur) ->
    N = max(1, WaypointCount - 1),
    [#{distance_meters => TotalDist / N, duration_seconds => TotalDur / N} || _ <- lists:seq(1, N)].

%% The optimized visiting sequence from the `stops` FeatureSet. Stops come
%% back in INPUT order, each carrying a 1-based Sequence = its position in the
%% optimized route; inverted into the canonical waypoint_order. A non-integer
%% Sequence is forwarded as undefined so the shared helper rejects the whole
%% ordering (it also enforces length, range and no duplicates).
waypoint_order(Stops, N) ->
    Positions = [
        case thinwrap_location_json:path(F, [<<"attributes">>, <<"Sequence">>]) of
            Seq when is_integer(Seq) -> Seq - 1;
            _ -> undefined
        end
     || F <- Stops
    ],
    thinwrap_location_util:invert_waypoint_positions(Positions, N).

%% ---------------------------------------------------------------------------
%% Vendor error mapping

http_error(Status, Headers, Body) ->
    Raw = thinwrap_location_json:decode(Body),
    thinwrap_location_error:provider_error(
        Status, Headers, Raw, map_vendor_error(Status, Raw), error_message(Raw)
    ).

body_error(Status, Body) ->
    thinwrap_location_error:classified(
        map_vendor_error(Status, Body),
        Status,
        thinwrap_location_json:get(Body, <<"error">>),
        error_message(Body)
    ).

map_vendor_error(Status, Body) ->
    case body_error_code(Body) of
        _ when Status =:= 429 -> rate_limited;
        429 ->
            rate_limited;
        C when C =:= 498; C =:= 499; C =:= 403 -> auth_failed;
        C when C =:= 400; C =:= 404 ->
            %% Esri has no distinct code for "no route": an unroutable stop
            %% comes back as HTTP 200 with error.code 400 and a details[] entry
            %% naming the stop as **unlocated** (live-verified). `unlocated` is
            %% Esri's own term for a stop it could not snap to the network, so
            %% matching it reads a stated condition rather than inferring one.
            case has_unlocated_stop(Body) of
                true -> no_route;
                false -> invalid_request
            end;
        500 ->
            provider_unavailable;
        C when is_integer(C) -> unknown;
        undefined when Status =:= 401; Status =:= 403 -> auth_failed;
        undefined when Status =:= 400 -> invalid_request;
        undefined when Status >= 500, Status < 600 -> provider_unavailable;
        undefined ->
            unknown
    end.

body_error_code(Body) ->
    case thinwrap_location_json:get(thinwrap_location_json:get(Body, <<"error">>), <<"code">>) of
        C when is_number(C) -> trunc(C);
        C when is_binary(C) -> matrix_oid(C);
        _ -> undefined
    end.

error_message(Body) ->
    E = thinwrap_location_json:get(Body, <<"error">>),
    case
        {
            thinwrap_location_json:str(thinwrap_location_json:get(E, <<"message">>)),
            thinwrap_location_json:get(E, <<"code">>)
        }
    of
        {<<>>, C} when is_number(C) ->
            integer_to_binary(trunc(C));
        {<<>>, C} when is_binary(C), C =/= <<>> ->
            C;
        {<<>>, _} ->
            case thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"message">>)) of
                <<>> -> thinwrap_location_json:str(E);
                M -> M
            end;
        {Em, _} ->
            Em
    end.

%% Whether an Esri error body names a stop it could not locate on the network.
%% Live-verified shape: HTTP 200 with `{"error": {"code": 400, "message":
%% "Unable to complete operation.", "details": ["Location \"Location 1\" in
%% \"Stops\" is unlocated. ..."]}}` — details[] is the only place the cause
%% appears.
has_unlocated_stop(Body) ->
    lists:any(
        fun(D) -> is_binary(D) andalso contains(string:lowercase(D), <<"unlocated">>) end,
        thinwrap_location_util:list_or_empty(
            thinwrap_location_json:path(Body, [<<"error">>, <<"details">>])
        )
    ).

%% Whether an Esri error body is reverseGeocode's "no address here" answer.
is_no_address(Body) ->
    E = thinwrap_location_json:get(Body, <<"error">>),
    body_error_code(Body) =:= 400 andalso
        lists:any(
            fun(T) -> contains(string:lowercase(T), <<"unable to find address">>) end,
            [
                thinwrap_location_json:str(thinwrap_location_json:get(E, <<"message">>))
                | [
                    thinwrap_location_json:str(D)
                 || D <- thinwrap_location_util:list_or_empty(
                        thinwrap_location_json:get(E, <<"details">>)
                    )
                ]
            ]
        ).

%% ---------------------------------------------------------------------------
%% Request helpers

%% Exactly one of api_key / arcgis_token. Checked per call rather than at
%% config validation, as in the sibling libraries: both set is
%% invalid_request, neither is auth_failed. An empty binary counts as unset.
bearer_token(Config) ->
    case {has_credential(Config, api_key), has_credential(Config, arcgis_token)} of
        {true, true} ->
            thinwrap_location_error:fail(
                thinwrap_location_error:invalid_request(
                    <<"esri config: api_key and arcgis_token are mutually exclusive — "/utf8,
                        "provide exactly one.">>
                )
            );
        {false, false} ->
            Msg = <<"esri config: one of api_key or arcgis_token is required.">>,
            thinwrap_location_error:fail(
                thinwrap_location_error:new(auth_failed, #{message => Msg, provider_message => Msg})
            );
        {true, false} ->
            thinwrap_location_input:secret(Config, api_key);
        {false, true} ->
            thinwrap_location_input:secret(Config, arcgis_token)
    end.

has_credential(Config, Key) ->
    case maps:find(Key, Config) of
        {ok, <<>>} -> false;
        {ok, _} -> true;
        error -> false
    end.

point_feature_set(Points) ->
    thinwrap_location_json:encode(#{
        <<"features">> => [
            #{
                <<"geometry">> => #{
                    <<"x">> => Lng, <<"y">> => Lat, <<"spatialReference">> => #{<<"wkid">> => 4326}
                }
            }
         || #{lat := Lat, lng := Lng} <- Points
        ]
    }).

%% The departure time form fields for routing (`startTime`) and the matrix
%% (`timeOfDay`): none for traffic_mode none, `now` for traffic without a
%% time, else the instant flagged as UTC — the `*IsUTC` flags default to
%% false, which makes Esri read the number as a clock time in the first
%% stop's (or facility's) local time zone and shift it by that zone's offset.
time_fields(TimeKey, UtcKey, Ms, I) ->
    case {thinwrap_location_util:traffic_requested(maps:get(traffic_mode, I)), Ms} of
        {false, _} -> [];
        {true, undefined} -> [{TimeKey, <<"now">>}];
        {true, _} -> [{TimeKey, integer_to_binary(Ms)}, {UtcKey, <<"true">>}]
    end.

departure_ms(undefined, _Label) -> undefined;
departure_ms(When, Label) -> epoch_ms(When, Label).

%% A departure time as Esri epoch milliseconds. Unix seconds and a
%% `calendar:datetime()` are UTC instants. A binary is parsed as ISO-8601; one
%% without an offset is read as UTC (parity with the siblings), NOT the host's
%% local zone — otherwise the same input yields a different instant per host.
%% An unparseable binary is invalid_request: dropping it would silently
%% compute a time-independent answer the caller did not ask for.
epoch_ms(Secs, _Label) when is_integer(Secs) ->
    Secs * 1000;
epoch_ms({{_, _, _}, {_, _, _}} = DT, Label) ->
    thinwrap_location_util:to_system_ms(DT, Label);
epoch_ms(Bin, Label) when is_binary(Bin) ->
    case parse_iso(Bin) of
        {ok, Ms} ->
            Ms;
        error ->
            thinwrap_location_error:fail(
                thinwrap_location_error:invalid_request(
                    <<Label/binary, " departure_time is not a valid ISO-8601 datetime: '",
                        Bin/binary, "'">>
                )
            )
    end.

parse_iso(Bin) ->
    Re =
        "^([0-9]{4})-([0-9]{2})-([0-9]{2})"
        "(?:[Tt ]([0-9]{2})(?::([0-9]{2})(?::([0-9]{2})(?:[.,]([0-9]+))?)?)?)?"
        "([Zz]|[+-][0-9]{2}(?::?[0-9]{2})?)?$",
    case re:run(Bin, Re, [{capture, all_but_first, binary}]) of
        {match, Groups} ->
            {Fields, [Frac, Off]} = lists:split(6, pad(Groups, 8)),
            [Year, Month, Day, Hour, Min, Sec] = [int(F) || F <- Fields],
            case
                calendar:valid_date(Year, Month, Day) andalso Hour < 24 andalso Min < 60 andalso
                    Sec < 60
            of
                true ->
                    case offset_seconds(Off) of
                        {ok, OffSecs} ->
                            Gs = calendar:datetime_to_gregorian_seconds(
                                {{Year, Month, Day}, {Hour, Min, Sec}}
                            ),
                            {ok, (Gs - 62167219200 - OffSecs) * 1000 + frac_ms(Frac)};
                        error ->
                            error
                    end;
                false ->
                    error
            end;
        nomatch ->
            error
    end.

%% Esri reports most failures as HTTP 200 with an `error` object.
check_body_error(Status, Raw) ->
    case thinwrap_location_json:get(Raw, <<"error">>) of
        undefined -> ok;
        _ -> thinwrap_location_error:fail(body_error(Status, Raw))
    end.

pad(L, N) -> L ++ lists:duplicate(N - length(L), <<>>).

int(<<>>) -> 0;
int(B) -> binary_to_integer(B).

frac_ms(<<>>) -> 0;
frac_ms(F) -> binary_to_integer(binary:part(<<F/binary, "000">>, 0, 3)).

offset_seconds(<<>>) ->
    {ok, 0};
offset_seconds(<<Z>>) when Z =:= $Z; Z =:= $z ->
    {ok, 0};
offset_seconds(<<Sign, Rest/binary>>) ->
    Digits = binary:replace(Rest, <<":">>, <<>>),
    {H, M} =
        case Digits of
            <<Hh:2/binary>> -> {int(Hh), 0};
            <<Hh:2/binary, Mm:2/binary>> -> {int(Hh), int(Mm)}
        end,
    case H < 24 andalso M < 60 of
        true when Sign =:= $+ -> {ok, H * 3600 + M * 60};
        true -> {ok, -(H * 3600 + M * 60)};
        false -> error
    end.

%% Form POST with the passthrough merged in: `body` keys overlay the form
%% fields (a passthrough `null` sends an empty value), `query` goes on the URL.
post_form(Config, Url, Form, I) ->
    {Merged, MHeaders, PtQuery} = merge_passthrough(Form, I),
    Final = [{K, stringify(V)} || {K, V} <- Merged],
    thinwrap_location_http:send_post_form(Config, Url, Final, MHeaders, PtQuery).

%% Overlay `passthrough.body` onto the ordered connector fields: a caller key
%% replaces the connector's value in place, new keys are appended. Every
%% connector value is a scalar or an already-encoded JSON string, so there is
%% nothing to deep-merge.
merge_passthrough(Base, I) ->
    PtBody = thinwrap_location_passthrough:body(I),
    {_, Headers, Query} = thinwrap_location_passthrough:merge(#{}, #{}, [], I),
    Replaced = [{K, maps:get(K, PtBody, V)} || {K, V} <- Base],
    Extra = [{K, V} || {K, V} <- lists:sort(maps:to_list(PtBody)), not lists:keymember(K, 1, Base)],
    {Replaced ++ Extra, Headers, Query}.

%% A form/query value as Esri expects it: strings verbatim, booleans as
%% `true`/`false`, numbers in fixed-point, null as empty, anything structured
%% as compact JSON.
stringify(B) when is_binary(B) -> B;
stringify(true) -> <<"true">>;
stringify(false) -> <<"false">>;
stringify(null) -> <<>>;
stringify(N) when is_number(N) -> thinwrap_location_util:fmt_coord(N);
stringify(A) when is_atom(A) -> atom_to_binary(A, utf8);
stringify(Other) -> thinwrap_location_json:encode(Other).

bool_bin(true) -> <<"true">>;
bool_bin(false) -> <<"false">>.

join(List) -> iolist_to_binary(lists:join(<<",">>, List)).

%% ---------------------------------------------------------------------------
%% Response-order access
%%
%% Python dicts keep the response's key order, and a few Esri decisions
%% depend on it: the shape-based Cumul_*/Total_* fallbacks pick the FIRST
%% matching key, and sparse-matrix cells are emitted in response order. Maps
%% do not keep order, so those paths read a second, order-preserving decode
%% where every object is `{ord, [{Key, Value}]}`.

ordered_decode(Bin) ->
    try
        json:decode(Bin, ok, #{
            object_finish => fun(Acc, Old) -> {{ord, lists:reverse(Acc)}, Old} end
        })
    of
        {Term, ok, _} -> Term
    catch
        _:_ -> undefined
    end.

opath(V, []) ->
    V;
opath({ord, KVs}, [K | Rest]) ->
    case lists:keyfind(K, 1, KVs) of
        {_, V} -> opath(V, Rest);
        false -> undefined
    end;
opath(_, _) ->
    undefined.

onth(L, I) when is_list(L), I >= 0, I < length(L) -> lists:nth(I + 1, L);
onth(_, _) -> undefined.

okvs({ord, KVs}) -> KVs;
okvs(_) -> [].

%% `Map`'s keys in response order (from `Ordered`), any the ordered view
%% missed appended in term order.
ordered_keys(Ordered, Map) ->
    OKeys = dedup([K || {K, _} <- okvs(Ordered), is_map_key(K, Map)]),
    OKeys ++ (lists:sort(maps:keys(Map)) -- OKeys).

%% `Map`'s entries in response order, from the ordered view when it matches.
%% Nested objects stay `{ord, _}` tuples.
ordered_kvs({ord, _} = Ordered, _Map) ->
    okvs(Ordered);
ordered_kvs(_, Map) ->
    [{K, to_ord(V)} || {K, V} <- lists:sort(maps:to_list(Map))].

to_ord(#{} = M) -> {ord, [{K, to_ord(V)} || {K, V} <- lists:sort(maps:to_list(M))]};
to_ord(V) -> V.

dedup(L) ->
    lists:reverse(
        lists:foldl(
            fun(X, Acc) ->
                case lists:member(X, Acc) of
                    true -> Acc;
                    false -> [X | Acc]
                end
            end,
            [],
            L
        )
    ).

%% ---------------------------------------------------------------------------
%% Small helpers

nth0(L, I) when I >= 0, I < length(L) -> lists:nth(I + 1, L);
nth0(_, _) -> undefined.

index_of(X, L) -> index_of(X, L, 0).
index_of(_, [], _) -> -1;
index_of(X, [X | _], I) -> I;
index_of(X, [_ | T], I) -> index_of(X, T, I + 1).

first_index([], _) -> -1;
first_index([Name | _], L) -> index_of(Name, L).

first(_, []) ->
    undefined;
first(F, [H | T]) ->
    case F(H) of
        true -> H;
        false -> first(F, T)
    end.

has_prefix(B, P) -> binary:longest_common_prefix([B, P]) =:= byte_size(P).

has_suffix(B, S) -> binary:longest_common_suffix([B, S]) =:= byte_size(S).

contains(B, P) -> binary:match(B, P) =/= nomatch.

%% The cost-column list as Python's repr prints it, for the error message.
py_repr_list(L) ->
    [
        "[",
        lists:join(", ", [
            case V of
                B when is_binary(B) -> ["'", B, "'"];
                _ -> thinwrap_location_json:encode(V)
            end
         || V <- L
        ]),
        "]"
    ].
