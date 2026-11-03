# Conventions — `thinwrap_location` (Erlang)

## Files and names

- Every module is prefixed `thinwrap_location_` (Erlang has one global module
  namespace). Provider modules: `thinwrap_location_<provider>.erl`.
- Internal modules carry `-moduledoc false.`; internal exported functions
  carry `-doc false.`. Every exported function has a `-spec`
  (`warn_missing_spec` is on, `warnings_as_errors` too).
- Formatting is erlfmt (`rebar3 fmt`); CI runs `rebar3 fmt --check`.
- Lint is Elvis (`rebar3 lint`); the policy and every deviation from Elvis's
  defaults, with its reason, live in `elvis.config`. Elvis reads unexpanded
  source, so call other modules by their literal name (no `?ALIAS:f()` macros)
  and do not `-import`.
- Dead code is rebar3_hank (`rebar3 hank`): no unused macros, records,
  includes or callbacks.
- Types are checked by Dialyzer and eqWAlizer (`scripts/eqwalize.sh`, `src/`
  only; needs `brew install erlang-language-platform` and Java 11+). Decoded
  vendor JSON is `term()`: narrow it with a guard or pattern the code path
  already guarantees, not a cast. Add no eqWAlizer support dependency.
- Comments explain WHY (vendor quirks, live-verified behaviour, billing), not
  the history of the change.

## Data shapes

| Thing | Shape |
|---|---|
| normalized input/output | map, **atom** keys (`total_distance_meters`) |
| strings | binaries, UTF-8 |
| closed vocabularies | atoms, byte-identical to the sibling string values (`driving`, `durationWithoutTraffic`, `privateBus`) |
| coordinates | `#{lat := number(), lng := number()}` |
| absent optional output | key **omitted** (use `thinwrap_location_util:put_opt/3`) — never `undefined`/`null`/`nil` |
| distances / durations in results | floats (`thinwrap_location_json:num/1`) |
| vendor JSON (request bodies, `raw`) | maps with **binary** keys; decoded JSON `null` is the atom `null` |
| query strings | ordered `[{binary(), binary() \| [binary()]}]`; a list value repeats the key |
| departure time input | Unix seconds, UTC `calendar:datetime()`, or RFC 3339 binary |

Request bodies use binary keys so a caller's `passthrough.body` (keys
converted to binaries) deep-merges onto them.

## Two kinds of failure

- **Operation failure** → `{error, connector_error()}`: vendor error, transport
  failure/timeout, request *data* the vendor would reject (`invalid_request`),
  capability rejection (`unsupported_*`). Inside a connector:
  `thinwrap_location_error:fail(thinwrap_location_error:invalid_request(Msg))`
  and friends (`classified/4`, `unknown/3`, `provider_error/5`).
- **Misuse** → `erlang:error({badarg, Description})`, raised by
  `thinwrap_location_input` before any HTTP: unknown/missing keys, wrong types,
  enum atom outside its set, provider lacking the operation. Descriptions never
  include config values (they may be credentials), and no public function may
  fail with a `function_clause` on the config (its args would be printed).

Where the Python sibling raises `ConnectorError`, Erlang returns `{error, _}`;
where it raises `TypeError`/`ValueError`, Erlang raises `badarg`. Keep that
mapping exact — `tests/test_error_contract.py` in the sibling is the reference.

## Error mapping

Each provider module has a private `map_vendor_error(Status, Body)`. Build the
non-2xx error with `thinwrap_location_error:provider_error(Status, Headers,
Body, Code, ProviderMessage)` — it adds the `Retry-After` surfacing and
redaction. An in-body error on a 2xx uses `classified/4`. A 2xx the connector
cannot interpret is `unknown`, never an empty result.

## Credentials

Read them with `thinwrap_location_input:secret(Config, Key)` at the point of
use (a credential may be a fun/0). Never put a credential in an error message
or cause; redaction (`thinwrap_location_util:redact_credentials/1`) is
defense-in-depth, not the plan.

## Testing

- eunit, one `test/thinwrap_location_<area>_tests.erl` per Python test file.
- `thinwrap_location_fake_transport:config(Config, Responses)` returns
  `{Config1, Pid}`: queued responses (`resp/2,3`, `gzip_resp/2`, or
  `{error, Reason}`), recorded requests via `calls/1` / `last/1`, helpers
  `qget/2`, `qall/2`, `path_of/1`, `body_json/1`, `body_form/1`, `header/2`.
  Poll sleep is already a no-op.
- Assert the captured request (URL, query, headers, body), the normalized
  result, and the error `code`/`status`.
- `thinwrap_location_httpc_tests` exercises the real adapter against a local
  TLS listener; no test touches the network.
