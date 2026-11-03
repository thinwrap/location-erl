# thinwrap_location (Erlang)

Unified, **SDK-free**, **zero-dependency** Erlang wrapper for routing, distance
matrix, geocoding, and isochrone across **Google, Mapbox, HERE, ESRI, TomTom, and
OSRM**. Switch vendor by changing the config's `provider`; the input and output
shapes stay identical. Synchronous, stateless, OTP-only — bring your own HTTP
client if you want `hackney`, `gun` or `Finch`. Works the same from Elixir and
Gleam.

```erlang
%% rebar.config
{deps, [thinwrap_location]}.
```

```elixir
# mix.exs
{:thinwrap_location, "~> 1.3"}
```

Requires Erlang/OTP ≥ 27. No runtime dependencies (OTP `inets`, `ssl`, `json`).

## Two-minute route

```erlang
Config = #{provider => google, api_key => <<"...">>},
case thinwrap_location:route(Config, #{
    waypoints => [#{lat => 40.7128, lng => -74.0060},   % New York
                  #{lat => 41.4173, lng => -73.0001}]   % Bridgeport
}) of
    {ok, #{total_distance_meters := M, total_duration_seconds := S}} ->
        io:format("~.1f km, ~B min~n", [M / 1000, round(S / 60)]);
    {error, #{code := Code, message := Msg}} ->
        io:format("~s: ~s~n", [Code, Msg])
end.
```

```elixir
config = %{provider: :google, api_key: System.fetch_env!("GOOGLE_API_KEY")}

{:ok, %{total_distance_meters: m}} =
  :thinwrap_location.route(config, %{
    waypoints: [%{lat: 40.7128, lng: -74.0060}, %{lat: 41.4173, lng: -73.0001}]
  })
```

## Operations & providers

The config's **`provider` selects the connector**. Asking a provider for an
operation it does not support raises `{badarg, _}` (e.g. `geocode/2` with
`osrm`); see [Error handling](#error-handling). `thinwrap_location:supports/2`
answers the question at runtime.

| Function | Providers |
|---|---|
| `route/2` | Google, Mapbox, HERE, ESRI, OSRM, TomTom |
| `matrix/2` (flat cells) | Google, Mapbox, HERE, ESRI, OSRM, TomTom |
| `geocode/2`, `reverse_geocode/2`, `autocomplete/2`, `place_details/2` | 5 (no OSRM) |
| `isochrone/2` | Mapbox, HERE, ESRI, TomTom |

Configs:

| `provider` | Keys |
|---|---|
| `google`, `here`, `tomtom` | `api_key` |
| `mapbox` | `access_token` |
| `esri` | exactly one of `api_key` or `arcgis_token` |
| `osrm` | `base_url` (required), optional `supported_exclude_classes` |

Any credential may be a binary or a zero-arity fun returning one
(`api_key => fun() -> os:getenv(...) end`), which keeps the secret out of crash
reports that print the config. Every config also accepts `transport` (see
[below](#bring-your-own-http-client)).

Per-provider details (endpoints, auth, error mapping, passthrough) live in
[`docs/providers/`](https://github.com/thinwrap/location-erl/tree/main/docs/providers) — one page per provider.

## Routing options that cost money

Three inputs exist because the cheap thing and the correct thing are not always
the same request. All three default to the lean option; you opt up explicitly.

| Option | Default | What it changes |
|---|---|---|
| `polyline_quality` | `simplified` | Geometry fidelity. `detailed` returned a **30x larger** polyline on Mapbox and **31x** on OSRM in measurement, with identical distances and durations. Honoured by Google/Mapbox/OSRM; silently ignored by HERE/TomTom/Esri. |
| `traffic_mode` | `none` | Whether to route against traffic (see [Traffic](#traffic-none-vs-traffic)). `traffic` selects a **Pro-tier SKU** on Google and HERE's **Time-Aware Routing** rate, so it is never enabled implicitly — not even by passing `departure_time`. `live` is a deprecated alias of `traffic`. |
| `include` | `[]` | Which optional output fields to fetch. Each token maps 1:1 onto one optional result field. |

```erlang
{ok, Result} = thinwrap_location:route(Config, #{
    waypoints => Waypoints,
    traffic_mode => traffic,                 % traffic-aware routing
    polyline_quality => detailed,            % full geometry
    include => [durationWithoutTraffic]      % the extra output field
}),
%% Present only when requested AND returned natively — never synthesized, so
%% an absent key tells you this provider did not supply it.
case Result of
    #{total_duration_without_traffic_seconds := Free, total_duration_seconds := T} ->
        {congestion_seconds, T - Free};
    _ ->
        unknown
end.
```

`durationWithoutTraffic` is native on Google (`staticDuration`), HERE
(`baseDuration`) and TomTom (`noTrafficTravelTimeInSeconds`); Mapbox, OSRM and
Esri do not return it, so the key stays absent there rather than being faked.

### Traffic: `none` vs `traffic`

`traffic_mode` applies to routing and matrix. `none` (the default) uses the
provider's time-independent speeds, and a `departure_time` never adds traffic.
`traffic` uses the traffic expected at `departure_time`: live close to now,
typical later, and now when no time is given. `live` is a deprecated alias of
`traffic` and behaves identically.

| Provider | `none` | `traffic` |
|---|---|---|
| Google | `TRAFFIC_UNAWARE`; the time is not sent (Google rejects it there) | `TRAFFIC_AWARE` + time (**Pro SKU**) |
| HERE | `departureTime=any`, or the time + `traffic[mode]=disabled` | HERE's default, with the time if given (**Time-Aware SKU** on routing) |
| Esri | the time is not sent | the time, or `now` |
| Mapbox Directions | `driving`, the time is not sent | `driving-traffic` + time |
| Mapbox Matrix | `driving`, the time is not sent | `driving-traffic`; driving with a time → `unsupported_field` (`depart_at` is a beta) |
| TomTom routing | `traffic=false` + time. **Approximate:** TomTom still applies typical traffic | `traffic=true` + time |
| TomTom matrix | `historical` + `departAt: "any"` (the time is not sent) | `live` + the time, or `"now"` |
| OSRM, Mapbox Optimization, walking/cycling | no traffic | **ignored** (no traffic available). Mapbox Optimization driving + time → `unsupported_field` |

`departure_time` is Unix seconds, a UTC `calendar:datetime()`, or an RFC 3339
binary (`<<"2026-11-02T08:00:00Z">>`).

### Making OSRM's avoid-flags work

Whether OSRM accepts `exclude=toll` is a property of **your server**, not of
OSRM: the public demo build rejects it with `InvalidValue`, while a self-hosted
instance verified live honoured it and genuinely rerouted. Stock OSRM compiles no
exclude classes, so the flags are rejected up front by default. If your profile
was built with them, declare it:

```erlang
Osrm = #{provider => osrm,
         base_url => <<"https://routing.internal">>,
         supported_exclude_classes => [<<"toll">>, <<"ferry">>]}.
```

## Autocomplete → place details

`autocomplete/2` returns predictions; `place_details/2` resolves one into a full
candidate. "Place details" and "geocode by place id" are the same vendor call on
all five providers, so this is one operation, and it returns an ordinary
geocode candidate.

```erlang
{ok, #{predictions := [First | _] = Preds}} =
    thinwrap_location:autocomplete(Config, #{input => <<"blue bottle">>}),
%% Render the usual two-line suggestion without splitting `description` on a comma.
[case P of
     #{structured_format := #{main_text := Main} = Sf} ->
         {Main, maps:get(secondary_text, Sf, <<>>)};
     #{description := D} ->
         {D, <<>>}
 end || P <- Preds],
{ok, Details} = thinwrap_location:place_details(Config, #{place_id => maps:get(place_id, First)}).
```

`place_id` values are **provider-scoped** — a Google place id is meaningless to
Mapbox.

`Details` has no `candidate` key when the provider does not know the id (HERE and
Mapbox answer 404, TomTom and Esri an empty result, Google a 404 `NOT_FOUND`) or
returns the place without a location — ids expire and places close, so match on
it. `raw` still carries the vendor body. An id the vendor rejects as invalid is
still an `invalid_request` error — and Google answers most unknown ids that way
(400 `INVALID_ARGUMENT`), as does Esri for a stale `magicKey`.

### Two things that cost money here

**Google's Place Details SKU is driven by the field mask**, so `name`
(`displayName`) is a Pro-tier field and only requested behind an opt-in:
`include => [name]`. This is the *opposite* of Compute Routes, whose SKU is
driven by request *features*.

**Mapbox Search Box bills per session, not per request.** A `suggest` and the
`retrieve` that follows count as one billable session only when they carry the
same `session_token`. The wrapper holds no state, so it cannot remember the token
for you; when you omit it, the connector generates a fresh UUIDv4 for that one
call, which is valid but billed as its own session.

### `structured_format` support

| Provider | `main_text` / `secondary_text` |
|---|---|
| Google | `structuredFormat.mainText` / `.secondaryText` — default-on, free |
| Mapbox | `name` / `place_formatted` |
| HERE | `title` / `address.label` — no `secondary_text` for *query*-type suggestions |
| TomTom | `poi.name` / `address.freeformAddress` — **absent for street results** |
| Esri | not supported — a single flat `text` |

It is **never synthesized**: no `structured_format` key means the provider gave no
distinct main part, and `description` remains the thing to render.

## Normalized surface

Distances are **meters**, durations **seconds** (both floats), coordinates
`#{lat, lng}` (latitude first), and route geometry a **Google precision-5
polyline** binary. Optional output fields are **omitted** from the result map
when the provider gave nothing — read them with `maps:get/3` or pattern match.
Every result carries `raw`, the decoded vendor body (objects as binary-keyed
maps, JSON `null` as the atom `null`). Isochrone contour geometry is a GeoJSON
`Polygon` (`[Exterior | Holes]`, rings closed, exterior counter-clockwise and
holes clockwise per RFC 7946), or a `MultiPolygon` when a contour comes in several
disconnected parts — check `type` before reading `coordinates`.

## Bring your own HTTP client

The default transport is OTP `httpc` (`thinwrap_location_httpc`): **HTTPS-only**,
30-second timeout, never follows redirects, and verifies certificates and host
names with OTP's defaults. An `http://` URL — e.g. a self-hosted OSRM at
`http://localhost:5000` — is refused with `invalid_request` before any network
I/O. Options: `transport => {thinwrap_location_httpc, #{timeout => 10000,
profile => my_profile}}`.

To use another client, implement the one-callback `thinwrap_location_transport`
behaviour:

```erlang
-module(my_hackney_transport).
-behaviour(thinwrap_location_transport).
-export([request/2]).

request(#{method := Method, url := Url, headers := Headers} = Req, _Opts) ->
    Body = maps:get(body, Req, <<>>),
    case hackney:request(Method, Url, maps:to_list(Headers), Body, [with_body]) of
        {ok, Status, RespHeaders, RespBody} ->
            {ok, #{status => Status,
                   headers => maps:from_list([{string:lowercase(K), V} || {K, V} <- RespHeaders]),
                   body => RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.
```

**Contract:** a non-2xx must be **returned** as a response, never as an error —
the connector's own status mapping (429 → `rate_limited`, 401 → `auth_failed`, …)
reads it. Return `{error, timeout}` on a timeout so callers get the `timeout`
code. Never follow redirects.

The wrapper holds no state — no caching, retries, idempotency keys, telemetry,
processes or ETS tables. (The HERE/TomTom async-matrix submit/poll/retrieve
cycle is transient, within a single `matrix/2` call, in your process.)

## Passthrough

Forward vendor-specific fields the normalized input doesn't expose with
`passthrough => #{body => ..., headers => ..., query => ...}`. `body` is
deep-merged into the request body; `headers`/`query` are shallow-merged. Your
values win, including over connector-set ones. Header names match
case-insensitively: your `x-goog-fieldmask` replaces the connector's
`X-Goog-FieldMask` and is sent in your spelling.

```erlang
thinwrap_location:route(Config, #{waypoints => Wps,
                                  passthrough => #{query => #{alternatives => <<"true">>}}}).
```

A list-valued vendor parameter the connector already sets — Google's
`X-Goog-FieldMask`, HERE routing's `return`, a matrix `annotations` list, Esri's
`accumulateAttributeNames` — is **replaced** by your value, not merged, so you
can also remove a default. To append instead, start from the default the
connector itself sends, published in `thinwrap_location_defaults`:

```erlang
Mask = lists:join(<<",">>, thinwrap_location_defaults:google_routes_field_mask()
                           ++ [<<"routes.travelAdvisory">>]),
thinwrap_location:route(Config, #{waypoints => Wps, passthrough =>
    #{headers => #{<<"X-Goog-FieldMask">> => iolist_to_binary(Mask)}}}).
```

## Polyline utilities

Four locked, cross-language-parity helpers in `thinwrap_location_polyline`:
`encode/1`, `decode/1`, `decode_flex/1` (HERE) and `encode_esri_paths/1`.

## Error handling

Every **operation** failure is `{error, Error}`, a plain map:

```erlang
#{code := atom(),               % the classification to branch on
  message := binary(),
  status => integer(),          % the HTTP status, when the provider answered
  provider_message => binary(),
  cause => term()}              % redacted vendor body or transport message
```

That covers a vendor error, a transport failure, a timeout, request data rejected
before sending (too few waypoints, an empty matrix, a malformed country code, an
unparseable date, …) and a capability the provider lacks (`unsupported_*`).
Pre-flight rejections have no `status`.

Misusing the API is a bug in your code, so it raises `error({badarg,
Description})` before any request and is deliberately **not** an `{error, _}`:
an unknown or missing config/input key, a value of the wrong type, an atom
outside its set (`travel_mode => flying`), a provider without the operation, a
`transport` module that does not export `request/2`. The description never
includes config values.

HERE's `transport_mode` is forwarded verbatim, so HERE judges it and a bad value
is an `{error, _}`.

`code` has the 6 canonical values (`invalid_recipient`, `rate_limited`,
`auth_failed`, `provider_unavailable`, `invalid_request`, `unknown`) plus 7
location-extended (`unsupported_field`, `unsupported_option`,
`unsupported_travel_mode`, `profile_not_configured`, `matrix_polling_timeout`,
`no_route`, `timeout`) — the same strings as the TS, PHP, Go and Python siblings.

### `no_route` — "there is no route", normalized

The providers agree on nothing here. Google answers HTTP **200** with `routes`
absent; HERE 200 with `routes: []` plus a `notices[].code`; Mapbox
`code: "NoRoute"` on either 200 or 422; OSRM the same codes on a **400**; TomTom
a 400 with `detailedError.code`; Esri a 200 whose in-body `error.code: 400` names
an **unlocated** stop. In practice it almost always means *a waypoint could not be
matched to the road network*: every provider tested routes Reykjavik→Oslo via
ferry.

### `timeout`

Separated from `provider_unavailable` because it is the one transport failure a
caller acts on differently — back off and retry, versus treat the provider as
down. There is **no** `retry_after_seconds` key: the raw `Retry-After` header
rides in `cause` as `<<"retryAfter">>`, with its parsed seconds woven into
`provider_message`.

## Security

Report vulnerabilities **privately** — please do not open a public issue.
Preferred: a [private security advisory](https://github.com/thinwrap/location-erl/security/advisories/new)
on this repository. Alternatively, email **security@thinwrap.dev**. Include the
affected versions and a minimal reproduction if you have one.

A vulnerability in a *provider's* own API or service belongs to that vendor
rather than to this wrapper — please report those upstream.

MIT © Dmitry Polyanovsky
