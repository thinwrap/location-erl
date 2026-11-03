-module(thinwrap_location_input).
-moduledoc false.

%% Validation and defaults for configs and operation inputs. Everything here
%% is misuse detection, so every failure raises `{badarg, Description}`
%% before any HTTP — never a connector error. Descriptions never echo a
%% config value: it may be a credential.

-export([config/1, input/2, secret/2, opt/3]).

-define(PROVIDERS, [google, mapbox, here, esri, osrm, tomtom]).

-define(CREDENTIAL_KEYS, #{
    google => [api_key],
    here => [api_key],
    tomtom => [api_key],
    mapbox => [access_token],
    esri => [api_key, arcgis_token],
    osrm => []
}).

-doc false.
-spec config(term()) -> thinwrap_location:config().
config(#{provider := P0} = C) ->
    P = provider(P0),
    Creds = maps:get(P, ?CREDENTIAL_KEYS),
    Extra =
        case P of
            osrm -> [base_url, supported_exclude_classes];
            _ -> []
        end,
    Allowed = [provider, transport, sleep] ++ Creds ++ Extra,
    [
        bad(["unknown config key for ", atom_to_list(P), ": ", key_text(K)])
     || K <- maps:keys(C), not lists:member(K, Allowed)
    ],
    [check_secret(K, V) || K := V <- C, lists:member(K, Creds)],
    check_credentials(P, C),
    C1 = C#{transport => transport(maps:get(transport, C, undefined))},
    case C1 of
        #{sleep := S} when not is_function(S, 1) -> bad(["config sleep must be a fun/1"]);
        _ -> ok
    end,
    case P of
        osrm ->
            case C1 of
                #{base_url := U} when is_binary(U) -> ok;
                _ -> bad(["osrm config requires base_url (a binary)"])
            end,
            case maps:get(supported_exclude_classes, C1, []) of
                L when is_list(L) ->
                    lists:all(fun is_binary/1, L) orelse
                        bad(["supported_exclude_classes must be a list of binaries"]);
                _ ->
                    bad(["supported_exclude_classes must be a list of binaries"])
            end;
        _ ->
            ok
    end,
    checked_config(C1);
config(_) ->
    bad(["config must be a map with a provider key"]).

%% The guard spells out ?PROVIDERS so the result is typed as a provider().
provider(P) when
    P =:= google; P =:= mapbox; P =:= here; P =:= esri; P =:= osrm; P =:= tomtom
->
    P;
provider(_) ->
    bad(["config provider must be one of ", join(?PROVIDERS)]).

%% config/1 has checked every key of `C` by now, with lists:all/orelse checks
%% no type checker follows into a map type; this identity is where the
%% validated map becomes a config().
-spec checked_config(map()) -> thinwrap_location:config().
checked_config(C) -> C.

%% Presence of the single required credential (the sibling libraries' required
%% config field). Esri's "exactly one of api_key / arcgis_token" rule is NOT
%% checked here: across the siblings it is a connector error (invalid_request
%% for both, auth_failed for neither), raised by the Esri connector per call.
check_credentials(esri, _C) ->
    ok;
check_credentials(osrm, _C) ->
    ok;
check_credentials(P, C) ->
    [K] = maps:get(P, ?CREDENTIAL_KEYS),
    maps:is_key(K, C) orelse bad([atom_to_list(P), " config requires ", atom_to_list(K)]).

check_secret(_K, V) when is_binary(V) -> ok;
check_secret(_K, V) when is_function(V, 0) -> ok;
check_secret(K, _V) -> bad(["config ", atom_to_list(K), " must be a binary or a fun/0"]).

transport(undefined) ->
    {thinwrap_location_httpc, #{}};
transport({Mod, _Opts} = T) when is_atom(Mod) ->
    case code:ensure_loaded(Mod) of
        {module, Mod} -> ok;
        _ -> bad(["transport module ", atom_to_list(Mod), " cannot be loaded"])
    end,
    erlang:function_exported(Mod, request, 2) orelse
        bad(["transport module ", atom_to_list(Mod), " does not export request/2"]),
    T;
transport(_) ->
    bad(["config transport must be {Module, Opts}"]).

-doc false.
%% Resolve a credential (binary or fun/0) at the point of use.
-spec secret(thinwrap_location:config(), atom()) -> binary().
secret(Config, Key) ->
    case maps:get(Key, Config) of
        F when is_function(F, 0) ->
            case F() of
                B when is_binary(B) -> B;
                _ -> bad(["config ", atom_to_list(Key), " fun must return a binary"])
            end;
        B when is_binary(B) ->
            B;
        _ ->
            bad(["config ", atom_to_list(Key), " must be a binary or a fun/0"])
    end.

-doc false.
%% An optional input value, or `Default`.
-spec opt(map(), atom(), term()) -> term().
opt(Input, Key, Default) -> maps:get(Key, Input, Default).

%% ---------------------------------------------------------------------------
%% Inputs: {Key, required | {default, V} | optional, Check}

-define(TRAVEL, {enum, [driving, walking, cycling]}).
-define(TRAFFIC, {enum, [none, traffic, live]}).
-define(PASSTHROUGH, {passthrough, optional, passthrough}).
-define(COUNTRY_FILTER, {country_filter, optional, {list, binary}}).

spec(route) ->
    [
        {waypoints, required, {list, latlng}},
        {optimize, {default, false}, boolean},
        {optimize_fixed_origin, {default, false}, boolean},
        {optimize_fixed_destination, {default, false}, boolean},
        {is_round_trip, {default, false}, boolean},
        {departure_time, optional, departure},
        {avoid_tolls, {default, false}, boolean},
        {avoid_ferries, {default, false}, boolean},
        {avoid_highways, {default, false}, boolean},
        {travel_mode, {default, driving}, ?TRAVEL},
        {transport_mode, optional, atom_or_binary},
        ?PASSTHROUGH,
        {polyline_quality, {default, simplified}, {enum, [simplified, detailed]}},
        {traffic_mode, {default, none}, ?TRAFFIC},
        {include, {default, []}, {list, {enum, [durationWithoutTraffic]}}}
    ];
spec(matrix) ->
    [
        {origins, required, {list, latlng}},
        {destinations, required, {list, latlng}},
        {travel_mode, {default, driving}, ?TRAVEL},
        {avoid_tolls, {default, false}, boolean},
        {departure_time, optional, departure},
        {transport_mode, optional, atom_or_binary},
        ?PASSTHROUGH,
        {traffic_mode, {default, none}, ?TRAFFIC}
    ];
spec(geocode) ->
    [
        {address, required, binary},
        {language, optional, binary},
        ?COUNTRY_FILTER,
        ?PASSTHROUGH
    ];
spec(reverse_geocode) ->
    [
        {location, required, latlng},
        {language, optional, binary},
        ?PASSTHROUGH
    ];
spec(autocomplete) ->
    [
        {input, required, binary},
        {location, optional, latlng},
        {radius, optional, number},
        {language, optional, binary},
        {session_token, optional, binary},
        ?COUNTRY_FILTER,
        ?PASSTHROUGH
    ];
spec(place_details) ->
    [
        {place_id, required, binary},
        {language, optional, binary},
        {session_token, optional, binary},
        {include, {default, []}, {list, {enum, [name]}}},
        ?PASSTHROUGH
    ];
spec(isochrone) ->
    [
        {center, required, latlng},
        {type, required, {enum, [time, distance]}},
        {values, required, {list, number}},
        {travel_mode, {default, driving}, ?TRAVEL},
        {departure_time, optional, departure},
        ?PASSTHROUGH
    ].

-doc false.
-spec input(thinwrap_location:operation(), term()) -> map().
input(Op, Input) when is_map(Input) ->
    Spec = spec(Op),
    Known = [K || {K, _, _} <- Spec],
    [
        bad([atom_to_list(Op), ": unknown input key ", key_text(K)])
     || K <- maps:keys(Input), not lists:member(K, Known)
    ],
    lists:foldl(
        fun({K, Presence, Check}, Acc) ->
            case {maps:find(K, Input), Presence} of
                {{ok, V}, _} ->
                    check(Op, K, Check, V),
                    Acc#{K => V};
                {error, required} ->
                    bad([atom_to_list(Op), ": missing required input key ", atom_to_list(K)]);
                {error, {default, D}} ->
                    Acc#{K => D};
                {error, optional} ->
                    Acc
            end
        end,
        #{},
        Spec
    );
input(Op, _) ->
    bad([atom_to_list(Op), ": input must be a map"]).

check(Op, K, Check, V) ->
    valid(Check, V) orelse
        bad([atom_to_list(Op), ": ", atom_to_list(K), " must be ", describe(Check)]).

valid(boolean, V) ->
    is_boolean(V);
valid(binary, V) ->
    is_binary(V);
valid(number, V) ->
    is_number(V);
valid(atom_or_binary, V) ->
    (is_atom(V) andalso V =/= undefined) orelse is_binary(V);
valid(latlng, #{lat := La, lng := Ln}) ->
    is_number(La) andalso is_number(Ln);
valid(latlng, _) ->
    false;
valid({enum, Vs}, V) ->
    lists:member(V, Vs);
valid({list, C}, L) when is_list(L) -> lists:all(fun(V) -> valid(C, V) end, L);
valid({list, _}, _) ->
    false;
valid(departure, I) when is_integer(I) -> true;
valid(departure, B) when is_binary(B) -> true;
valid(departure, {{Y, Mo, D}, {H, Mi, S}}) ->
    lists:all(fun is_integer/1, [Y, Mo, D, H, Mi, S]) andalso calendar:valid_date(Y, Mo, D);
valid(departure, _) ->
    false;
valid(passthrough, #{} = P) ->
    lists:all(fun(K) -> lists:member(K, [body, headers, query]) end, maps:keys(P)) andalso
        is_map(maps:get(body, P, #{})) andalso
        is_map(maps:get(headers, P, #{})) andalso
        is_map(maps:get(query, P, #{}));
valid(passthrough, _) ->
    false.

describe(boolean) -> "a boolean";
describe(binary) -> "a binary";
describe(number) -> "a number";
describe(atom_or_binary) -> "an atom or a binary";
describe(latlng) -> "#{lat => number(), lng => number()}";
describe({enum, Vs}) -> ["one of ", join(Vs)];
describe({list, C}) -> ["a list of ", describe(C)];
describe(departure) -> "Unix seconds, a calendar:datetime() or an RFC 3339 binary";
describe(passthrough) -> "#{body => map(), headers => map(), query => map()}".

join(Atoms) -> lists:join(", ", [atom_to_list(A) || A <- Atoms]).

key_text(K) when is_atom(K) -> atom_to_list(K);
key_text(_) -> "(non-atom key)".

-spec bad(iodata()) -> no_return().
bad(IoList) ->
    erlang:error({badarg, unicode:characters_to_binary(IoList)}).
