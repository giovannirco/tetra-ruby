# The Tetra contract

Tetra is implemented four times: [Go](https://github.com/giovannirco/tetra-go), [Ruby](https://github.com/giovannirco/tetra-ruby), [Node.js](https://github.com/giovannirco/tetra-node) and [TypeScript](https://github.com/giovannirco/tetra-ts). All four behave the same way, byte for byte where it matters, and `scripts/smoke.sh` checks it. Any implementation can sit behind the same Service, dashboard and alerts.

## Arithmetic

| Method and path | Operation |
|---|---|
| `GET /api/sum?term_one=<a>&term_two=<b>` | a + b |
| `GET /api/sub?term_one=<a>&term_two=<b>` | a − b |
| `GET /api/mul?term_one=<a>&term_two=<b>` | a × b |
| `GET /api/div?term_one=<a>&term_two=<b>` | a ÷ b, truncated toward zero |

Success is `200` with `{"result":<integer>}`, for example `GET /api/sub?term_one=4&term_two=1` → `{"result":3}`.

**Numbers.** Terms and results are signed 64-bit integers (−9223372036854775808 to 9223372036854775807). A term is an optional `+` or `-` followed by decimal digits; nothing else is accepted, so `1.5`, `1e3`, ` 4` and `0x10` are rejected. Integer results mean division truncates toward zero: `7/2 = 3`, `-7/2 = -3`. A result outside the 64-bit range is an error, never a wrapped value. The Ruby and JavaScript runtimes have arbitrary-size or floating-point numbers, and they enforce the same range explicitly.

**Errors** are `400` with `{"error":"<message>"}`. The first problem found is reported, term_one before term_two.

| Case | Message |
|---|---|
| parameter missing or empty | `missing query parameter term_one` |
| not an integer | `term_one must be an integer, got "abc"` (the value is cut to 32 characters) |
| outside the 64-bit range | `term_one is outside the 64-bit integer range` |
| division by zero | `division by zero` |
| result overflows | `result overflows a 64-bit integer` |

Other `/api/*` paths: `404 {"error":"not found"}`. A known operation called with a method other than GET or HEAD: `405 {"error":"method not allowed"}` plus `Allow: GET, HEAD`.

## Catalogue

`GET /api` lists the operations, so clients and the UI never hard-code them:

```json
{"service":"tetra","implementation":"go","version":"v0.1.0",
 "operations":[{"name":"sum","symbol":"+","label":"Addition","path":"/api/sum"}, …]}
```

## Operations endpoints

| Path | Purpose |
|---|---|
| `GET /healthz` | Liveness. `200 {"status":"ok"}` while the process can serve. Checks no dependencies. |
| `GET /readyz` | Readiness. `200 {"status":"ready"}`; `503 {"status":"draining"}` once shutdown has started. |
| `GET /metrics` | Prometheus text format. |
| `GET /version` | `service`, `implementation`, `version`, `commit`, `build_date`, `runtime`, `hostname` (the pod name in Kubernetes), `started_at`. |
| `GET /events` | Server-Sent Events: one `calc` event per calculation on this instance. |
| `GET /` | The web UI. |

Every response carries `X-Request-Id`: a valid incoming one (up to 64 of `[A-Za-z0-9._-]`) is kept, otherwise one is generated. JSON responses are `application/json; charset=utf-8` with `Cache-Control: no-store`. Responses carry a strict `Content-Security-Policy` (same origin only) plus `X-Content-Type-Options`, `Referrer-Policy` and `X-Frame-Options`.

### Live event

```json
{"operation":"sub","term_one":"4","term_two":"1","result":"3","status":200,"outcome":"ok",
 "duration_ms":0.021,"request_id":"…","time":"2026-10-08T12:00:00Z"}
```

`result` is a string (or `null` on error) so 64-bit values survive JavaScript. `error` is present on failures. `outcome` is one of `ok`, `invalid_input`, `division_by_zero`, `overflow`. A slow subscriber loses events instead of slowing requests down; the stream sends a keep-alive comment every 15 s and closes when the server shuts down.

## Metrics

| Metric | Type | Labels |
|---|---|---|
| `tetra_http_requests_total` | counter | `method`, `route`, `status` |
| `tetra_http_request_duration_seconds` | histogram | `method`, `route` (not recorded for `/events`) |
| `tetra_http_requests_in_flight` | gauge | |
| `tetra_calc_operations_total` | counter | `operation`, `outcome` |
| `tetra_live_subscribers` | gauge | |
| `tetra_live_events_dropped_total` | counter | |
| `tetra_build_info` | gauge (always 1) | `implementation`, `version`, `commit`, `runtime` |

`route` is the matched route template (`/api/sum`, `/healthz`, `/` for UI files, `/api/` for the 404/405 fallback, `unmatched` otherwise), so its values are bounded no matter what paths clients send. Histogram buckets (seconds): 0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1. Each implementation also exports its runtime's standard process metrics.

## Logs

One JSON object per line on stdout. Each request logs `msg: "request"` with `method`, `path`, `route`, `status`, `duration_ms`, `request_id`, `remote_addr`, `user_agent` (plus `bytes` where the runtime exposes it). Probes and scrapes are logged at debug level unless they fail.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `8000` | Listen port |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `DRAIN_DELAY_SECONDS` | `5` | Seconds between failing readiness and closing the listener on SIGTERM |
| `SHUTDOWN_TIMEOUT_SECONDS` | `10` | Upper bound for in-flight requests to finish |
| `MAX_LIVE_STREAMS` | `100` | Concurrent `/events` connections; more get `503` |

## Shutdown

On SIGTERM or SIGINT: readiness turns `503`, the server keeps serving for `DRAIN_DELAY_SECONDS` so the endpoints controller and load balancers stop sending traffic, live streams are closed, in-flight requests get up to `SHUTDOWN_TIMEOUT_SECONDS`, and the process exits 0.
