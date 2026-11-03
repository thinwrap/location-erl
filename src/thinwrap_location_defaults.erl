-module(thinwrap_location_defaults).
-moduledoc """
Connector default lists for list-valued vendor parameters.

A passthrough REPLACES a list-valued parameter wholesale (a field-mask
header, HERE's `return` query, an `annotations` list) rather than appending to
it — an append-only merge would leave no way to remove a default. These are
exactly what the connectors send, so a caller who wants the default plus one
field can build it without copying strings:

```erlang
Mask = lists:join(<<",">>, thinwrap_location_defaults:google_routes_field_mask()
                           ++ [<<"routes.travelAdvisory">>]),
thinwrap_location:route(Config, Input#{passthrough =>
    #{headers => #{<<"X-Goog-FieldMask">> => iolist_to_binary(Mask)}}}).
```
""".

-export([
    google_routes_field_mask/0,
    google_routes_field_mask_duration_without_traffic/0,
    google_routes_field_mask_waypoint_order/0,
    google_matrix_field_mask/0,
    google_place_details_field_mask/0,
    google_place_details_field_mask_name/0,
    here_routing_return/0,
    here_matrix_attributes/0,
    mapbox_matrix_annotations/0,
    osrm_table_annotations/0,
    esri_routing_accumulate_attributes_driving/0,
    esri_routing_accumulate_attributes_walking/0,
    esri_matrix_accumulate_attributes/0
]).

-doc "Google Compute Routes `X-Goog-FieldMask`.".
-spec google_routes_field_mask() -> [binary()].
google_routes_field_mask() ->
    [
        <<"routes.legs.distanceMeters">>,
        <<"routes.legs.duration">>,
        <<"routes.distanceMeters">>,
        <<"routes.duration">>,
        <<"routes.polyline.encodedPolyline">>
    ].

-doc "Appended only when `include` names `durationWithoutTraffic`.".
-spec google_routes_field_mask_duration_without_traffic() -> [binary()].
google_routes_field_mask_duration_without_traffic() ->
    [<<"routes.legs.staticDuration">>, <<"routes.staticDuration">>].

-doc "Appended only when the request reorders waypoints (any optimize flag or `is_round_trip`).".
-spec google_routes_field_mask_waypoint_order() -> [binary()].
google_routes_field_mask_waypoint_order() ->
    [<<"routes.optimizedIntermediateWaypointIndex">>].

-doc """
Google Compute Route Matrix `X-Goog-FieldMask`. `status`/`condition` decide
whether a cell is reachable; without them an unroutable pair surfaces as a
zero cell.
""".
-spec google_matrix_field_mask() -> [binary()].
google_matrix_field_mask() ->
    [
        <<"originIndex">>,
        <<"destinationIndex">>,
        <<"distanceMeters">>,
        <<"duration">>,
        <<"status">>,
        <<"condition">>
    ].

-doc "Google Place Details `X-Goog-FieldMask` (Essentials tier).".
-spec google_place_details_field_mask() -> [binary()].
google_place_details_field_mask() ->
    [<<"id">>, <<"formattedAddress">>, <<"location">>, <<"viewport">>].

-doc "Appended only when `include` names `name`: `displayName` is a Pro-tier field.".
-spec google_place_details_field_mask_name() -> [binary()].
google_place_details_field_mask_name() ->
    [<<"displayName">>].

-doc "HERE Routing v8 `return`: summary feeds legs and totals, polyline the geometry.".
-spec here_routing_return() -> [binary()].
here_routing_return() ->
    [<<"polyline">>, <<"summary">>].

-doc "HERE Matrix v8 `matrixAttributes`; the decoder needs both.".
-spec here_matrix_attributes() -> [binary()].
here_matrix_attributes() ->
    [<<"travelTimes">>, <<"distances">>].

-doc "Mapbox Matrix `annotations`; the decoder needs both matrices.".
-spec mapbox_matrix_annotations() -> [binary()].
mapbox_matrix_annotations() ->
    [<<"duration">>, <<"distance">>].

-doc "OSRM Table `annotations`; OSRM's own default (`duration` alone) leaves no distances.".
-spec osrm_table_annotations() -> [binary()].
osrm_table_annotations() ->
    [<<"duration">>, <<"distance">>].

-doc """
Esri route `accumulateAttributeNames` for driving. The time attribute must
match the travel mode's impedance or Esri silently returns no cumulative time.
""".
-spec esri_routing_accumulate_attributes_driving() -> [binary()].
esri_routing_accumulate_attributes_driving() ->
    [<<"TravelTime">>, <<"Kilometers">>].

-doc "Esri route `accumulateAttributeNames` for walking.".
-spec esri_routing_accumulate_attributes_walking() -> [binary()].
esri_routing_accumulate_attributes_walking() ->
    [<<"WalkTime">>, <<"Kilometers">>].

-doc "Esri OD cost matrix `accumulateAttributeNames`; Kilometers is the distance column.".
-spec esri_matrix_accumulate_attributes() -> [binary()].
esri_matrix_accumulate_attributes() ->
    [<<"Kilometers">>].
