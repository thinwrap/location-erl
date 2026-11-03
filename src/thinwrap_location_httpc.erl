-module(thinwrap_location_httpc).
-moduledoc """
Default transport, built on OTP `httpc`.

Options (all optional), passed as `transport => {thinwrap_location_httpc, Opts}`:

- `timeout` — whole-request budget in milliseconds (default `30000`). `httpc`
  itself defaults to `infinity`, so a blackholed connection would otherwise
  hang the calling process forever.
- `connect_timeout` — milliseconds (default: `timeout`).
- `profile` — an `httpc` profile you started yourself (default: `default`).
  The library never starts a profile or any other process.
- `ssl` — a **complete** list of `ssl` client options. Leave it out: since
  OTP 26 `httpc` verifies the peer and its host name against the OS trust
  store by default, and passing *any* `ssl` list replaces those defaults
  rather than adding to them.

The adapter is HTTPS-only: an `http://` (or any other) URL is refused with an
`invalid_request` error instead of being sent in cleartext. A self-hosted
endpoint on plain HTTP (an OSRM on a private network) needs your own transport.
Redirects are never followed.
""".

-behaviour(thinwrap_location_transport).

-export([request/2]).

-define(DEFAULT_TIMEOUT_MS, 30000).
%% Cloudflare-fronted APIs answer a missing or library-default User-Agent with
%% 403 "error code: 1010", so the adapter names itself. A User-Agent already on
%% the request wins.
-define(USER_AGENT, "thinwrap-location-erlang").

-doc "Send one request with `httpc`. See the module doc for `Opts`.".
-spec request(thinwrap_location_transport:request(), map()) ->
    {ok, thinwrap_location_transport:response()} | {error, term()}.
request(#{method := Method, url := Url, headers := Headers} = Req, Opts) when is_map(Opts) ->
    case uri_scheme(Url) of
        <<"https">> ->
            ok = ensure_started(),
            send(Method, Url, Headers, maps:get(body, Req, undefined), Opts);
        Scheme ->
            {error, {connector_error, scheme_refused(Scheme)}}
    end;
request(Req, Opts) ->
    erlang:error(badarg, [Req, Opts]).

send(Method, Url, Headers0, Body, Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT_MS),
    HttpOpts0 = [
        {timeout, Timeout},
        {connect_timeout, maps:get(connect_timeout, Opts, Timeout)},
        {autoredirect, false}
    ],
    HttpOpts =
        case Opts of
            #{ssl := Ssl} -> [{ssl, Ssl} | HttpOpts0];
            _ -> HttpOpts0
        end,
    {ContentType, Headers} = split_content_type(with_user_agent(Headers0)),
    HttpcHeaders = [{to_list(K), to_list(V)} || {K, V} <- Headers],
    Request =
        case Method of
            get -> {Url, HttpcHeaders};
            post -> {Url, HttpcHeaders, ContentType, body_or_empty(Body)}
        end,
    Profile = maps:get(profile, Opts, default),
    case httpc:request(Method, Request, HttpOpts, [{body_format, binary}], Profile) of
        {ok, {{_Version, Status, _Reason}, RespHeaders, RespBody}} ->
            {ok, #{status => Status, headers => headers_map(RespHeaders), body => RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

%% `inets`/`ssl` are listed in the app's `applications`, so a release or a Mix
%% project has them running; this covers a bare `erl -pa` / escript caller and
%% is a no-op otherwise.
ensure_started() ->
    case application:ensure_all_started([inets, ssl]) of
        {ok, _} -> ok;
        {error, _} = E -> erlang:error(E)
    end.

uri_scheme(Url) ->
    case uri_string:parse(Url) of
        %% `Url` is a binary, so every parsed component is one too.
        #{scheme := S} when is_binary(S) -> string:lowercase(S);
        _ -> <<>>
    end.

%% A configuration problem rather than an unreachable provider, so a typed
%% invalid_request that says what to do. The URL is never echoed: a self-hosted
%% base URL may carry userinfo credentials.
scheme_refused(<<"http">>) ->
    thinwrap_location_error:invalid_request(
        <<
            "The default transport is HTTPS-only and refuses http:// URLs. To reach a "
            "cleartext http endpoint (e.g. a self-hosted OSRM on a private network), "
            "pass your own transport in the config's transport key."
        >>
    );
scheme_refused(Scheme) ->
    Shown =
        case Scheme of
            <<>> -> <<"(none)">>;
            _ -> Scheme
        end,
    thinwrap_location_error:invalid_request(
        <<"The default transport only sends https:// URLs (got scheme: ", Shown/binary,
            "). Pass your own transport in the config's transport key for anything else.">>
    ).

with_user_agent(Headers) ->
    case lists:any(fun(K) -> string:lowercase(K) =:= <<"user-agent">> end, maps:keys(Headers)) of
        true -> Headers;
        false -> Headers#{<<"User-Agent">> => <<?USER_AGENT>>}
    end.

%% httpc takes the content type as a separate request element and adds the
%% header itself; leaving it in the header list too would send it twice.
split_content_type(Headers) ->
    maps:fold(
        fun(K, V, {CT, Acc}) ->
            case string:lowercase(K) of
                <<"content-type">> -> {to_list(V), Acc};
                _ -> {CT, [{K, V} | Acc]}
            end
        end,
        {"application/octet-stream", []},
        Headers
    ).

body_or_empty(undefined) -> <<>>;
body_or_empty(B) -> B.

%% httpc already lower-cases response header names; a repeated header arrives
%% as separate entries and is joined the way RFC 9110 allows.
headers_map(List) ->
    lists:foldl(
        fun({K, V}, Acc) ->
            Key = string:lowercase(thinwrap_location_util:chars_to_bin(K)),
            Val = thinwrap_location_util:chars_to_bin(V),
            case Acc of
                #{Key := Prev} -> Acc#{Key := <<Prev/binary, ", ", Val/binary>>};
                _ -> Acc#{Key => Val}
            end
        end,
        #{},
        List
    ).

to_list(B) when is_binary(B) -> unicode:characters_to_list(B);
to_list(L) when is_list(L) -> L.
