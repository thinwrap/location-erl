-module(thinwrap_location_osrm).
-moduledoc false.

%% OSRM: routing (route / trip), matrix (table). Self-hosted, so `base_url` is
%% required and validated per operation; no auth; in-body status codes.

-export([route/2, matrix/2]).

-define(PROFILE_NOT_FOUND_RE, "(?i)profile\\s+not\\s+found").

%% ---------------------------------------------------------------------------
%% Routing

-doc false.
-spec route(thinwrap_location:config(), map()) -> thinwrap_location:route_result().
route(Config, #{waypoints := Wps} = I) ->
    BaseUrl = base_url(Config),
    validate_routing_compat(I, supported(Config)),
    length(Wps) >= 2 orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<"OSRM Routing requires at least two waypoints">>
            )
        ),
    RoundTrip = maps:get(is_round_trip, I),
    FixedOrigin = maps:get(optimize_fixed_origin, I),
    FixedDestination = maps:get(optimize_fixed_destination, I),
    UseTrip = maps:get(optimize, I) orelse FixedOrigin orelse FixedDestination orelse RoundTrip,
    Profile = profile(maps:get(travel_mode, I)),
    Coords = thinwrap_location_util:join_coords(Wps, lnglat, <<";">>),
    Endpoint =
        case UseTrip of
            true -> <<"trip">>;
            false -> <<"route">>
        end,
    Url = <<BaseUrl/binary, "/", Endpoint/binary, "/v1/", Profile/binary, "/", Coords/binary>>,
    %% steps and annotations are deliberately NOT sent on /route: nothing in
    %% the route result reads them, and leg distance/duration are present
    %% regardless of annotations. (The Table service is different — it
    %% defaults annotations to duration,distance because that IS what
    %% populates the cells.)
    Overview =
        case maps:get(polyline_quality, I) of
            detailed -> <<"full">>;
            simplified -> <<"simplified">>
        end,
    %% Only classes the operator declared AND the caller asked for; validation
    %% has already rejected any undeclared request.
    Excludes = [Class || {_, Class, true} <- avoid_flags(I)],
    TripQuery =
        case UseTrip of
            true ->
                Source0 =
                    case FixedOrigin of
                        true -> <<"first">>;
                        false -> <<"any">>
                    end,
                Destination0 =
                    case FixedDestination of
                        true -> <<"last">>;
                        false -> <<"any">>
                    end,
                %% With roundtrip=false OSRM accepts first/last, first/any and
                %% any/last (trip.cpp IsSupportedParameterCombination: roundtrip
                %% || fixed_start || fixed_end, since v5.27) and rejects only
                %% any/any with HTTP 400 NotImplemented. A plain optimize
                %% (neither endpoint fixed, open route) therefore keeps the
                %% input's first & last fixed and reorders the middle.
                {Source, Destination} =
                    case {RoundTrip, Source0, Destination0} of
                        {false, <<"any">>, <<"any">>} -> {<<"first">>, <<"last">>};
                        _ -> {Source0, Destination0}
                    end,
                [
                    {<<"source">>, Source},
                    {<<"destination">>, Destination},
                    {<<"roundtrip">>, atom_to_binary(RoundTrip)}
                ];
            false ->
                []
        end,
    Query =
        [{<<"overview">>, Overview}, {<<"geometries">>, <<"polyline">>}] ++
            [{<<"exclude">>, join(Excludes, <<",">>)} || Excludes =/= []] ++
            TripQuery,
    {Status, Raw} = get_json(Config, Url, Query, I, UseTrip),
    Raw =/= undefined orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status, undefined, <<"OSRM routing returned a malformed response body">>
            )
        ),
    %% The `/trip/v1` service returns its route objects under `trips`, not
    %% `routes`.
    Routes =
        case truthy(thinwrap_location_json:get(Raw, <<"routes">>)) of
            true -> thinwrap_location_json:get(Raw, <<"routes">>);
            false -> thinwrap_location_json:get(Raw, <<"trips">>)
        end,
    (thinwrap_location_json:str(thinwrap_location_json:get(Raw, <<"code">>)) =:= <<"Ok">> andalso
        truthy(Routes)) orelse
        thinwrap_location_error:fail(route_in_body_error(Raw, UseTrip, Status)),
    Route =
        case Routes of
            [Rt | _] when is_map(Rt) -> Rt;
            _ ->
                thinwrap_location_error:fail(
                    thinwrap_location_error:unknown(
                        Status, Raw, <<"OSRM returned a malformed route">>
                    )
                )
        end,
    Legs = [
        leg(L, Status, Raw)
     || L <- thinwrap_location_util:list_or_empty(thinwrap_location_json:get(Route, <<"legs">>))
    ],
    {TotalDistance, TotalDuration} = distance_duration(Route, Status, Raw),
    ok = thinwrap_location_util:assert_route_has_legs(
        length(Legs), length(Wps), <<"OSRM routing">>, Raw, Status
    ),
    WaypointOrder =
        case {UseTrip, thinwrap_location_json:get(Raw, <<"waypoints">>)} of
            %% Canonical waypoint_order = full visiting sequence of INPUT
            %% indices (origin/destination inclusive). OSRM /trip returns
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
        %% OSRM's polyline is already precision-5.
        polyline => thinwrap_location_json:str(thinwrap_location_json:get(Route, <<"geometry">>)),
        raw => Raw
    }).

%% ---------------------------------------------------------------------------
%% Matrix (Table service)

-doc false.
-spec matrix(thinwrap_location:config(), map()) -> thinwrap_location:matrix_result().
matrix(Config, #{origins := Os, destinations := Ds} = I) ->
    BaseUrl = base_url(Config),
    %% traffic_mode and departure_time are ignored, as on routing (see
    %% validate_routing_compat/2). Same exclude rule as routing: honoured only
    %% when the operator declared the class.
    AvoidTolls = maps:get(avoid_tolls, I),
    require_exclude_class(<<"avoid_tolls">>, <<"toll">>, AvoidTolls, supported(Config)),
    (Os =/= [] andalso Ds =/= []) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<"OSRM Matrix requires at least one origin and one destination">>
            )
        ),
    No = length(Os),
    Nd = length(Ds),
    Profile = profile(maps:get(travel_mode, I)),
    Coords = thinwrap_location_util:join_coords(Os ++ Ds, lnglat, <<";">>),
    Url = <<BaseUrl/binary, "/table/v1/", Profile/binary, "/", Coords/binary>>,
    %% `annotations` is a default, not an invariant: it sits in the base query
    %% so a consumer's passthrough.query replaces it like any other list default.
    Query =
        [
            {<<"sources">>, indices(0, No)},
            {<<"destinations">>, indices(No, Nd)},
            {<<"annotations">>, join(thinwrap_location_defaults:osrm_table_annotations(), <<",">>)}
        ] ++
            [{<<"exclude">>, <<"toll">>} || AvoidTolls],
    {Status, Raw} = get_json(Config, Url, Query, I, false),
    case Raw of
        #{<<"code">> := <<"Ok">>} -> ok;
        _ -> thinwrap_location_error:fail(matrix_in_body_error(Raw, Status))
    end,
    Durs = thinwrap_location_json:get(Raw, <<"durations">>),
    Dists = thinwrap_location_json:get(Raw, <<"distances">>),
    thinwrap_location_matrix:dimensions_ok(Durs, Dists, No, Nd) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:unknown(
                Status,
                Raw,
                <<"OSRM matrix returned a table that does not match the requested dimensions">>
            )
        ),
    #{cells => thinwrap_location_matrix:grid_cells(Durs, Dists, No, Nd), raw => Raw}.

%% OSRM is GET-only and keyless: the caller's passthrough adds headers and
%% query parameters; there is no body to merge. A non-2xx fails here; the
%% decoded body (`undefined` when malformed) is the caller's to interpret.
get_json(Config, Url, Query, I, UseTrip) ->
    {_, Headers, MQuery} = thinwrap_location_passthrough:merge(#{}, #{}, Query, I),
    #{status := Status, headers := RH, body := RB} =
        thinwrap_location_http:send_get(Config, Url, Headers, MQuery),
    thinwrap_location_util:ok_status(Status) orelse
        thinwrap_location_error:fail(http_error(Status, RH, RB, UseTrip)),
    {Status, thinwrap_location_json:decode(RB)}.

leg(L, Status, Raw) ->
    {D, Du} = distance_duration(L, Status, Raw),
    #{distance_meters => D, duration_seconds => Du}.

indices(From, Count) ->
    join([integer_to_binary(N) || N <- lists:seq(From, From + Count - 1)], <<";">>).

%% ---------------------------------------------------------------------------
%% Validation

%% Validate and normalize the OSRM base URL, returning the value to build on.
%%
%% OSRM is the only provider requiring an explicit base URL and shipping zero
%% auth, so there is no default to fall back to (the public demo server is
%% deliberately not one).
%%
%% Two checks: non-empty, and an `http://` or `https://` scheme, so a bare
%% host in config fails as an `invalid_request` that names the config.
%% `http://` passes here because an injected transport may serve it; the
%% default transport is HTTPS-only and refuses it with its own
%% `invalid_request`. The rejected value is echoed with its userinfo masked: a
%% base URL for a server behind basic auth carries the credentials inline.
%%
%% A path prefix is explicitly ALLOWED (hosting OSRM at `https://host/osrm`
%% behind a reverse proxy is a normal deployment); trailing slashes are
%% stripped so the built `<base>/route/v1/...` cannot contain a double slash.
base_url(Config) ->
    case maps:get(base_url, Config) of
        <<>> ->
            thinwrap_location_error:fail(
                thinwrap_location_error:new(invalid_request, #{
                    message =>
                        <<
                            "OSRM connector requires explicit baseUrl. "
                            "The public demo server is not used as a default."
                        >>,
                    provider_message => <<"baseUrl is required for OSRM">>
                })
            );
        Url ->
            case has_http_scheme(Url) of
                true ->
                    strip_trailing_slashes(Url);
                false ->
                    thinwrap_location_error:fail(
                        thinwrap_location_error:new(invalid_request, #{
                            message =>
                                <<"OSRM baseUrl must start with http:// or https:// (got: ",
                                    (thinwrap_location_util:redact_url_userinfo(Url))/binary, ")">>,
                            provider_message =>
                                <<"OSRM baseUrl must start with http:// or https://">>
                        })
                    )
            end
    end.

has_http_scheme(Url) ->
    Prefix = ascii_lower(binary:part(Url, 0, min(8, byte_size(Url)))),
    case Prefix of
        <<"http://", _/binary>> -> true;
        <<"https://">> -> true;
        _ -> false
    end.

ascii_lower(Bin) ->
    <<
        <<
            (case C of
                _ when C >= $A, C =< $Z -> C + 32;
                _ -> C
            end)
        >>
     || <<C>> <= Bin
    >>.

strip_trailing_slashes(Url) ->
    case binary:last(<<"x", Url/binary>>) of
        $/ -> strip_trailing_slashes(binary:part(Url, 0, byte_size(Url) - 1));
        _ -> Url
    end.

supported(Config) -> maps:get(supported_exclude_classes, Config, []).

%% The normalized avoid-flag → OSRM `exclude` class mapping, paired with
%% whether the caller requested it. Ordered, so the first unsupported flag is
%% the one reported.
avoid_flags(I) ->
    [
        {<<"avoid_tolls">>, <<"toll">>, maps:get(avoid_tolls, I)},
        {<<"avoid_ferries">>, <<"ferry">>, maps:get(avoid_ferries, I)},
        {<<"avoid_highways">>, <<"motorway">>, maps:get(avoid_highways, I)}
    ].

%% OSRM has no time parameter and no request-time traffic: traffic needs a
%% graph rebuilt with "edge weight updates" (osrm-backend wiki, Traffic). So
%% traffic_mode is ignored, and departure_time with it — under `none` a time
%% has no effect by definition, so refusing it would reject a valid request.
%%
%% Whether an avoid-flag works depends on the OPERATOR'S build, not on OSRM:
%% exclude=toll is rejected as InvalidValue by the public demo build and
%% honoured by a self-hosted instance with the class compiled in (verified
%% live — it genuinely rerouted). So the capability is declared in config, and
%% anything not declared is still rejected up front rather than sent and
%% bounced with an opaque vendor error.
validate_routing_compat(I, Supported) ->
    lists:foreach(
        fun({Flag, Class, Requested}) ->
            require_exclude_class(Flag, Class, Requested, Supported)
        end,
        avoid_flags(I)
    ).

%% Reject a requested avoid-flag whose exclude class the operator has not
%% declared.
require_exclude_class(Flag, Class, Requested, Supported) ->
    case Requested andalso not lists:member(Class, Supported) of
        true ->
            thinwrap_location_error:fail(
                thinwrap_location_error:unsupported_option(
                    <<Flag/binary, " requires an OSRM build with the '", Class/binary,
                        "' exclude class compiled in; declare it via the osrm config's "
                        "supported_exclude_classes">>
                )
            );
        false ->
            ok
    end.

%% A route's or leg's `distance`/`duration`. OSRM always sends both, so a
%% missing one is a malformed response rather than a free, instant trip.
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
                    Status, Raw, <<"OSRM returned a route or leg without distance/duration">>
                )
            )
    end.

%% ---------------------------------------------------------------------------
%% Vendor error mapping

%% Classify an OSRM envelope `code`, or `undefined` when it is not one this
%% connector recognizes (so the caller falls back to HTTP-status mapping).
%%
%% Shared by both error paths because OSRM does not distinguish them: these
%% codes arrive with a **4xx** in practice (live-verified on both the public
%% demo build and a self-hosted instance — NoSegment, InvalidOptions and
%% InvalidValue all came back as 400), and the same code on a 200 means the
%% same thing.
%%
%% NoRoute / NoSegment / NoTrips are `no_route`: the request was well-formed
%% and the server answered, there simply is no connecting route (or no road
%% near a coordinate to snap to). A NoRoute whose message states a missing
%% profile is `profile_not_configured` instead — never inferred from a bare one.
classify_envelope_code(Code, Message, _UseTrip) when
    Code =:= <<"NoRoute">>; Code =:= <<"NoSegment">>
->
    case Message =/= <<>> andalso re:run(Message, ?PROFILE_NOT_FOUND_RE, [unicode]) =/= nomatch of
        true -> profile_not_configured;
        false -> no_route
    end;
%% A /trip-endpoint outcome. On a /route dispatch it should never occur, so an
%% unexpected one stays unclassified.
classify_envelope_code(<<"NoTrips">>, _Message, true) ->
    no_route;
classify_envelope_code(<<"NoTrips">>, _Message, false) ->
    undefined;
classify_envelope_code(Code, _Message, _UseTrip) when
    Code =:= <<"InvalidQuery">>;
    Code =:= <<"InvalidOptions">>;
    Code =:= <<"InvalidValue">>;
    Code =:= <<"TooBig">>
->
    invalid_request;
%% A trip endpoint combination this server does not implement: any/any on an
%% open trip, or first/any / any/last on a build older than v5.27.
classify_envelope_code(<<"NotImplemented">>, _Message, _UseTrip) ->
    unsupported_option;
classify_envelope_code(_Code, _Message, _UseTrip) ->
    undefined.

%% Proxy-layer statuses win: a 401/429 from a reverse proxy has no OSRM
%% envelope. Otherwise OSRM serves EVERY non-Ok envelope code with a 4xx, so
%% the envelope code — not the status — distinguishes "no route exists" from
%% "your request was wrong".
map_vendor_error(S, _Body, _UseTrip) when S =:= 401; S =:= 403 ->
    auth_failed;
map_vendor_error(429, _Body, _UseTrip) ->
    rate_limited;
map_vendor_error(S, _Body, _UseTrip) when S >= 500, S < 600 ->
    provider_unavailable;
map_vendor_error(S, Body, UseTrip) ->
    case
        classify_envelope_code(
            thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"code">>)),
            thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"message">>)),
            UseTrip
        )
    of
        undefined when S =:= 400; S =:= 404 -> invalid_request;
        undefined -> unknown;
        Code -> Code
    end.

error_message(Body) ->
    case thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"message">>)) of
        <<>> -> thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"error">>));
        M -> M
    end.

%% OSRM serves NoTrips with a 4xx as readily as in a 200 envelope, so /trip
%% classifies it the same on both paths. The Table service never produces it.
http_error(Status, Headers, Data, UseTrip) ->
    Raw = thinwrap_location_json:decode(Data),
    thinwrap_location_error:provider_error(
        Status, Headers, Raw, map_vendor_error(Status, Raw, UseTrip), error_message(Raw)
    ).

%% Map a 2xx OSRM envelope to a typed error: reached when the envelope code is
%% not `Ok`, or when routes/trips came back empty. An `Ok` envelope with an
%% empty routes[] is `no_route`, not `unknown`: the envelope says the request
%% was fine and the server answered, there is simply nothing to return — the
%% same outcome as Google's empty routes[], so a consumer gets one "provider
%% answered, no route" case to branch on. `Status` is the real HTTP status: the
%% server answered, and an absent status is what a transport failure looks like.
route_in_body_error(Body, UseTrip, Status) ->
    Code = thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"code">>)),
    Message = thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"message">>)),
    case Code of
        <<"Ok">> ->
            Noun =
                case UseTrip of
                    true -> <<"trips">>;
                    false -> <<"routes">>
                end,
            thinwrap_location_error:classified(
                no_route,
                Status,
                Body,
                <<"OSRM returned no ", Noun/binary, " with envelope code Ok">>
            );
        _ ->
            Pc = or_unknown(classify_envelope_code(Code, Message, UseTrip)),
            thinwrap_location_error:classified(Pc, Status, Body, fallback_message(Message, Code))
    end.

%% A 2xx Table envelope that is not `Ok`, with the same envelope codes as
%% routing (a NoSegment is a coordinate with no road to snap to on either
%% service). NoTable is the Table service's own invalid-request code.
matrix_in_body_error(Body, Status) ->
    Code = thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"code">>)),
    Message = thinwrap_location_json:str(thinwrap_location_json:get(Body, <<"message">>)),
    Pc =
        case Code of
            <<"NoTable">> -> invalid_request;
            _ -> or_unknown(classify_envelope_code(Code, Message, false))
        end,
    thinwrap_location_error:classified(Pc, Status, Body, fallback_message(Message, Code)).

or_unknown(undefined) -> unknown;
or_unknown(Code) -> Code.

fallback_message(<<>>, <<>>) -> <<"OSRM returned code: unknown">>;
fallback_message(<<>>, Code) -> <<"OSRM returned code: ", Code/binary>>;
fallback_message(Message, _Code) -> Message.

%% ---------------------------------------------------------------------------
%% Helpers

profile(walking) -> <<"walking">>;
profile(cycling) -> <<"cycling">>;
profile(driving) -> <<"driving">>.

truthy(undefined) -> false;
truthy(false) -> false;
truthy(<<>>) -> false;
truthy([]) -> false;
truthy(M) when is_map(M) -> map_size(M) > 0;
truthy(N) when is_number(N) -> N /= 0;
truthy(_) -> true.

join(Parts, Sep) -> iolist_to_binary(lists:join(Sep, Parts)).
