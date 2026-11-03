-module(thinwrap_location_matrix).
-moduledoc false.

%% Matrix helpers shared across connectors: the Mapbox/OSRM duration +
%% distance grid decoder, and the async-matrix (HERE, TomTom) polling budget.

-export([dimensions_ok/4, grid_cells/4, poll_deadline/1, strip_timeout/1]).
-export([poll_initial_delay_ms/0, poll_max_delay_ms/0, poll_backoff/0]).

-define(POLL_INITIAL_DELAY_MS, 1000).
-define(POLL_MAX_DELAY_MS, 5000).
-define(POLL_BACKOFF, 1.5).
-define(POLL_DEFAULT_DEADLINE_MS, 60000).

-doc false.
-spec poll_initial_delay_ms() -> pos_integer().
poll_initial_delay_ms() -> ?POLL_INITIAL_DELAY_MS.
-doc false.
-spec poll_max_delay_ms() -> pos_integer().
poll_max_delay_ms() -> ?POLL_MAX_DELAY_MS.
-doc false.
-spec poll_backoff() -> float().
poll_backoff() -> ?POLL_BACKOFF.

-doc false.
%% Whether both tables are lists of at least `No` rows of at least `Nd`
%% entries — anything else cannot be indexed as the requested grid.
-spec dimensions_ok(term(), term(), non_neg_integer(), non_neg_integer()) -> boolean().
dimensions_ok(Durs, Dists, No, Nd) when is_list(Durs), is_list(Dists) ->
    length(Durs) >= No andalso length(Dists) >= No andalso
        lists:all(
            fun({Du, Di}) ->
                is_list(Du) andalso is_list(Di) andalso length(Du) >= Nd andalso length(Di) >= Nd
            end,
            lists:zip(lists:sublist(Durs, No), lists:sublist(Dists, No))
        );
dimensions_ok(_, _, _, _) ->
    false.

-doc false.
%% Cells from a Mapbox/OSRM-shaped grid. Both return `null` for an unroutable
%% pair; that cell — like any non-number — is omitted rather than coerced to
%% 0, which would read as "same location". Call `dimensions_ok/4` first.
-spec grid_cells(term(), term(), non_neg_integer(), non_neg_integer()) ->
    [thinwrap_location:matrix_cell()].
grid_cells(Durs, Dists, No, Nd) when is_list(Durs), is_list(Dists) ->
    [
        #{
            origin_index => I,
            destination_index => J,
            distance_meters => float(Di),
            duration_seconds => float(Du)
        }
     || {I, DuRow, DiRow} <- lists:zip3(
            lists:seq(0, No - 1), lists:sublist(Durs, No), lists:sublist(Dists, No)
        ),
        %% Always true after dimensions_ok/4; states the row type.
        is_list(DuRow),
        is_list(DiRow),
        {J, Du, Di} <- lists:zip3(
            lists:seq(0, Nd - 1), lists:sublist(DuRow, Nd), lists:sublist(DiRow, Nd)
        ),
        is_number(Du),
        is_number(Di)
    ].

-doc false.
%% The async-matrix deadline in ms: 60 s, or the caller's
%% `passthrough => #{body => #{timeoutMs => N}}`. `timeoutMs` must be a number
%% greater than 0; anything else is `invalid_request` before any request — a
%% value that cannot be a deadline is a caller mistake, and falling back to
%% the default would poll for a budget the caller never asked for.
-spec poll_deadline(map()) -> number().
poll_deadline(Input) ->
    case maps:find(<<"timeoutMs">>, thinwrap_location_passthrough:body(Input)) of
        error ->
            ?POLL_DEFAULT_DEADLINE_MS;
        {ok, Ms} when is_number(Ms), Ms > 0 ->
            Ms;
        {ok, Other} ->
            thinwrap_location_error:fail(
                thinwrap_location_error:invalid_request(
                    iolist_to_binary(
                        io_lib:format(
                            "passthrough timeoutMs must be a finite number of milliseconds "
                            "greater than 0 (got ~0tP)",
                            [Other, 5]
                        )
                    )
                )
            )
    end.

-doc false.
%% `Input` with `timeoutMs` removed from the passthrough body, so the control
%% value never goes on the wire. The caller's map is not changed.
-spec strip_timeout(map()) -> map().
strip_timeout(#{passthrough := #{body := Body} = Pt} = Input) ->
    Input#{passthrough := Pt#{body := maps:without([timeoutMs, <<"timeoutMs">>], Body)}};
strip_timeout(Input) ->
    Input.
