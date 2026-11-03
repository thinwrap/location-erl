-module(thinwrap_location_error).
-moduledoc """
Builders for `t:thinwrap_location:connector_error/0`, the plain map every
operation failure is returned as.

Connectors build errors here and `fail/1` them; the public `thinwrap_location`
functions catch that and return `{error, Error}`. Misuse of the API (a missing
config key, a bad enum atom) is not a connector error: it raises `badarg`.

There is deliberately no `retry_after_seconds` key: the raw `Retry-After`
header rides in `cause` as `<<"retryAfter">>`, and its parsed seconds are
woven into `provider_message`.
""".

-export([
    new/2,
    invalid_request/1,
    unsupported_option/1,
    classified/4,
    unknown/3,
    provider_error/5,
    require_list/4,
    require_list/5,
    fail/1,
    codes/0
]).

-export_type([code/0]).

-type code() ::
    %% Canonical, shared across thinwrap scopes.
    invalid_recipient
    | rate_limited
    | auth_failed
    | provider_unavailable
    | invalid_request
    | unknown
    %% Location-extended.
    | unsupported_field
    | unsupported_option
    | unsupported_travel_mode
    | profile_not_configured
    | matrix_polling_timeout
    | no_route
    | timeout.

-define(THROW_TAG, thinwrap_location_error).

-doc "Every `code()` value, in declaration order.".
-spec codes() -> [code()].
codes() ->
    [
        invalid_recipient,
        rate_limited,
        auth_failed,
        provider_unavailable,
        invalid_request,
        unknown,
        unsupported_field,
        unsupported_option,
        unsupported_travel_mode,
        profile_not_configured,
        matrix_polling_timeout,
        no_route,
        timeout
    ].

-doc """
Build an error. `Fields` may carry `status`, `provider_message`, `message`
and `cause`; `message` falls back to `provider_message`, then to a generic
text, so it is always present.
""".
-spec new(code(), map()) -> thinwrap_location:connector_error().
new(Code, Fields) ->
    Message =
        case Fields of
            #{message := M} when is_binary(M), M =/= <<>> -> M;
            #{provider_message := P} when is_binary(P), P =/= <<>> -> P;
            _ -> <<"Connector error">>
        end,
    Base = #{code => Code, message => Message},
    maps:merge(Base, maps:with([status, provider_message, cause], drop_undefined(Fields))).

-doc "A pre-flight `invalid_request` (no HTTP round-trip).".
-spec invalid_request(binary()) -> thinwrap_location:connector_error().
invalid_request(Msg) ->
    new(invalid_request, #{message => Msg, provider_message => Msg}).

-doc "A pre-flight `unsupported_option` (no HTTP round-trip).".
-spec unsupported_option(binary()) -> thinwrap_location:connector_error().
unsupported_option(Msg) ->
    new(unsupported_option, #{message => Msg, provider_message => Msg}).

-doc """
An error with an explicit code for an in-body vendor error (a 2xx with an
error payload): message and cause are credential-redacted, the cause keeping
its shape.
""".
-spec classified(code(), integer() | undefined, term(), binary()) ->
    thinwrap_location:connector_error().
classified(Code, Status, Cause, Msg0) ->
    Msg = thinwrap_location_util:redact_credentials(Msg0),
    new(Code, #{
        status => Status,
        message => Msg,
        provider_message => Msg,
        cause => redact_cause(Cause)
    }).

-doc "An `unknown` error for a malformed vendor body.".
-spec unknown(integer() | undefined, term(), binary()) -> thinwrap_location:connector_error().
unknown(Status, Cause, Msg) ->
    classified(unknown, Status, Cause, Msg).

-doc """
The error for a non-2xx response. The status-to-code classification and the
message are the connector's; this adds the shared `Retry-After` surfacing:
the raw header is merged into the decoded body as `<<"retryAfter">>` and its
parsed seconds appended to the message.
""".
-spec provider_error(
    integer(), thinwrap_location_transport:headers(), term(), code(), binary() | undefined
) -> thinwrap_location:connector_error().
provider_error(Status, Headers, Body, Code, ProviderMsg) ->
    {Cause, Msg} =
        case maps:get(<<"retry-after">>, Headers, <<>>) of
            <<>> ->
                {Body, ProviderMsg};
            RetryAfter ->
                Merged =
                    case Body of
                        #{} -> Body#{<<"retryAfter">> => RetryAfter};
                        _ -> #{<<"retryAfter">> => RetryAfter}
                    end,
                {Merged, with_retry_seconds(ProviderMsg, RetryAfter)}
        end,
    RedactedMsg =
        case Msg of
            undefined -> undefined;
            _ -> thinwrap_location_util:redact_credentials(Msg)
        end,
    new(Code, #{status => Status, provider_message => RedactedMsg, cause => redact_cause(Cause)}).

with_retry_seconds(Msg, RetryAfter) ->
    try binary_to_integer(string:trim(RetryAfter)) of
        Secs ->
            Suffix = <<"retry after ", (integer_to_binary(Secs))/binary, " seconds">>,
            case string:trim(default_bin(Msg)) of
                <<>> -> Suffix;
                Base -> <<Base/binary, "; ", Suffix/binary>>
            end
    catch
        error:badarg -> Msg
    end.

default_bin(undefined) -> <<>>;
default_bin(B) -> B.

-doc """
The list under `Raw[Key]` of a 2xx body, or `fail/1` with `unknown`.

A body that is not a JSON object, or whose result list is absent or not a
list, is a response the connector cannot interpret: returning an empty result
for it would present an outage or a truncated body as a genuine "no results".
`MissingOk` is for vendors whose JSON drops an empty list entirely (Google's
proto3 JSON omits empty repeated fields), where absence IS the zero answer.
""".
-spec require_list(integer(), term(), binary(), binary(), boolean()) -> list().
require_list(Status, Raw, Key, Label, MissingOk) ->
    case Raw of
        #{Key := L} when is_list(L) ->
            L;
        #{Key := null} when MissingOk ->
            [];
        #{} when MissingOk, not is_map_key(Key, Raw) ->
            [];
        _ ->
            fail(
                unknown(
                    Status,
                    Raw,
                    <<Label/binary, " returned a malformed response body (no ", Key/binary,
                        " list)">>
                )
            )
    end.

-doc "`require_list/5` with `MissingOk = false`.".
-spec require_list(integer(), term(), binary(), binary()) -> list().
require_list(Status, Raw, Key, Label) ->
    require_list(Status, Raw, Key, Label, false).

-doc """
Abort the current operation with `Error`. Only valid inside a call made
through `thinwrap_location`, which turns it into `{error, Error}`.
""".
-spec fail(thinwrap_location:connector_error()) -> no_return().
fail(Error) ->
    throw({?THROW_TAG, Error}).

%% Mask credential-looking substrings inside a decoded vendor body (should a
%% provider ever echo the request URL or key) while keeping its shape, so
%% structured access such as the `retryAfter` lookup keeps working.
redact_cause(B) when is_binary(B) ->
    thinwrap_location_util:redact_credentials(B);
redact_cause(M) when is_map(M) ->
    maps:map(fun(_K, V) -> redact_cause(V) end, M);
redact_cause(L) when is_list(L) ->
    [redact_cause(V) || V <- L];
redact_cause(Other) ->
    Other.

drop_undefined(M) ->
    maps:filter(fun(_K, V) -> V =/= undefined end, M).
