-module(thinwrap_location_util).
-moduledoc false.

%% Small shared helpers: URL building, credential redaction, time formatting,
%% coordinate formatting, waypoint-order validation. Connectors call these as
%% building blocks; nothing here intercepts a request globally.

-export([
    ok_status/1,
    build_url/2,
    merge_query/2,
    redact_credentials/1,
    redact_url_userinfo/1,
    traffic_requested/1,
    to_system_ms/2,
    iso_string/2,
    iso_seconds_string/2,
    fmt_coord/1,
    to_lng_lat/1,
    to_lat_lng/1,
    join_coords/3,
    is_complete_waypoint_order/2,
    invert_waypoint_positions/2,
    assert_route_has_legs/5,
    assert_finite_number/2,
    bin/1,
    chars_to_bin/1,
    quote_segment/1,
    put_opt/3,
    nonempty/1,
    list_or_empty/1
]).

-export_type([query/0, query_value/0]).

%% One value, or several emitted as the SAME key repeated (`avoid=a&avoid=b`),
%% the only list form some vendors accept (TomTom rejects a comma-joined avoid).
-type query_value() :: binary() | [binary()].
%% Ordered, because a stable query string keeps requests reproducible.
-type query() :: [{binary(), query_value()}].

-spec ok_status(integer()) -> boolean().
ok_status(S) -> S >= 200 andalso S < 300.

-spec build_url(binary(), query()) -> binary().
build_url(Url, []) ->
    Url;
build_url(Url, Query) ->
    Pairs = lists:append([expand(K, V) || {K, V} <- Query]),
    case Pairs of
        [] ->
            Url;
        _ ->
            %% Every key and value is a binary (expand/2) and compose_query
            %% percent-encodes any byte, so the result is always a binary.
            Qs = known_binary(uri_string:compose_query(Pairs)),
            Sep =
                case binary:match(Url, <<"?">>) of
                    nomatch -> <<"?">>;
                    _ -> <<"&">>
                end,
            <<Url/binary, Sep/binary, Qs/binary>>
    end.

expand(K, Vs) when is_list(Vs) -> [{bin(K), bin(V)} || V <- Vs];
expand(K, V) -> [{bin(K), bin(V)}].

-doc false.
%% Overlay `Override` (a passthrough query map or list) onto `Base`, replacing
%% same-named keys in place and appending new ones. Keys are case-sensitive,
%% as query parameters are.
-spec merge_query(query(), map() | query()) -> query().
merge_query(Base, Override) when is_map(Override) ->
    merge_query(Base, lists:sort(maps:to_list(Override)));
merge_query(Base, Override) ->
    lists:foldl(
        fun({K0, V}, Acc) ->
            K = bin(K0),
            case lists:keymember(K, 1, Acc) of
                true -> lists:keyreplace(K, 1, Acc, {K, V});
                false -> Acc ++ [{K, V}]
            end
        end,
        [{bin(K), V} || {K, V} <- Base],
        Override
    ).

-define(CRED_RE,
    "(?i)((?:access_token|apikey|api_key|key|token|sig|signature)=)[^&\\s\"']+"
).
-define(USERINFO_RE, "(?i)\\b([a-z][a-z0-9+.-]*://)[^/\\s@?#\"']+@").

-doc false.
%% Mask the values of common credential query params, and the userinfo of any
%% `scheme://user:pass@host` URL, in free-form text (a transport error message,
%% a vendor body that echoes the request URL).
-spec redact_credentials(binary()) -> binary().
redact_credentials(S) when is_binary(S) ->
    S1 = re:replace(S, ?CRED_RE, "\\1[REDACTED]", [global, unicode, {return, binary}]),
    re:replace(S1, ?USERINFO_RE, "\\1[REDACTED]@", [global, unicode, {return, binary}]).

-doc false.
%% Replace the userinfo of a single URL with `[REDACTED]`: a self-hosted
%% endpoint behind basic auth is often configured with the credentials inline.
-spec redact_url_userinfo(binary()) -> binary().
redact_url_userinfo(Url) ->
    Start =
        case binary:match(Url, <<"://">>) of
            {P, 3} -> P + 3;
            nomatch -> 0
        end,
    Rest = binary:part(Url, Start, byte_size(Url) - Start),
    AuthorityLen =
        case binary:match(Rest, [<<"/">>, <<"?">>, <<"#">>]) of
            {I, _} -> I;
            nomatch -> byte_size(Rest)
        end,
    Authority = binary:part(Rest, 0, AuthorityLen),
    case binary:matches(Authority, <<"@">>) of
        [] ->
            Url;
        Ms ->
            {At, 1} = lists:last(Ms),
            Prefix = binary:part(Url, 0, Start),
            After = binary:part(Rest, At + 1, byte_size(Rest) - At - 1),
            <<Prefix/binary, "[REDACTED]@", After/binary>>
    end.

-doc false.
%% `live` is the deprecated alias of `traffic`; deciding it in one place keeps
%% the alias identical everywhere.
-spec traffic_requested(atom()) -> boolean().
traffic_requested(traffic) -> true;
traffic_requested(live) -> true;
traffic_requested(_) -> false.

-doc false.
%% A departure time as Unix milliseconds. Accepts Unix seconds (integer), a
%% UTC `calendar:datetime()`, or an RFC 3339 binary; an unparseable binary is
%% request data the vendor would reject, so it fails with `invalid_request`.
-spec to_system_ms(thinwrap_location:departure_time(), binary()) -> integer().
to_system_ms(Secs, _Label) when is_integer(Secs) ->
    Secs * 1000;
to_system_ms({{_, _, _}, {_, _, _}} = DT, _Label) ->
    (calendar:datetime_to_gregorian_seconds(DT) - 62167219200) * 1000;
to_system_ms(Bin, Label) when is_binary(Bin) ->
    %% `calendar:rfc3339_to_system_time/2` does not validate the calendar date:
    %% month 13 silently rolls into the next year. Check the fields first.
    Re = "^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt ]([0-9]{2}):([0-9]{2}):([0-9]{2})",
    Valid =
        case re:run(Bin, Re, [{capture, all_but_first, list}]) of
            {match, Fields} ->
                valid_date_time([list_to_integer(F) || F <- Fields]);
            nomatch ->
                false
        end,
    try
        Valid = true,
        calendar:rfc3339_to_system_time(binary_to_list(Bin), [{unit, millisecond}])
    catch
        _:_ ->
            thinwrap_location_error:fail(
                thinwrap_location_error:invalid_request(
                    <<Label/binary, " is not an ISO-8601 / RFC 3339 timestamp">>
                )
            )
    end.

%% Leap second allowed (`:60`), as RFC 3339 does.
valid_date_time([Y, Mo, D, H, Mi, S]) ->
    calendar:valid_date(Y, Mo, D) andalso H < 24 andalso Mi < 60 andalso S < 61.

-doc false.
%% ISO 8601 UTC with millisecond precision and a `Z` suffix, matching JS
%% `Date.prototype.toISOString()` like the sibling libraries.
-spec iso_string(thinwrap_location:departure_time(), binary()) -> binary().
iso_string(When, Label) ->
    Ms = to_system_ms(When, Label),
    chars_to_bin(calendar:system_time_to_rfc3339(Ms, [{unit, millisecond}, {offset, "Z"}])).

-doc false.
%% ISO 8601 at *seconds* precision. HERE's legacy findsequence2 rejects
%% fractional seconds ("Bad Format for Date and Time", HTTP 400), so precision
%% is a property of the endpoint, not of the value.
-spec iso_seconds_string(thinwrap_location:departure_time(), binary()) -> binary().
iso_seconds_string(When, Label) ->
    Secs = to_system_ms(When, Label) div 1000,
    chars_to_bin(calendar:system_time_to_rfc3339(Secs, [{unit, second}, {offset, "Z"}])).

-doc false.
%% Shortest fixed-point decimal, never exponential (geo APIs reject `5.0e-5`
%% in a URL); integral values without a trailing `.0`. Ten fractional digits
%% is far beyond sub-millimetre precision. BEAM floats are always finite, so
%% unlike the sibling libraries there is no NaN/Infinity case to reject.
-spec fmt_coord(number()) -> binary().
fmt_coord(I) when is_integer(I) ->
    integer_to_binary(I);
fmt_coord(F) when is_float(F) ->
    case F == trunc(F) of
        true -> integer_to_binary(trunc(F));
        false -> float_to_binary(F, [{decimals, 10}, compact])
    end.

-doc false.
%% `lng,lat` (OSRM / Mapbox convention).
-spec to_lng_lat(thinwrap_location:lat_lng()) -> binary().
to_lng_lat(#{lat := Lat, lng := Lng}) ->
    <<(fmt_coord(Lng))/binary, ",", (fmt_coord(Lat))/binary>>.

-doc false.
%% `lat,lng` (HERE / Google convention).
-spec to_lat_lng(thinwrap_location:lat_lng()) -> binary().
to_lat_lng(#{lat := Lat, lng := Lng}) ->
    <<(fmt_coord(Lat))/binary, ",", (fmt_coord(Lng))/binary>>.

-doc false.
-spec join_coords([thinwrap_location:lat_lng()], lnglat | latlng, binary()) -> binary().
join_coords(Coords, Fmt, Sep) ->
    Parts = [
        case Fmt of
            lnglat -> to_lng_lat(C);
            latlng -> to_lat_lng(C)
        end
     || C <- Coords
    ],
    iolist_to_binary(lists:join(Sep, Parts)).

-doc false.
%% Whether `Order` is a complete permutation of `[0..N-1]`: right length,
%% integers only, all in range, no duplicates. A vendor can break the canonical
%% visit order with a sentinel (Google's `[-1]`), a duplicate or a short list;
%% a wrong permutation would corrupt the caller's reordering of its own data,
%% so it is rejected (omitted), never repaired.
-spec is_complete_waypoint_order(list(), non_neg_integer()) -> boolean().
is_complete_waypoint_order(Order, N) when length(Order) =/= N ->
    false;
is_complete_waypoint_order(Order, N) ->
    Idx = [as_index(V) || V <- Order],
    lists:all(fun(I) -> is_integer(I) andalso I >= 0 andalso I < N end, Idx) andalso
        length(lists:usort(Idx)) =:= N.

-doc false.
%% Invert visit-position data (`Positions[i]` = the position input waypoint i
%% occupies; OSRM/Mapbox `waypoint_index`, Esri `Sequence`) into the canonical
%% visit order. `undefined` when absent, incomplete or malformed — never a
%% partially-filled list.
-spec invert_waypoint_positions(list(), non_neg_integer()) -> [non_neg_integer()] | undefined.
invert_waypoint_positions(Positions, N) when length(Positions) =/= N ->
    undefined;
invert_waypoint_positions(Positions, N) ->
    Idx = [as_index(V) || V <- Positions],
    case is_complete_waypoint_order(Idx, N) of
        false ->
            undefined;
        true ->
            Pairs = lists:zip(Idx, lists:seq(0, N - 1)),
            [Input || {_Pos, Input} <- lists:keysort(1, Pairs)]
    end.

as_index(I) when is_integer(I) -> I;
as_index(F) when is_float(F), F == trunc(F) -> trunc(F);
as_index(_) -> undefined.

-doc false.
%% A multi-waypoint route with no legs arrived structurally intact but
%% describes no journey. Deliberately not an exact `N - 1` leg check: Mapbox
%% and OSRM silent waypoints (`waypoints=0;2` via passthrough) legitimately
%% produce fewer legs.
-spec assert_route_has_legs(non_neg_integer(), non_neg_integer(), binary(), term(), integer()) ->
    ok.
assert_route_has_legs(Legs, WaypointCount, _Provider, _Raw, _Status) when
    Legs > 0; WaypointCount < 2
->
    ok;
assert_route_has_legs(_Legs, WaypointCount, Provider, Raw, Status) ->
    Msg = iolist_to_binary([
        Provider,
        " returned a route with no legs for ",
        integer_to_binary(WaypointCount),
        " waypoints"
    ]),
    thinwrap_location_error:fail(
        thinwrap_location_error:new(no_route, #{
            status => Status, message => Msg, provider_message => Msg, cause => Raw
        })
    ).

-doc false.
%% A scalar such as a search radius must be a number; anything else is a wrong
%% argument type (misuse), so `badarg`.
-spec assert_finite_number(term(), binary()) -> ok.
assert_finite_number(V, _Label) when is_number(V) -> ok;
assert_finite_number(V, Label) -> erlang:error({badarg, Label}, [V, Label]).

-doc false.
-spec bin(binary() | atom() | integer() | float() | string()) -> binary().
bin(B) when is_binary(B) -> B;
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(I) when is_integer(I) -> integer_to_binary(I);
bin(F) when is_float(F) -> fmt_coord(F);
bin(L) when is_list(L) ->
    case unicode:characters_to_binary(L) of
        B when is_binary(B) -> B;
        %% A caller's passthrough key or value that is not valid Unicode is
        %% misuse; the value itself stays out of the error (it may be a secret).
        _ -> erlang:error({badarg, <<"expected a binary, atom, number or Unicode string">>})
    end.

-doc false.
%% Chardata that is valid Unicode by construction (this library's own
%% `io_lib`/`calendar`/`uri_string` output, or byte-valued header strings from
%% `httpc`), as a binary. The match only narrows the type: a failure would be a
%% broken invariant, not bad input.
-spec chars_to_bin(unicode:chardata()) -> binary().
chars_to_bin(Chars) ->
    known_binary(unicode:characters_to_binary(Chars)).

-doc false.
%% Percent-encode one URL path segment. `uri_string:quote/1` throws on invalid
%% UTF-8 rather than returning its error tuple, so for a binary argument the
%% result is a binary; the match only narrows the type.
-spec quote_segment(binary()) -> binary().
quote_segment(Bin) ->
    %% `uri_string:quote/1` throws (not returns) `{error, invalid_input, _}` on
    %% a binary that is not UTF-8. A caller's place id or address is request
    %% data, so that is `invalid_request`, never an exception escaping the call.
    try uri_string:quote(Bin) of
        Quoted -> known_binary(Quoted)
    catch
        throw:{error, _, _} ->
            thinwrap_location_error:fail(
                thinwrap_location_error:invalid_request(
                    <<"value is not valid UTF-8 and cannot be placed in a URL path">>
                )
            )
    end.

%% The binary branch of a stdlib result whose spec also admits an error or a
%% charlist that the call site rules out; anything else is a broken invariant.
-spec known_binary(term()) -> binary().
known_binary(B) when is_binary(B) -> B.

-doc false.
%% Add an optional result key only when there is a value: absent optional
%% output is an omitted key, never `undefined`/`null`.
-spec put_opt(atom(), term(), map()) -> map().
put_opt(_K, undefined, M) -> M;
put_opt(K, V, M) -> M#{K => V}.

-doc false.
-spec nonempty(binary()) -> binary() | undefined.
nonempty(<<>>) -> undefined;
nonempty(B) -> B.

-doc false.
-spec list_or_empty(term()) -> list().
list_or_empty(L) when is_list(L) -> L;
list_or_empty(_) -> [].
