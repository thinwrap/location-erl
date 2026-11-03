-module(thinwrap_location_mapbox).
-moduledoc false.

%% Mapbox: routing (Directions / Optimized-Trips v1), matrix (Directions
%% Matrix), geocoding (Geocoding v6), autocomplete + place details (Search
%% Box), isochrone.

-export([
    route/2,
    matrix/2,
    geocode/2,
    reverse_geocode/2,
    autocomplete/2,
    place_details/2,
    isochrone/2
]).

-define(DIRECTIONS_URL, <<"https://api.mapbox.com/directions/v5/mapbox">>).
-define(OPTIMIZED_TRIPS_URL, <<"https://api.mapbox.com/optimized-trips/v1/mapbox">>).
-define(MATRIX_URL, <<"https://api.mapbox.com/directions-matrix/v1/mapbox">>).
-define(GEOCODE_FORWARD_URL, <<"https://api.mapbox.com/search/geocode/v6/forward">>).
-define(GEOCODE_REVERSE_URL, <<"https://api.mapbox.com/search/geocode/v6/reverse">>).
-define(SEARCHBOX_URL, <<"https://api.mapbox.com/search/searchbox/v1/suggest">>).
-define(RETRIEVE_URL, <<"https://api.mapbox.com/search/searchbox/v1/retrieve">>).
-define(ISOCHRONE_URL, <<"https://api.mapbox.com/isochrone/v1/mapbox">>).

%% ---------------------------------------------------------------------------
%% Routing

-doc false.
-spec route(thinwrap_location:config(), map()) -> thinwrap_location:route_result().
route(Config, #{waypoints := Wps} = I) ->
    length(Wps) >= 2 orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<"Mapbox Routing requires at least two waypoints">>
            )
        ),
    UseOptimized =
        maps:get(optimize, I) orelse maps:get(optimize_fixed_origin, I) orelse
            maps:get(optimize_fixed_destination, I) orelse maps:get(is_round_trip, I),
    {Resp, SentQuery} =
        case UseOptimized of
            true ->
                validate_optimized_compat(I),
                %% Optimization v1 has no driving-traffic profile, so traffic
                %% cannot be applied on this path and is ignored (documented).
                dispatch_optimized(Config, I, profile(maps:get(travel_mode, I), none));
            false ->
                dispatch_directions(
                    Config, I, profile(maps:get(travel_mode, I), maps:get(traffic_mode, I))
                )
        end,
    Geometries = effective_geometries(SentQuery),
    #{status := Status, headers := RH, body := RB} = Resp,
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(
            routing_vendor_error(Status, RH, thinwrap_location_json:decode(RB))
        ),
    Raw = thinwrap_location_json:decode(RB),
    is_map(Raw) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status, Raw, <<"Mapbox returned a malformed response body">>
            )
        ),
    case thinwrap_location_json:str(thinwrap_location_json:get(Raw, <<"code">>)) of
        Code when Code =/= <<>>, Code =/= <<"Ok">> ->
            thinwrap_location_error:fail(
                thinwrap_location_error:classified(
                    body_code(Code), Status, Raw, <<"Mapbox returned code: ", Code/binary>>
                )
            );
        _ ->
            ok
    end,
    Routes = first_truthy([
        thinwrap_location_json:get(Raw, <<"routes">>), thinwrap_location_json:get(Raw, <<"trips">>)
    ]),
    %% A 2xx with an empty routes/trips array is Mapbox saying "nothing found",
    %% not a malformed response.
    truthy(Routes) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:classified(
                no_route, Status, Raw, <<"Mapbox returned no routes">>
            )
        ),
    Route =
        case Routes of
            [R | _] when is_map(R) -> R;
            _ ->
                thinwrap_location_error:fail(
                    thinwrap_location_error:unknown(
                        Status, Raw, <<"Mapbox returned a malformed route">>
                    )
                )
        end,
    Legs = [
        leg(L, Status, Raw)
     || L <- thinwrap_location_util:list_or_empty(thinwrap_location_json:get(Route, <<"legs">>))
    ],
    {TotalDistance, TotalDuration} = distance_duration(Route, Status, Raw),
    %% Normalize the geometry to precision-5, decoding according to the
    %% `geometries` value actually sent — NOT the connector's polyline6
    %% default, which passthrough.query may have overridden.
    Polyline = normalize_geometry(
        thinwrap_location_json:get(Route, <<"geometry">>), Geometries, Status
    ),
    ok = thinwrap_location_util:assert_route_has_legs(
        length(Legs), length(Wps), <<"Mapbox Routing">>, Raw, Status
    ),
    WaypointOrder =
        case {UseOptimized, thinwrap_location_json:get(Raw, <<"waypoints">>)} of
            %% Canonical waypoint_order = full visiting sequence of INPUT
            %% indices (origin/destination inclusive). Mapbox returns
            %% waypoints[] in INPUT order, where each waypoint_index is the
            %% position that input waypoint occupies in the optimized trip —
            %% i.e. the INVERSE of the canonical. Invert it, validated against
            %% the INPUT waypoint count so a truncated or duplicate-index
            %% waypoints[] omits the ordering instead of yielding a permutation
            %% that silently drops or repeats a waypoint.
            {true, WpsOut} when is_list(WpsOut) ->
                thinwrap_location_util:invert_waypoint_positions(
                    [thinwrap_location_json:get(Wp, <<"waypoint_index">>) || Wp <- WpsOut],
                    length(Wps)
                );
            _ ->
                undefined
        end,
    thinwrap_location_util:put_opt(waypoint_order, WaypointOrder, #{
        legs => Legs,
        total_distance_meters => TotalDistance,
        total_duration_seconds => TotalDuration,
        polyline => Polyline,
        raw => Raw
    }).

dispatch_directions(Config, I, Profile) ->
    Coords = thinwrap_location_util:join_coords(maps:get(waypoints, I), lnglat, <<";">>),
    Url = <<?DIRECTIONS_URL/binary, "/", Profile/binary, "/", Coords/binary>>,
    Query =
        [
            {<<"access_token">>, token(Config)},
            {<<"geometries">>, <<"polyline6">>},
            {<<"overview">>, overview(I)}
        ] ++
            [{<<"exclude">>, Ex} || Ex <- [excludes(I, Profile)], Ex =/= <<>>] ++
            %% Mapbox documents `depart_at` for the driving profiles only.
            %% Walking and cycling durations do not depend on traffic, so leaving
            %% it off there returns the same route the caller would get with it.
            %% On plain `driving` it is also left off: there `depart_at` makes the
            %% duration "a prediction for travel time based on historical travel
            %% data" — typical traffic, which traffic_mode `none` promises not to
            %% add. Mapbox documents `depart_at` as one of exactly three ISO 8601
            %% forms, none carrying milliseconds — so seconds precision.
            [
                {<<"depart_at">>,
                    thinwrap_location_util:iso_seconds_string(DT, <<"departure_time">>)}
             || Profile =:= <<"driving-traffic">>,
                DT <- [maps:get(departure_time, I, undefined)],
                DT =/= undefined
            ],
    send_get(Config, Url, Query, I).

%% GET /optimized-trips/v1 — the single-vehicle waypoint-order optimizer that
%% matches every sibling provider (v2 is a fleet/VRP product for a future
%% multi-vehicle surface). v1 (OSRM-trip-based) supports an open route only as
%% source=first + destination=last, so plain optimize and the both-fixed case
%% keep BOTH endpoints and reorder the middle, matching Google/TomTom/HERE/Esri
%% (a single fixed endpoint is rejected up front); is_round_trip returns to the
%% first waypoint, and there Mapbox accepts destination=last as well (live:
%% roundtrip=true&destination=last → Ok).
dispatch_optimized(Config, I, Profile) ->
    Coords = thinwrap_location_util:join_coords(maps:get(waypoints, I), lnglat, <<";">>),
    Url = <<?OPTIMIZED_TRIPS_URL/binary, "/", Profile/binary, "/", Coords/binary>>,
    RoundTrip = maps:get(is_round_trip, I),
    Query =
        [
            {<<"access_token">>, token(Config)},
            {<<"geometries">>, <<"polyline6">>},
            {<<"overview">>, overview(I)},
            {<<"roundtrip">>, atom_to_binary(RoundTrip)},
            {<<"source">>, <<"first">>}
        ] ++
            [
                {<<"destination">>, <<"last">>}
             || not RoundTrip orelse maps:get(optimize_fixed_destination, I)
            ],
    send_get(Config, Url, Query, I).

leg(L, Status, Raw) ->
    {D, Du} = distance_duration(L, Status, Raw),
    #{distance_meters => D, duration_seconds => Du}.

%% Pre-flight checks for the Optimization v1 path. Its documented query
%% parameters are annotations, approaches, bearings, destination,
%% distributions, geometries, language, overview, radiuses, source, steps and
%% roundtrip, and "unrecognized options in the query string result in an
%% InvalidInput error" — so there is no `exclude` and no `depart_at` to send.
%% Refusing the options up front gives the caller a typed error naming the
%% option rather than a vendor InvalidInput. A departure time under traffic
%% mode `none`, or on walking/cycling (which have no traffic variant), has no
%% effect by definition, so it is dropped rather than refused.
validate_optimized_compat(I) ->
    validate_trip_endpoints(I),
    (maps:get(avoid_tolls, I) orelse maps:get(avoid_ferries, I) orelse
        maps:get(avoid_highways, I)) andalso
        thinwrap_location_error:fail(
            thinwrap_location_error:unsupported_option(
                <<
                    "Mapbox Optimization v1 does not support "
                    "avoid_tolls / avoid_ferries / avoid_highways"
                >>
            )
        ),
    (maps:is_key(departure_time, I) andalso driving_traffic(I)) andalso
        thinwrap_location_error:fail(
            unsupported_field(
                <<"Mapbox Optimization v1 does not support departure_time with traffic">>
            )
        ),
    ok.

%% Reject an open trip that pins exactly one endpoint. Optimization v1 answers
%% `first/any` and `any/last` with `200 {"code":"NotImplemented"}` when
%% `roundtrip=false` (live-verified), even though the OSRM Trip service it
%% descends from accepts both since v5.27. Quietly pinning the other endpoint
%% as well would return a route whose last (or first) stop the caller never
%% fixed, so the option is refused before any request.
validate_trip_endpoints(I) ->
    Origin = maps:get(optimize_fixed_origin, I),
    case maps:get(is_round_trip, I) orelse Origin =:= maps:get(optimize_fixed_destination, I) of
        true ->
            ok;
        false ->
            Pinned =
                case Origin of
                    true -> <<"optimize_fixed_origin">>;
                    false -> <<"optimize_fixed_destination">>
                end,
            thinwrap_location_error:fail(
                thinwrap_location_error:unsupported_option(
                    <<"Mapbox Optimization v1 cannot optimize an open route with only ",
                        Pinned/binary,
                        " set: with roundtrip=false only a fixed origin AND a fixed destination "
                        "is supported. Set both flags, or use is_round_trip.">>
                )
            )
    end.

%% Walking and cycling accept only a subset of exclude classes (live: `toll`
%% and `motorway` → 422 "exclude value must be one of: ferry,
%% cash_only_tolls, ..."). Nothing is lost by leaving those two off: tolls do
%% not apply to either mode, the cycling profile already avoids highways, and
%% walking follows sidewalks and trails. `ferry` is accepted by every profile.
excludes(I, Profile) ->
    Motorised = not lists:member(Profile, [<<"walking">>, <<"cycling">>]),
    Ex =
        [<<"toll">> || maps:get(avoid_tolls, I), Motorised] ++
            [<<"ferry">> || maps:get(avoid_ferries, I)] ++
            [<<"motorway">> || maps:get(avoid_highways, I), Motorised],
    iolist_to_binary(lists:join(<<",">>, Ex)).

%% `simplified` is the default and the reason is measured, not aesthetic: on
%% one ~140km route the simplified geometry was 203 characters against 6146
%% for `full` — a 30x payload for vertices most callers never look at, with
%% identical distances and durations.
%%
%% `steps` and `annotations` are deliberately NOT sent. Nothing in the route
%% result reads turn-by-turn steps or per-segment annotations, and steps are
%% the single largest part of a Mapbox routing response — so requesting them
%% inflated every response for data the wrapper then discarded. A consumer
%% who wants them adds `passthrough.query`.
overview(I) ->
    case maps:get(polyline_quality, I) of
        detailed -> <<"full">>;
        simplified -> <<"simplified">>
    end.

%% A route's or leg's `distance`/`duration`. Mapbox always sends both, so a
%% missing one is a malformed response — reading it as 0 would report a free,
%% instant trip.
distance_duration(Obj, Status, Raw) ->
    case
        {
            thinwrap_location_json:num_opt(thinwrap_location_json:get(Obj, <<"distance">>)),
            thinwrap_location_json:num_opt(thinwrap_location_json:get(Obj, <<"duration">>))
        }
    of
        {D, Du} when is_float(D), is_float(Du) ->
            {D, Du};
        _ ->
            thinwrap_location_error:fail(
                thinwrap_location_error:unknown(
                    Status, Raw, <<"Mapbox returned a route or leg without distance/duration">>
                )
            )
    end.

%% The `geometries` value actually sent, after passthrough.query merged over
%% the connector's own `polyline6`. The geometry decoder MUST match what was
%% requested: decoding a precision-5 `polyline` with the precision-6 decoder
%% divides every coordinate by 10 — a silent 10x position shift, not an error —
%% so the connector reads back its own effective query rather than assuming its
%% default survived the override.
effective_geometries(Query) ->
    case lists:keyfind(<<"geometries">>, 1, Query) of
        {_, V} when is_binary(V), V =/= <<>> -> V;
        _ -> <<"polyline6">>
    end.

%% Normalize a Mapbox route geometry to the canonical precision-5 polyline,
%% honouring the effective `geometries` parameter: `polyline6` (connector
%% default) is decoded at precision 6 and re-encoded at 5; `polyline` is
%% already precision-5 and emitted verbatim (as OSRM does); `geojson` has its
%% `[lng, lat]` pairs encoded at precision 5. An absent, empty or unusable
%% GeoJSON geometry yields `<<>>` rather than failing — the leg distances and
%% durations are still meaningful.
normalize_geometry(Geometry, <<"geojson">>, _Status) ->
    case thinwrap_location_json:get(Geometry, <<"coordinates">>) of
        Coords when is_list(Coords) -> geojson_polyline(Coords, []);
        _ -> <<>>
    end;
normalize_geometry(Geometry, Geometries, Status) ->
    case {thinwrap_location_json:str(Geometry), Geometries} of
        {<<>>, _} -> <<>>;
        {Encoded, <<"polyline">>} -> Encoded;
        {Encoded, _} -> thinwrap_location_polyline:encode(decode_p6(Encoded, Status))
    end.

geojson_polyline([], Acc) ->
    thinwrap_location_polyline:encode(lists:reverse(Acc));
geojson_polyline([[A, B | _] | Rest], Acc) ->
    %% GeoJSON is [lng, lat] order.
    case {thinwrap_location_json:num_opt(B), thinwrap_location_json:num_opt(A)} of
        {Lat, Lng} when is_float(Lat), is_float(Lng) ->
            geojson_polyline(Rest, [#{lat => Lat, lng => Lng} | Acc]);
        _ ->
            <<>>
    end;
geojson_polyline(_, _) ->
    <<>>.

%% Precision-6 polyline decoder. The shared decoder is locked to precision 5,
%% and this one also rejects characters above the 6-bit alphabet, so a
%% corrupt geometry is `unknown` instead of a fabricated coordinate.
decode_p6(Bin, Status) -> decode_p6(Bin, 0, 0, [], Status).

decode_p6(<<>>, _Lat, _Lng, Acc, _Status) ->
    lists:reverse(Acc);
decode_p6(Bin, Lat0, Lng0, Acc, Status) ->
    {DLat, R1} = p6_signed(Bin, 0, 0, Status),
    {DLng, R2} = p6_signed(R1, 0, 0, Status),
    Lat = Lat0 + DLat,
    Lng = Lng0 + DLng,
    decode_p6(R2, Lat, Lng, [#{lat => Lat / 1.0e6, lng => Lng / 1.0e6} | Acc], Status).

p6_signed(<<>>, _Shift, _Acc, Status) ->
    malformed_p6(Status);
p6_signed(<<C, Rest/binary>>, Shift, Acc, Status) ->
    B = C - 63,
    (B >= 0 andalso B =< 16#3F) orelse malformed_p6(Status),
    Acc1 = Acc bor ((B band 16#1F) bsl Shift),
    case B < 16#20 of
        true when Acc1 band 1 =:= 1 -> {bnot (Acc1 bsr 1), Rest};
        true -> {Acc1 bsr 1, Rest};
        false -> p6_signed(Rest, Shift + 5, Acc1, Status)
    end.

-spec malformed_p6(integer()) -> no_return().
malformed_p6(Status) ->
    Msg = <<"Malformed Mapbox polyline6 geometry">>,
    thinwrap_location_error:fail(
        thinwrap_location_error:new(unknown, #{
            status => Status, message => Msg, provider_message => Msg
        })
    ).

%% ---------------------------------------------------------------------------
%% Matrix

-doc false.
-spec matrix(thinwrap_location:config(), map()) -> thinwrap_location:matrix_result().
matrix(Config, #{origins := Os, destinations := Ds} = I) ->
    (Os =/= [] andalso Ds =/= []) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<"Mapbox Matrix requires non-empty origins and destinations">>
            )
        ),
    %% The Matrix API documents no `exclude`, and `depart_at` only as a sign-up
    %% beta; a standard account gets HTTP 422 "Request too large for custom
    %% parameters" for either. Refused up front rather than silently dropped,
    %% so the caller never receives cells computed without the constraint they
    %% set. A beta account can still send depart_at via passthrough.query.
    %% Under traffic mode `none`, and on walking/cycling (no traffic variant),
    %% the time has no effect by definition, so it is dropped rather than
    %% refused; only driving traffic at a given time is unanswerable.
    maps:get(avoid_tolls, I) andalso
        thinwrap_location_error:fail(
            thinwrap_location_error:unsupported_option(
                <<
                    "Mapbox Matrix does not support avoid_tolls "
                    "(the Matrix API has no exclude parameter)"
                >>
            )
        ),
    Profile = profile(maps:get(travel_mode, I), maps:get(traffic_mode, I)),
    (maps:is_key(departure_time, I) andalso Profile =:= <<"driving-traffic">>) andalso
        thinwrap_location_error:fail(
            unsupported_field(
                <<
                    "Mapbox Matrix does not support departure_time with traffic "
                    "(depart_at is a sign-up beta; send it via passthrough.query "
                    "if your account has it)"
                >>
            )
        ),
    No = length(Os),
    Nd = length(Ds),
    Coords = thinwrap_location_util:join_coords(Os ++ Ds, lnglat, <<";">>),
    Url = <<?MATRIX_URL/binary, "/", Profile/binary, "/", Coords/binary>>,
    %% `annotations` is a default, not an invariant: it sits in the base query
    %% so a consumer's passthrough.query replaces it like any other list default.
    Query = [
        {<<"access_token">>, token(Config)},
        {<<"sources">>, indices(0, No)},
        {<<"destinations">>, indices(No, Nd)},
        {<<"annotations">>, join(thinwrap_location_defaults:mapbox_matrix_annotations())}
    ],
    %% Matrix shares Directions' error envelope, including NoRoute / NoSegment
    %% on a 422, so the body code decides as it does for routing.
    {Status, Raw} = get_json(Config, Url, Query, I, fun routing_vendor_error/3, []),
    is_map(Raw) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status, Raw, <<"Mapbox Matrix returned a malformed response body">>
            )
        ),
    case thinwrap_location_json:get(Raw, <<"code">>) of
        <<"Ok">> ->
            ok;
        C ->
            Code = thinwrap_location_json:str(C),
            thinwrap_location_error:fail(
                thinwrap_location_error:classified(
                    body_code(Code), Status, Raw, <<"Mapbox returned code: ", Code/binary>>
                )
            )
    end,
    Durs = thinwrap_location_json:get(Raw, <<"durations">>),
    Dists = thinwrap_location_json:get(Raw, <<"distances">>),
    thinwrap_location_matrix:dimensions_ok(Durs, Dists, No, Nd) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status,
                Raw,
                iolist_to_binary([
                    "Mapbox Matrix returned a matrix that does not match the requested ",
                    integer_to_binary(No),
                    "x",
                    integer_to_binary(Nd),
                    " dimensions"
                ])
            )
        ),
    #{cells => thinwrap_location_matrix:grid_cells(Durs, Dists, No, Nd), raw => Raw}.

indices(From, Count) ->
    join([integer_to_binary(N) || N <- lists:seq(From, From + Count - 1)], <<";">>).

%% ---------------------------------------------------------------------------
%% Geocoding (Geocoding v6)

-doc false.
-spec geocode(thinwrap_location:config(), map()) -> thinwrap_location:geocode_result().
geocode(Config, #{address := Address} = I) ->
    Query =
        [{<<"q">>, Address}, {<<"access_token">>, token(Config)}] ++
            language(I) ++
            country(I),
    {_, Raw} = search_get(Config, ?GEOCODE_FORWARD_URL, Query, I, <<"features">>, false),
    #{candidates => normalize_features(Raw), raw => Raw}.

-doc false.
-spec reverse_geocode(thinwrap_location:config(), map()) -> thinwrap_location:geocode_result().
reverse_geocode(Config, #{location := #{lat := Lat, lng := Lng}} = I) ->
    Query =
        [
            {<<"longitude">>, thinwrap_location_util:fmt_coord(Lng)},
            {<<"latitude">>, thinwrap_location_util:fmt_coord(Lat)},
            {<<"access_token">>, token(Config)}
        ] ++ language(I),
    {_, Raw} = search_get(Config, ?GEOCODE_REVERSE_URL, Query, I, <<"features">>, false),
    #{candidates => normalize_features(Raw), raw => Raw}.

%% ---------------------------------------------------------------------------
%% Autocomplete (Search Box /suggest)

-doc false.
-spec autocomplete(thinwrap_location:config(), map()) -> thinwrap_location:autocomplete_result().
autocomplete(Config, #{input := Text} = I) ->
    %% Search Box requires `session_token` on /suggest and groups every call
    %% that shares one into a single billable session, closed by the /retrieve
    %% that carries the same value. The caller's token is what makes that
    %% grouping work; a fresh UUIDv4 (Mapbox's recommended format) keeps a
    %% one-off call valid when none is supplied.
    Query =
        [{<<"q">>, Text} | session_query(Config, I)] ++
            %% `country_filter` (ISO 3166-1 alpha-2) → Search Box `country=`
            %% (lowercase, comma-separated), same translation as forward geocode.
            country(I),
    {_, Raw} = search_get(Config, ?SEARCHBOX_URL, Query, I, <<"suggestions">>, false),
    Preds = [
        prediction(S)
     || S <- thinwrap_location_util:list_or_empty(
            thinwrap_location_json:get(Raw, <<"suggestions">>)
        )
    ],
    #{predictions => Preds, raw => Raw}.

prediction(S) ->
    %% Search Box returns `name` (the POI/street) and `place_formatted`
    %% (the rest of the address) as separate fields.
    Name = thinwrap_location_json:str(thinwrap_location_json:get(S, <<"name">>)),
    Description =
        case thinwrap_location_json:str(thinwrap_location_json:get(S, <<"full_address">>)) of
            <<>> -> Name;
            Full -> Full
        end,
    Structured =
        case Name of
            <<>> ->
                undefined;
            _ ->
                thinwrap_location_util:put_opt(
                    secondary_text,
                    thinwrap_location_util:nonempty(
                        thinwrap_location_json:str(
                            thinwrap_location_json:get(S, <<"place_formatted">>)
                        )
                    ),
                    #{main_text => Name}
                )
        end,
    P0 = thinwrap_location_util:put_opt(
        place_id,
        thinwrap_location_util:nonempty(
            thinwrap_location_json:str(thinwrap_location_json:get(S, <<"mapbox_id">>))
        ),
        #{description => Description}
    ),
    thinwrap_location_util:put_opt(structured_format, Structured, P0).

%% ---------------------------------------------------------------------------
%% Place details (Search Box /retrieve)

%% Pass the SAME `session_token` used for the preceding autocomplete: Search
%% Box bills per *session*, so a matching token makes suggest+retrieve one
%% billable session while a missing or fresh one makes it two.
%% `session_token` is required on /retrieve, so a UUIDv4 is generated when
%% none is supplied.
-doc false.
-spec place_details(thinwrap_location:config(), map()) -> thinwrap_location:place_details_result().
place_details(Config, #{place_id := PlaceId} = I) ->
    Query = session_query(Config, I),
    Url = <<?RETRIEVE_URL/binary, "/", (thinwrap_location_util:quote_segment(PlaceId))/binary>>,
    %% /retrieve answers an id it has no data for with 404 ("No data found for
    %% requested ID"): no such place, not a failed request.
    case search_get(Config, Url, Query, I, <<"features">>, true) of
        {404, Raw} ->
            #{raw => Raw};
        {_, Raw} ->
            %% Retrieve returns a GeoJSON FeatureCollection — the same shape as
            %% v6 geocode, so the geocode normalizer applies unchanged.
            case normalize_features(Raw) of
                [] ->
                    #{raw => Raw};
                [Cand | _] ->
                    Name =
                        case
                            {
                                lists:member(name, maps:get(include, I)),
                                thinwrap_location_util:list_or_empty(
                                    thinwrap_location_json:get(Raw, <<"features">>)
                                )
                            }
                        of
                            {true, [F | _]} ->
                                thinwrap_location_util:nonempty(
                                    thinwrap_location_json:str(
                                        thinwrap_location_json:path(F, [
                                            <<"properties">>, <<"name">>
                                        ])
                                    )
                                );
                            _ ->
                                undefined
                        end,
                    thinwrap_location_util:put_opt(name, Name, #{candidate => Cand, raw => Raw})
            end
    end.

%% GET a Search/Geocoding endpoint, returning `{Status, Raw}` with the result
%% list under `ListKey` checked present.
search_get(Config, Url, Query, I, ListKey, NotFoundIsEmpty) ->
    Passed = [404 || NotFoundIsEmpty],
    case get_json(Config, Url, Query, I, fun search_error/3, Passed) of
        {404, _Raw} = NotFound ->
            NotFound;
        {Status, Raw} = Found ->
            _ = thinwrap_location_error:require_list(Status, Raw, ListKey, <<"Mapbox Search">>),
            Found
    end.

%% Mapbox is GET-only with the token in the query: the caller's passthrough
%% adds headers and query parameters. Returns the response and the query
%% actually sent, which passthrough may have changed.
send_get(Config, Url, Query, I) ->
    {_, Headers, MQuery} = thinwrap_location_passthrough:merge(#{}, #{}, Query, I),
    {thinwrap_location_http:send_get(Config, Url, Headers, MQuery), MQuery}.

%% send_get/4 returning `{Status, DecodedBody}` (`undefined` when empty or
%% malformed). A non-2xx fails as `ToError(Status, Headers, DecodedBody)`,
%% except a status in `Passed`, left for the caller to interpret.
get_json(Config, Url, Query, I, ToError, Passed) ->
    {#{status := Status, headers := RH, body := RB}, _} = send_get(Config, Url, Query, I),
    Raw = thinwrap_location_json:decode(RB),
    thinwrap_location_util:ok_status(Status) orelse lists:member(Status, Passed) orelse
        thinwrap_location_error:fail(ToError(Status, RH, Raw)),
    {Status, Raw}.

%% A non-2xx from the Search, Geocoding or Isochrone APIs.
search_error(Status, RH, Raw) ->
    thinwrap_location_error:provider_error(Status, RH, Raw, status_code(Status), message(Raw)).

normalize_features(Raw) ->
    lists:filtermap(
        fun feature_candidate/1,
        thinwrap_location_util:list_or_empty(thinwrap_location_json:get(Raw, <<"features">>))
    ).

feature_candidate(F) ->
    case thinwrap_location_json:path(F, [<<"geometry">>, <<"coordinates">>]) of
        [A, B | _] ->
            located_candidate(
                F, thinwrap_location_json:num_opt(B), thinwrap_location_json:num_opt(A)
            );
        _ ->
            false
    end.

%% A feature without a numeric position is dropped, never placed at (0,0).
located_candidate(F, Lat, Lng) when is_float(Lat), is_float(Lng) ->
    Props = thinwrap_location_json:get(F, <<"properties">>),
    Addr =
        case
            thinwrap_location_json:str(
                thinwrap_location_json:get(Props, <<"full_address">>)
            )
        of
            <<>> ->
                thinwrap_location_json:str(
                    thinwrap_location_json:get(F, <<"place_name">>)
                );
            Full ->
                Full
        end,
    C0 = #{
        formatted_address => Addr, location => #{lat => Lat, lng => Lng}
    },
    C1 = thinwrap_location_util:put_opt(
        place_id,
        thinwrap_location_util:nonempty(
            thinwrap_location_json:str(
                thinwrap_location_json:get(Props, <<"mapbox_id">>)
            )
        ),
        C0
    ),
    {true,
        thinwrap_location_util:put_opt(
            viewport,
            viewport(thinwrap_location_json:get(Props, <<"bbox">>)),
            C1
        )};
located_candidate(_F, _Lat, _Lng) ->
    false.

%% [minLng, minLat, maxLng, maxLat]; dropped whole unless all four are numbers.
viewport([_, _, _, _] = Bbox) ->
    case [thinwrap_location_json:num_opt(C) || C <- Bbox] of
        [MinLng, MinLat, MaxLng, MaxLat] when
            is_float(MinLng), is_float(MinLat), is_float(MaxLng), is_float(MaxLat)
        ->
            #{
                southwest => #{lat => MinLat, lng => MinLng},
                northeast => #{lat => MaxLat, lng => MaxLng}
            };
        _ ->
            undefined
    end;
viewport(_) ->
    undefined.

%% ---------------------------------------------------------------------------
%% Isochrone

-doc false.
-spec isochrone(thinwrap_location:config(), map()) -> thinwrap_location:isochrone_result().
isochrone(Config, #{center := #{lat := Lat, lng := Lng}, type := Type, values := Values} = I) ->
    ok = thinwrap_location_isochrone:validate_cap(Values),
    IsTime = Type =:= time,
    %% Mapbox takes whole minutes / whole meters, in increasing order ("Times
    %% must be in increasing order"). `Sent` maps each wire value back to the
    %% caller's own value, so a 90 s break reads back as 90 s, not 2 min × 60.
    Sent = contour_values(Values, IsTime),
    Profile = profile(maps:get(travel_mode, I), none),
    Url =
        <<?ISOCHRONE_URL/binary, "/", Profile/binary, "/",
            (thinwrap_location_util:fmt_coord(Lng))/binary, ",",
            (thinwrap_location_util:fmt_coord(Lat))/binary>>,
    ContourKey =
        case IsTime of
            true -> <<"contours_minutes">>;
            false -> <<"contours_meters">>
        end,
    %% `polygons` is a connector default set BEFORE the merge so a consumer's
    %% passthrough.query can override it.
    Query =
        [
            {<<"access_token">>, token(Config)},
            {<<"polygons">>, <<"true">>},
            {ContourKey, join([integer_to_binary(K) || {K, _} <- Sent])}
        ] ++
            [
                {<<"depart_at">>, thinwrap_location_isochrone:departure(DT, <<"Mapbox Isochrone">>)}
             || DT <- [maps:get(departure_time, I, undefined)], DT =/= undefined
            ],
    {Status, Raw} = get_json(Config, Url, Query, I, fun search_error/3, []),
    is_map(Raw) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status, Raw, <<"Mapbox returned a non-JSON/unparseable body">>
            )
        ),
    Contours = [
        case
            {
                thinwrap_location_json:num_opt(
                    thinwrap_location_json:path(F, [<<"properties">>, <<"contour">>])
                ),
                polygon_parts(thinwrap_location_json:get(F, <<"geometry">>))
            }
        of
            {Contour, Parts} when is_float(Contour), Parts =/= [] ->
                #{
                    value => contour_value(Contour, IsTime, Sent),
                    geometry => thinwrap_location_isochrone:contour_geometry(Parts)
                };
            _ ->
                thinwrap_location_error:fail(
                    thinwrap_location_error:unknown(
                        Status,
                        Raw,
                        <<"Mapbox Isochrone returned a contour without a value or polygon">>
                    )
                )
        end
     || F <- thinwrap_location_util:list_or_empty(thinwrap_location_json:get(Raw, <<"features">>))
    ],
    Contours =/= [] orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status, Raw, <<"Mapbox Isochrone returned no contours">>
            )
        ),
    #{
        contours => lists:sort(fun(#{value := A}, #{value := B}) -> A =< B end, Contours),
        raw => Raw
    }.

%% A contour Mapbox echoes that the connector did not send (a passthrough.query
%% override) falls back to a plain unit conversion.
contour_value(Contour, IsTime, Sent) ->
    Fallback =
        case IsTime of
            true -> Contour * 60;
            false -> Contour
        end,
    case Contour == trunc(Contour) andalso lists:keyfind(trunc(Contour), 1, Sent) of
        {_, V} -> float(V);
        _ -> float(Fallback)
    end.

%% `[{WireValue, CallerValue}]` in ascending wire order. Mapbox accepts integer
%% minutes (`contours_minutes`) and integer meters (`contours_meters`) only,
%% in increasing order. A time break under 60 s rounds to 0 minutes, which
%% Mapbox rejects, and two breaks that round to the same integer would come
%% back as one contour — so both are refused up front rather than sent and
%% silently merged.
contour_values(Values, IsTime) ->
    lists:foldl(
        fun(V, Sent) ->
            (IsTime andalso V < 60) andalso
                thinwrap_location_error:fail(
                    thinwrap_location_error:invalid_request(
                        <<"Mapbox isochrone time breaks are whole minutes; ",
                            (thinwrap_location_util:fmt_coord(V))/binary,
                            " s is under the 60 s minimum">>
                    )
                ),
            Key =
                case IsTime of
                    true -> js_round(V / 60);
                    false -> js_round(V)
                end,
            Key > 0 orelse
                thinwrap_location_error:fail(
                    thinwrap_location_error:invalid_request(
                        <<"Mapbox isochrone distance breaks are whole meters; ",
                            (thinwrap_location_util:fmt_coord(V))/binary, " m rounds to 0">>
                    )
                ),
            case lists:keyfind(Key, 1, Sent) of
                {_, Prev} ->
                    Unit =
                        case IsTime of
                            true -> <<"minute">>;
                            false -> <<"meter">>
                        end,
                    thinwrap_location_error:fail(
                        thinwrap_location_error:invalid_request(
                            <<"Mapbox isochrone breaks ",
                                (thinwrap_location_util:fmt_coord(Prev))/binary, " and ",
                                (thinwrap_location_util:fmt_coord(V))/binary, " round to the same ",
                                Unit/binary, " (", (integer_to_binary(Key))/binary, ")">>
                        )
                    );
                false ->
                    Sent ++ [{Key, V}]
            end
        end,
        [],
        lists:sort(Values)
    ).

%% JavaScript Math.round (half toward +Infinity), like the siblings.
js_round(X) -> floor(X + 0.5).

%% A feature geometry as a list of `[Exterior | Holes]` parts; empty when
%% nothing polygonal is usable. GeoJSON allows a MultiPolygon feature, so one
%% is accepted alongside the Polygon that `polygons=true` normally returns; a
%% missing `type` is read as Polygon. Unusable pieces are skipped one at a
%% time, as the sibling libraries do: a part without a usable exterior is
%% dropped, an unusable hole is dropped from its part, and the remaining parts
%% are kept — one bad ring should not throw away the rest of the contour.
polygon_parts(Geometry) ->
    Coords = thinwrap_location_json:get(Geometry, <<"coordinates">>),
    Polygons =
        case thinwrap_location_json:get(Geometry, <<"type">>) of
            <<"MultiPolygon">> -> Coords;
            _ -> [Coords]
        end,
    [
        [Ext | [H || H <- Holes, is_ring(H)]]
     || [Ext | Holes] <- thinwrap_location_util:list_or_empty(Polygons), is_ring(Ext)
    ].

%% Whether `Ring` is a non-empty list of `[lng, lat]` number pairs.
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

%% ---------------------------------------------------------------------------
%% Vendor error mapping

message(Body) ->
    case thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"message">>)) of
        <<>> -> thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"error">>));
        M -> M
    end.

status_code(S) when S =:= 401; S =:= 403 -> auth_failed;
status_code(429) -> rate_limited;
status_code(S) when S =:= 422; S =:= 400 -> invalid_request;
status_code(S) when S >= 500, S < 600 -> provider_unavailable;
status_code(_) -> unknown.

%% NoRoute/NoTrips/NoSegment: the request was well-formed and Mapbox answered —
%% there is simply no connecting route (or no road near a coordinate to snap
%% to). Live-verified: Mapbox serves this on HTTP 200 as well as 422.
%% Optimization v1 answers a source/destination/roundtrip combination it does
%% not implement with HTTP 200 and NotImplemented (live-verified); reachable
%% when passthrough overrides the combination the connector chose.
body_code(C) when C =:= <<"NoRoute">>; C =:= <<"NoTrips">>; C =:= <<"NoSegment">> -> no_route;
body_code(C) when C =:= <<"InvalidInput">>; C =:= <<"ProfileNotFound">> -> invalid_request;
body_code(<<"NotImplemented">>) -> unsupported_option;
body_code(_) -> unknown.

routing_vendor_error(Status, Headers, Body) ->
    Code = thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"code">>)),
    Pc = routing_status_code(Status, Code),
    Msg =
        case {message(Body), Code} of
            {<<>>, <<>>} -> <<"Mapbox request failed: HTTP ", (integer_to_binary(Status))/binary>>;
            {<<>>, _} -> <<"Mapbox returned code: ", Code/binary>>;
            {M, _} -> M
        end,
    %% Through provider_error (like the matrix/isochrone paths) so a 429
    %% Retry-After lands in cause and the message/cause are redacted.
    thinwrap_location_error:provider_error(Status, Headers, Body, Pc, Msg).

routing_status_code(S, _Code) when S =:= 401; S =:= 403 ->
    auth_failed;
routing_status_code(429, _Code) ->
    rate_limited;
%% Live-verified: Mapbox serves its no-route envelope with HTTP 422 as well as
%% 200, so the envelope code — not the status — decides. ProcessingError is
%% Mapbox failing on a valid request, so it stays unknown. Every other 422
%% (InvalidInput, e.g. an exclude class the profile rejects) is a request the
%% caller has to change.
routing_status_code(422, C) when C =:= <<"NoRoute">>; C =:= <<"NoTrips">>; C =:= <<"NoSegment">> ->
    no_route;
routing_status_code(422, <<"ProcessingError">>) ->
    unknown;
routing_status_code(422, _Code) ->
    invalid_request;
routing_status_code(S, _Code) when S >= 500, S < 600 ->
    provider_unavailable;
routing_status_code(400, _Code) ->
    invalid_request;
routing_status_code(_S, _Code) ->
    unknown.

%% ---------------------------------------------------------------------------
%% Helpers

token(Config) -> thinwrap_location_input:secret(Config, access_token).

%% Mapbox selects traffic by PROFILE, not by a flag: driving-traffic on
%% Directions and Matrix. Walking and cycling have no traffic variant, so
%% traffic is ignored there.
driving_traffic(I) ->
    profile(maps:get(travel_mode, I), maps:get(traffic_mode, I)) =:= <<"driving-traffic">>.

profile(walking, _) ->
    <<"walking">>;
profile(cycling, _) ->
    <<"cycling">>;
profile(driving, Traffic) ->
    case thinwrap_location_util:traffic_requested(Traffic) of
        true -> <<"driving-traffic">>;
        false -> <<"driving">>
    end.

unsupported_field(Msg) ->
    thinwrap_location_error:new(unsupported_field, #{message => Msg, provider_message => Msg}).

language(I) ->
    [{<<"language">>, L} || L <- [maps:get(language, I, <<>>)], L =/= <<>>].

country(I) ->
    case maps:get(country_filter, I, []) of
        [] -> [];
        Cs -> [{<<"country">>, join([string:lowercase(C) || C <- Cs])}]
    end.

%% The query head shared by /suggest and /retrieve, in the order both send it.
session_query(Config, I) ->
    [{<<"access_token">>, token(Config)}, {<<"session_token">>, session_token(I)}] ++ language(I).

%% The caller's Search Box session token, else a fresh UUIDv4.
session_token(I) ->
    case maps:get(session_token, I, <<>>) of
        <<>> -> uuid4();
        T -> T
    end.

uuid4() ->
    <<A:48, _:4, B:12, _:2, C:62>> = crypto:strong_rand_bytes(16),
    <<U0:32, U1:16, U2:16, U3:16, U4:48>> = <<A:48, 4:4, B:12, 2:2, C:62>>,
    iolist_to_binary(
        io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [U0, U1, U2, U3, U4])
    ).

%% Python-style truthiness for a decoded JSON value: absent, null, false, 0,
%% "" and empty containers are all "nothing here".
truthy(undefined) -> false;
truthy(false) -> false;
truthy(<<>>) -> false;
truthy([]) -> false;
truthy(M) when is_map(M) -> map_size(M) > 0;
truthy(N) when is_number(N) -> N /= 0;
truthy(_) -> true.

first_truthy([V | Rest]) ->
    case truthy(V) of
        true -> V;
        false -> first_truthy(Rest)
    end;
first_truthy([]) ->
    [].

join(Parts) -> join(Parts, <<",">>).

join(Parts, Sep) -> iolist_to_binary(lists:join(Sep, Parts)).
