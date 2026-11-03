-module(thinwrap_location_polyline).
-moduledoc """
The four locked polyline utilities, byte-for-byte compatible with the
TypeScript, PHP, Go and Python siblings (tested against the shared parity
vectors).

- `encode/1` — coordinates to a Google precision-5 polyline.
- `decode/1` — a Google precision-5 polyline to coordinates.
- `decode_flex/1` — a HERE flexible polyline to coordinates (altitude skipped).
- `encode_esri_paths/1` — coordinate paths to an Esri JSON `paths` geometry.

Every normalized routing result carries its geometry as a precision-5
polyline, whatever the provider returned.
""".

-export([encode/1, decode/1, decode_flex/1, encode_esri_paths/1]).
-export([decode_or_fail/1, decode_flex_or_fail/1]).

-define(FLEX_TABLE,
    {62, -1, -1, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, -1, -1, -1, -1, -1, -1, -1, 0, 1, 2, 3, 4,
        5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, -1, -1, -1,
        -1, 63, -1, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45,
        46, 47, 48, 49, 50, 51}
).

-doc "Encode coordinates into a Google-format precision-5 polyline.".
-spec encode([thinwrap_location:lat_lng()]) -> binary().
encode(Coords) when is_list(Coords) ->
    {Out, _, _} = lists:foldl(
        fun
            (#{lat := La, lng := Ln}, {Acc, PLat, PLng}) when is_number(La), is_number(Ln) ->
                Lat = js_round(La * 1.0e5),
                Lng = js_round(Ln * 1.0e5),
                {[Acc, encode_signed(Lat - PLat), encode_signed(Lng - PLng)], Lat, Lng};
            (C, _) ->
                erlang:error(badarg, [C])
        end,
        {[], 0, 0},
        Coords
    ),
    iolist_to_binary(Out);
encode(Other) ->
    erlang:error(badarg, [Other]).

-doc """
Decode a Google-format precision-5 polyline. A truncated or invalid string
is data, not misuse, so it returns `{error, Error}` with code `unknown`.
""".
-spec decode(binary()) ->
    {ok, [thinwrap_location:lat_lng()]} | {error, thinwrap_location:connector_error()}.
decode(Encoded) when is_binary(Encoded) ->
    catch_malformed(fun() -> decode_or_fail(Encoded) end);
decode(Other) ->
    erlang:error(badarg, [Other]).

-doc "Decode a HERE flexible polyline; altitude, if present, is decoded and skipped.".
-spec decode_flex(binary()) ->
    {ok, [thinwrap_location:lat_lng()]} | {error, thinwrap_location:connector_error()}.
decode_flex(Encoded) when is_binary(Encoded) ->
    catch_malformed(fun() -> decode_flex_or_fail(Encoded) end);
decode_flex(Other) ->
    erlang:error(badarg, [Other]).

-doc """
Convert coordinate paths into an Esri JSON `paths` geometry: each point an
`[lng, lat]` pair, CRS fixed at WGS-84.
""".
-spec encode_esri_paths([[thinwrap_location:lat_lng()]]) -> map().
encode_esri_paths(Paths) ->
    #{
        <<"paths">> => [[[Lng, Lat] || #{lat := Lat, lng := Lng} <- Path] || Path <- Paths],
        <<"spatialReference">> => #{<<"wkid">> => 4326}
    }.

-doc false.
-spec decode_or_fail(binary()) -> [thinwrap_location:lat_lng()].
decode_or_fail(Encoded) ->
    decode_pairs(Encoded, 0, 0, []).

decode_pairs(<<>>, _Lat, _Lng, Acc) ->
    lists:reverse(Acc);
decode_pairs(Bin, Lat0, Lng0, Acc) ->
    {DLat, Rest1} = decode_signed(Bin),
    {DLng, Rest2} = decode_signed(Rest1),
    Lat = Lat0 + DLat,
    Lng = Lng0 + DLng,
    decode_pairs(Rest2, Lat, Lng, [#{lat => Lat / 1.0e5, lng => Lng / 1.0e5} | Acc]).

decode_signed(Bin) ->
    {R, Rest} = decode_varint(Bin, 0, 0),
    {zigzag(R), Rest}.

decode_varint(<<>>, _, _) ->
    malformed();
decode_varint(<<C, _/binary>>, _, _) when C < 63 ->
    malformed();
decode_varint(<<C, Rest/binary>>, Shift, Acc) ->
    B = C - 63,
    Acc1 = Acc bor ((B band 16#1F) bsl Shift),
    case B < 16#20 of
        true -> {Acc1, Rest};
        false -> decode_varint(Rest, Shift + 5, Acc1)
    end.

-doc false.
-spec decode_flex_or_fail(binary()) -> [thinwrap_location:lat_lng()].
decode_flex_or_fail(Encoded) ->
    {_Version, R1} = flex_unsigned(Encoded),
    {Header2, R2} = flex_unsigned(R1),
    Precision = Header2 band 16#0F,
    ThirdDim = (Header2 bsr 4) band 16#07,
    Factor = math:pow(10, Precision),
    flex_points(R2, ThirdDim =/= 0, Factor, 0, 0, []).

flex_points(<<>>, _, _, _, _, Acc) ->
    lists:reverse(Acc);
flex_points(Bin, Third, Factor, Lat0, Lng0, Acc) ->
    {DLat, R1} = flex_zigzag(Bin),
    {DLng, R2} = flex_zigzag(R1),
    R3 =
        case Third of
            true -> element(2, flex_zigzag(R2));
            false -> R2
        end,
    Lat = Lat0 + DLat,
    Lng = Lng0 + DLng,
    flex_points(R3, Third, Factor, Lat, Lng, [#{lat => Lat / Factor, lng => Lng / Factor} | Acc]).

flex_zigzag(Bin) ->
    {R, Rest} = flex_unsigned(Bin),
    {zigzag(R), Rest}.

flex_unsigned(Bin) -> flex_unsigned(Bin, 0, 0).

flex_unsigned(<<>>, _, _) ->
    malformed();
flex_unsigned(<<C, Rest/binary>>, Shift, Acc) ->
    case flex_digit(C - 45) of
        -1 ->
            malformed();
        B ->
            Acc1 = Acc bor ((B band 16#1F) bsl Shift),
            case B < 16#20 of
                true -> {Acc1, Rest};
                false -> flex_unsigned(Rest, Shift + 5, Acc1)
            end
    end.

%% -1 for a character outside the flexible-polyline alphabet.
flex_digit(Di) when Di >= 0, Di < tuple_size(?FLEX_TABLE) -> element(Di + 1, ?FLEX_TABLE);
flex_digit(_) -> -1.

zigzag(R) when R band 1 =:= 1 -> bnot (R bsr 1);
zigzag(R) -> R bsr 1.

encode_signed(Value) ->
    V =
        case Value < 0 of
            true -> bnot (Value bsl 1);
            false -> Value bsl 1
        end,
    encode_chunks(V, []).

encode_chunks(V, Acc) when V >= 16#20 ->
    encode_chunks(V bsr 5, [((16#20 bor (V band 16#1F)) + 63) | Acc]);
encode_chunks(V, Acc) ->
    lists:reverse([V + 63 | Acc]).

%% JavaScript Math.round (half toward +Infinity), so encoding matches the
%% TypeScript sibling on .5 boundaries.
js_round(X) -> floor(X + 0.5).

-spec malformed() -> no_return().
malformed() ->
    thinwrap_location_error:fail(
        thinwrap_location_error:new(unknown, #{
            message => <<"Malformed polyline">>, provider_message => <<"Malformed polyline">>
        })
    ).

catch_malformed(Fun) ->
    try
        {ok, Fun()}
    catch
        throw:{thinwrap_location_error, E} -> {error, E}
    end.
