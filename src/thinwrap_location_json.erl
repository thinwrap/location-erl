-module(thinwrap_location_json).
-moduledoc false.

%% JSON on OTP's own `json` module (OTP 27+), plus absence-tolerant accessors
%% for walking a decoded vendor body, where full typing would be overkill.
%%
%% Decoded shape: objects are maps with binary keys, arrays are lists, `null`
%% is the atom `null`, numbers stay integer or float as written.

-export([encode/1, decode/1, get/2, str/1, num/1, num_opt/1, list/1, path/2]).

-doc false.
%% Compact UTF-8 JSON. Atom keys/values other than true/false/null encode as
%% strings. A non-UTF-8 binary or an unencodable term is request data the
%% vendor could never accept, so it fails with `invalid_request`.
-spec encode(term()) -> binary().
encode(Term) ->
    try
        %% encode/2 with the stock encoder is exactly encode/1, but typed to
        %% accept any term: an unencodable one is the error branch below.
        iolist_to_binary(json:encode(Term, fun json:encode_value/2))
    catch
        error:Reason ->
            thinwrap_location_error:fail(
                thinwrap_location_error:new(invalid_request, #{
                    message => <<"Failed to encode request body">>,
                    provider_message => <<"Failed to encode request body">>,
                    cause => encode_reason(Reason)
                })
            )
    end.

%% Keep the offending value out of the error: it could be a credential.
encode_reason({invalid_byte, _}) -> invalid_byte;
encode_reason({unsupported_type, _}) -> unsupported_type;
encode_reason(R) when is_atom(R) -> R;
encode_reason(_) -> encode_failed.

-doc false.
%% Decode arbitrary JSON, `undefined` for an empty or malformed body. OTP's
%% decoder raises on malformed input and already rejects the non-JSON
%% NaN/Infinity tokens.
-spec decode(binary() | undefined) -> term() | undefined.
decode(undefined) ->
    undefined;
decode(<<>>) ->
    undefined;
decode(Bin) when is_binary(Bin) ->
    try
        json:decode(Bin)
    catch
        error:_ -> undefined
    end.

-doc false.
-spec get(term(), binary()) -> term() | undefined.
get(#{} = M, Key) ->
    case maps:get(Key, M, undefined) of
        null -> undefined;
        V -> V
    end;
get(_, _) ->
    undefined.

-doc false.
%% Walk nested object keys; any non-object along the way yields `undefined`.
-spec path(term(), [binary()]) -> term() | undefined.
path(V, []) -> V;
path(V, [K | Rest]) -> path(get(V, K), Rest).

-doc false.
-spec str(term()) -> binary().
str(B) when is_binary(B) -> B;
str(_) -> <<>>.

-doc false.
%% A JSON number as a float, `0.0` when absent or not a number.
-spec num(term()) -> float().
num(N) when is_number(N) -> float(N);
num(_) -> 0.0.

-doc false.
%% A JSON number as a float, `undefined` when absent. Use wherever a zero
%% would be indistinguishable from real data — coordinates above all, where a
%% 0.0 fallback fabricates a "Null Island" position.
-spec num_opt(term()) -> float() | undefined.
num_opt(N) when is_number(N) -> float(N);
num_opt(_) -> undefined.

-doc false.
-spec list(term()) -> list() | undefined.
list(L) when is_list(L) -> L;
list(_) -> undefined.
