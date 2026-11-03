# HERE Connectors (Erlang)

HERE Location Services connectors for routing, distance matrix, geocoding, and isochrone via direct HTTP calls (OTP only — no vendor SDK).

## Quick start

See the [package README](../../README.md) for installation. The config's **`provider` key selects the connector** — pass a HERE config to any operation it supports:

```erlang
Config = #{provider => here, api_key => list_to_binary(os:getenv("HERE_KEY"))},

{ok, Route}   = thinwrap_location:route(Config, #{waypoints => [Origin, Destination]}),
{ok, Matrix}  = thinwrap_location:matrix(Config, #{origins => Os, destinations => Ds}),
{ok, Geo}     = thinwrap_location:geocode(Config, #{address => <<"Invalidenstr. 116, Berlin">>}),
{ok, Contour} = thinwrap_location:isochrone(Config, #{center => Center, type => time, values => [600]}).
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `api_key` | `binary()` or `fun(() -> binary())` | yes | HERE API key (REST) — a single key works across Router v8, Matrix v8, Geocode/Revgeocode/Autosuggest/Lookup, Isolines v8. The fun form keeps the key out of crash reports that print the config. |
| `sleep` | `fun((Milliseconds) -> term())` | no | The wait between async-matrix polls; default `fun timer:sleep/1`. A test seam. |

Inject a custom transport with `transport => {Module, Opts}` (see the package README); the default `httpc` transport never follows redirects.

## Auth setup

Provision a project at https://platform.here.com/ and create a REST API key. Sent as `apiKey=` query param on every request. Static — no refresh.

## Vendor docs

- Routing v8: https://docs.here.com/routing/docs/routing-v8-intro
- Matrix Routing v8: https://docs.here.com/routing/reference/postmatrix
- Geocoding & Search: https://docs.here.com/geocoding-and-search/reference/
- Isoline Routing v8: https://docs.here.com/routing/docs/isoline-v8-intro
- Pricing & rate limits: https://www.here.com/pricing

---

## Routing

### Endpoints

- Standard routing: `GET https://router.hereapi.com/v8/routes`
- Waypoint sequence: `GET https://wps.hereapi.com/v8/findsequence2`

### Input

`optimize => true` (or `optimize_fixed_origin` / `optimize_fixed_destination`) with three or
more waypoints triggers the two-step `findsequence2` → `routes` flow. Travel mode maps to HERE
`transportMode`. Intermediate waypoints are added as `via=lat,lng` query parameters.
`is_round_trip => true` returns `{error, #{code := unsupported_option}}`: `findsequence2`
optimizes an open route with fixed first and last waypoints.

The avoid flags reach **both** legs, so the stops are ordered under the same constraints the
route honours. `findsequence2` takes them as road features in one comma-delimited segment of its
`mode` string, `-3` meaning "strictly avoid": `avoid_tolls` ⇒ `tollroad:-3`, `avoid_highways` ⇒
`motorway:-3`, `avoid_ferries` ⇒ `boatFerry:-3,railFerry:-3` — e.g.
`mode=fastest;car;traffic:disabled;tollroad:-3,motorway:-3`. A `departure_time` goes to
`findsequence2` as `departure` at **seconds** precision (the legacy endpoint answers 400 "Bad
Format for Date and Time" to a fractional value), and to `/v8/routes` as `departureTime` with
milliseconds.

`legs` has one entry per consecutive waypoint pair. HERE `sections` are not legs: a section
also ends at an implicit mode change, so a ferry or car shuttle inside a driving route becomes
its own transit section. The connector closes a leg after each section whose
`arrival.place.waypoint` is set (a `via` from the request) and after the final section,
summing the grouped sections' distance and duration.

`transport_mode` (an atom or a binary, forwarded verbatim) overrides the base `travel_mode`
mapping with HERE's own vehicle classes. The **same** value goes to every endpoint, and the
endpoints accept different sets:

| Value | `/v8/routes` | Matrix v8 | `findsequence2` (`optimize => true`) |
|---|---|---|---|
| `car`, `truck`, `pedestrian`, `bicycle`, `scooter`, `taxi` | yes | yes | yes |
| `bus` | yes | yes | yes |
| `privateBus` | yes | yes | **no — HTTP 400** |

`bus` and `privateBus` are **not synonyms**. `bus` may drive through bus-restricted and
bus-exclusive streets; `privateBus` uses those streets only where a waypoint sits on one, which
is the private pick-up / drop-off case. HERE lists `bicycle`, `bus` and `privateBus` as Beta.

Because optimization runs through the legacy `findsequence2` endpoint, whose `mode` grammar
accepts only `car`, `truck`, `pedestrian`, `bus`, `bicycle`, `scooter` and `taxi`, combining
`privateBus` with `optimize => true` fails with `invalid_request` and the provider message
`Unknown transport mode 'privateBus'`. The connector forwards the value verbatim rather than
substituting `bus` for you — pick `bus` yourself when you need optimization. The value is not
validated locally either: HERE judges it, so a typo comes back as HERE's own 400.

HERE's routing enum has one further value, `networkRestrictedTruck`, deliberately not
documented here: `findsequence2` and Matrix v8 both reject it, and `/v8/routes` returns 400
`Missing 'networkRestrictedTruck[permittedNetworks]' parameter` unless that companion parameter
is supplied, which the connector does not model. Reach it through `passthrough => #{query => ...}`
together with `networkRestrictedTruck[permittedNetworks]` if you need it.

Taxi-specific tuning is likewise passthrough query; HERE's bracketed keys pass through
verbatim:

```erlang
thinwrap_location:route(Config, #{
    waypoints => [Origin, Destination],
    transport_mode => taxi,
    %% Default is true. When true, HERE also ignores traffic on roads with taxi
    %% lanes, on the assumption a taxi can bypass the congestion.
    passthrough => #{query => #{<<"taxi[allowDriveThroughTaxiRoads]">> => <<"false">>}}
}).
```

> The passthrough query is merged into **both** legs of the optimized flow. `findsequence2`
> ignores query parameters it does not recognize (verified live), so a `/v8/routes`-only key
> such as `taxi[...]` rides along harmlessly rather than failing the sequence call.

If `findsequence2` returns an ordering that is not a complete permutation of the input indices,
the call fails with `unknown` (`cause => #{<<"sequence">> => ...}`) rather than reordering the
waypoints wrongly: the sequence also drives the follow-up `/v8/routes` request. An unroutable
request is HTTP 200 with `routes: []` and a critical `notices[]` entry; it comes back as
`no_route` with the notice (e.g. `couldNotMatchOrigin`) in `provider_message`.

### Traffic and billing

Traffic is **off unless you pass `traffic_mode => traffic`** (or the deprecated alias `live`). HERE's own default is the
opposite: a request without `departureTime` is computed for the current time, against live
traffic. That also decides the price — HERE bills `/v8/routes` as **Time-Aware Routing**
(fewer free requests and a higher per-1k rate, see [HERE pricing](https://www.here.com/get-started/pricing))
rather than basic **Routing** unless the request carries `departureTime=any` or `traffic[mode]=disabled`.

| `traffic_mode` | `departure_time` | Sent on `/v8/routes` |
|---|---|---|
| `none` (default) | not set | `departureTime=any` |
| `none` (default) | set | `departureTime=<ISO>&traffic[mode]=disabled` |
| `traffic` | not set | nothing — HERE applies live traffic |
| `traffic` | set | `departureTime=<ISO>` |

`departureTime=any` ignores dynamic traffic but still applies long-term closures.
`traffic[mode]=disabled` is the only way to keep your departure time without traffic, and it
ignores **all** traffic data, long-term closures included — so a `departure_time` with
`none` can route through a road HERE knows is closed. Pass `traffic` if closures matter more to
you than the Time-Aware rate. An `arrivalTime`, or a `departureTime` other than `any`, supplied
through passthrough (`query` on routing, `body` on matrix) counts as a set time and switches the `none` default to
`traffic[mode]=disabled`, since HERE rejects `departureTime=any` combined with `arrivalTime`.

The same rule covers the `/v8/routes` call in the optimized flow; `findsequence2` carries
traffic in its own `mode` string (`traffic:disabled` unless `traffic`). Both keys are set before
the passthrough merge, so a passthrough query can still override them, e.g.
`passthrough => #{query => #{<<"traffic[mode]">> => <<"default">>}}`.

### Error mapping

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401 | (any) | `auth_failed` |
| 403 | (any) | `auth_failed` |
| 400 | (any) | `invalid_request` |
| 429 | (respects `Retry-After`) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| 200 | `findsequence2` `{"results": null, "errors": [...]}` | `unknown`, the `errors` text in `provider_message` |

### Retry-After

On HTTP 429, the error's `cause` carries the raw header as `<<"retryAfter">>`; the parsed seconds are appended to `provider_message`.

### Turn-by-turn instructions

Off by default and **not normalized** — the route result has no `steps` key. Request
`actions,instructions` and read them from `raw`:

```erlang
Return = lists:join(<<",">>, thinwrap_location_defaults:here_routing_return()
                             ++ [<<"actions">>, <<"instructions">>]),
{ok, #{raw := Raw}} = thinwrap_location:route(Config, #{
    waypoints => [Origin, Destination],
    passthrough => #{query => #{<<"return">> => iolist_to_binary(Return)}}
}).
```

Actions land at `routes[].sections[].actions[]`: `action` (the maneuver), `instruction` (localized
text), `offset` (an index into that section's polyline), plus `duration` and `length`.
HERE rejects `instructions` unless `actions` is requested alongside it. The `return` you pass
replaces the connector's own — see [Replacing a default list](#replacing-a-default-list).

For a full navigation payload HERE offers `turnByTurnActions`, which requires `polyline` in the
same `return` list.

---

## Matrix

### Endpoint

`POST https://matrix.router.hereapi.com/v8/matrix?async=true` → poll status → retrieve.

### Flow

Matrix v8 is always asynchronous, and the whole cycle runs inside the one `matrix/2` call (the
library holds no state between calls):

1. **Submit** — the response carries `matrixId` and `statusUrl`.
2. **Poll** `statusUrl` with backoff: 1 s, ×1.5 each time, capped at 5 s, until the deadline.
   Completion is HTTP 303 (`Location` + a `resultUrl` body), or a 200 whose `status` is
   `completed`; `failed` is `provider_unavailable`. Past the deadline the call returns
   `matrix_polling_timeout` with `cause => #{<<"matrixId">> => ..., <<"statusUrl">> => ...}`.
3. **Retrieve** `resultUrl` with `Accept-Encoding: gzip` (HERE answers 406 without it). HERE
   usually 303-redirects to a pre-signed storage URL; the connector follows that single hop
   itself, https only, **without** the API key. The gzip body is decompressed with `zlib`.

The provider-returned `statusUrl` and `resultUrl` must be `https` on `hereapi.com` or a
subdomain of it before the API key is attached; anything else is `invalid_request` and the key
is never sent.

### Input

`transport_mode` overrides the base `travel_mode` mapping. Matrix v8 accepts the same eight
values as Routing v8 — `car`, `truck`, `pedestrian`, `bicycle`, `scooter`, `taxi`, `bus`,
`privateBus` — with no `findsequence2` caveat, since matrix is a single call. `car` is HERE's
default and is not sent.

The poll deadline defaults to 60 s; override it with
`passthrough => #{body => #{timeoutMs => N}}`, a number of milliseconds greater than 0 —
anything else (a numeric binary, zero, a negative) returns `invalid_request` before any request
is sent. `timeoutMs` is a control value and never goes on the wire.

`traffic_mode` follows the [routing rule](#traffic-and-billing) in body form: `none` sends
`"departureTime": "any"`, or your ISO time plus `"traffic": {"mode": "disabled"}` (with the
same closure caveat); `traffic` sends neither. Matrix v8 is one SKU with no traffic surcharge,
but its durations include live traffic by default, so this keeps them consistent with
`none`. Override via the passthrough body (e.g. `#{traffic => #{mode => <<"default">>}}`).

### Output

`travelTimes` fills `duration_seconds` and `distances` fills `distance_meters`, as-is (seconds
and meters). A cell HERE flags in `errorCodes` (anything but 0, or 3 "usable despite a violated
constraint") and a cell whose value is not a number are omitted from `cells` rather than read as
0. Arrays too short for the requested grid are `unknown`.

---

## Geocoding

### Endpoints

- Forward: `GET https://geocode.search.hereapi.com/v1/geocode`
- Reverse: `GET https://revgeocode.search.hereapi.com/v1/revgeocode`
- Autocomplete: `GET https://autosuggest.search.hereapi.com/v1/autosuggest`
- Place details: `GET https://lookup.search.hereapi.com/v1/lookup?id=`

### `formatted_address` is `address.label`

Geocode, reverse geocode and place details take `formatted_address` from `address.label`,
the full address. HERE's `title` is the result's display name — for a POI just its name
(`"Empire State Building"` vs. `"Empire State Building, 20 W 34th St, New York, NY 10118,
United States"`) — so it is used only when an item has no label, and on place details it is
what `name` returns (with `include => [name]`).

Place details answers an id Lookup does not know (HTTP 404) or an item without a `position`
with a result that has no `candidate` key, not an error. An item without a `position` is
skipped in geocode results, and a partial `mapView` is dropped whole rather than 0-filled.

### Autosuggest requires a search context

HERE documents exactly one of `at`, `in=circle` or `in=bbox` as **mandatory** on
Autosuggest, and rejects a request carrying none of them. Pass `location` (optionally with
`radius`) and the connector supplies it:

```erlang
{ok, Res} = thinwrap_location:autocomplete(Config, #{
    input => <<"Dizen">>, location => #{lat => 32.08, lng => 34.78}
}).
```

`location` alone becomes `at=`; `location` + `radius` becomes `in=circle:…;r=…`. If you
need a bounding box instead, supply it yourself via `passthrough => #{query => #{in => ...}}` —
the connector accepts that as the context. Calling `autocomplete/2` with no context at all
returns `invalid_request` locally rather than relaying a vendor 400.

### Country filter

`country_filter` is ISO 3166-1 alpha-2 throughout this library; HERE expects **alpha-3**,
so the connector translates it (case-insensitively; blank entries are skipped). A code with no
ISO alpha-3 mapping returns `invalid_request` and points you at the passthrough query `in` for
anything non-standard that HERE nonetheless accepts.

```erlang
{ok, Res} = thinwrap_location:autocomplete(Config, #{
    input => <<"Dizen">>,
    location => #{lat => 32.08, lng => 34.78},
    country_filter => [<<"IL">>, <<"PS">>]
}).
%% → ...&at=32.08,34.78&in=countryCode:ISR,PSE
```

> **HERE spells both the country filter and the spatial filter `in`.** Its docs require
> the country filter to *accompany* one of `at` / `in=circle` / `in=bbox`, so when you
> combine `country_filter` with `radius` the connector emits `in` **twice** — once for the
> circle and once for the country codes — rather than letting one overwrite the other.
> Nothing is silently dropped, and `radius` still applies.

### Match-highlighting offsets

**Not normalized** — a prediction has no `matches` key. Only 2 of the 5 geocoders return
offsets at all (HERE and Google), and they disagree on both the encoding and which string the
offsets index, so this stays vendor-native in `raw`:

```erlang
{ok, #{raw := #{<<"items">> := [First | _]}}} = thinwrap_location:autocomplete(Config, #{
    input => <<"Dizen">>, location => #{lat => 32.08, lng => 34.78}
}),
Highlights = maps:get(<<"highlights">>, First, #{}).
%% → #{<<"title">> => [#{<<"start">> => _, <<"end">> => _}],
%%     <<"address">> => #{<<"label">> => [...], <<"city">> => [...]}}
```

Note the shape difference from Google, which is why neither can be normalized into one
key: HERE anchors offsets to `title` and to individual **address components**
(`label`, `city`, `street`, `houseNumber`), and names the bounds `start`/`end`. Google
anchors to its own `mainText`/`secondaryText` and names them `startOffset`/`endOffset`.

---

## Isochrone

### Endpoint

`GET https://isoline.router.hereapi.com/v8/isolines`

### Input

The standard isochrone input. `type` (`time` / `distance`) maps to HERE
`range[type]=time|distance`; `values` become the comma-joined `range[values]`. `walking` maps to
`pedestrian`; `cycling` returns `unsupported_travel_mode` before any request is sent.

`departure_time` ⇒ `departureTime=`. An ISO-8601 date-time binary is sent verbatim (its offset,
or its absence, preserved); Unix seconds and a `calendar:datetime()` are sent as UTC at seconds
precision. A binary that is not an ISO-8601 date-time returns `invalid_request` before any
request is sent. Isochrones have no `traffic_mode`, so a `departure_time` makes the contour
traffic-aware for that time, as HERE documents that a concrete departure time "take[s] traffic
flow and other time-dependent effects into account". HERE's isoline docs do not say what an
omitted time means (on Routing v8 it is the request time, with live traffic). Pass
`passthrough => #{query => #{<<"departureTime">> => <<"any">>}}` for an isoline without traffic
flow.

### Output

HERE types an isoline's `polygons` as a MultiPolygon: disconnected parts (e.g. linked only by a
ferry `connection`) come back as separate entries, each with an `outer` ring and optional `inner`
holes. One entry gives a `Polygon`, several give a `MultiPolygon`; holes are kept, and rings are
closed and wound per RFC 7946 (exterior counter-clockwise, holes clockwise). Contours are sorted
by `value`.

---

## Replacing a default list

Passthrough **replaces** a list-valued parameter the connector sets; it does not merge with it.
That is deliberate — a merge would leave you no way to remove a value. To add one, start from
the published default, the same list the connector builds its request from:

| Operation | Parameter | Function |
|---|---|---|
| Routing | `return` query (comma-joined) | `thinwrap_location_defaults:here_routing_return()` = `[<<"polyline">>, <<"summary">>]` |
| Matrix | `matrixAttributes` body (JSON array) | `thinwrap_location_defaults:here_matrix_attributes()` = `[<<"travelTimes">>, <<"distances">>]` |

```erlang
Return = lists:join(<<",">>, thinwrap_location_defaults:here_routing_return()
                             ++ [<<"turnByTurnActions">>]),
thinwrap_location:route(Config, #{
    waypoints => [Origin, Destination],
    passthrough => #{query => #{<<"return">> => iolist_to_binary(Return)}}
}).
```

`matrixAttributes` goes through the passthrough body; the body is deep-merged, but a list is a
leaf, so your list replaces the connector's (`passthrough => #{body => #{matrixAttributes => [...]}}`).

> **Omitting a value the normalizer reads.**
>
> - Routing, silently: drop `summary` and every leg's distance and duration and the totals come
>   back `0.0`, with `duration_without_traffic_seconds` omitted; drop `polyline` and `polyline`
>   comes back `<<>>`. Nothing fails.
> - Matrix, loudly: `travelTimes` fills `duration_seconds` and `distances` fills
>   `distance_meters`. Drop either and the call returns `unknown`, because the result no longer
>   has the requested dimensions.
