-module(thinwrap_location_here).
-moduledoc false.

%% HERE: routing (Routing v8, plus the legacy findsequence2 optimizer),
%% matrix (always-async Matrix v8), geocoding + autosuggest + lookup
%% (Geocoding & Search v7), isochrone (Isoline Routing v8).

-export([
    route/2, matrix/2, geocode/2, reverse_geocode/2, autocomplete/2, place_details/2, isochrone/2
]).

-define(ROUTER_URL, <<"https://router.hereapi.com/v8/routes">>).
-define(SEQUENCE_URL, <<"https://wps.hereapi.com/v8/findsequence2">>).
-define(MATRIX_URL, <<"https://matrix.router.hereapi.com/v8/matrix">>).
-define(MATRIX_HOST, <<"matrix.router.hereapi.com">>).
-define(GEOCODE_URL, <<"https://geocode.search.hereapi.com/v1/geocode">>).
-define(REVGEOCODE_URL, <<"https://revgeocode.search.hereapi.com/v1/revgeocode">>).
-define(AUTOSUGGEST_URL, <<"https://autosuggest.search.hereapi.com/v1/autosuggest">>).
-define(LOOKUP_URL, <<"https://lookup.search.hereapi.com/v1/lookup">>).
-define(ISOLINE_URL, <<"https://isoline.router.hereapi.com/v8/isolines">>).

%% ---------------------------------------------------------------------------
%% Routing

-doc false.
-spec route(thinwrap_location:config(), map()) -> thinwrap_location:route_result().
route(Config, #{waypoints := Wps} = I) ->
    length(Wps) >= 2 orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<"HERE Routing requires at least two waypoints">>
            )
        ),
    %% findsequence2 optimizes an OPEN route (fixed first/last waypoint); it
    %% cannot return a closed round trip. Surface the unsupported flag instead
    %% of silently returning an open route.
    (not maps:get(is_round_trip, I)) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:new(unsupported_option, #{
                message => <<"HERE route optimization does not support round trips (isRoundTrip)">>,
                provider_message =>
                    <<
                        "HERE findsequence2 optimizes an open route "
                        "(fixed first/last waypoint) and cannot return a closed round trip; "
                        "remove isRoundTrip or use a provider that supports it (e.g. Mapbox/OSRM)."
                    >>
            })
        ),
    UseOpt =
        maps:get(optimize, I) orelse maps:get(optimize_fixed_origin, I) orelse
            maps:get(optimize_fixed_destination, I),
    {Ordered, Order} =
        case UseOpt andalso length(Wps) > 2 of
            true ->
                {Sequence, SeqStatus} = find_sequence(Config, I),
                %% The sequence must be a complete permutation before it can
                %% reorder the waypoints, or the follow-up /routes request would
                %% drop or duplicate a stop. HERE is the one connector that fails
                %% rather than omitting the ordering, because the sequence also
                %% drives that request.
                thinwrap_location_util:is_complete_waypoint_order(Sequence, length(Wps)) orelse
                    thinwrap_location_error:fail(
                        thinwrap_location_error:new(unknown, #{
                            status => SeqStatus,
                            message =>
                                <<"HERE findsequence2 returned an invalid waypoint ordering">>,
                            provider_message =>
                                <<"HERE findsequence2 returned an invalid waypoint ordering">>,
                            cause => #{<<"sequence">> => Sequence}
                        })
                    ),
                {[lists:nth(X + 1, Wps) || X <- Sequence], Sequence};
            false ->
                {Wps, undefined}
        end,
    thinwrap_location_util:put_opt(waypoint_order, Order, call_routes(Config, Ordered, I)).

call_routes(Config, Waypoints, I) ->
    First = hd(Waypoints),
    Last = lists:last(Waypoints),
    Intermediates = lists:droplast(tl(Waypoints)),
    Traffic = thinwrap_location_util:traffic_requested(maps:get(traffic_mode, I)),
    DT = maps:get(departure_time, I, undefined),
    %% HERE applies live traffic whenever departureTime is omitted (it assumes
    %% "now"), and bills such requests as Time-Aware Routing rather than basic
    %% Routing unless the request carries departureTime=any or
    %% traffic[mode]=disabled, so traffic_mode none must say so explicitly.
    %% `any` still honours long-term closures; `disabled` is the only switch
    %% that keeps a caller-supplied time, at the cost of ignoring those closures
    %% too. A time supplied through passthrough counts as well: HERE rejects
    %% `any` combined with arrivalTime (400), and a passthrough departureTime
    %% would replace `any` and silently restore Time-Aware billing. Set before
    %% the passthrough merge so a caller can still override either key.
    CarriesTime = carries_time(DT, pt_query(I)),
    Query0 =
        [
            {<<"apiKey">>, key(Config)},
            {<<"transportMode">>, transport_mode(I)},
            {<<"return">>, join(thinwrap_location_defaults:here_routing_return())},
            {<<"routingMode">>, <<"fast">>},
            {<<"origin">>, thinwrap_location_util:to_lat_lng(First)},
            {<<"destination">>, thinwrap_location_util:to_lat_lng(Last)}
        ] ++ departure_time_field(DT),
    Query1 =
        case {Traffic, CarriesTime} of
            {true, _} -> Query0;
            {false, true} -> Query0 ++ [{<<"traffic[mode]">>, <<"disabled">>}];
            {false, false} -> Query0 ++ [{<<"departureTime">>, <<"any">>}]
        end,
    Query =
        Query1 ++ [{<<"avoid[features]">>, AF} || AF <- [avoid_features(I)], AF =/= <<>>],
    {MHeaders, MQuery} = passthrough_get(Query, I),
    %% `via` is a repeated key, appended after the merge like the siblings do.
    Vias = [{<<"via">>, thinwrap_location_util:to_lat_lng(W)} || W <- Intermediates],
    {Status, Raw} = send_json(Config, ?ROUTER_URL, MHeaders, MQuery ++ Vias),
    Route =
        case thinwrap_location_json:get(Raw, <<"routes">>) of
            [R | _] ->
                R;
            Routes ->
                falsy(Routes) orelse
                    %% A truthy non-list cannot hold a route: malformed, below.
                    throw_route_unknown(Status, Raw),
                %% Live-verified: HERE answers an unroutable request with HTTP
                %% 200, routes: [], and a critical entry in notices[] (e.g.
                %% couldNotMatchOrigin). The notice is the only statement of
                %% *why*, so it is surfaced.
                Msg =
                    case notice(Raw) of
                        undefined -> <<"HERE Routing returned no routes">>;
                        Notice -> <<"HERE Routing returned no routes: ", Notice/binary>>
                    end,
                thinwrap_location_error:fail(
                    thinwrap_location_error:classified(no_route, Status, Raw, Msg)
                )
        end,
    RawSections = thinwrap_location_json:get(Route, <<"sections">>),
    (is_map(Route) andalso
        lists:all(fun is_map/1, thinwrap_location_util:list_or_empty(RawSections))) orelse
        throw_route_unknown(Status, Raw),
    Sections = thinwrap_location_util:list_or_empty(RawSections),
    %% HERE ships baseDuration inside the summary block already requested, so
    %% the opt-in costs nothing extra; it only gates whether the field is
    %% surfaced, keeping the normalized shape identical across providers.
    WantsBase = lists:member(durationWithoutTraffic, maps:get(include, I)),
    Coords = lists:append([
        thinwrap_location_polyline:decode_flex_or_fail(P)
     || S <- Sections,
        P <- [thinwrap_location_json:str(thinwrap_location_json:get(S, <<"polyline">>))],
        P =/= <<>>
    ]),
    SectionLegs = [section_leg(S, WantsBase) || S <- Sections],
    Legs = group_sections_into_legs(Sections, SectionLegs, length(Waypoints)),
    ok = thinwrap_location_util:assert_route_has_legs(
        length(Legs), length(Waypoints), <<"HERE Routing">>, Raw, Status
    ),
    %% Summed from the sections HERE returned, matching how the traffic-aware
    %% totals are derived, and only when EVERY section carried the value, so a
    %% partial response omits the field rather than under-reporting it.
    TotalBase =
        case WantsBase andalso SectionLegs =/= [] of
            true -> total_base(SectionLegs);
            false -> undefined
        end,
    thinwrap_location_util:put_opt(total_duration_without_traffic_seconds, TotalBase, #{
        legs => Legs,
        total_distance_meters => sum([maps:get(distance_meters, L) || L <- SectionLegs]),
        total_duration_seconds => sum([maps:get(duration_seconds, L) || L <- SectionLegs]),
        polyline => thinwrap_location_polyline:encode(Coords),
        raw => Raw
    }).

-spec throw_route_unknown(integer(), term()) -> no_return().
throw_route_unknown(Status, Raw) ->
    thinwrap_location_error:fail(
        thinwrap_location_error:unknown(Status, Raw, <<"HERE Routing returned a malformed route">>)
    ).

section_leg(S, WantsBase) ->
    Summ = thinwrap_location_json:get(S, <<"summary">>),
    Base =
        case WantsBase of
            true ->
                thinwrap_location_json:num_opt(
                    thinwrap_location_json:get(Summ, <<"baseDuration">>)
                );
            false ->
                undefined
        end,
    thinwrap_location_util:put_opt(duration_without_traffic_seconds, Base, #{
        distance_meters => thinwrap_location_json:num(
            thinwrap_location_json:get(Summ, <<"length">>)
        ),
        duration_seconds => thinwrap_location_json:num(
            thinwrap_location_json:get(Summ, <<"duration">>)
        )
    }).

all_have_base(Legs) ->
    lists:all(fun(L) -> maps:is_key(duration_without_traffic_seconds, L) end, Legs).

%% The summed duration_without_traffic, `undefined` unless every leg has one.
total_base(Legs) ->
    case all_have_base(Legs) of
        true -> sum([maps:get(duration_without_traffic_seconds, L) || L <- Legs]);
        false -> undefined
    end.

%% Fold HERE route sections into one leg per consecutive waypoint pair.
%%
%% A section is the stretch between consecutive waypoints OR an implicit mode
%% change — a ferry or car shuttle inside a driving route starts its own
%% transit section — so sections are not legs. The waypoint boundary is
%% marked on the place itself: `arrival.place.waypoint` is present when that
%% place is the `via` with the same index, and absent for the origin, the
%% destination and any stop the router added. A leg therefore closes after a
%% section whose arrival carries `waypoint`, and after the final section.
%% Values are summed across the group; duration_without_traffic only when
%% every grouped section carried it. With no marker anywhere and exactly one
%% section per waypoint pair, the sections already are the legs.
group_sections_into_legs(Sections, SectionLegs, WaypointCount) ->
    Closes = [
        thinwrap_location_json:path(S, [<<"arrival">>, <<"place">>, <<"waypoint">>]) =/= undefined
     || S <- Sections
    ],
    case (not lists:member(true, Closes)) andalso length(SectionLegs) =:= WaypointCount - 1 of
        true -> SectionLegs;
        false -> group(lists:zip(Closes, SectionLegs), [], [])
    end.

group([], _Group, Acc) ->
    lists:reverse(Acc);
group([{Close, Leg} | Rest], Group0, Acc) ->
    Group = [Leg | Group0],
    case Close orelse Rest =:= [] of
        true -> group(Rest, [], [merge_group(lists:reverse(Group)) | Acc]);
        false -> group(Rest, Group, Acc)
    end.

merge_group(Group) ->
    thinwrap_location_util:put_opt(duration_without_traffic_seconds, total_base(Group), #{
        distance_meters => sum([maps:get(distance_meters, L) || L <- Group]),
        duration_seconds => sum([maps:get(duration_seconds, L) || L <- Group])
    }).

find_sequence(Config, #{waypoints := Wps} = I) ->
    First = hd(Wps),
    Last = lists:last(Wps),
    Intermediates = lists:droplast(tl(Wps)),
    Query =
        [
            {<<"apiKey">>, key(Config)},
            {<<"start">>, thinwrap_location_util:to_lat_lng(First)},
            {<<"end">>, thinwrap_location_util:to_lat_lng(Last)},
            %% The avoid features ride in `mode` so the optimizer orders the
            %% stops under the same constraints the follow-up /routes call
            %% honours — otherwise the ordering and the route can disagree.
            %% Traffic is kept separate because enabling it on findsequence2
            %% is BILLABLE, so it follows the explicit traffic_mode opt-in.
            {<<"mode">>, sequence_mode(transport_mode(I), I)}
        ] ++
            %% findsequence2 documents the departure-time param as `departure`
            %% (ISO 8601) and ignores an unrecognized `departureTime` without an
            %% error. Seconds precision: the endpoint 400s on a fractional value.
            [
                {<<"departure">>,
                    thinwrap_location_util:iso_seconds_string(DT, <<"departure_time">>)}
             || DT <- [maps:get(departure_time, I, undefined)], DT =/= undefined
            ] ++
            [
                {
                    <<"destination", (integer_to_binary(N))/binary>>,
                    thinwrap_location_util:to_lat_lng(W)
                }
             || {N, W} <- lists:zip(lists:seq(1, length(Intermediates)), Intermediates)
            ],
    %% Passthrough (query + headers) applies to this leg too, so a consumer
    %% can tune the sequence request as well as the route.
    {Status, Raw} = get_json(Config, ?SEQUENCE_URL, Query, I),
    Entries = waypoint_entries(
        case thinwrap_location_json:list(thinwrap_location_json:get(Raw, <<"results">>)) of
            [FirstResult | _] -> thinwrap_location_json:get(FirstResult, <<"waypoints">>);
            _ -> undefined
        end,
        Status,
        Raw
    ),
    Sorted = [
        E
     || {_, E} <- lists:keysort(1, [
            {thinwrap_location_json:num(thinwrap_location_json:get(E, <<"sequence">>)), E}
         || E <- Entries
        ])
    ],
    LastIndex = length(Wps) - 1,
    Absolute = lists:filtermap(
        fun(E) ->
            case thinwrap_location_json:str(thinwrap_location_json:get(E, <<"id">>)) of
                <<"start">> ->
                    {true, 0};
                <<"end">> ->
                    {true, LastIndex};
                <<"destination", Rest/binary>> ->
                    try binary_to_integer(string:trim(Rest)) of
                        N when N >= 1, N < LastIndex -> {true, N};
                        _ -> false
                    catch
                        error:badarg -> false
                    end;
                _ ->
                    false
            end
        end,
        Sorted
    ),
    {Absolute, Status}.

%% The first result's `waypoints`, which must be a list of objects.
waypoint_entries(Entries, Status, Raw) when is_list(Entries) ->
    case lists:all(fun is_map/1, Entries) of
        true -> Entries;
        false -> no_sequence(Status, Raw)
    end;
waypoint_entries(_Entries, Status, Raw) ->
    no_sequence(Status, Raw).

%% The legacy WPS endpoint also reports a rejected request as HTTP 200 with
%% {"results": null, "errors": [...], "responseCode": "400"}, so the reason
%% arrives here rather than via http_error.
-spec no_sequence(integer(), term()) -> no_return().
no_sequence(Status, Raw) ->
    Msg =
        case error_message(Raw) of
            <<>> -> <<"HERE findsequence2 returned no sequence">>;
            Reason -> <<"HERE findsequence2 returned no sequence: ", Reason/binary>>
        end,
    thinwrap_location_error:fail(thinwrap_location_error:unknown(Status, Raw, Msg)).

%% The findsequence2 `mode`: `Type;TransportModes;TrafficMode;Feature:weight,...`.
%% The road features share ONE segment, comma-delimited, and `-3` means
%% "strictly avoid". Ferries are two features there (boatFerry, railFerry)
%% where /routes has one `ferry`, so both are avoided.
sequence_mode(TransportMode, I) ->
    Traffic =
        case thinwrap_location_util:traffic_requested(maps:get(traffic_mode, I)) of
            true -> <<"enabled">>;
            false -> <<"disabled">>
        end,
    Features =
        [<<"tollroad:-3">> || maps:get(avoid_tolls, I)] ++
            [<<"motorway:-3">> || maps:get(avoid_highways, I)] ++
            lists:append([[<<"boatFerry:-3">>, <<"railFerry:-3">>] || maps:get(avoid_ferries, I)]),
    Mode = <<"fastest;", TransportMode/binary, ";traffic:", Traffic/binary>>,
    case Features of
        [] -> Mode;
        _ -> <<Mode/binary, ";", (join(Features))/binary>>
    end.

%% ---------------------------------------------------------------------------
%% Matrix (always async: submit -> poll -> retrieve)

-doc false.
-spec matrix(thinwrap_location:config(), map()) -> thinwrap_location:matrix_result().
matrix(Config, #{origins := Os, destinations := Ds} = I0) ->
    (Os =/= [] andalso Ds =/= []) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<"HERE Matrix requires at least one origin and one destination">>
            )
        ),
    Deadline = thinwrap_location_matrix:poll_deadline(I0),
    I = thinwrap_location_matrix:strip_timeout(I0),
    {MatrixId, StatusUrl} = submit(Config, I),
    ResultUrl = poll(Config, MatrixId, StatusUrl, Deadline),
    retrieve(Config, ResultUrl, length(Os), length(Ds)).

submit(Config, #{origins := Os, destinations := Ds} = I) ->
    Profile = transport_mode(I),
    Traffic = thinwrap_location_util:traffic_requested(maps:get(traffic_mode, I)),
    DT = maps:get(departure_time, I, undefined),
    %% Matrix v8 is a single SKU, but like /v8/routes it computes against live
    %% traffic whenever departureTime is omitted, which contradicts the
    %% traffic_mode none default. Same switches as routing (see call_routes),
    %% in body form, including the passthrough time fields (matrix also 400s
    %% on `any` + arrivalTime).
    CarriesTime = carries_time(DT, thinwrap_location_passthrough:body(I)),
    Body0 = #{
        <<"origins">> => [#{<<"lat">> => Lat, <<"lng">> => Lng} || #{lat := Lat, lng := Lng} <- Os],
        <<"destinations">> => [
            #{<<"lat">> => Lat, <<"lng">> => Lng}
         || #{lat := Lat, lng := Lng} <- Ds
        ],
        <<"regionDefinition">> => #{<<"type">> => <<"autoCircle">>},
        <<"matrixAttributes">> => thinwrap_location_defaults:here_matrix_attributes()
    },
    Body1 = maps:merge(
        Body0,
        maps:from_list(
            [{<<"transportMode">>, Profile} || Profile =/= <<"car">>] ++
                [
                    {<<"avoid">>, #{<<"features">> => [<<"tollRoad">>]}}
                 || maps:get(avoid_tolls, I)
                ] ++
                departure_time_field(DT)
        )
    ),
    Body =
        case {Traffic, CarriesTime} of
            {true, _} -> Body1;
            {false, true} -> Body1#{<<"traffic">> => #{<<"mode">> => <<"disabled">>}};
            {false, false} -> Body1#{<<"departureTime">> => <<"any">>}
        end,
    Query = [{<<"apiKey">>, key(Config)}, {<<"async">>, <<"true">>}],
    {MBody, MHeaders, MQuery} = thinwrap_location_passthrough:merge(Body, #{}, Query, I),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_location_http:send_post_json(Config, ?MATRIX_URL, MBody, MHeaders, MQuery),
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(http_error(Status, RH, RB)),
    St = thinwrap_location_json:decode(RB),
    case
        {
            thinwrap_location_json:str(thinwrap_location_json:get(St, <<"matrixId">>)),
            thinwrap_location_json:str(thinwrap_location_json:get(St, <<"statusUrl">>))
        }
    of
        {Id, Url} when Id =/= <<>>, Url =/= <<>> ->
            {Id, Url};
        _ ->
            thinwrap_location_error:fail(
                thinwrap_location_error:unknown(
                    Status, St, <<"HERE Matrix submit response missing matrixId or statusUrl">>
                )
            )
    end.

poll(Config, MatrixId, StatusUrl, DeadlineMs) ->
    assert_here_api_url(StatusUrl, <<"statusUrl">>),
    Sleep = maps:get(sleep, Config, fun timer:sleep/1),
    DeadlineAt = erlang:monotonic_time(millisecond) + DeadlineMs,
    poll_loop(
        Config,
        Sleep,
        MatrixId,
        StatusUrl,
        DeadlineAt,
        thinwrap_location_matrix:poll_initial_delay_ms()
    ).

poll_loop(Config, Sleep, MatrixId, StatusUrl, DeadlineAt, Delay) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= DeadlineAt of
        true ->
            thinwrap_location_error:fail(
                thinwrap_location_error:new(matrix_polling_timeout, #{
                    message => <<"HERE Matrix polling deadline exceeded">>,
                    provider_message => <<"matrixId: ", MatrixId/binary>>,
                    cause => #{<<"matrixId">> => MatrixId, <<"statusUrl">> => StatusUrl}
                })
            );
        false ->
            _ = Sleep(ceil(min(Delay, DeadlineAt - Now))),
            Next = min(
                thinwrap_location_matrix:poll_max_delay_ms(),
                round(Delay * thinwrap_location_matrix:poll_backoff())
            ),
            Resp =
                #{status := Status, headers := RH, body := RB} =
                thinwrap_location_http:send_get(Config, StatusUrl, #{}, [
                    {<<"apiKey">>, key(Config)}
                ]),
            case Status of
                %% On completion Matrix v8 answers 303 See Other with
                %% Location: <resultUrl> and a {matrixId, status: "completed",
                %% resultUrl} body. Handled BEFORE the non-2xx guard: a 303 is
                %% not a failure. The default transport never follows
                %% redirects, so the 303 is observable here.
                303 ->
                    require_result_url(Resp, thinwrap_location_json:decode(RB));
                _ ->
                    thinwrap_location_util:ok_status(Status) orelse
                        thinwrap_location_error:fail(http_error(Status, RH, RB)),
                    St = thinwrap_location_json:decode(RB),
                    case job_state(St) of
                        %% Belt-and-braces alongside the 303 path.
                        <<"completed">> ->
                            require_result_url(Resp, St);
                        <<"failed">> ->
                            thinwrap_location_error:fail(
                                thinwrap_location_error:new(provider_unavailable, #{
                                    status => Status,
                                    provider_message => <<"HERE Matrix job failed">>,
                                    cause => St
                                })
                            );
                        _ ->
                            poll_loop(Config, Sleep, MatrixId, StatusUrl, DeadlineAt, Next)
                    end
            end
    end.

%% A status body's `status`, falling back to `state`.
job_state(St) ->
    case thinwrap_location_json:str(thinwrap_location_json:get(St, <<"status">>)) of
        <<>> -> thinwrap_location_json:str(thinwrap_location_json:get(St, <<"state">>));
        S -> S
    end.

%% The async resultUrl from a completed poll: the body's `resultUrl`
%% (present in both the 303 body and a 200 completed body), else the
%% `Location` header set on the 303.
require_result_url(#{status := Status, headers := RH}, Body) ->
    case thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"resultUrl">>)) of
        <<>> ->
            case header(RH, <<"location">>) of
                <<>> ->
                    thinwrap_location_error:fail(
                        thinwrap_location_error:unknown(
                            Status, Body, <<"HERE Matrix poll completed without resultUrl">>
                        )
                    );
                Loc ->
                    Loc
            end;
        Url ->
            Url
    end.

retrieve(Config, ResultUrl, No, Nd) ->
    assert_here_api_url(ResultUrl, <<"resultUrl">>),
    %% GET the validated hereapi.com resultUrl WITH the apiKey (401 without)
    %% and Accept-Encoding: gzip (406 Not Acceptable without). HERE answers 303
    %% to a pre-signed storage URL rather than inline; that single hop is
    %% followed manually so the apiKey never leaves the HERE host.
    Gzip = #{<<"Accept-Encoding">> => <<"gzip">>},
    Resp0 = thinwrap_location_http:send_get(Config, ResultUrl, Gzip, [{<<"apiKey">>, key(Config)}]),
    #{status := Status, headers := RH, body := RB} =
        case Resp0 of
            #{status := S0, headers := H0} when S0 >= 300, S0 < 400 ->
                Location =
                    case header(H0, <<"location">>) of
                        <<>> ->
                            thinwrap_location_error:fail(
                                thinwrap_location_error:unknown(
                                    S0,
                                    undefined,
                                    <<"HERE Matrix retrieve redirect missing Location header">>
                                )
                            );
                        L ->
                            L
                    end,
                %% The pre-signed URL is self-authenticating and lives off the
                %% HERE host, so it is NOT host-checked and never gets the key —
                %% but a plaintext or other-scheme downgrade is refused.
                https(Location) orelse
                    thinwrap_location_error:fail(
                        thinwrap_location_error:unknown(
                            S0, undefined, <<"HERE Matrix result redirect must be an https URL">>
                        )
                    ),
                thinwrap_location_http:send_get(Config, Location, Gzip, []);
            _ ->
                Resp0
        end,
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(http_error(Status, RH, RB)),
    Raw = thinwrap_location_json:decode(gunzip_if_needed(RH, RB)),
    Matrix = thinwrap_location_json:get(Raw, <<"matrix">>),
    is_map(Matrix) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status, Raw, <<"HERE Matrix retrieve missing matrix payload">>
            )
        ),
    Stride =
        case
            thinwrap_location_json:num(thinwrap_location_json:get(Matrix, <<"numDestinations">>))
        of
            N when N > 0 -> trunc(N);
            _ -> Nd
        end,
    Expected = (No - 1) * Stride + Nd,
    Tt = value_tuple(thinwrap_location_json:get(Matrix, <<"travelTimes">>), Expected, Status, Raw),
    Di = value_tuple(thinwrap_location_json:get(Matrix, <<"distances">>), Expected, Status, Raw),
    %% Per-cell status parallel to travelTimes/distances (0 = OK, 3 = usable
    %% despite a violated constraint); any other code marks the value as
    %% unspecified.
    ErrorCodes = list_to_tuple(
        thinwrap_location_util:list_or_empty(thinwrap_location_json:get(Matrix, <<"errorCodes">>))
    ),
    %% Cells HERE flagged as failed and any non-number entry are omitted
    %% rather than read as 0.
    Cells = [
        #{
            origin_index => O,
            destination_index => D,
            distance_meters => Dist,
            duration_seconds => Dur
        }
     || O <- lists:seq(0, No - 1),
        D <- lists:seq(0, Nd - 1),
        Idx <- [O * Stride + D],
        cell_ok(ErrorCodes, Idx),
        Dist <- [thinwrap_location_json:num_opt(element(Idx + 1, Di))],
        Dur <- [thinwrap_location_json:num_opt(element(Idx + 1, Tt))],
        Dist =/= undefined,
        Dur =/= undefined
    ],
    #{cells => Cells, raw => Raw}.

%% A flat travelTimes/distances array as a tuple for indexed reads; it must
%% hold at least the `Min` entries the requested grid indexes.
value_tuple(L, Min, _Status, _Raw) when is_list(L), length(L) >= Min ->
    list_to_tuple(L);
value_tuple(_L, _Min, Status, Raw) ->
    thinwrap_location_error:fail(
        thinwrap_location_error:unknown(
            Status, Raw, <<"HERE Matrix returned arrays too short for the requested dimensions">>
        )
    ).

cell_ok(ErrorCodes, Idx) when Idx < tuple_size(ErrorCodes) ->
    Ec = element(Idx + 1, ErrorCodes),
    is_number(Ec) andalso (Ec == 0 orelse Ec == 3);
cell_ok(_, _) ->
    true.

%% HERE serves the matrix result gzip-only, and because the connector sets
%% Accept-Encoding itself a transport does not auto-decompress: the body
%% arrives as raw gzip bytes. A transport that already decompressed presents
%% plain JSON and is returned untouched; a stray Content-Encoding header on an
%% already-decompressed body is tolerated.
gunzip_if_needed(_Headers, <<>>) ->
    <<>>;
gunzip_if_needed(Headers, Body) ->
    Encoding = string:lowercase(header(Headers, <<"content-encoding">>)),
    Gzipped =
        binary:match(Encoding, <<"gzip">>) =/= nomatch orelse
            (case Body of
                <<16#1F, 16#8B, _/binary>> -> true;
                _ -> false
            end),
    case Gzipped of
        false ->
            Body;
        true ->
            try
                zlib:gunzip(Body)
            catch
                error:_ -> Body
            end
    end.

%% Only attach the apiKey to a provider-returned URL on a HERE host: a
%% tampered or proxied statusUrl/resultUrl must not be able to harvest it.
assert_here_api_url(Url, Label) ->
    Parsed =
        try uri_string:parse(Url) of
            #{} = M -> M;
            _ -> #{}
        catch
            _:_ -> #{}
        end,
    Host = string:lowercase(url_part(host, Parsed)),
    Host =/= <<>> orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:new(invalid_request, #{
                message => <<"HERE Matrix ", Label/binary, " is not a valid URL">>,
                provider_message => <<"HERE Matrix ", Label/binary, " is not a valid URL">>,
                cause => #{<<"url">> => Url}
            })
        ),
    Allowed =
        Host =:= ?MATRIX_HOST orelse Host =:= <<"hereapi.com">> orelse
            ends_with(Host, <<".hereapi.com">>),
    Scheme = string:lowercase(url_part(scheme, Parsed)),
    (Scheme =:= <<"https">> andalso Allowed) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:new(invalid_request, #{
                message => <<"HERE Matrix ", Label/binary, " points to an unexpected host">>,
                provider_message =>
                    <<"HERE Matrix ", Label/binary, " points to an unexpected host">>,
                cause => #{<<"url">> => Url}
            })
        ),
    ok.

%% A component of a URL parsed from a binary, so a binary itself; `<<>>`
%% when absent.
url_part(Key, Parsed) ->
    case maps:get(Key, Parsed, <<>>) of
        B when is_binary(B) -> B;
        _ -> <<>>
    end.

%% ---------------------------------------------------------------------------
%% Geocoding (Geocoding & Search v7)

-doc false.
-spec geocode(thinwrap_location:config(), map()) -> thinwrap_location:geocode_result().
geocode(Config, #{address := Address} = I) ->
    Query =
        [{<<"q">>, Address}, {<<"apiKey">>, key(Config)}] ++
            lang(I) ++
            [
                {<<"in">>, F}
             || F <- [country_code_filter(maps:get(country_filter, I, []))], F =/= undefined
            ],
    Raw = search_get(Config, ?GEOCODE_URL, Query, I, <<"HERE Geocoding">>),
    #{candidates => normalize_items(thinwrap_location_json:get(Raw, <<"items">>)), raw => Raw}.

-doc false.
-spec reverse_geocode(thinwrap_location:config(), map()) -> thinwrap_location:geocode_result().
reverse_geocode(Config, #{location := Loc} = I) ->
    Query =
        [{<<"at">>, thinwrap_location_util:to_lat_lng(Loc)}, {<<"apiKey">>, key(Config)}] ++
            lang(I),
    Raw = search_get(Config, ?REVGEOCODE_URL, Query, I, <<"HERE Reverse Geocoding">>),
    #{candidates => normalize_items(thinwrap_location_json:get(Raw, <<"items">>)), raw => Raw}.

search_get(Config, Url, Query, I, Label) ->
    {Status, Raw} = get_json(Config, Url, Query, I),
    _ = thinwrap_location_error:require_list(Status, Raw, <<"items">>, Label),
    Raw.

%% The caller's passthrough headers and query merged onto a GET's own query.
passthrough_get(Query, I) ->
    {_, Headers, MQuery} = thinwrap_location_passthrough:merge(#{}, #{}, Query, I),
    {Headers, MQuery}.

%% GET with passthrough merged in; see send_json/4.
get_json(Config, Url, Query, I) ->
    {Headers, MQuery} = passthrough_get(Query, I),
    send_json(Config, Url, Headers, MQuery).

%% GET; a non-2xx fails through http_error/3, otherwise the status and the
%% decoded body.
send_json(Config, Url, Headers, Query) ->
    #{status := Status, headers := RH, body := RB} =
        thinwrap_location_http:send_get(Config, Url, Headers, Query),
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(http_error(Status, RH, RB)),
    {Status, thinwrap_location_json:decode(RB)}.

%% `country_filter` (ISO 3166-1 alpha-2) to HERE's `countryCode:<alpha-3 CSV>`.
%% Shared by geocode and autocomplete so the two cannot drift on which codes
%% they accept. `undefined` when there is nothing to filter on, which keeps
%% "no country filter" distinguishable from an empty one.
country_code_filter(Filter) ->
    %% Blank entries are skipped rather than reported as "mapping unavailable
    %% for ".
    Alpha3 = [
        case maps:find(string:uppercase(C), iso_alpha2_to_alpha3()) of
            {ok, A3} ->
                A3;
            error ->
                thinwrap_location_error:fail(
                    thinwrap_location_error:invalid_request(
                        <<"HERE country code mapping unavailable for ", C/binary,
                            "; please use passthrough => #{query => #{<<\"in\">> => ...}} "
                            "to pass HERE's alpha-3 directly.">>
                    )
                )
        end
     || C <- Filter,
        string:trim(C) =/= <<>>
    ],
    case Alpha3 of
        [] -> undefined;
        _ -> <<"countryCode:", (join(Alpha3))/binary>>
    end.

normalize_items(Items) ->
    lists:filtermap(
        fun(Item) ->
            %% `address.label` is the full address; `title` is the display name,
            %% which for a POI is just its name (live: title "Empire State
            %% Building", label "Empire State Building, 20 W 34th St, ..."). The
            %% title is only a fallback for an item without a label.
            Addr =
                case address_label(Item) of
                    <<>> ->
                        thinwrap_location_json:str(thinwrap_location_json:get(Item, <<"title">>));
                    Label ->
                        Label
                end,
            Pos = thinwrap_location_json:get(Item, <<"position">>),
            %% Skip an item without a real position rather than emit a
            %% fabricated (0,0) "Null Island" candidate.
            case
                {
                    thinwrap_location_json:num_opt(thinwrap_location_json:get(Pos, <<"lat">>)),
                    thinwrap_location_json:num_opt(thinwrap_location_json:get(Pos, <<"lng">>))
                }
            of
                {Lat, Lng} when is_float(Lat), is_float(Lng) ->
                    Mv = thinwrap_location_json:get(Item, <<"mapView">>),
                    %% A partial mapView is dropped whole: a 0-filled edge would
                    %% stretch the consumer's bounds to the equator or the prime
                    %% meridian.
                    Viewport =
                        case
                            [
                                thinwrap_location_json:num_opt(thinwrap_location_json:get(Mv, K))
                             || K <- [<<"south">>, <<"west">>, <<"north">>, <<"east">>]
                            ]
                        of
                            [S, W, N, E] when is_float(S), is_float(W), is_float(N), is_float(E) ->
                                #{
                                    southwest => #{lat => S, lng => W},
                                    northeast => #{lat => N, lng => E}
                                };
                            _ ->
                                undefined
                        end,
                    Cand0 = #{formatted_address => Addr, location => #{lat => Lat, lng => Lng}},
                    Cand1 = thinwrap_location_util:put_opt(
                        place_id,
                        thinwrap_location_util:nonempty(
                            thinwrap_location_json:str(thinwrap_location_json:get(Item, <<"id">>))
                        ),
                        Cand0
                    ),
                    {true, thinwrap_location_util:put_opt(viewport, Viewport, Cand1)};
                _ ->
                    false
            end
        end,
        thinwrap_location_util:list_or_empty(Items)
    ).

%% ---------------------------------------------------------------------------
%% Autocomplete (Autosuggest)

-doc false.
-spec autocomplete(thinwrap_location:config(), map()) -> thinwrap_location:autocomplete_result().
autocomplete(Config, #{input := Text} = I) ->
    Spatial =
        case {maps:get(location, I, undefined), maps:get(radius, I, undefined)} of
            {undefined, _} ->
                [];
            {Loc, undefined} ->
                [{<<"at">>, thinwrap_location_util:to_lat_lng(Loc)}];
            {Loc, R} ->
                [
                    {<<"in">>,
                        <<"circle:", (thinwrap_location_util:to_lat_lng(Loc))/binary, ";r=",
                            (thinwrap_location_util:fmt_coord(R))/binary>>}
                ]
        end,
    Query =
        [{<<"q">>, Text}, {<<"apiKey">>, key(Config)}, {<<"limit">>, <<"10">>}] ++
            lang(I) ++
            Spatial,
    CountryFilter = country_code_filter(maps:get(country_filter, I, [])),
    {MHeaders, MQuery} = passthrough_get(Query, I),
    %% Autosuggest is the one HERE endpoint that mandates a search context:
    %% exactly one of `at`, `in=circle` or `in=bbox`, and a country filter has
    %% to accompany one of them. Without it HERE rejects the request, so fail
    %% here with something actionable. Checked after the merge so a caller's
    %% own `in=bbox:` still satisfies it.
    (present(MQuery, <<"at">>) orelse present(MQuery, <<"in">>)) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<
                    "HERE Autosuggest requires a search context: "
                    "pass `location` (optionally with `radius`), "
                    "or supply one via passthrough => #{query => #{<<\"at\">> => ...}} "
                    "(or <<\"in\">>)."
                >>
            )
        ),
    %% The country filter rides ALONGSIDE the spatial context rather than
    %% replacing it, and HERE spells both `in`, so the key is repeated.
    FullQuery = MQuery ++ [{<<"in">>, CountryFilter} || CountryFilter =/= undefined],
    {Status, Raw} = send_json(Config, ?AUTOSUGGEST_URL, MHeaders, FullQuery),
    Items = thinwrap_location_error:require_list(Status, Raw, <<"items">>, <<"HERE Autosuggest">>),
    #{predictions => [prediction(It) || It <- Items], raw => Raw}.

prediction(It) ->
    Title = thinwrap_location_json:str(thinwrap_location_json:get(It, <<"title">>)),
    %% HERE's query-type suggestions carry a title but no address at
    %% all, so secondary_text is omitted rather than empty.
    Structured =
        case Title of
            <<>> ->
                undefined;
            _ ->
                thinwrap_location_util:put_opt(
                    secondary_text,
                    thinwrap_location_util:nonempty(address_label(It)),
                    #{main_text => Title}
                )
        end,
    P0 = thinwrap_location_util:put_opt(
        place_id,
        thinwrap_location_util:nonempty(
            thinwrap_location_json:str(thinwrap_location_json:get(It, <<"id">>))
        ),
        #{description => Title}
    ),
    thinwrap_location_util:put_opt(structured_format, Structured, P0).

address_label(Item) ->
    thinwrap_location_json:str(thinwrap_location_json:path(Item, [<<"address">>, <<"label">>])).

lang(I) ->
    [{<<"lang">>, L} || L <- [maps:get(language, I, <<>>)], L =/= <<>>].

present(Query, Key) ->
    case lists:keyfind(Key, 1, Query) of
        {_, V} -> V =/= <<>> andalso V =/= [];
        false -> false
    end.

%% ---------------------------------------------------------------------------
%% Place details (Lookup)

-doc false.
-spec place_details(thinwrap_location:config(), map()) -> thinwrap_location:place_details_result().
place_details(Config, #{place_id := PlaceId} = I) ->
    Query = [{<<"apiKey">>, key(Config)}, {<<"id">>, PlaceId}] ++ lang(I),
    {MHeaders, MQuery} = passthrough_get(Query, I),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_location_http:send_get(Config, ?LOOKUP_URL, MHeaders, MQuery),
    Raw = thinwrap_location_json:decode(RB),
    case Status of
        %% Lookup answers an id it does not know with 404: "no such place",
        %% not a failed request.
        404 -> #{raw => Raw};
        _ -> place_details_result(Status, RH, RB, Raw, I)
    end.

place_details_result(Status, RH, RB, Raw, I) ->
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(http_error(Status, RH, RB)),
    is_map(Raw) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status, Raw, <<"HERE Place Details returned a malformed response body">>
            )
        ),
    %% Lookup returns one items[]-shaped entry, so the geocode
    %% normalizer applies unchanged.
    case normalize_items([Raw]) of
        [] ->
            #{raw => Raw};
        [Cand | _] ->
            %% HERE's `title` IS the display name; free, but still
            %% gated so the shape matches every other provider.
            Name =
                case lists:member(name, maps:get(include, I)) of
                    true ->
                        thinwrap_location_util:nonempty(
                            thinwrap_location_json:str(
                                thinwrap_location_json:get(Raw, <<"title">>)
                            )
                        );
                    false ->
                        undefined
                end,
            thinwrap_location_util:put_opt(name, Name, #{candidate => Cand, raw => Raw})
    end.

%% ---------------------------------------------------------------------------
%% Isochrone (Isoline Routing v8)

-doc false.
-spec isochrone(thinwrap_location:config(), map()) -> thinwrap_location:isochrone_result().
isochrone(Config, #{center := Center, type := Type, values := Values} = I) ->
    ok = thinwrap_location_isochrone:validate_cap(Values),
    TravelMode = maps:get(travel_mode, I),
    TravelMode =/= cycling orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:new(unsupported_travel_mode, #{
                message => <<"HERE isochrone does not support cycling">>,
                provider_message => <<"HERE isochrone does not support cycling">>
            })
        ),
    Mode =
        case TravelMode of
            walking -> <<"pedestrian">>;
            driving -> <<"car">>
        end,
    Query =
        [
            {<<"apiKey">>, key(Config)},
            {<<"origin">>, thinwrap_location_util:to_lat_lng(Center)},
            {<<"range[type]">>, atom_to_binary(Type)},
            {<<"range[values]">>, join([thinwrap_location_util:fmt_coord(V) || V <- Values])},
            {<<"transportMode">>, Mode}
        ] ++
            [
                {<<"departureTime">>,
                    thinwrap_location_isochrone:departure(DT, <<"HERE Isochrone">>)}
             || DT <- [maps:get(departure_time, I, undefined)], DT =/= undefined
            ],
    {Status, Raw} = get_json(Config, ?ISOLINE_URL, Query, I),
    Isolines = thinwrap_location_error:require_list(
        Status, Raw, <<"isolines">>, <<"HERE Isochrone">>
    ),
    Contours = [isoline_contour(Iso, Status, Raw) || Iso <- Isolines],
    Contours =/= [] orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(Status, Raw, <<"HERE Isochrone returned no isolines">>)
        ),
    #{
        contours => lists:sort(fun(#{value := A}, #{value := B}) -> A =< B end, Contours),
        raw => Raw
    }.

isoline_contour(Iso, Status, Raw) ->
    %% `polygons` is a MultiPolygon: an isoline can split into several parts
    %% (islands, areas joined only by a ferry `connection`), each with its own
    %% `inner` holes. Every part is kept.
    Parts = [
        P
     || Poly <- thinwrap_location_util:list_or_empty(
            thinwrap_location_json:get(Iso, <<"polygons">>)
        ),
        P <- [isoline_part(Poly)],
        P =/= []
    ],
    case
        thinwrap_location_json:num_opt(thinwrap_location_json:path(Iso, [<<"range">>, <<"value">>]))
    of
        Value when is_float(Value), Parts =/= [] ->
            #{value => Value, geometry => thinwrap_location_isochrone:contour_geometry(Parts)};
        _ ->
            thinwrap_location_error:fail(
                thinwrap_location_error:unknown(
                    Status,
                    Raw,
                    <<"HERE Isochrone returned an isoline without a value or outer polygon">>
                )
            )
    end.

%% One isoline polygon as `[Outer | Inners]` `[lng, lat]` rings; `[]` when it
%% has no decodable outer ring.
isoline_part(Poly) ->
    case ring(thinwrap_location_json:str(thinwrap_location_json:get(Poly, <<"outer">>))) of
        [] ->
            [];
        Outer ->
            Holes = [
                H
             || Inner <- thinwrap_location_util:list_or_empty(
                    thinwrap_location_json:get(Poly, <<"inner">>)
                ),
                H <- [ring(thinwrap_location_json:str(Inner))],
                H =/= []
            ],
            [Outer | Holes]
    end.

ring(<<>>) ->
    [];
ring(Encoded) ->
    [
        [Lng, Lat]
     || #{lat := Lat, lng := Lng} <- thinwrap_location_polyline:decode_flex_or_fail(Encoded)
    ].

%% ---------------------------------------------------------------------------
%% Vendor error mapping

map_vendor_error(S) when S =:= 401; S =:= 403 -> auth_failed;
map_vendor_error(429) -> rate_limited;
map_vendor_error(400) -> invalid_request;
map_vendor_error(S) when S >= 500, S < 600 -> provider_unavailable;
map_vendor_error(_) -> unknown.

error_message(Body) when is_map(Body) ->
    Title = thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"title">>)),
    Cause = thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"cause">>)),
    Errors = error_list(thinwrap_location_json:get(Body, <<"errors">>)),
    ErrMsg = thinwrap_location_json:str(
        thinwrap_location_json:path(Body, [<<"error">>, <<"message">>])
    ),
    case {Title, Cause} of
        {<<>>, <<>>} ->
            %% findsequence2 is the legacy WPS shape — no title/cause, just
            %% {"results": null, "errors": ["Bad Format for Date and Time: ..."],
            %% "responseCode": "400"}. Without `errors` the one statement of
            %% *why* is dropped.
            first_nonempty([
                Errors,
                ErrMsg,
                thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"message">>)),
                thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"error">>))
            ]);
        {_, <<>>} ->
            Title;
        {<<>>, _} ->
            Cause;
        _ ->
            <<Title/binary, ": ", Cause/binary>>
    end;
error_message(_) ->
    <<>>.

first_nonempty([V]) -> V;
first_nonempty([<<>> | Rest]) -> first_nonempty(Rest);
first_nonempty([V | _]) -> V.

error_list(L) when is_list(L) ->
    join([S || Item <- L, S <- [thinwrap_location_json:str(Item)], S =/= <<>>], <<"; ">>);
error_list(_) ->
    <<>>.

http_error(Status, Headers, Body) ->
    Raw = thinwrap_location_json:decode(Body),
    thinwrap_location_error:provider_error(
        Status, Headers, Raw, map_vendor_error(Status), error_message(Raw)
    ).

%% The first usable `notices[]` entry of a routing response. Live-verified
%% shape: `{"routes": [], "notices": [{"title", "code", "severity"}]}`.
notice(Raw) ->
    Found = [
        N
     || Notice <- thinwrap_location_util:list_or_empty(
            thinwrap_location_json:get(Raw, <<"notices">>)
        ),
        N <- [
            notice_text(
                thinwrap_location_json:str(thinwrap_location_json:get(Notice, <<"title">>)),
                thinwrap_location_json:str(thinwrap_location_json:get(Notice, <<"code">>))
            )
        ],
        N =/= undefined
    ],
    case Found of
        [N | _] -> N;
        [] -> undefined
    end.

notice_text(<<>>, <<>>) -> undefined;
notice_text(<<>>, Code) -> Code;
notice_text(Title, <<>>) -> Title;
notice_text(Title, Code) -> <<Title/binary, " (", Code/binary, ")">>.

%% ---------------------------------------------------------------------------
%% Helpers

key(Config) -> thinwrap_location_input:secret(Config, api_key).

%% `transport_mode` overrides the travel_mode mapping and is forwarded
%% verbatim: HERE judges it, so a local check would change the error the
%% caller gets from the vendor. The SAME value goes to /routes (transportMode),
%% Matrix v8 (body transportMode) and findsequence2 (`mode`), whose accepted
%% sets differ: privateBus is valid on the first two only.
transport_mode(#{transport_mode := M}) -> thinwrap_location_util:bin(M);
transport_mode(#{travel_mode := walking}) -> <<"pedestrian">>;
transport_mode(#{travel_mode := cycling}) -> <<"bicycle">>;
transport_mode(_) -> <<"car">>.

avoid_features(I) ->
    join(
        [<<"tollRoad">> || maps:get(avoid_tolls, I)] ++
            [<<"ferry">> || maps:get(avoid_ferries, I)] ++
            [<<"controlledAccessHighway">> || maps:get(avoid_highways, I)]
    ).

pt_query(I) ->
    Q = maps:get(query, maps:get(passthrough, I, #{}), #{}),
    maps:from_list([{thinwrap_location_util:bin(K), V} || K := V <- Q]).

%% Whether the request will carry a time of its own: the normalized
%% departure_time, or a departureTime other than `any` / an arrivalTime in the
%% caller's passthrough (`Pt`, the query map or the body map).
carries_time(DT, Pt) ->
    DT =/= undefined orelse
        not is_any(maps:get(<<"departureTime">>, Pt, <<"any">>)) orelse
        maps:is_key(<<"arrivalTime">>, Pt).

departure_time_field(undefined) ->
    [];
departure_time_field(DT) ->
    [{<<"departureTime">>, thinwrap_location_util:iso_string(DT, <<"departure_time">>)}].

is_any(any) -> true;
is_any(<<"any">>) -> true;
is_any(_) -> false.

%% Python truthiness for a decoded JSON value: absent, null, empty or zero.
falsy(undefined) -> true;
falsy([]) -> true;
falsy(false) -> true;
falsy(<<>>) -> true;
falsy(M) when is_map(M) -> map_size(M) =:= 0;
falsy(N) when is_number(N) -> N == 0;
falsy(_) -> false.

sum(Values) -> lists:foldl(fun(V, Acc) -> Acc + V end, 0.0, Values).

join(List) -> join(List, <<",">>).

join(List, Sep) -> iolist_to_binary(lists:join(Sep, List)).

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

ends_with(Bin, Suffix) ->
    Size = byte_size(Bin) - byte_size(Suffix),
    Size >= 0 andalso binary:part(Bin, Size, byte_size(Suffix)) =:= Suffix.

iso_alpha2_to_alpha3() ->
    #{
        <<"AD">> => <<"AND">>,
        <<"AE">> => <<"ARE">>,
        <<"AF">> => <<"AFG">>,
        <<"AG">> => <<"ATG">>,
        <<"AI">> => <<"AIA">>,
        <<"AL">> => <<"ALB">>,
        <<"AM">> => <<"ARM">>,
        <<"AO">> => <<"AGO">>,
        <<"AQ">> => <<"ATA">>,
        <<"AR">> => <<"ARG">>,
        <<"AS">> => <<"ASM">>,
        <<"AT">> => <<"AUT">>,
        <<"AU">> => <<"AUS">>,
        <<"AW">> => <<"ABW">>,
        <<"AX">> => <<"ALA">>,
        <<"AZ">> => <<"AZE">>,
        <<"BA">> => <<"BIH">>,
        <<"BB">> => <<"BRB">>,
        <<"BD">> => <<"BGD">>,
        <<"BE">> => <<"BEL">>,
        <<"BF">> => <<"BFA">>,
        <<"BG">> => <<"BGR">>,
        <<"BH">> => <<"BHR">>,
        <<"BI">> => <<"BDI">>,
        <<"BJ">> => <<"BEN">>,
        <<"BL">> => <<"BLM">>,
        <<"BM">> => <<"BMU">>,
        <<"BN">> => <<"BRN">>,
        <<"BO">> => <<"BOL">>,
        <<"BQ">> => <<"BES">>,
        <<"BR">> => <<"BRA">>,
        <<"BS">> => <<"BHS">>,
        <<"BT">> => <<"BTN">>,
        <<"BV">> => <<"BVT">>,
        <<"BW">> => <<"BWA">>,
        <<"BY">> => <<"BLR">>,
        <<"BZ">> => <<"BLZ">>,
        <<"CA">> => <<"CAN">>,
        <<"CC">> => <<"CCK">>,
        <<"CD">> => <<"COD">>,
        <<"CF">> => <<"CAF">>,
        <<"CG">> => <<"COG">>,
        <<"CH">> => <<"CHE">>,
        <<"CI">> => <<"CIV">>,
        <<"CK">> => <<"COK">>,
        <<"CL">> => <<"CHL">>,
        <<"CM">> => <<"CMR">>,
        <<"CN">> => <<"CHN">>,
        <<"CO">> => <<"COL">>,
        <<"CR">> => <<"CRI">>,
        <<"CU">> => <<"CUB">>,
        <<"CV">> => <<"CPV">>,
        <<"CW">> => <<"CUW">>,
        <<"CX">> => <<"CXR">>,
        <<"CY">> => <<"CYP">>,
        <<"CZ">> => <<"CZE">>,
        <<"DE">> => <<"DEU">>,
        <<"DJ">> => <<"DJI">>,
        <<"DK">> => <<"DNK">>,
        <<"DM">> => <<"DMA">>,
        <<"DO">> => <<"DOM">>,
        <<"DZ">> => <<"DZA">>,
        <<"EC">> => <<"ECU">>,
        <<"EE">> => <<"EST">>,
        <<"EG">> => <<"EGY">>,
        <<"EH">> => <<"ESH">>,
        <<"ER">> => <<"ERI">>,
        <<"ES">> => <<"ESP">>,
        <<"ET">> => <<"ETH">>,
        <<"FI">> => <<"FIN">>,
        <<"FJ">> => <<"FJI">>,
        <<"FK">> => <<"FLK">>,
        <<"FM">> => <<"FSM">>,
        <<"FO">> => <<"FRO">>,
        <<"FR">> => <<"FRA">>,
        <<"GA">> => <<"GAB">>,
        <<"GB">> => <<"GBR">>,
        <<"GD">> => <<"GRD">>,
        <<"GE">> => <<"GEO">>,
        <<"GF">> => <<"GUF">>,
        <<"GG">> => <<"GGY">>,
        <<"GH">> => <<"GHA">>,
        <<"GI">> => <<"GIB">>,
        <<"GL">> => <<"GRL">>,
        <<"GM">> => <<"GMB">>,
        <<"GN">> => <<"GIN">>,
        <<"GP">> => <<"GLP">>,
        <<"GQ">> => <<"GNQ">>,
        <<"GR">> => <<"GRC">>,
        <<"GS">> => <<"SGS">>,
        <<"GT">> => <<"GTM">>,
        <<"GU">> => <<"GUM">>,
        <<"GW">> => <<"GNB">>,
        <<"GY">> => <<"GUY">>,
        <<"HK">> => <<"HKG">>,
        <<"HM">> => <<"HMD">>,
        <<"HN">> => <<"HND">>,
        <<"HR">> => <<"HRV">>,
        <<"HT">> => <<"HTI">>,
        <<"HU">> => <<"HUN">>,
        <<"ID">> => <<"IDN">>,
        <<"IE">> => <<"IRL">>,
        <<"IL">> => <<"ISR">>,
        <<"IM">> => <<"IMN">>,
        <<"IN">> => <<"IND">>,
        <<"IO">> => <<"IOT">>,
        <<"IQ">> => <<"IRQ">>,
        <<"IR">> => <<"IRN">>,
        <<"IS">> => <<"ISL">>,
        <<"IT">> => <<"ITA">>,
        <<"JE">> => <<"JEY">>,
        <<"JM">> => <<"JAM">>,
        <<"JO">> => <<"JOR">>,
        <<"JP">> => <<"JPN">>,
        <<"KE">> => <<"KEN">>,
        <<"KG">> => <<"KGZ">>,
        <<"KH">> => <<"KHM">>,
        <<"KI">> => <<"KIR">>,
        <<"KM">> => <<"COM">>,
        <<"KN">> => <<"KNA">>,
        <<"KP">> => <<"PRK">>,
        <<"KR">> => <<"KOR">>,
        <<"KW">> => <<"KWT">>,
        <<"KY">> => <<"CYM">>,
        <<"KZ">> => <<"KAZ">>,
        <<"LA">> => <<"LAO">>,
        <<"LB">> => <<"LBN">>,
        <<"LC">> => <<"LCA">>,
        <<"LI">> => <<"LIE">>,
        <<"LK">> => <<"LKA">>,
        <<"LR">> => <<"LBR">>,
        <<"LS">> => <<"LSO">>,
        <<"LT">> => <<"LTU">>,
        <<"LU">> => <<"LUX">>,
        <<"LV">> => <<"LVA">>,
        <<"LY">> => <<"LBY">>,
        <<"MA">> => <<"MAR">>,
        <<"MC">> => <<"MCO">>,
        <<"MD">> => <<"MDA">>,
        <<"ME">> => <<"MNE">>,
        <<"MF">> => <<"MAF">>,
        <<"MG">> => <<"MDG">>,
        <<"MH">> => <<"MHL">>,
        <<"MK">> => <<"MKD">>,
        <<"ML">> => <<"MLI">>,
        <<"MM">> => <<"MMR">>,
        <<"MN">> => <<"MNG">>,
        <<"MO">> => <<"MAC">>,
        <<"MP">> => <<"MNP">>,
        <<"MQ">> => <<"MTQ">>,
        <<"MR">> => <<"MRT">>,
        <<"MS">> => <<"MSR">>,
        <<"MT">> => <<"MLT">>,
        <<"MU">> => <<"MUS">>,
        <<"MV">> => <<"MDV">>,
        <<"MW">> => <<"MWI">>,
        <<"MX">> => <<"MEX">>,
        <<"MY">> => <<"MYS">>,
        <<"MZ">> => <<"MOZ">>,
        <<"NA">> => <<"NAM">>,
        <<"NC">> => <<"NCL">>,
        <<"NE">> => <<"NER">>,
        <<"NF">> => <<"NFK">>,
        <<"NG">> => <<"NGA">>,
        <<"NI">> => <<"NIC">>,
        <<"NL">> => <<"NLD">>,
        <<"NO">> => <<"NOR">>,
        <<"NP">> => <<"NPL">>,
        <<"NR">> => <<"NRU">>,
        <<"NU">> => <<"NIU">>,
        <<"NZ">> => <<"NZL">>,
        <<"OM">> => <<"OMN">>,
        <<"PA">> => <<"PAN">>,
        <<"PE">> => <<"PER">>,
        <<"PF">> => <<"PYF">>,
        <<"PG">> => <<"PNG">>,
        <<"PH">> => <<"PHL">>,
        <<"PK">> => <<"PAK">>,
        <<"PL">> => <<"POL">>,
        <<"PM">> => <<"SPM">>,
        <<"PN">> => <<"PCN">>,
        <<"PR">> => <<"PRI">>,
        <<"PS">> => <<"PSE">>,
        <<"PT">> => <<"PRT">>,
        <<"PW">> => <<"PLW">>,
        <<"PY">> => <<"PRY">>,
        <<"QA">> => <<"QAT">>,
        <<"RE">> => <<"REU">>,
        <<"RO">> => <<"ROU">>,
        <<"RS">> => <<"SRB">>,
        <<"RU">> => <<"RUS">>,
        <<"RW">> => <<"RWA">>,
        <<"SA">> => <<"SAU">>,
        <<"SB">> => <<"SLB">>,
        <<"SC">> => <<"SYC">>,
        <<"SD">> => <<"SDN">>,
        <<"SE">> => <<"SWE">>,
        <<"SG">> => <<"SGP">>,
        <<"SH">> => <<"SHN">>,
        <<"SI">> => <<"SVN">>,
        <<"SJ">> => <<"SJM">>,
        <<"SK">> => <<"SVK">>,
        <<"SL">> => <<"SLE">>,
        <<"SM">> => <<"SMR">>,
        <<"SN">> => <<"SEN">>,
        <<"SO">> => <<"SOM">>,
        <<"SR">> => <<"SUR">>,
        <<"SS">> => <<"SSD">>,
        <<"ST">> => <<"STP">>,
        <<"SV">> => <<"SLV">>,
        <<"SX">> => <<"SXM">>,
        <<"SY">> => <<"SYR">>,
        <<"SZ">> => <<"SWZ">>,
        <<"TC">> => <<"TCA">>,
        <<"TD">> => <<"TCD">>,
        <<"TF">> => <<"ATF">>,
        <<"TG">> => <<"TGO">>,
        <<"TH">> => <<"THA">>,
        <<"TJ">> => <<"TJK">>,
        <<"TK">> => <<"TKL">>,
        <<"TL">> => <<"TLS">>,
        <<"TM">> => <<"TKM">>,
        <<"TN">> => <<"TUN">>,
        <<"TO">> => <<"TON">>,
        <<"TR">> => <<"TUR">>,
        <<"TT">> => <<"TTO">>,
        <<"TV">> => <<"TUV">>,
        <<"TW">> => <<"TWN">>,
        <<"TZ">> => <<"TZA">>,
        <<"UA">> => <<"UKR">>,
        <<"UG">> => <<"UGA">>,
        <<"UM">> => <<"UMI">>,
        <<"US">> => <<"USA">>,
        <<"UY">> => <<"URY">>,
        <<"UZ">> => <<"UZB">>,
        <<"VA">> => <<"VAT">>,
        <<"VC">> => <<"VCT">>,
        <<"VE">> => <<"VEN">>,
        <<"VG">> => <<"VGB">>,
        <<"VI">> => <<"VIR">>,
        <<"VN">> => <<"VNM">>,
        <<"VU">> => <<"VUT">>,
        <<"WF">> => <<"WLF">>,
        <<"WS">> => <<"WSM">>,
        <<"YE">> => <<"YEM">>,
        <<"YT">> => <<"MYT">>,
        <<"ZA">> => <<"ZAF">>,
        <<"ZM">> => <<"ZMB">>,
        <<"ZW">> => <<"ZWE">>
    }.
