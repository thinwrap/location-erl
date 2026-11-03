# `thinwrap_location` (Erlang) — contributor guide

This folder (`.ai/`) is for developers — and the coding agents working alongside
them — who are **changing this library**. It is not usage documentation.

> **Using the package?** See [`../README.md`](../README.md). `.ai/` is contributor-only.

## Map of this folder

- **guidelines.md** (this file) — entry point + the "add a connector" recipe.
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — public module → provider module → shared HTTP seam, and the invariants.
- [`CONVENTIONS.md`](./CONVENTIONS.md) — data shapes, error handling, naming, testing.

## The shape in one sentence

A consumer calls `thinwrap_location:Op(Config, Input)`; the config's `provider`
key selects a provider module (`thinwrap_location_<provider>`), which builds the
request, sends it through `thinwrap_location_http` (the injectable transport +
transport-error normalization), and normalizes the answer. No global middleware.

## Setup & verify

```bash
rebar3 compile
rebar3 do eunit, cover        # ≥80% total line coverage
rebar3 xref
rebar3 dialyzer
rebar3 lint                   # Elvis, policy in elvis.config
rebar3 hank                   # dead code
scripts/eqwalize.sh           # eqWAlizer over src/ (needs elp + Java 11+)
rebar3 fmt --check            # erlfmt
```

`scripts/eqwalize.sh` runs eqWAlizer through ELP: `brew install
erlang-language-platform` (or a release binary from
github.com/WhatsApp/erlang-language-platform) and a Java 11+ runtime on
`PATH` (with Homebrew's keg-only JDK:
`PATH=/opt/homebrew/opt/openjdk/bin:$PATH scripts/eqwalize.sh`). It checks
`src/` only: tests pass mistyped inputs on purpose to assert `badarg`.

OTP ≥ 27 (the stdlib `json` module). **Zero runtime dependencies — do not add
any.** HTTP is OTP `httpc` behind a behaviour; JSON is OTP `json`; SigV4/HMAC,
if ever needed, is hand-rolled on `crypto`.

## Add a connector

The Python sibling (`../location-py/src/thinwrap/location/_<provider>.py`) is
the reference port: same requests, same normalization, same error mapping.

1. **Provider module** — `src/thinwrap_location_<provider>.erl`, `-moduledoc false`,
   exporting one function per supported operation with the public name and
   arity `Op(Config, Input)` (`route/2`, `matrix/2`, `geocode/2`, …). Vendor
   error mapping and response navigation are private functions in the same module.
2. **Dispatch** — add the provider to `?SUPPORT` and `provider_module/1` in
   `thinwrap_location.erl`, and its credential keys to `?CREDENTIAL_KEYS` in
   `thinwrap_location_input.erl`.
3. **Tests** — `test/thinwrap_location_<provider>_tests.erl` (eunit), ported
   from the Python `tests/test_<provider>.py`; use
   `thinwrap_location_fake_transport:config/2`.

### Definition of done (the CI gates)

```bash
rebar3 do eunit, cover && rebar3 cover --min_coverage=80 && rebar3 xref && \
  rebar3 dialyzer && rebar3 lint && rebar3 hank && scripts/eqwalize.sh && \
  rebar3 fmt --check && rebar3 hex build
```

## Invariants you must not break

- **Zero runtime deps / no vendor SDKs.**
- **Stateless wrapper.** No caching, retries, idempotency keys, telemetry, and
  no processes, ETS tables or application env. (HERE/TomTom async-matrix
  submit/poll/retrieve is transient, inside one call.)
- **≥90% baseline-coverage rule.** A field belongs on the normalized input
  only if ≥90% of that operation's providers support it; everything else goes
  to `passthrough` (input) / `raw` (output).
- **Normalize at the wire layer.** meters / seconds / `#{lat, lng}` / Google
  precision-5 polyline. The four polyline utilities are locked.
- **Per-connector locality.** Vendor error mapping and outlier translation live
  in the provider module — never in `thinwrap_location_http`.
- **Error codes** — 6 canonical + 7 location-extended, the same strings as the
  siblings, as atoms. The raw `Retry-After` rides in `cause` as `<<"retryAfter">>`.
- **Two kinds of failure** — operation failures are `{error, connector_error()}`;
  misuse raises `{badarg, Description}`. See CONVENTIONS.
