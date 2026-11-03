-module(thinwrap_location_transport).
-moduledoc """
The bring-your-own HTTP seam.

The library never depends on a third-party HTTP client. It defines this one
callback and ships `thinwrap_location_httpc` (OTP `httpc`) as the default. To
use `hackney`, `gun`, `Finch`, … implement the behaviour and pass it in the
config:

```erlang
Config = #{provider => google, api_key => Key,
           transport => {my_hackney_transport, #{pool => maps}}}.
```

`request/2` sends one request and returns one response. Rules:

- A non-2xx answer is a **response**, never an error: return
  `{ok, #{status := 404, ...}}`. The connector owns status-to-error mapping.
- Return `{error, timeout}` (or any term containing the atom `timeout`) when
  the request timed out, so callers get the `timeout` code rather than
  `provider_unavailable`.
- Any other `{error, Reason}` is reported as `provider_unavailable`. The
  reason is rendered to a redacted string; it is never returned as a term,
  because a client's error may embed the request URL and its credentials.
- `{error, {connector_error, Error}}` surfaces a ready-made
  `t:thinwrap_location:connector_error/0` unchanged (the default transport
  uses it to refuse non-`https` URLs).
- Never follow redirects: a 3xx must come back as a response, or the
  provider's credentials would be re-sent to wherever it points.
""".

-export_type([request/0, response/0, headers/0, method/0, transport/0]).

-type method() :: get | post.
%% Header names as given by the connector (request) or lower-cased (response).
-type headers() :: #{binary() => binary()}.

-type request() :: #{
    method := method(),
    url := binary(),
    headers := headers(),
    body => binary()
}.

%% `headers` keys MUST be lower-cased; repeated headers joined with `", "`.
-type response() :: #{
    status := 100..599,
    headers := headers(),
    body := binary()
}.

-type transport() :: {module(), Opts :: term()}.

-callback request(Request :: request(), Opts :: term()) ->
    {ok, response()} | {error, term()}.
