-module(thinwrap_location_passthrough).
-moduledoc false.

%% The per-operation input escape hatch. `body` is deep-merged into the
%% connector's request body; `headers` and `query` are shallow-merged. Caller
%% values intentionally OVERRIDE connector-set ones (auth included) — there is
%% deliberately no reserved-key protection. Header names match
%% case-insensitively and the caller's spelling is the one sent. Body and
%% query keys may be atoms or binaries; they go on the wire verbatim.

-export([merge/4, body/1]).

-doc false.
-spec merge(map(), thinwrap_location_transport:headers(), thinwrap_location_util:query(), map()) ->
    {map(), thinwrap_location_transport:headers(), thinwrap_location_util:query()}.
merge(Body, Headers, Query, Input) ->
    Pt = maps:get(passthrough, Input, #{}),
    {
        deep_merge(Body, keys_to_binary(maps:get(body, Pt, #{}))),
        thinwrap_location_http:merge_headers(Headers, maps:get(headers, Pt, #{})),
        thinwrap_location_util:merge_query(Query, maps:get(query, Pt, #{}))
    }.

-doc false.
%% The caller's passthrough body alone (keys as binaries), for connectors that
%% read a control value out of it (e.g. HERE/TomTom `timeoutMs`).
-spec body(map()) -> map().
body(Input) ->
    keys_to_binary(maps:get(body, maps:get(passthrough, Input, #{}), #{})).

deep_merge(Target, Source) ->
    maps:fold(
        fun(K, V, Acc) ->
            case {V, maps:get(K, Acc, undefined)} of
                {#{}, #{} = Existing} -> Acc#{K => deep_merge(Existing, V)};
                _ -> Acc#{K => V}
            end
        end,
        Target,
        Source
    ).

keys_to_binary(M) when is_map(M) ->
    maps:fold(
        fun(K, V, Acc) -> Acc#{thinwrap_location_util:bin(K) => keys_to_binary(V)} end,
        #{},
        M
    );
keys_to_binary(L) when is_list(L) ->
    [keys_to_binary(V) || V <- L];
keys_to_binary(V) ->
    V.
