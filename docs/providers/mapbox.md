# Mapbox Connectors (Erlang)

Mapbox connectors for routing, distance matrix, geocoding, and isochrone via direct HTTP calls (OTP only — no vendor SDK).

## Quick start

See the [package README](../../README.md) for installation. The config's **`provider` key selects the connector** — pass a Mapbox config to any operation it supports:

```erlang
Config = #{provider => mapbox, access_token => list_to_binary(os:getenv("MAPBOX_TOKEN"))},

{ok, Route}   = thinwrap_location:route(Config, #{waypoints => [Origin, Destination]}),
{ok, Matrix}  = thinwrap_location:matrix(Config, #{origins => Os, destinations => Ds}),
{ok, Geo}     = thinwrap_location:geocode(Config, #{address => <<"1 Main St">>}),
{ok, Contour} = thinwrap_location:isochrone(Config, #{center => Center, type => time, values => [600]}).
```

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `access_token` | `binary()` or `fun(() -> binary())` | yes | Mapbox public or secret access token (must include `directions:read`, `matrix:read`, `geocoding:read`, `isochrone:read` scopes). The fun form keeps the token out of crash reports that print the config. |

Inject a custom transport with `transport => {Module, Opts}` (see the package README); the default `httpc` transport never follows redirects.

## Auth setup

Create a token at https://account.mapbox.com/access-tokens/. Sent as `access_token=` query param on every request. Static — no refresh.

## Vendor docs

- Directions: https://docs.mapbox.com/api/navigation/directions/
- Matrix: https://docs.mapbox.com/api/navigation/matrix/
- Geocoding v6: https://docs.mapbox.com/api/search/geocoding/
- Isochrone: https://docs.mapbox.com/api/navigation/isochrone/
- Rate limits: https://docs.mapbox.com/api/overview/#rate-limits

---

## Routing

### Endpoint

- Directions: `GET https://api.mapbox.com/directions/v5/mapbox/{profile}/{coordinates}`
- Optimized trips: `GET https://api.mapbox.com/optimized-trips/v1/mapbox/{profile}/{coordinates}`

### Input

The standard route input. Travel mode is encoded into the URL path. Polyline returned in standard Google precision-5 format.

`traffic_mode => traffic` (or the deprecated `live`) with driving selects the
**`driving-traffic`** profile — Mapbox chooses traffic by profile, not by a flag. Walking and
cycling have no traffic variant, so traffic is ignored there; the optimized path also ignores
it and stays on `driving` (Optimization v1 has no `driving-traffic`).

`departure_time` becomes `depart_at` (UTC, seconds precision) on **`driving-traffic`** only.
Under `none` it is not sent: on plain `driving`, `depart_at` makes the duration a prediction
from historical travel data (typical traffic), which `none` promises not to add. Walking and
cycling durations do not depend on time, so it is left off there too.

The avoid flags become `exclude` classes (`toll`, `ferry`, `motorway`). Walking and cycling
accept only a subset — `toll`/`motorway` there fail with 422 "exclude value must be one of:
ferry, cash_only_tolls, …" — so for those profiles only `ferry` is sent. Nothing is lost: tolls
do not apply to either mode, the cycling profile already avoids highways, and walking follows
sidewalks and trails.

Any of `optimize`, `optimize_fixed_origin`, `optimize_fixed_destination` or `is_round_trip`
selects Optimization v1, whose accepted query parameters are a fixed list (unrecognized ones fail
with `InvalidInput`). These are refused before any request:

| Input on the optimized path | `code` |
|---|---|
| `avoid_tolls` / `avoid_ferries` / `avoid_highways` (v1 has no `exclude`) | `unsupported_option` |
| `departure_time` with `traffic`/`live` on driving (v1 has no `depart_at`); under `none` or on walking/cycling it is dropped | `unsupported_field` |
| exactly one of `optimize_fixed_origin` / `optimize_fixed_destination` without `is_round_trip` (v1 supports an open trip only as `source=first` + `destination=last`; the others return `NotImplemented`) | `unsupported_option` |

A round trip always sends `source=first`, plus `destination=last` when
`optimize_fixed_destination` is set.

### Overriding `geometries` via passthrough

The connector requests `geometries=polyline6` and re-encodes to precision-5. If you override
`geometries` through `passthrough => #{query => ...}`, the decoder **follows your value**:

| `geometries` | Handling |
|---|---|
| `polyline6` (default) | decoded at precision 6, re-encoded at precision 5 |
| `polyline` | already precision-5 — emitted verbatim |
| `geojson` | `[lng, lat]` pairs encoded at precision 5 |

This matters because the two encodings are indistinguishable as strings: decoding a
precision-5 polyline with a precision-6 decoder divides every coordinate by 10, which lands
your route in the wrong hemisphere with no error raised. An unusable GeoJSON geometry yields an
empty polyline (`<<>>`) rather than an error — the leg distances and durations are still valid.
A corrupt `polyline6` string is `{error, #{code := unknown}}`.

### Error mapping

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401 | (any) | `auth_failed` |
| 403 | (any) | `auth_failed` |
| 400 | (any) | `invalid_request` |
| 422 | `code` `NoRoute` / `NoSegment` / `NoTrips` | `no_route` |
| 422 | `code` `ProcessingError` | `unknown` |
| 422 | any other `code` (e.g. `InvalidInput`) | `invalid_request` |
| 429 | (respects `Retry-After`) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| 2xx | `code` `NoRoute` / `NoSegment` / `NoTrips`, or no routes | `no_route` |
| 2xx | `code` `InvalidInput` / `ProfileNotFound` | `invalid_request` |
| 2xx | `code` `NotImplemented` (a source/destination/roundtrip combination overridden via passthrough) | `unsupported_option` |
| 2xx | a route or leg without `distance` / `duration` | `unknown` (never a 0 m / 0 s route) |

### Retry-After

On HTTP 429, the error's `cause` carries the raw header as `<<"retryAfter">>`; parsed seconds appear in `provider_message`.

### `passthrough` example

```erlang
{ok, Res} = thinwrap_location:route(Config, #{
    waypoints => [Origin, Destination],
    passthrough => #{query => #{<<"annotations">> => <<"duration,distance,speed">>,
                                <<"overview">> => <<"full">>}}
}).
```

### Turn-by-turn instructions

Off by default and **not normalized** — the route result has no `steps` key. Ask for `steps`
and read them from `raw`:

```erlang
{ok, #{raw := Raw}} = thinwrap_location:route(Config, #{
    waypoints => [Origin, Destination],
    passthrough => #{query => #{<<"steps">> => <<"true">>}}
}).
```

Instruction text is at `routes[].legs[].steps[].maneuver.instruction`, alongside `type`,
`modifier`, `bearing_before` / `bearing_after` and `location`. With `optimize => true` the
connector calls `/optimized-trips/v1`, which returns the same objects under **`trips[]`** rather
than `routes[]`.

`steps` is its own parameter, so this merges additively — nothing the connector sends is
displaced. `banner_instructions` and `voice_instructions` (SSML) are separate opt-ins, and both
require `steps=true`.

Steps are the single largest part of a Mapbox routing response, which is why the connector does
not request them by default.

---

## Matrix

### Endpoint

`GET https://api.mapbox.com/directions-matrix/v1/mapbox/{profile}/{coordinates}`

### Input

The standard matrix input. `traffic_mode => traffic` (or `live`) with driving selects
the `driving-traffic` profile. Under `none`, and on walking/cycling (no traffic variant), a
`departure_time` is dropped (it has no effect by definition). Refused before any request:

| Input | `code` |
|---|---|
| `avoid_tolls` (the Matrix API has no `exclude`) | `unsupported_option` |
| `departure_time` with `traffic`/`live` on driving (`depart_at` is a sign-up beta on Matrix) | `unsupported_field` |

A standard account gets 422 "Request too large for custom parameters" for either. An account
enrolled in the `depart_at` beta can send it through `passthrough => #{query => ...}`.

### Error mapping

Same as routing: the envelope `code` decides on a 422 and in a 200 body alike (`NoRoute` /
`NoSegment` → `no_route`). Retry-After surfacing identical. A `null` or non-numeric cell is
omitted rather than reported as 0.

---

## Geocoding

### Endpoints

- Forward: `GET https://api.mapbox.com/search/geocode/v6/forward`
- Reverse: `GET https://api.mapbox.com/search/geocode/v6/reverse`
- Autocomplete (Search Box): `GET https://api.mapbox.com/search/searchbox/v1/suggest`
- Place details (Search Box): `GET https://api.mapbox.com/search/searchbox/v1/retrieve/{mapbox_id}`

### Input

The standard geocode / reverse-geocode / autocomplete / place-details inputs. Other
Geocoding/Search Box-specific fields go via `passthrough => #{query => ...}`.

### Country filter

`country_filter` (ISO 3166-1 alpha-2) is translated to lowercased CSV `country=us,ca` on
**forward geocode and autocomplete alike**.

```erlang
thinwrap_location:autocomplete(Config, #{input => <<"coffee">>,
                                         country_filter => [<<"IL">>, <<"PS">>]}).
%% → ...&country=il,ps
```

### Session tokens (billing)

Search Box bills per **session**: every `/suggest` that shares a `session_token`, closed by the
`/retrieve` carrying the same value, is one billable session. Pass the same `session_token` to
`autocomplete/2` and the following `place_details/2`; a missing or fresh token makes them two
sessions. `session_token` is required on both endpoints, so a UUIDv4 is generated when you
supply none.

`place_details/2` resolves a `mapbox_id` from autocomplete. An id Search Box has no data for
(HTTP 404) is `{ok, #{raw := Raw}}` with no `candidate` key. `include => [name]` adds the
feature's `name`.

### No match-highlighting offsets

Search Box `/suggest` returns no match offsets — no `matches`, `highlights` or equivalent.
Of the five geocoders only Google and HERE return them, so a UI that bolds the matched
substring cannot get those offsets from Mapbox; it has to match client-side against
`description` / `structured_format`.

---

## Isochrone

### Endpoint

`GET https://api.mapbox.com/isochrone/v1/mapbox/{profile}/{lng},{lat}`

### Input

The standard isochrone input. `type` (`time` / `distance`) toggles between the
`contours_minutes` and `contours_meters` query params. Mapbox accepts up to 4 contour values per
call.

Mapbox takes whole minutes and whole meters, in increasing order, so the connector sorts the
values and rounds them (seconds to the nearest minute, meters to the nearest meter). Each
returned contour's `value` is **your** value, not the rounded one — a 90 s break is sent as
`2` and comes back as `90.0`. Values Mapbox cannot express are `{error, #{code :=
invalid_request}}` before any request: a time break under 60 s (it would round to 0), and two
breaks that round to the same minute or meter (Mapbox would return one contour for both).

`departure_time` ⇒ `depart_at=`. An ISO-8601 date-time binary is sent verbatim, so its
offset — or its lack of one — is preserved; Unix seconds and a `calendar:datetime()` are sent as
UTC at seconds precision. A binary that is not an ISO-8601 date-time is `invalid_request`
before any request is sent; any other type raises `badarg`.
Isochrones have no `traffic_mode`, so a `departure_time` (sent as `depart_at`) makes the contour
traffic-aware for that time: Mapbox documents that "the isochrone contours will reflect traffic
conditions at the time provided". Driving uses the `driving` profile, which without `depart_at`
uses average conditions.

### Output

With `polygons=true` each feature is a GeoJSON `Polygon`; a `MultiPolygon` feature is accepted too
and returned as a `MultiPolygon`. Holes are kept, and rings are re-wound to RFC 7946 (exterior
counter-clockwise, holes clockwise). Malformed pieces are skipped one at a time: a part without a
usable exterior is dropped, as is an unusable hole, and the rest is kept. Only a contour with
nothing usable left is `unknown`.

---

## Replacing a default list

Passthrough **replaces** a list-valued parameter the connector sets; it does not merge with it.
That is deliberate — a merge would leave you no way to remove a value. The published default is
the same list the connector builds its request from:

| Operation | Parameter | Function |
|---|---|---|
| Matrix | `annotations` query (comma-joined) | `thinwrap_location_defaults:mapbox_matrix_annotations()` = `[<<"duration">>, <<"distance">>]` |

Mapbox documents only `duration` (its own default) and `distance` for this parameter, so the
connector already sends every value there is and there is nothing to append. A caller can still
replace it:

```erlang
thinwrap_location:matrix(Config, #{
    origins => Origins,
    destinations => Destinations,
    passthrough => #{query => #{<<"annotations">> => <<"duration">>}}
}).
```

> **Omitting a value the normalizer reads.** `durations` fills `duration_seconds` and `distances`
> fills `distance_meters`. Drop either and the call returns `{error, #{code := unknown}}`, because
> the response no longer carries a matrix of the requested dimensions — you get an error, never
> zero-valued cells.
