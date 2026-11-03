# Google Maps Platform Connector (Erlang)

Google Maps Platform connector for routing, distance matrix, geocoding, autocomplete and place
details via direct HTTP calls — OTP `httpc` and `json` only, no vendor SDK.

## Quick start

See the [package README](../../README.md) for installation. The config's **`provider` selects
the connector** — pass a `google` config to any operation it supports:

```erlang
Config = #{provider => google, api_key => fun() -> list_to_binary(os:getenv("GOOGLE_MAPS_API_KEY")) end},

{ok, Route}  = thinwrap_location:route(Config, #{waypoints => [Origin, Destination]}),
{ok, Matrix} = thinwrap_location:matrix(Config, #{origins => Os, destinations => Ds}),
{ok, Geo}    = thinwrap_location:geocode(Config, #{address => <<"1600 Amphitheatre Parkway">>}).
```

`thinwrap_location:isochrone/2` with a `google` config raises `{badarg, _}` — Google is not
wired for isochrone (`thinwrap_location:supports(google, isochrone)` is `false`).

## Configuration

| Key | Type | Required | Notes |
|---|---|---|---|
| `api_key` | `binary()` or `fun(() -> binary())` | yes | Google Maps Platform API key (a single key works across Routes + Geocoding + Places) |

Inject a custom HTTP client with `transport => {Module, Opts}` (see the package README); the
default `thinwrap_location_httpc` transport never follows redirects.

## Auth setup

Generate a key at https://console.cloud.google.com/google/maps-apis/credentials with the
**Routes API**, **Geocoding API**, and **Places API (New)** enabled. Sent as the
`X-Goog-Api-Key` header (Routes v2 / Route Matrix v2 / Places API New) or the `key=` query
parameter (Geocoding). Static key — no refresh, no rotation.

## Vendor docs

- Routes API v2: https://developers.google.com/maps/documentation/routes
- Geocoding API: https://developers.google.com/maps/documentation/geocoding
- Places Autocomplete (New): https://developers.google.com/maps/documentation/places/web-service/place-autocomplete
- Rate limits: https://developers.google.com/maps/documentation/routes/usage-and-billing

---

## Routing

### Endpoint

`POST https://routes.googleapis.com/directions/v2:computeRoutes`

### Input

The standard `route/2` input applies as-is: `waypoints`, `travel_mode`, `optimize`,
`is_round_trip`, `departure_time`, `avoid_tolls`, `avoid_ferries`, `avoid_highways`,
`polyline_quality` (`simplified` ⇒ `OVERVIEW`, Google's own default; `detailed` ⇒
`HIGH_QUALITY`). Provider-specific Routes v2 features (lane guidance, extra route modifiers) go
via `passthrough => #{body => ...}`.

`traffic_mode` sets `routingPreference` for DRIVE and TWO_WHEELER (Google rejects it for WALK
and BICYCLE): `none` ⇒ `TRAFFIC_UNAWARE` (time-independent average speeds, Essentials SKU),
`traffic` / `live` ⇒ `TRAFFIC_AWARE` (**Pro SKU**). `departure_time` is sent only with traffic:
Google rejects a timestamp on `TRAFFIC_UNAWARE` ("Timestamp cannot be set for
TRAFFIC_UNAWARE routing mode.", HTTP 400), so under `none` it is dropped.

`include => [durationWithoutTraffic]` adds the static-duration fields to the field mask and
surfaces `duration_without_traffic_seconds` (per leg) and
`total_duration_without_traffic_seconds` — only when Google actually returns them.

### `waypoint_order` and Google's `[-1]` answer

Google reports the optimized order as `routes.optimizedIntermediateWaypointIndex`, over the
INTERMEDIATE waypoints only. The connector projects that onto the canonical `waypoint_order`
(all input indices, in visit order, origin/destination inclusive).

Google does **not** always return real indices: when it declines to optimize it answers
`[-1]`. The connector validates the projection and **omits the `waypoint_order` key entirely**
unless it is a complete permutation of `[0..N-1]` — so an absent `waypoint_order` means "no
usable ordering", never a silently corrupt one. The rest of the result (legs, totals, polyline,
raw) is returned as normal, and `raw` still carries the vendor's own field if you need to
inspect it.

"No route" is HTTP 200 with `routes` absent or empty, returned as `no_route`.

### Error mapping

| Vendor HTTP | Vendor signal | `code` |
|---|---|---|
| 401 | (any) | `auth_failed` |
| 403 | `error.status == "QUOTA_EXCEEDED"` | `rate_limited` |
| 403 | (other) | `auth_failed` |
| 400 | `error.details[]` `ErrorInfo.reason` (e.g. `API_KEY_INVALID`) | `auth_failed` |
| 400 | `ErrorInfo.reason` `RATE_LIMIT_EXCEEDED` / `RESOURCE_QUOTA_EXCEEDED` | `rate_limited` |
| 400 | (other) | `invalid_request` |
| 429 | (any; respects `Retry-After`) | `rate_limited` |
| 5xx | (any) | `provider_unavailable` |
| network failure / timeout | — | `provider_unavailable` / `timeout` |

### Retry-After

On HTTP 429, the raw `Retry-After` header rides in the error's `cause` as `<<"retryAfter">>`;
the parsed seconds count is woven into `provider_message` as `…; retry after N seconds`.

### `passthrough` example

```erlang
Mask = iolist_to_binary(lists:join(<<",">>,
    thinwrap_location_defaults:google_routes_field_mask() ++ [<<"routes.warnings">>])),
thinwrap_location:route(Config, #{
    waypoints => [Origin, Destination],
    passthrough => #{
        body => #{languageCode => <<"fr">>, units => <<"IMPERIAL">>},
        %% The mask REPLACES the connector's own, so start from the published default.
        headers => #{<<"X-Goog-FieldMask">> => Mask}
    }
}).
```

### Turn-by-turn instructions

Off by default and **not normalized** — the result has no `steps` key. Add the step fields to
the mask and read them from `raw`, which carries Google's response verbatim:

```erlang
Mask = iolist_to_binary(lists:join(<<",">>,
    thinwrap_location_defaults:google_routes_field_mask()
        ++ [<<"routes.legs.steps.navigationInstruction">>])),
{ok, #{raw := Raw}} = thinwrap_location:route(Config, #{
    waypoints => [Origin, Destination],
    passthrough => #{headers => #{<<"X-Goog-FieldMask">> => Mask}}
}).
```

Instruction text is at `routes[].legs[].steps[].navigationInstruction.instructions`; the icon
enum is at `.maneuver`. The mask you pass replaces the connector's own — see
[Replacing a default list](#replacing-a-default-list) for why and what to keep.

Requesting steps does not change the SKU: the Compute Routes SKU is selected by request
*features* (`TRAFFIC_AWARE`, two-wheel routing), not by requested fields. It does enlarge the
response considerably.

---

## Matrix

### Endpoint

`POST https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix`

### Input

Standard `matrix/2` input (`origins`, `destinations`, `travel_mode`, `avoid_tolls`,
`departure_time`). `traffic_mode` and `departure_time` follow the [routing rule](#input);
Route Matrix bills per element, so `traffic` moves every element onto the Pro SKU. The connector
flattens the NDJSON response into `cells` with `origin_index` + `destination_index`; an element
without `status` and `condition`, a non-OK `status`, or a `condition` other than
`ROUTE_EXISTS` is a failed cell and is omitted.

### Error mapping

Same table as routing (the Routes API shares the error surface, including the
`ErrorInfo.reason` auth mapping). Retry-After surfacing identical.

### `passthrough` example

```erlang
thinwrap_location:matrix(Config, #{
    origins => Os,
    destinations => Ds,
    passthrough => #{body => #{routingPreference => <<"TRAFFIC_AWARE_OPTIMAL">>}}
}).
```

---

## Geocoding

### Endpoints

- Forward / reverse: `GET https://maps.googleapis.com/maps/api/geocode/json` (`key=` query auth)
- Autocomplete: `POST https://places.googleapis.com/v1/places:autocomplete` (Places API New;
  `X-Goog-Api-Key` header auth + JSON body)
- Place details: `GET https://places.googleapis.com/v1/places/{place_id}` (Places API New)

### Input

Standard `geocode/2` / `reverse_geocode/2` / `autocomplete/2` / `place_details/2` input.
Autocomplete sends `location` (+ `radius`) as a `locationBias` circle and `session_token` as the
body's `sessionToken`; place details sends it as the `sessionToken` query parameter, which
closes the session autocomplete opened so it bills once. Other Places fields go via
`passthrough`.

### Error mapping

The Geocoding API returns HTTP 200 with a `status` field on errors. The connector maps:

| Google `status` | `code` |
|---|---|
| `OK` / `ZERO_RESULTS` | (no error) |
| `REQUEST_DENIED` | `auth_failed` |
| `OVER_DAILY_LIMIT` | `auth_failed` (invalid key, billing not enabled, a self-imposed usage cap, or an invalid payment method — an account fix, not a retry) |
| `OVER_QUERY_LIMIT` | `rate_limited` |
| `INVALID_REQUEST` | `invalid_request` |
| `UNKNOWN_ERROR` | `provider_unavailable` |

Autocomplete and place details (Places API New) answer in the `google.rpc` error shape instead,
and use the routing table above: an invalid key is HTTP 400 `INVALID_ARGUMENT` whose
`ErrorInfo.reason` is `API_KEY_INVALID`, surfaced as `auth_failed` — as are the other
key/credential reasons (`API_KEY_SERVICE_BLOCKED`, `API_KEY_HTTP_REFERRER_BLOCKED`, …).

Place details: a 404 `NOT_FOUND` returns a result without `candidate`. Places v1 answers most
unknown ids (live-verified) with 400 `INVALID_ARGUMENT`, indistinguishable from a malformed
one, so those stay `invalid_request`.

### `passthrough` example

```erlang
thinwrap_location:geocode(Config, #{
    address => <<"1600 Amphitheatre Parkway">>,
    passthrough => #{query => #{region => <<"us">>, language => <<"en">>}}
}).
```

### Country filter

`country_filter` is ISO 3166-1 alpha-2 throughout this library, and each operation translates
it into the parameter that operation's endpoint actually takes:

| Operation | Parameter |
|---|---|
| `geocode/2` | `components=country:XX` — **one country only** |
| `autocomplete/2` | `includedRegionCodes` (JSON body) |

```erlang
{ok, _} = thinwrap_location:autocomplete(Config, #{
    input => <<"Dizen">>, country_filter => [<<"IL">>, <<"PS">>]
}).
%% -> body includedRegionCodes == [<<"il">>, <<"ps">>]
```

Things the translation handles for you, because they fail quietly otherwise:

- **Autocomplete takes ccTLD codes, not ISO**, and the two disagree on the United Kingdom —
  ISO `GB` is ccTLD `uk`. Passing `GB` through unchanged returns no UK predictions rather than
  an error, so the connector rewrites it.
- **Google caps the list at 15** and rejects the whole request over that. The connector returns
  `invalid_request` before the round-trip. An entry that is not two ASCII letters is
  `invalid_request` too.
- **`geocode/2` honours a single country.** `components=country:US|country:CA` is not an OR:
  Google applies the first country and pads the results with unrelated matches ("Windsor" with
  `US|CA` → only Windsor, CT; `CA|US` → only Windsor, ON). More than one entry returns
  `unsupported_option` before any request; autocomplete's `includedRegionCodes` does take a
  list.

> **Setting a country filter also suppresses Google's *query* predictions.** It changes which
> *kinds* of suggestion come back, not only how many — a query-type row (a search term rather
> than a place) will no longer appear at all.

### Structured format

Autocomplete predictions carry `structured_format => #{main_text, secondary_text}` from
`placePrediction.structuredFormat` — default-on for Places Autocomplete, so free to surface. It
is present only when Google sends a non-empty main part.

### Match-highlighting offsets

**Not normalized** — predictions have no `matches` key. Only 2 of the 5 geocoders return offsets
at all (Google and HERE), and they disagree on both the encoding and which string the offsets
index, so this stays vendor-native in `raw`:

```erlang
{ok, #{raw := Raw}} = thinwrap_location:autocomplete(Config, #{input => <<"Dizen">>}),
[#{<<"placePrediction">> := #{<<"structuredFormat">> := #{<<"mainText">> := Main}}} | _] =
    maps:get(<<"suggestions">>, Raw),
Matches = maps:get(<<"matches">>, Main, []).
%% -> [#{<<"startOffset">> => integer(), <<"endOffset">> => integer()}]
```

Available on `text`, `structuredFormat.mainText` and `structuredFormat.secondaryText`, and
present by default — no extra request field and no extra cost.

> These are Unicode **code-point** offsets, and Erlang binaries are UTF-8 bytes, so do not
> `binary:part/3` with them: slice the code points instead —
> `lists:sublist(unicode:characters_to_list(Text), Start + 1, End - Start)`.

---

## Replacing a default list

Every Google endpoint that takes an `X-Goog-FieldMask` gets the connector's own.
`passthrough => #{headers => #{<<"X-Goog-FieldMask">> => ...}}` **replaces** that mask (the
header name matches case-insensitively); it does not merge with it. That is deliberate — a
merge would leave you no way to remove a field. To add one, start from the published default,
which is the same list the connector builds its request from:

```erlang
Mask = iolist_to_binary(lists:join(<<",">>,
    thinwrap_location_defaults:google_routes_field_mask() ++ [<<"routes.travelAdvisory">>])),
thinwrap_location:route(Config, #{
    waypoints => [Origin, Destination],
    passthrough => #{headers => #{<<"X-Goog-FieldMask">> => Mask}}
}).
```

| Operation | Always sent (`thinwrap_location_defaults:`) | Added by the connector when… |
|---|---|---|
| Routing | `google_routes_field_mask()` | `google_routes_field_mask_duration_without_traffic()` — `include` has `durationWithoutTraffic`; `google_routes_field_mask_waypoint_order()` — any `optimize*` flag or `is_round_trip` |
| Matrix | `google_matrix_field_mask()` | — |
| Place details | `google_place_details_field_mask()` | `google_place_details_field_mask_name()` — `include` has `name` |

Your mask replaces the conditional groups too, so re-add any group your request would have
triggered.

> **Omitting a field the normalizer reads empties that output — mostly without an error.**
> Absent values are coalesced, so the result looks like a real zero-length route.
>
> - Routing: `routes.legs.distanceMeters` / `routes.legs.duration` → each leg's distance /
>   duration (`0.0`); `routes.distanceMeters` / `routes.duration` → the totals (`0.0`);
>   `routes.polyline.encodedPolyline` → `polyline` (`<<>>`); the static-duration fields →
>   `duration_without_traffic_seconds` (absent); `routes.optimizedIntermediateWaypointIndex` →
>   `waypoint_order` (absent). Dropping every `routes.legs.*` field leaves the route with no
>   legs, which returns `no_route`.
> - Matrix: `distanceMeters` / `duration` → the cell values (`0.0`); `originIndex` /
>   `destinationIndex` → the cell position (every cell lands on `0`); `status` / `condition` →
>   reachability — an element carrying neither is treated as a failed cell, so dropping both
>   omits every cell.
> - Place details: `formattedAddress` → `formatted_address` (`<<>>`); `id` → `place_id`
>   (absent); `viewport` → `viewport` (absent); `displayName` → `name` (absent, and only read
>   when `name` is included). Dropping `location` returns no `candidate`, since a candidate is
>   never given a fabricated coordinate.
>
> Each mask field also selects Google's billing tier on Place Details, so adding a field there
> can move the call onto a pricier SKU.
