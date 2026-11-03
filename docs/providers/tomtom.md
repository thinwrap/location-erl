# TomTom Connectors (Erlang)

TomTom Maps connectors for routing, distance matrix, geocoding, and isochrone (reachable range) via direct HTTP calls (OTP only — no vendor SDK).

## Quick start

See the [package README](../../README.md) for installation. The config's **`provider` key selects the connector** — pass a TomTom config to any operation it supports:

```erlang
Config = #{provider => tomtom, api_key => list_to_binary(os:getenv("TOMTOM_KEY"))},

{ok, Route}   = thinwrap_location:route(Config, #{waypoints => [Origin, Destination]}),
{ok, Matrix}  = thinwrap_location:matrix(Config, #{origins => Os, destinations => Ds}),
{ok, Geo}     = thinwrap_location:geocode(Config, #{address => <<"Museumstraat 1, Amsterdam">>}),
{ok, Contour} = thinwrap_location:isochrone(Config, #{center => Center, type => time, values => [600]}).
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `api_key` | `binary()` or `fun(() -> binary())` | yes | TomTom API key — works across Routing v1, Matrix v2, Search v2, Reachable Range v1. The fun form keeps the key out of crash reports that print the config. |
| `sleep` | `fun((Milliseconds) -> term())` | no | The wait between async-matrix polls (grids over 100 cells); default `fun timer:sleep/1`. A test seam. |

Inject a custom transport with `transport => {Module, Opts}` (see the package README); the default `httpc` transport never follows redirects.

## Auth setup

Create a key at https://developer.tomtom.com/user/me/apps. Sent as `key=` query param on every request. Static — no refresh.

## Vendor docs

- Routing: https://developer.tomtom.com/routing-api/documentation/tomtom-maps/calculate-route
- Matrix Routing: https://developer.tomtom.com/matrix-routing-v2-api/documentation/synchronous-matrix
- Geocoding: https://developer.tomtom.com/geocoding-api/documentation/geocode
- Reachable Range: https://developer.tomtom.com/routing-api/documentation/tomtom-maps/calculate-reachable-range
- Rate limits: https://developer.tomtom.com/

---

## Routing

### Endpoint

`GET https://api.tomtom.com/routing/1/calculateRoute/{locations}/json`

### Input

The standard route input. Any of `optimize`, `optimize_fixed_origin`,
`optimize_fixed_destination` maps to `computeBestOrder=true` (with three or more
waypoints). TomTom always keeps **both** the first and the last waypoint fixed and has no
way to free one end, so a single fixed-endpoint flag also leaves the other end in place.
`is_round_trip => true` returns `{error, #{code := unsupported_option}}`.

`traffic_mode` is always sent, because TomTom's `traffic` defaults to on: `none` ⇒
`traffic=false`, `traffic`/`live` ⇒ `traffic=true`; `departure_time` ⇒ `departAt` either way.
**`none` is approximate here.** TomTom routing has no time-independent mode (`departAt=any`
is rejected with `traffic=false`), and under `traffic=false` "the effect of historic traffic
on effective road speeds is still incorporated" — so durations include typical traffic for
the departure time, or for now.

The avoid flags are sent as a **repeated** `avoid` parameter
(`avoid=tollRoads&avoid=motorways`): calculateRoute rejects a comma-joined list with
`400 Invalid avoid value`.

`include => [durationWithoutTraffic]` adds `computeTravelTimeFor=all`, which asks TomTom for
extra computed values, so it stays strictly opt-in; `noTrafficTravelTimeInSeconds` then fills
`duration_without_traffic_seconds` on the legs and the total. A summary missing
`lengthInMeters` or `travelTimeInSeconds`, or a route point without coordinates, is `unknown`
rather than a zero-length or (0,0) value.

### `waypoint_order`

TomTom reports `optimizedWaypoints[]` over the INTERMEDIATE waypoints only, each entry's
`providedIndex` being 0-based across those intermediates. The connector sorts by
`optimizedIndex`, projects to absolute input indices, and brackets the result with the fixed
origin and destination to produce the canonical `waypoint_order`.

The projection is validated: `waypoint_order` is **omitted entirely** unless it is a complete
permutation of `[0..N-1]`, so it is never a permutation that silently drops or repeats a
waypoint. The rest of the result is returned as normal, and `raw` still carries the
vendor's own `optimizedWaypoints` array.

### Error mapping

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 400 | `detailedError.code` `MAP_MATCHING_FAILURE` or `NO_ROUTE_FOUND` | `no_route` |
| 400 | (other) | `invalid_request` |
| 404 | routing, matrix, place details | `invalid_request` |
| 401 / 403 | (any) | `auth_failed` |
| 429 | (respects `Retry-After`) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |

`MAP_MATCHING_FAILURE` is live-verified; `NO_ROUTE_FOUND` is TomTom's documented sibling code
for the same outcome. The status codes in the last three rows win over a `detailedError`. On
geocode, reverse geocode, autocomplete and isochrone a 404 is `unknown`.

### Retry-After

On HTTP 429, the error's `cause` carries the raw header as `<<"retryAfter">>`; the parsed seconds are appended to `provider_message`.

### Turn-by-turn instructions

Off by default and **not normalized** — the route result has no `steps` key. Set
`instructionsType` and read the result from `raw`:

```erlang
{ok, #{raw := Raw}} = thinwrap_location:route(Config, #{
    waypoints => [Origin, Destination],
    %% <<"text">> | <<"tagged">> | <<"coded">>
    passthrough => #{query => #{<<"instructionsType">> => <<"text">>}}
}).
```

`text` gives plain messages, `tagged` gives the same messages marked up for formatting, and
`coded` omits `message` entirely (maneuver data only). `instructionsType` is its own parameter, so
this merges additively — the connector's `routeRepresentation=polyline` is untouched.

> **TomTom's guidance is route-level, not per-leg.** Instructions land at
> `routes[].guidance.instructions[]` — one flat list for the whole route, not nested under `legs[]`
> the way Google, Mapbox and OSRM nest theirs. To attribute an instruction to a leg you anchor it
> yourself via `routeOffsetInMeters` or `pointIndex` (the index of the instruction's point within
> the route polyline).

Each instruction carries `instructionType` and `maneuver` (two separate vocabularies), `message`,
`street`, `roadNumbers`, `signpostText`, `exitNumber`, `junctionType`,
`turnAngleInDecimalDegrees` and `drivingSide`.

---

## Matrix

### Endpoint

`POST https://api.tomtom.com/routing/matrix/2` for up to **100 cells** (origins × destinations);
larger grids go to `POST https://api.tomtom.com/routing/matrix/2/async` (submit → poll → result,
up to 2500 cells). TomTom's synchronous endpoint allows 100 cells by default — 200 only for a
narrow `departAt=any` historical-traffic request, 2500 only on Enterprise plans.

The async cycle runs inside the one `matrix/2` call: the job is polled at
`/routing/matrix/2/async/{jobId}` with backoff (1 s, ×1.5 each time, capped at 5 s) until its
`state` is `Completed` (`Failed` is `provider_unavailable`), then the result is fetched from
`.../{jobId}/result`. Past the deadline the call returns `matrix_polling_timeout` with
`cause => #{<<"jobId">> => ...}`.

A large async result is answered with HTTP 302 and a temporary download URL in `Location`. The
connector follows that one hop itself (https only, never cached), without the API key, which the
download URL does not need.

### Input

The standard matrix input. Cycling returns `{error, #{code := unsupported_travel_mode}}` before any request is sent: Matrix v2 has no bicycle mode, so the connector rejects it locally rather than spending a round-trip on a certain 400.

`traffic_mode` is sent as `options.traffic`. `none` ⇒ `"historical"` with `departAt: "any"`,
TomTom's time-independent average; a `departure_time` is dropped, since historical traffic at
a real time is typical traffic for that time. `traffic`/`live` ⇒ `"live"` with the
`departure_time` as given, or `departAt: "now"` without one (TomTom rejects `"live"` with
`departAt=any`, HTTP 400). The 200-cell
synchronous allowance is not used (it holds only for historical traffic and no other
options), so the 100-cell sync/async split is the same for both.

The async poll deadline defaults to 60 s; override it with
`passthrough => #{body => #{timeoutMs => N}}`, a number of milliseconds greater than 0.
Anything else — a numeric binary, zero, a negative — returns `invalid_request` before any
request is sent, on the synchronous path too. `timeoutMs` never goes on the wire.

### Output

A cell without both `lengthInMeters` and `travelTimeInSeconds` (an unroutable pair carries
`detailedError` instead) is omitted from `cells`, not reported as 0 m / 0 s. A cell without a
valid integer `originIndex`/`destinationIndex` makes the whole call `unknown`: it cannot be
placed in the grid.

---

## Geocoding

### Endpoints

- Forward: `GET https://api.tomtom.com/search/2/geocode/{query}.json`
- Reverse: `GET https://api.tomtom.com/search/2/reverseGeocode/{lat},{lng}.json`
- Autocomplete (Fuzzy Search): `GET https://api.tomtom.com/search/2/search/{query}.json`
- Place details: `GET https://api.tomtom.com/search/2/place.json?entityId=`

The query is percent-encoded into the path; an empty `address` or `input` returns
`invalid_request` before any request is sent.

### Why Fuzzy Search, and not TomTom's Autocomplete endpoint

TomTom ships a service literally named Autocomplete
(`/search/2/autocomplete/{query}.json`), and this connector deliberately does **not** use
it. That service is a query *preprocessor*: it recognizes entities inside the input and
returns `segments[]` describing them (`brand`, `category`, `plaintext`) so you can feed
them back into another search call. Its results carry no place id, no coordinates and no
formatted address, so it cannot populate a prediction's `description` or `place_id`, and the
`place_id` handoff into `place_details/2` would have nothing to pass.

Fuzzy Search with `typeahead=true` is the endpoint that returns actual place suggestions,
which is what this operation means.

`structured_format` is emitted only for POI results (`main_text` = `poi.name`,
`secondary_text` = `address.freeformAddress`). Street and address results have no `poi.name`
(live-verified), so the key is omitted there rather than guessed by splitting the address.

### No match-highlighting offsets

Fuzzy Search returns no match offsets — no `matches`, `highlights` or equivalent. Of the
five geocoders only Google and HERE return them, so a UI that bolds the matched substring
has to match client-side.

> TomTom's *Autocomplete* service (the one above, which this connector does not use) does
> return offsets, but they index **the user's input query**
> (`segments[].matches.inputQuery[]` with `offset`/`length`) rather than the result text —
> the opposite of what highlighting a suggestion needs. Switching endpoints would not buy
> you highlighting.

### Country filter

`country_filter` (ISO 3166-1 alpha-2) is translated to `countrySet=<comma-csv>` on
**forward geocode and autocomplete alike**.

```erlang
{ok, Res} = thinwrap_location:autocomplete(Config, #{
    input => <<"Dizen">>, country_filter => [<<"IL">>, <<"PS">>]
}).
%% → ...&countrySet=IL,PS
```

---

## Isochrone

### Endpoint

`GET https://api.tomtom.com/routing/1/calculateReachableRange/{lat},{lng}/json`

### Input

The standard isochrone input. `type => time` ⇒ `timeBudgetInSec=`; `type => distance` ⇒ `distanceBudgetInMeters=`. Multi-value calls fan out via one request per value, and the result then carries `meta => #{request_count => N}`; `raw` is the list of the per-value bodies.

`departure_time` ⇒ `departAt=`. An ISO-8601 date-time binary is sent verbatim (its offset, or
its absence, preserved); Unix seconds and a `calendar:datetime()` are sent as UTC at seconds
precision. A binary that is not an ISO-8601 date-time returns `invalid_request` before any
request is sent. Isochrones have no `traffic_mode`, so a `departure_time` (sent as `departAt`)
makes the contour traffic-aware for that time, using the traffic TomTom expects then. No
`traffic` parameter is sent, so TomTom's defaults apply (`traffic=true`, `departAt=now`):
without a `departure_time` the range reflects the traffic now.
`passthrough => #{query => #{<<"traffic">> => <<"false">>}}` ignores current traffic, but
historic traffic still applies, as on Routing.

Driving only: TomTom states that in `calculateReachableRange` requests "the values bicycle and
pedestrian must not be used", so `walking` and `cycling` return
`{error, #{code := unsupported_travel_mode}}` before any request is sent.

### Output

The reachable range is one boundary, so a contour is always a single-ring `Polygon`, closed and
wound counter-clockwise (RFC 7946). Contours are sorted by `value`.
