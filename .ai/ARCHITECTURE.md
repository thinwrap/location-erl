# Architecture — `thinwrap_location` (Erlang)

## Public module → provider module → HTTP seam

```
thinwrap_location:route(Config, Input)
   │  thinwrap_location_input:config/1   badarg on misuse (keys, types, transport)
   │  supports(Provider, route)          badarg if the provider lacks the op
   │  thinwrap_location_input:input/2    badarg on misuse; fills defaults
   ▼
thinwrap_location_google:route(Config, Input)          (provider module)
   │  builds body/headers/query, merges passthrough
   ▼
thinwrap_location_http:send_post_json/5                (shared seam)
   │  {Mod, Opts} = transport;  Mod:request(Req, Opts)
   ▼
thinwrap_location_httpc (default) | caller's module    (transport behaviour)
```

- **One public module.** `thinwrap_location` exports one function per operation.
  It validates, dispatches, and converts a thrown connector error into
  `{error, Error}`. Nothing else in the library is called by consumers except
  `thinwrap_location_polyline`, `thinwrap_location_defaults`, and the
  `thinwrap_location_transport` behaviour.
- **Config-as-selector.** `#{provider => google, api_key => K}`; the provider
  atom picks the module. Unknown config keys are misuse (catches typos such as
  `apikey`), as are credential values that are neither a binary nor a fun/0.
- **`thinwrap_location_http`** centralizes only the HTTP seam: request
  assembly, case-insensitive header merge, the transport call, and
  transport-failure normalization — `{error, Reason}` → `provider_unavailable`,
  or `timeout` when the atom `timeout` appears anywhere in `Reason`; the reason
  is kept only as a credential-redacted string. A crashing transport is treated
  the same way; a transport that returns a malformed value raises
  `{bad_transport_return, Mod, Shape}` (caller bug, not an outage). No JSON
  parsing, no error mapping.

## Non-local failure

Connector code fails with `thinwrap_location_error:fail(Error)`, which throws
`{thinwrap_location_error, Error}`. Only `thinwrap_location:call/3` (and the
public polyline decoders) catch it. This keeps provider code linear — the
Python sibling raises `ConnectorError` the same way — while the public surface
stays `{ok, _} | {error, _}`.

## Location-distinctive invariants

Same as the siblings; see `../location-py/.ai/ARCHITECTURE.md` for the full
reasoning. In short: wire-layer normalization; four locked polyline utilities
(tested against `test/data/parity-vectors.json`); per-connector error mapping;
OSRM requires `base_url` (validated per operation); HERE always / TomTom
(> 100 cells) async matrix with 1 s → ×1.5 → 5 s backoff and a 60 s default
deadline (`passthrough.body.timeoutMs`), `matrix_polling_timeout` on expiry;
grid-coverage assertions before flattening.

## Erlang-specific choices

- **Synchronous calls** in the caller's process. The library starts no
  processes; async-matrix polling sleeps with the configurable `sleep` fun
  (default `timer:sleep/1`).
- **Maps everywhere**, atom keys for normalized data, binary keys for vendor
  JSON (`raw`, request bodies). No records in the public API — they are awkward
  from Elixir and Gleam.
- **Default transport** `thinwrap_location_httpc`: HTTPS only, 30 s timeout,
  never follows redirects, binary bodies, names itself in `User-Agent`, uses
  OTP's verified-TLS defaults (passing any `ssl` option replaces them).
- **BEAM floats are always finite**, so the siblings' NaN/Infinity rejections
  have no Erlang equivalent; a non-number where a number is expected is badarg.
