-module(thinwrap_location_isochrone).
-moduledoc false.

%% Shared by every isochrone connector: break-value validation, departure
%% time, and contour geometry (ring closure, RFC 7946 winding, the
%% Polygon-vs-MultiPolygon choice, Esri ring grouping).

-export([
    validate_cap/1,
    departure/2,
    contour_geometry/1,
    normalize_polygon/1,
    esri_parts/1,
    signed_area/1
]).

%% Maximum contour breaks across all four isochrone providers (Mapbox's ceiling).
-define(MAX_VALUES, 4).

-doc false.
-spec validate_cap([number()]) -> ok.
validate_cap([]) ->
    thinwrap_location_error:fail(
        thinwrap_location_error:invalid_request(<<"isochrone requires at least one break value">>)
    );
validate_cap(Values) ->
    lists:all(fun(V) -> V > 0 end, Values) orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<"isochrone break values must be finite numbers greater than 0">>
            )
        ),
    length(Values) =< ?MAX_VALUES orelse
        thinwrap_location_error:fail(
            thinwrap_location_error:invalid_request(
                <<"Maximum ", (integer_to_binary(?MAX_VALUES))/binary,
                    " values supported (Mapbox native ceiling)">>
            )
        ),
    ok.

-doc false.
%% The departure string to send. An ISO-8601 date-time binary is sent
%% verbatim, so the caller's offset — or its absence, which a vendor may read
%% as local time — is preserved; Unix seconds and a `calendar:datetime()` go
%% out as UTC at seconds precision. A binary that is not an ISO-8601
%% date-time is `invalid_request`: forwarded unchecked, a vendor either
%% rejects it opaquely or ignores it and computes a time-independent
%% isochrone the caller did not ask for.
-spec departure(thinwrap_location:departure_time(), binary()) -> binary().
departure(Bin, Label) when is_binary(Bin) ->
    case iso_date_time(Bin) of
        true ->
            Bin;
        false ->
            thinwrap_location_error:fail(
                thinwrap_location_error:invalid_request(
                    <<Label/binary, " departure_time must be an ISO-8601 date-time string, got ",
                        (printable(Bin))/binary>>
                )
            )
    end;
departure(When, Label) ->
    thinwrap_location_util:iso_seconds_string(When, Label).

iso_date_time(Bin) ->
    Re =
        "^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2})(:([0-9]{2})(\\.[0-9]+)?)?"
        "([Zz]|[+-][0-9]{2}(:?[0-9]{2})?)?$",
    case re:run(Bin, Re, [{capture, [1, 2, 3, 4, 5], list}]) of
        {match, [Y, Mo, D, H, Mi]} ->
            calendar:valid_date(list_to_integer(Y), list_to_integer(Mo), list_to_integer(D)) andalso
                list_to_integer(H) < 24 andalso list_to_integer(Mi) < 60;
        nomatch ->
            false
    end.

printable(Bin) ->
    case byte_size(Bin) > 64 of
        true -> <<(binary:part(Bin, 0, 64))/binary, "...">>;
        false -> Bin
    end.

-doc false.
%% Shoelace area of an `[x, y]` ring: positive counter-clockwise, negative
%% clockwise, 0 when degenerate. Closure does not matter.
-spec signed_area([[number()]]) -> float().
signed_area([]) ->
    0.0;
signed_area([First | Rest] = Ring) ->
    %% Each vertex with the one after it, the last wrapping to the first.
    Edges = lists:zip(Ring, Rest ++ [First]),
    Sum = lists:foldl(
        fun({[X1, Y1 | _], [X2, Y2 | _]}, Acc) -> Acc + (X1 * Y2 - X2 * Y1) end, 0, Edges
    ),
    Sum / 2.

closed(Ring) ->
    Out = [[X, Y] || [X, Y | _] <- Ring],
    [F | _] = Out,
    case F =:= lists:last(Out) of
        true -> Out;
        false -> Out ++ [F]
    end.

%% A degenerate (zero-area) ring has no winding to fix, so it is only closed.
wound(Ring, Ccw) ->
    Out = closed(Ring),
    Area = signed_area(Out),
    case (Ccw andalso Area < 0) orelse (not Ccw andalso Area > 0) of
        true -> lists:reverse(Out);
        false -> Out
    end.

-doc false.
%% `[exterior | holes]` closed and wound per RFC 7946 §3.1.6 (exterior
%% counter-clockwise, holes clockwise), whatever winding the vendor used.
-spec normalize_polygon([[[number()]]]) -> [[[number()]]].
normalize_polygon([Ext | Holes]) ->
    [wound(Ext, true) | [wound(H, false) || H <- Holes]].

-doc false.
%% One part stays a plain Polygon, so the common single-part result keeps its
%% shape; only a genuinely multi-part contour becomes a MultiPolygon.
-spec contour_geometry([[[[number()]]]]) -> #{type := binary(), coordinates := list()}.
contour_geometry([Part]) ->
    #{type => <<"Polygon">>, coordinates => normalize_polygon(Part)};
contour_geometry(Parts) ->
    #{type => <<"MultiPolygon">>, coordinates => [normalize_polygon(P) || P <- Parts]}.

%% Even-odd ray cast; closure does not matter.
-spec contains([[number()]], number(), number()) -> boolean().
contains([], _X, _Y) ->
    false;
contains(Ring, X, Y) ->
    %% Each vertex with the one before it, the first wrapping to the last.
    Edges = lists:zip(Ring, [lists:last(Ring) | lists:droplast(Ring)]),
    lists:foldl(
        fun({[Xi, Yi | _], [Xj, Yj | _]}, In) ->
            Crosses = (Yi > Y) =/= (Yj > Y) andalso X < (Xj - Xi) * (Y - Yi) / (Yj - Yi) + Xi,
            In xor Crosses
        end,
        false,
        Edges
    ).

-doc false.
%% Group an Esri polygon's flat `rings` into `[exterior | holes]` parts. Esri
%% lists outer and hole rings in no guaranteed order and marks them only by
%% winding: clockwise is an exterior, counter-clockwise a hole. A zero-area
%% ring cannot bound a hole, so it is kept as its own exterior. If no ring is
%% clockwise the winding carries no signal and every ring is an exterior, so
%% no area is lost. Each hole goes to the smallest exterior containing its
%% first vertex, or to the largest exterior when none contains it.
-spec esri_parts([[[number()]]]) -> [[[[number()]]]].
esri_parts(Rings) ->
    Indexed = lists:zip(lists:seq(0, length(Rings) - 1), Rings),
    Areas = maps:from_list([{I, signed_area(R)} || {I, R} <- Indexed]),
    Ext0 = [I || {I, _} <- Indexed, maps:get(I, Areas) =< 0],
    Exteriors =
        case Ext0 of
            [] -> [I || {I, _} <- Indexed];
            _ -> Ext0
        end,
    Holes = [I || {I, _} <- Indexed, not lists:member(I, Exteriors)],
    RingAt = maps:from_list(Indexed),
    AbsArea = fun(I) -> abs(maps:get(I, Areas)) end,
    Largest = max_by(AbsArea, Exteriors),
    Owners = lists:foldl(
        fun(H, Acc) ->
            [[X, Y | _] | _] = maps:get(H, RingAt),
            Owner =
                case [I || I <- Exteriors, contains(maps:get(I, RingAt), X, Y)] of
                    [] -> Largest;
                    Containing -> min_by(AbsArea, Containing)
                end,
            maps:update_with(Owner, fun(Hs) -> Hs ++ [maps:get(H, RingAt)] end, Acc)
        end,
        maps:from_list([{I, []} || I <- Exteriors]),
        Holes
    ),
    [[maps:get(I, RingAt) | maps:get(I, Owners)] || I <- Exteriors].

%% First index wins on ties, matching Python's max()/min().
max_by(F, [H | T]) ->
    lists:foldl(
        fun(I, Best) ->
            case F(I) > F(Best) of
                true -> I;
                false -> Best
            end
        end,
        H,
        T
    ).
min_by(F, [H | T]) ->
    lists:foldl(
        fun(I, Best) ->
            case F(I) < F(Best) of
                true -> I;
                false -> Best
            end
        end,
        H,
        T
    ).
