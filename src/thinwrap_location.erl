-module(thinwrap_location).
-moduledoc """
Routing, distance matrix, geocoding and isochrone across Google, Mapbox, HERE,
Esri, TomTom and OSRM — one normalized surface, zero dependencies.

Every function takes a provider **config** and an **input** map and returns
`{ok, Result}` or `{error, ConnectorError}`:

```erlang
Config = #{provider => google, api_key => <<"...">>},
{ok, #{legs := Legs, polyline := Polyline}} =
    thinwrap_location:route(Config, #{
        waypoints => [#{lat => 40.7128, lng => -74.0060},
                      #{lat => 41.1865, lng => -73.1952}]
    }).
```

## Two kinds of failure

- **Operation failures** — a vendor error, a transport failure or timeout,
  request data the vendor would reject, an unsupported capability — come back
  as `{error, connector_error()}`, a plain map whose `code` you branch on.
- **Misuse** — a missing or unknown config/input key, a value of the wrong
  type, an enum atom outside its set, a provider that lacks the operation —
  raises `error({badarg, Description})`. Folding those into `{error, _}` would
  make a bug in the calling code look like bad end-user input or, worse, a
  retryable outage.

## Normalization

Distances are meters, durations seconds, coordinates `#{lat, lng}`
(latitude first), route geometry a Google precision-5 polyline whatever the
provider returned. Optional output fields are **omitted** from the result map
when the provider gave nothing — read them with `maps:get/3`. Every result
carries the decoded vendor body under `raw` (JSON `null` is the atom `null`).

## Passthrough

Every input accepts `passthrough => #{body => map(), headers => map(),
query => map()}`, forwarded verbatim and overriding what the connector set
(auth included): `body` deep-merged, `headers` and `query` shallow-merged.
""".

-export([
    route/2,
    matrix/2,
    geocode/2,
    reverse_geocode/2,
    autocomplete/2,
    place_details/2,
    isochrone/2,
    supports/2
]).

-export_type([
    config/0,
    provider/0,
    operation/0,
    secret/0,
    lat_lng/0,
    departure_time/0,
    connector_error/0,
    passthrough/0,
    travel_mode/0,
    traffic_mode/0,
    route_input/0,
    route_result/0,
    route_leg/0,
    matrix_input/0,
    matrix_result/0,
    matrix_cell/0,
    geocode_input/0,
    reverse_geocode_input/0,
    autocomplete_input/0,
    place_details_input/0,
    geocode_result/0,
    geocode_candidate/0,
    autocomplete_result/0,
    autocomplete_prediction/0,
    place_details_result/0,
    isochrone_input/0,
    isochrone_result/0,
    isochrone_contour/0,
    result/1
]).

-type provider() :: google | mapbox | here | esri | osrm | tomtom.
-type operation() ::
    route | matrix | geocode | reverse_geocode | autocomplete | place_details | isochrone.

%% A credential, or a zero-arity fun returning it. The fun form keeps the
%% secret out of crash reports and logs that print the config map (EEF
%% secure-coding guidance).
-type secret() :: binary() | fun(() -> binary()).

-doc """
Provider configuration. `provider` selects the connector; the credential
keys depend on it:

- `google`, `here`, `tomtom` — `api_key`
- `mapbox` — `access_token`
- `esri` — exactly one of `api_key` or `arcgis_token`
- `osrm` — `base_url` (required, your own server; a path prefix is allowed)
  and optionally `supported_exclude_classes`, the exclude classes your OSRM
  build was compiled with (`[<<"toll">>, <<"ferry">>, <<"motorway">>]`)

Optional on every provider: `transport` (see `thinwrap_location_transport`;
default `{thinwrap_location_httpc, #{}}`) and `sleep`, the wait used between
async-matrix polls (HERE always, TomTom for large grids) — a test seam.
""".
-type config() :: #{
    provider := provider(),
    api_key => secret(),
    access_token => secret(),
    arcgis_token => secret(),
    base_url => binary(),
    supported_exclude_classes => [binary()],
    transport => thinwrap_location_transport:transport(),
    sleep => fun((Milliseconds :: non_neg_integer()) -> term())
}.

-type lat_lng() :: #{lat := number(), lng := number()}.

-doc """
Unix seconds, a UTC `calendar:datetime()`, or an RFC 3339 binary
(`<<"2026-11-02T08:00:00Z">>`). An unparseable binary is `invalid_request`.
""".
-type departure_time() :: integer() | calendar:datetime() | binary().

-type passthrough() :: #{
    body => map(),
    headers => #{binary() | atom() => binary()},
    query => #{binary() | atom() => binary() | [binary()]}
}.

-type travel_mode() :: driving | walking | cycling.

-doc """
How much traffic a route or matrix is computed against. `none` (default):
time-independent durations — a `departure_time` never adds traffic. `traffic`:
the traffic expected at `departure_time` (now when absent). `live`: deprecated
alias of `traffic`, kept permanently. The default is a billing decision too:
on Google traffic-aware routing is a Pro-tier SKU, and HERE bills time-aware
routing unless traffic is explicitly disabled.
""".
-type traffic_mode() :: none | traffic | live.

-doc """
The operation-failure value. `code` is the normalized classification shared
with the sibling libraries; `status` is the HTTP status when the provider
answered; `cause` is the (credential-redacted) decoded vendor body or a
redacted transport message, with a `Retry-After` header surfaced as
`<<"retryAfter">>`.
""".
-type connector_error() :: #{
    code := thinwrap_location_error:code(),
    message := binary(),
    status => integer(),
    provider_message => binary(),
    cause => term()
}.

-type route_input() :: #{
    waypoints := [lat_lng()],
    optimize => boolean(),
    optimize_fixed_origin => boolean(),
    optimize_fixed_destination => boolean(),
    is_round_trip => boolean(),
    departure_time => departure_time(),
    avoid_tolls => boolean(),
    avoid_ferries => boolean(),
    avoid_highways => boolean(),
    travel_mode => travel_mode(),
    %% HERE only: overrides the travel_mode mapping, forwarded verbatim.
    transport_mode => atom() | binary(),
    passthrough => passthrough(),
    polyline_quality => simplified | detailed,
    traffic_mode => traffic_mode(),
    include => [durationWithoutTraffic]
}.

-type route_leg() :: #{
    distance_meters := float(),
    duration_seconds := float(),
    duration_without_traffic_seconds => float()
}.

-type route_result() :: #{
    legs := [route_leg()],
    total_distance_meters := float(),
    total_duration_seconds := float(),
    polyline := binary(),
    raw := term(),
    %% A complete permutation of input indices in visit order, when optimized.
    waypoint_order => [non_neg_integer()],
    total_duration_without_traffic_seconds => float()
}.

-type matrix_input() :: #{
    origins := [lat_lng()],
    destinations := [lat_lng()],
    travel_mode => travel_mode(),
    avoid_tolls => boolean(),
    departure_time => departure_time(),
    transport_mode => atom() | binary(),
    passthrough => passthrough(),
    traffic_mode => traffic_mode()
}.

-type matrix_cell() :: #{
    origin_index := non_neg_integer(),
    destination_index := non_neg_integer(),
    distance_meters := float(),
    duration_seconds := float()
}.

-type matrix_result() :: #{cells := [matrix_cell()], raw := term()}.

-type geocode_input() :: #{
    address := binary(),
    language => binary(),
    country_filter => [binary()],
    passthrough => passthrough()
}.

-type reverse_geocode_input() :: #{
    location := lat_lng(),
    language => binary(),
    passthrough => passthrough()
}.

-type autocomplete_input() :: #{
    input := binary(),
    location => lat_lng(),
    radius => number(),
    language => binary(),
    session_token => binary(),
    country_filter => [binary()],
    passthrough => passthrough()
}.

-type place_details_input() :: #{
    place_id := binary(),
    language => binary(),
    session_token => binary(),
    include => [name],
    passthrough => passthrough()
}.

-type geocode_candidate() :: #{
    formatted_address := binary(),
    location := lat_lng(),
    place_id => binary(),
    viewport => #{southwest := lat_lng(), northeast := lat_lng()}
}.

-type geocode_result() :: #{candidates := [geocode_candidate()], raw := term()}.

-type autocomplete_prediction() :: #{
    description := binary(),
    place_id => binary(),
    structured_format => #{main_text := binary(), secondary_text => binary()}
}.

-type autocomplete_result() :: #{predictions := [autocomplete_prediction()], raw := term()}.

%% `candidate` is omitted for an unknown place.
-type place_details_result() :: #{
    candidate => geocode_candidate(),
    name => binary(),
    raw := term()
}.

-type isochrone_input() :: #{
    center := lat_lng(),
    type := time | distance,
    %% Seconds for `time`, meters for `distance`.
    values := [number()],
    travel_mode => travel_mode(),
    departure_time => departure_time(),
    passthrough => passthrough()
}.

-type isochrone_contour() :: #{
    value := float(),
    %% GeoJSON `Polygon` or `MultiPolygon`; RFC 7946 winding, holes kept.
    geometry := #{type := binary(), coordinates := list()}
}.

-type isochrone_result() :: #{
    contours := [isochrone_contour()],
    raw := term(),
    meta => #{request_count := pos_integer()}
}.

-type result(T) :: {ok, T} | {error, connector_error()}.

-define(SUPPORT, #{
    route => [google, mapbox, here, esri, osrm, tomtom],
    matrix => [google, mapbox, here, esri, osrm, tomtom],
    geocode => [google, mapbox, here, esri, tomtom],
    reverse_geocode => [google, mapbox, here, esri, tomtom],
    autocomplete => [google, mapbox, here, esri, tomtom],
    place_details => [google, mapbox, here, esri, tomtom],
    isochrone => [mapbox, here, esri, tomtom]
}).

-doc "Whether `Provider` implements `Operation`.".
-spec supports(provider(), operation()) -> boolean().
supports(Provider, Operation) ->
    lists:member(Provider, maps:get(Operation, ?SUPPORT, [])).

-doc "Compute a route through `waypoints` (all six providers).".
-spec route(config(), route_input()) -> result(route_result()).
route(Config, Input) -> call(route, Config, Input).

-doc """
Compute the origins x destinations distance/duration matrix (all six
providers). Cells a provider could not route are absent from `cells`.
""".
-spec matrix(config(), matrix_input()) -> result(matrix_result()).
matrix(Config, Input) -> call(matrix, Config, Input).

-doc "Forward-geocode `address` (all providers except OSRM).".
-spec geocode(config(), geocode_input()) -> result(geocode_result()).
geocode(Config, Input) -> call(geocode, Config, Input).

-doc "Reverse-geocode `location` (all providers except OSRM).".
-spec reverse_geocode(config(), reverse_geocode_input()) -> result(geocode_result()).
reverse_geocode(Config, Input) -> call(reverse_geocode, Config, Input).

-doc "Suggest places for the partial `input` (all providers except OSRM).".
-spec autocomplete(config(), autocomplete_input()) -> result(autocomplete_result()).
autocomplete(Config, Input) -> call(autocomplete, Config, Input).

-doc """
Resolve a `place_id` from `autocomplete/2` into a full candidate (all
providers except OSRM). For Mapbox pass the same `session_token` as the
preceding autocomplete: Search Box bills per session.
""".
-spec place_details(config(), place_details_input()) -> result(place_details_result()).
place_details(Config, Input) -> call(place_details, Config, Input).

-doc "Compute reachable-area contours around `center` (Mapbox, HERE, Esri, TomTom).".
-spec isochrone(config(), isochrone_input()) -> result(isochrone_result()).
isochrone(Config, Input) -> call(isochrone, Config, Input).

call(Op, Config0, Input0) ->
    Config = thinwrap_location_input:config(Config0),
    #{provider := Provider} = Config,
    supports(Provider, Op) orelse
        erlang:error(
            {badarg,
                iolist_to_binary([
                    atom_to_binary(Provider), " does not support ", atom_to_binary(Op)
                ])}
        ),
    Input = thinwrap_location_input:input(Op, Input0),
    Mod = provider_module(Provider),
    try Mod:Op(Config, Input) of
        Result -> {ok, Result}
    catch
        throw:{thinwrap_location_error, Error} -> {error, Error}
    end.

provider_module(google) -> thinwrap_location_google;
provider_module(mapbox) -> thinwrap_location_mapbox;
provider_module(here) -> thinwrap_location_here;
provider_module(esri) -> thinwrap_location_esri;
provider_module(osrm) -> thinwrap_location_osrm;
provider_module(tomtom) -> thinwrap_location_tomtom.
