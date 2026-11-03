# ESRI ArcGIS Connector (Erlang)

ESRI ArcGIS Location Services connector for routing, distance matrix, geocoding, and isochrone
(service areas) via direct HTTP calls — OTP `httpc` and `json` only, no vendor SDK.

## Quick start

See the [package README](../../README.md) for installation. The config's **`provider` selects
the connector** — pass an `esri` config to any operation it supports:

```erlang
Config = #{provider => esri, api_key => fun() -> list_to_binary(os:getenv("ARCGIS_KEY")) end},

{ok, Route}    = thinwrap_location:route(Config, #{waypoints => [Origin, Destination]}),
{ok, Matrix}   = thinwrap_location:matrix(Config, #{origins => Os, destinations => Ds}),
{ok, Geo}      = thinwrap_location:geocode(Config, #{address => <<"380 New York St, Redlands">>}),
{ok, Isochron} = thinwrap_location:isochrone(Config, #{
    center => Origin, type => time, values => [600]
}).
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `api_key` | `binary()` or `fun(() -> binary())` | one of | ArcGIS API key (long-lived) — mutually exclusive with `arcgis_token` |
| `arcgis_token` | `binary()` or `fun(() -> binary())` | one of | OAuth-issued access token — mutually exclusive with `api_key` |

Provide exactly one of `api_key` or `arcgis_token`. The rule is checked **per call**, not when
the config is validated: supplying both returns `{error, #{code := invalid_request}}`;
supplying neither (or an empty binary) returns `{error, #{code := auth_failed}}`. Neither
sends a request, and neither error carries a `status`. A fun credential is called at the
point of use, so a refreshed token is picked up on the next call.

Inject a custom HTTP client with `transport => {Module, Opts}` (see the package README); the
default `thinwrap_location_httpc` transport never follows redirects.

## Auth setup

Create an API key at https://developers.arcgis.com/api-keys/. Sent as the `token=` form field
(NAServer endpoints) or query parameter (GeocodeServer). Token lifecycle: **refreshable** —
API keys are long-lived, but OAuth-issued tokens require client-side refresh (pass a fun).

The service hosts are fixed (`route-api.arcgis.com`, `geocode-api.arcgis.com`), so ArcGIS
Enterprise deployments cannot be reached through this connector — `passthrough` changes
parameters, not the endpoint.

## Vendor docs

- Route service: https://developers.arcgis.com/rest/routing/route-service-direct/
- **Response fields (the one that is easy to miss):** https://doc.esri.com/en/arcgis-pro/latest/tool-reference/ready-to-use/output-findroutes.html
  — the REST page above documents **parameters only**, and its "Types" link is *input*
  data types. Every output FIELD (`Cumul_*`, `Status`, `DistanceToNetworkInMeters`,
  `DirectionPointType`) is defined here, in the ArcGIS Pro tool reference.
- OD Cost Matrix: https://developers.arcgis.com/rest/routing/travelCostMatrix-service-direct/
- Geocoding service: https://developers.arcgis.com/rest/geocode/
- Service Area: https://developers.arcgis.com/rest/routing/serviceArea-service-direct/

## Form posts and passthrough

The NAServer operations (route, matrix, isochrone) are `application/x-www-form-urlencoded`
POSTs; the GeocodeServer operations are GETs. On both, `passthrough => #{body => ...}` overlays
the connector's **parameters** (form fields on a POST, query parameters on a GET): a key you
set replaces the connector's value, a new key is added. Values are stringified the way Esri
expects — binaries verbatim, `true`/`false`, numbers in fixed-point, maps and lists as compact
JSON (so a `travelMode` or `barriers` object can be passed as a map). A `null` value sends an
empty form field on a POST and drops the parameter on a GET. `passthrough => #{query => ...}`
always goes on the URL.

---

## Routing

### Endpoint

`POST https://route-api.arcgis.com/arcgis/rest/services/World/Route/NAServer/Route_World/solve`

### Input

Standard `route/2` input. Path geometry is returned as coordinate arrays `[[[lng,lat],...]]` and
encoded to a precision-5 polyline. `polyline_quality` and `include` are accepted and have no
effect here. `is_round_trip => true` returns `unsupported_option`: `findBestSequence`
optimizes an open route and has no closed round-trip mode.

Any of `optimize`, `optimize_fixed_origin`, `optimize_fixed_destination` sends
`findBestSequence=true` with both preserve flags explicit — Esri defaults both to `true`
once sequencing is on:

| Flags | `preserveFirstStop` / `preserveLastStop` |
|---|---|
| `optimize` only, or both fixed flags | `true` / `true` |
| `optimize_fixed_origin` only | `true` / `false` |
| `optimize_fixed_destination` only | `false` / `true` |

`waypoint_order` is present only on optimized routes, inverted from each stop's 1-based
`Sequence`; it is omitted when that data is missing or not a complete permutation.

`avoid_tolls` / `avoid_ferries` / `avoid_highways` map to the restrictions `Avoid Toll Roads`,
`Avoid Ferries` and `Avoid Limited Access Roads`. For driving (no `travelMode` sent — the
service default) they go in the top-level `restrictionAttributeNames`. When a travel-mode
object is sent (walking), Esri applies the mode's own `restrictionAttributeNames` and ignores
the top-level parameter, so the restrictions are appended to the mode's list instead. The
matrix's `avoid_tolls` follows the same rule.

Walking sends the **full** ArcGIS "Walking Time" travel-mode JSON object: a bare `"Walking"`
name is ignored by the service, which stays on driving. `travel_mode => cycling` returns
`unsupported_travel_mode` (Esri's hosted World service ships no cycling network).

Esri applies traffic whenever a start time is sent (typical traffic, or live within 4 hours
of now) and none without one, so the time follows `traffic_mode`:

| `traffic_mode` | `departure_time` | Sent |
|---|---|---|
| `none` (default) | any | no `startTime` — time-independent speeds |
| `traffic` / `live` | not set | `startTime=now` (live traffic where available) |
| `traffic` / `live` | set | `startTime` (epoch milliseconds) + `startTimeIsUTC=true` |

`startTimeIsUTC=true` matters because Esri's default (`false`) reads the value in the first
stop's local time zone. `departure_time` may be Unix seconds, a UTC `calendar:datetime()`, or
an ISO-8601 binary; a binary without an offset (`<<"2026-11-02T08:00:00">>`) is taken as UTC,
never as the host's local time. A binary that does not parse returns `invalid_request` before
any request, even under `none`. Dropping the time under `none` also leaves stop
`ArriveTime`/`DepartTime` in `raw` null and skips Esri's time-referenced closure data. A
`startTime` in `passthrough.body` still wins.

The connector sends `ignoreInvalidLocations=false`. Esri's default (`true`) drops a stop it
cannot locate on the network and routes the rest; with `false` the request fails instead, and
the in-body error naming the stop as *unlocated* maps to `no_route`.

### Per-leg values come from the stops FeatureSet, not from directions

Legs are differences of the per-stop **cumulative** costs
(`Cumul_TravelTime` / `Cumul_Kilometers`), so the connector sends `returnStops=true` +
`accumulateAttributeNames` (see [Replacing a default list](#replacing-a-default-list)) and
`returnDirections=false`. Esri documents the turn-by-turn output as **superseded** —
*"Legacy: This output type has been superseded by the DirectionPoints and DirectionLines
output classes, which should be used for all new scripts and workflows"* — and its `esriDMT*`
maneuver values are not enumerated in the REST reference at all.

Three consequences:

- Legs sum to the totals exactly, since both come from the same cumulative series. Stops are
  sorted by `Sequence` first, because Esri lists them in input order while the costs run along
  the route.
- **`raw` contains no `directions`.** For turn-by-turn text, request it through `passthrough`
  (`returnDirections`, `directionsOutputType`) and prefer `esriDOTFeatureSets`, whose
  `DirectionPointType` is a documented integer enum — Arrive (50), Depart (51),
  Straight (52) … — over the legacy `esriDMT*` strings.
- The cumulative field name follows the active impedance (`Cumul_TravelTime` driving,
  `Cumul_WalkTime` walking). The connector discovers the key; this only matters if you read
  `raw` yourself.

When the cumulative costs are unusable — a stop that failed to locate (`Status` other than 0),
a missing `Sequence`, a decreasing series — the route's own `Total_*` values are used and split
**evenly** across legs. If neither source carries a readable distance and duration, the call
returns `unknown` rather than a 0 m / 0 s route.

### Out-of-network coordinates: read the snap distance

Each stop in `raw` carries `DistanceToNetworkInMeters` — how far the coordinate was moved to
reach a routable road — plus a `Status` code (`0` OK, `1` Not Located, `5` Not Reached, `7` Not
located on closest).

A coordinate far from any road still yields a well-formed route to wherever it snapped, so that
distance is the only signal it happened. The acceptable threshold is application policy — a few
hundred metres is normal for a rural pickup and disqualifying for a city address — so the
library does not pick one. This is the Esri analogue of OSRM's `waypoints[].distance`.

### Error mapping

Esri reports most errors **in the body of an HTTP 200**; the in-body `error.code` decides.

| Vendor signal | `code` |
|---|---|
| HTTP 429, or body `error.code == 429` | `rate_limited` |
| body `error.code` `498` / `499` / `403` | `auth_failed` |
| body `error.code` `400` / `404` whose `details[]` names an *unlocated* stop | `no_route` |
| body `error.code` `400` / `404` (otherwise) | `invalid_request` |
| body `error.code` `500` | `provider_unavailable` |
| body `error.code` (any other) | `unknown` |
| HTTP 401 / 403 (no body code) | `auth_failed` |
| HTTP 400 (no body code) | `invalid_request` |
| HTTP 5xx (no body code) | `provider_unavailable` |
| transport failure / timeout | `provider_unavailable` / `timeout` |

For an in-body error, `status` is the HTTP status (usually 200) and `cause` is the `error`
object itself.

### Retry-After

ESRI's API tier may or may not document `Retry-After` (depends on subscription). When present
on HTTP 429, the raw header rides in `cause` as `<<"retryAfter">>` and the parsed seconds are
woven into `provider_message`.

### Turn-by-turn instructions

**Not normalized** — the result has no `steps` key. Unlike the other five providers this is a
*re-enable* rather than an opt-in: the service default is `returnDirections=true`, and the
connector sends `false` explicitly so the payload is not shipped on every call.

```erlang
{ok, #{raw := Raw}} = thinwrap_location:route(Config, #{
    waypoints => [Origin, Destination],
    passthrough => #{body => #{<<"returnDirections">> => true}}
}),
[#{<<"features">> := Steps} | _] = maps:get(<<"directions">>, Raw).
```

Directions land at `raw`'s `<<"directions">>[].features[].attributes` — `text`,
`maneuverType`, `length`, `time`. `returnDirections` is its own form field, so this merges
additively (values are stringified, so `true` works as well as `<<"true">>`).

> **Esri documents this output as superseded**, in favour of the DirectionPoints and
> DirectionLines output classes, which it recommends "for all new scripts and workflows". Its
> `esriDMT*` `maneuverType` enumeration is not published in the REST reference at all — only in
> the Runtime SDK references and legacy JS 3.x docs. Legs and totals come from the `stops`
> cumulative costs (`Cumul_*`) precisely so the normalized path does not depend on this surface.

---

## Matrix

### Endpoint

`POST .../OriginDestinationCostMatrix_World/solveODCostMatrix`

### Input

Standard `matrix/2` input. The request asks for `outputType=esriNAODOutputSparseMatrix` with
`impedanceAttributeName=TravelTime`. `traffic_mode` follows the [routing rule](#input) with
`timeOfDay` in place of `startTime` (`solveODCostMatrix` has no `startTime` parameter): `none`
sends no time, `traffic` sends `timeOfDay=now`, or your time as epoch milliseconds with
`timeOfDayIsUTC=true`. A `timeOfDay` in `passthrough.body` still wins.

### Output

Cells are decoded from the `costAttributeNames` columns (`TravelTime` driving / `WalkTime`
walking — the walking travel mode overrides the impedance — plus `Kilometers`), in the order
Esri lists them. A response without a recognised time column and `Kilometers` returns
`unknown` (the column list in `cause`) rather than emitting zeros. A cell missing either cost
is omitted, as is any pair Esri leaves out of the sparse answer; an out-of-range or
non-numeric origin/destination id returns `unknown`.

A straight-line `odLines` answer is read the same way — `Total_TravelTime` (or
`Total_WalkTime` walking) and `Total_Kilometers`, unroutable or cost-less pairs omitted, an
out-of-range origin/destination id returning `unknown`. `travel_mode => cycling` returns
`unsupported_travel_mode`. Use `passthrough => #{body => #{<<"travelMode">> => Map}}` to send a
different travel-mode object.

---

## Geocoding

### Endpoints

- Forward: `GET .../GeocodeServer/findAddressCandidates` (`singleLine`, `outFields=*`)
- Reverse: `GET .../GeocodeServer/reverseGeocode` (`location=lng,lat`)
- Suggest: `GET .../GeocodeServer/suggest` (`text`, optional `location=lng,lat`)
- Place details: `GET .../GeocodeServer/findAddressCandidates` (`magicKey`, `outFields=*`)

`language` is sent as `langCode`. Candidates carry `formatted_address` (Esri's `address`),
`location`, and `viewport` from the candidate's `extent` — omitted unless all four corners are
numbers. A candidate without coordinates is skipped, never reported at (0,0). Esri candidates
have no `place_id`.

Reverse geocode answers a location with no address nearby as an in-body error 400 ("Unable to
find address for the specified location."); that is returned as an empty `candidates` list, not
an error. Any other in-body 400 stays `invalid_request`.

A 2xx body that is not a JSON object, or that lacks the `candidates` / `suggestions` list,
returns `unknown` — never an empty result that would hide an outage.

### Place details

`place_id` is the `magicKey` from `autocomplete/2`, sent **alone**: Esri's docs pair it with the
original `SingleLine` text, but a live probe showed the key on its own resolves to the
byte-identical candidate. A `magicKey` that resolves to no candidate, or to one without a
location, returns a result without `candidate`; a stale `magicKey` (in-body error 400) stays
`invalid_request`. Esri returns only an address, so `name` is never present, even with
`include => [name]`.

### Country filter

`country_filter` (ISO 3166-1 alpha-2 — ESRI uses alpha-2 directly) is translated to
`countryCode=<comma-csv>` on **forward geocode and suggest alike**.

```erlang
{ok, _} = thinwrap_location:autocomplete(Config, #{
    input => <<"Dizen">>, country_filter => [<<"IL">>, <<"PS">>]
}).
%% -> ...&countryCode=IL%2CPS
```

### `suggest` returns the least of the five

A suggestion carries only `text` and `magicKey`. That is why ESRI is the one provider where
`structured_format` is never present (there is no distinct main part to split out), and it
returns no match-highlighting offsets and no result types either — of the five geocoders only
Google and HERE return offsets. `magicKey` becomes `place_id`. `radius` and `session_token` are
not sent.

---

## Isochrone

### Endpoint

`POST .../ServiceArea_World/solveServiceArea`

### Input

Standard `isochrone/2` input. `solveServiceArea` has no break-units parameter: `defaultBreaks`
are read in the units of the active impedance attribute.

- `type => time` ⇒ `defaultBreaks` in minutes (input seconds ÷ 60) under the default
  `TravelTime` impedance (or `WalkTime` for walking).
- `type => distance` ⇒ `defaultBreaks` in kilometres (input meters ÷ 1000) with
  `impedanceAttributeName=Kilometers`. For walking, the travel mode overrides that parameter, so
  the walking travel-mode object is sent with its own `impedanceAttributeName` set to
  `Kilometers` ("Walking Distance").
- `travel_mode => cycling` returns `unsupported_travel_mode`.

Breaks are sent to six decimals, and each returned contour's `value` is **your** value: 7 s goes
out as `0.116667` minutes, and converting Esri's `ToBreak` echo back would read 7.00002 s.

`outputPolygons` is `esriNAOutputPolygonDetailed` only when every break is within Esri's
detailed-polygon cap — 15 minutes (900 s) or 15 miles (24140 m); otherwise
`esriNAOutputPolygonSimplified`, whose cap is 300 minutes / 300 miles.

`departure_time` is sent as `timeOfDay` (epoch milliseconds) with `timeOfDayIsUTC=true`; an
unparseable binary returns `invalid_request` before any request. Isochrones have no
`traffic_mode`, so a `departure_time` makes the service area traffic-aware (typical traffic, or
live within 4 hours of now); omit it for time-independent speeds.

### Output

A service-area polygon's `rings` mix exterior rings (clockwise) and holes (counter-clockwise) in
no guaranteed order. The connector classifies them by winding and attaches each hole to the
exterior that contains it; one exterior gives a `<<"Polygon">>`, several give a
`<<"MultiPolygon">>`. Holes are kept, and rings are re-wound to RFC 7946 (exterior
counter-clockwise, holes clockwise). Contours come back sorted by `value`; a polygon without a
`ToBreak` or a usable ring, or an answer with no polygons, returns `unknown`.

---

## Replacing a default list

Passthrough **replaces** a list-valued parameter the connector sets; it does not merge with it.
That is deliberate — a merge would leave you no way to remove a value. To add one, start from
the published default, the same list the connector builds its request from.
`accumulateAttributeNames` is a comma-joined form field, so `passthrough.body` replaces it whole:

| Operation | Function in `thinwrap_location_defaults` | Sent when |
|---|---|---|
| Routing | `esri_routing_accumulate_attributes_driving()` = `[<<"TravelTime">>, <<"Kilometers">>]` | driving (the default) |
| Routing | `esri_routing_accumulate_attributes_walking()` = `[<<"WalkTime">>, <<"Kilometers">>]` | `travel_mode => walking` |
| Matrix | `esri_matrix_accumulate_attributes()` = `[<<"Kilometers">>]` | always (`TravelTime` is the impedance) |

```erlang
Names = iolist_to_binary(lists:join(<<",">>,
    thinwrap_location_defaults:esri_routing_accumulate_attributes_driving() ++ [<<"Miles">>])),
thinwrap_location:route(Config, #{
    waypoints => [Origin, Destination],
    passthrough => #{body => #{<<"accumulateAttributeNames">> => Names}}
}).
```

Pick the list that matches the travel mode: Esri only accumulates a time attribute the active
impedance uses, and silently returns nothing for the other one.

Legs are always read from `Cumul_<time>` for the mode's time attribute (`TravelTime` driving,
`WalkTime` walking) and `Cumul_Kilometers`, by name. Extra attributes you accumulate —
`Miles`, `TruckTravelTime`, anywhere in the list — land in `raw` and never change which fields
feed the legs.

> **Omitting a value the normalizer reads.**
>
> - Routing: per-leg values are differences of the stops' `Cumul_<time>` and `Cumul_Kilometers`.
>   If your list drops one, the connector falls back to matching the remaining `Cumul_*` keys by
>   shape, in response order (a `Miles` column still works as the distance), and failing that to
>   the route's `Total_*` values split **evenly** across legs — the totals stay right but
>   per-leg values do not. If the route carries no readable distance or duration either, the
>   call returns `unknown`.
> - Matrix: the `Kilometers` column fills `distance_meters`. Without it the call returns
>   `unknown` (the column list in `cause`) rather than reporting 0 m.

### Geocoding `outFields`

Forward geocode and place details send `outFields=*`. That is a wildcard, not a list, so there is
no default to extend. `outFields` only controls the `attributes` object on each candidate, and
the normalizer reads **none** of those attributes: `formatted_address` comes from the candidate's
`address`, `location` from `location.x`/`location.y`, and `viewport` from `extent`, all of which
Esri returns whatever `outFields` says. Narrowing `outFields` through `passthrough` therefore
changes only `raw`. Reverse geocode and suggest do not send it.
