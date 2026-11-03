-module(thinwrap_location_http).
-moduledoc false.

%% The shared HTTP seam every connector sends through: builds the request,
%% calls the configured transport, and normalizes a transport failure. It does
%% no JSON parsing and no error mapping — status-to-code translation stays in
%% each provider module.

-export([send_get/4, send_post_json/5, send_post_form/5, merge_headers/2]).
-export_type([headers/0]).

-type headers() :: thinwrap_location_transport:headers().

-doc false.
-spec send_get(thinwrap_location:config(), binary(), headers(), thinwrap_location_util:query()) ->
    thinwrap_location_transport:response().
send_get(Config, Url, Headers, Query) ->
    invoke(
        Config, get, thinwrap_location_util:build_url(Url, Query), undefined, undefined, Headers
    ).

-doc false.
-spec send_post_json(
    thinwrap_location:config(), binary(), term(), headers(), thinwrap_location_util:query()
) -> thinwrap_location_transport:response().
send_post_json(Config, Url, Body, Headers, Query) ->
    Data = thinwrap_location_json:encode(Body),
    invoke(
        Config,
        post,
        thinwrap_location_util:build_url(Url, Query),
        Data,
        <<"application/json">>,
        Headers
    ).

-doc false.
-spec send_post_form(
    thinwrap_location:config(),
    binary(),
    [{binary(), binary()}],
    headers(),
    thinwrap_location_util:query()
) -> thinwrap_location_transport:response().
send_post_form(Config, Url, Form, Headers, Query) ->
    Data = uri_string:compose_query(Form),
    invoke(
        Config,
        post,
        thinwrap_location_util:build_url(Url, Query),
        Data,
        <<"application/x-www-form-urlencoded">>,
        Headers
    ).

-doc false.
%% Overlay `Override` onto `Base` with HTTP's case-insensitive name rule
%% (RFC 9110 §5.1). A plain map merge of `X-Goog-FieldMask` and
%% `x-goog-fieldmask` keeps both, and the transport then sends two conflicting
%% values; here the override's spelling is the one sent.
-spec merge_headers(headers(), headers()) -> headers().
merge_headers(Base, Override) ->
    maps:fold(
        fun(Name0, Value, Acc) ->
            Name = thinwrap_location_util:bin(Name0),
            Lower = string:lowercase(Name),
            Kept = maps:filter(fun(K, _) -> string:lowercase(K) =/= Lower end, Acc),
            Kept#{Name => thinwrap_location_util:bin(Value)}
        end,
        Base,
        Override
    ).

invoke(Config, Method, Url, Body, ContentType, Headers0) ->
    CT =
        case ContentType of
            undefined -> #{};
            _ -> #{<<"Content-Type">> => ContentType}
        end,
    Headers = merge_headers(CT, Headers0),
    Req0 = #{method => Method, url => Url, headers => Headers},
    Req =
        case Body of
            undefined -> Req0;
            _ -> Req0#{body => Body}
        end,
    {Mod, Opts} = maps:get(transport, Config),
    Result =
        try
            Mod:request(Req, Opts)
        catch
            throw:{thinwrap_location_error, _} = Thrown ->
                throw(Thrown);
            Class:Reason ->
                {error, {Class, Reason}}
        end,
    case Result of
        {ok, #{status := S, headers := H, body := B} = Resp} when
            is_integer(S), is_map(H), is_binary(B)
        ->
            Resp;
        {error, {connector_error, #{code := _} = E}} ->
            thinwrap_location_error:fail(E);
        {error, Reason2} ->
            thinwrap_location_error:fail(transport_failure(Reason2, Url));
        Other ->
            %% A transport that breaks its contract is a bug in the calling
            %% code, not a provider outage — report it as such.
            erlang:error({bad_transport_return, Mod, shape(Other)})
    end.

shape({ok, M}) when is_map(M) -> {ok, maps:keys(M)};
shape(T) when is_tuple(T) -> {tuple, tuple_size(T)};
shape(T) when is_atom(T) -> T;
shape(_) -> other.

%% A client's error term may embed the full request URL, credential query
%% params included, so only a redacted string ever leaves this function.
transport_failure(Reason, Url) ->
    Text = thinwrap_location_util:chars_to_bin(io_lib:format("~0tP", [Reason, 30])),
    Msg = scrub_userinfo(thinwrap_location_util:redact_credentials(Text), Url),
    Code =
        case contains_timeout(Reason) of
            true -> timeout;
            false -> provider_unavailable
        end,
    thinwrap_location_error:new(Code, #{message => Msg, provider_message => Msg, cause => Msg}).

%% `httpc` says `timeout` for the whole-request budget and nests it as
%% `{failed_connect, [..., {inet, _, timeout}]}` for the connect phase.
contains_timeout(timeout) -> true;
contains_timeout(T) when is_tuple(T) -> contains_timeout(tuple_to_list(T));
contains_timeout([H | T]) -> contains_timeout(H) orelse contains_timeout(T);
contains_timeout(_) -> false.

%% Pattern redaction only sees `scheme://user:pass@` intact; a client may
%% quote the host part some other way, so scrub the known secret strings too.
scrub_userinfo(Msg, Url) ->
    case uri_string:parse(Url) of
        %% `Url` is a binary, so every parsed component is one too.
        #{userinfo := UI} when is_binary(UI), UI =/= <<>> ->
            Secrets =
                case binary:split(UI, <<":">>) of
                    [_User, Pass] when Pass =/= <<>> -> [UI, Pass];
                    _ -> [UI]
                end,
            lists:foldl(
                fun(S, Acc) -> binary:replace(Acc, S, <<"[REDACTED]">>, [global]) end,
                Msg,
                Secrets
            );
        _ ->
            Msg
    end.
