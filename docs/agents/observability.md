---
scribe:
  scan: "c0eb538903d7019b3401d4c399e9641f0e0c4eff"
  freshness: 100
  human_input: 0
  completeness: 100
  inferred_sections:
    - id: key-entry-points
      heading: "## Key Entry Points"
    - id: patterns--conventions
      heading: "## Patterns & Conventions"
    - id: gotchas
      heading: "## Gotchas"
    - id: dependencies--context
      heading: "## Dependencies & Context"
    - id: links
      heading: "## Links"
  watch_paths:
    - "src/metrics.rs"
    - "src/metrics/server.rs"
    - "src/metrics/process.rs"
    - "src/metrics/meta.rs"
    - "src/telemetry.rs"
    - "src/admin.rs"
    - "src/readiness.rs"
    - "src/readiness/server.rs"
    - "src/proxy/metrics.rs"
    - "src/dns/metrics.rs"
  stale_flags: []
---

# Observability

> This doc covers ztunnel's metrics, logging, admin server, and readiness subsystems.
> For proxy data plane behavior and connection handling, see [proxy-data-plane.md](proxy-data-plane.md).
> For DNS-specific metrics, see [dns-resolution.md](dns-resolution.md).

## Key Entry Points
- `src/metrics/server.rs`: `Server` — HTTP server exposing `/metrics` and `/stats/prometheus` endpoints. Uses `prometheus_client::encoding::text::encode` to serialize the registry. Supports OpenMetrics content negotiation via `Accept` header.
- `src/proxy/metrics.rs`: `Metrics` — connection-level metrics: `istio_tcp_connections_opened`, `istio_tcp_connections_closed`, `istio_tcp_received_bytes`, `istio_tcp_sent_bytes`, `istio_tcp_connection_failures`, `istio_open_sockets` (gauge), `istio_on_demand_dns`. Uses `CommonTrafficLabels` with 20+ labels (source/destination workload, namespace, identity, service, locality, etc.).
- `src/proxy/metrics.rs`: `ConnectionResult` — per-connection metric tracker. Increments `connection_opens` on creation, tracks bytes atomically, records `connection_close` and access log on drop. Pre-fetches `Counter` handles at creation to avoid ~300ns lookup per read/write.
- `src/dns/metrics.rs`: `Metrics` — DNS-specific metrics: `istio_dns_requests`, `istio_dns_upstream_requests`, `istio_dns_upstream_failures`, `istio_dns_upstream_request_duration_seconds`.
- `src/metrics/meta.rs`: `Metrics` — build info gauge: `istio_build{component="ztunnel", tag="<istio_version>"}`.
- `src/metrics/process.rs`: `ProcessMetrics` — process-level metrics: `process_open_fds` (from `/dev/fd`) and `process_max_fds` (from `RLIMIT_NOFILE`).
- `src/metrics.rs`: `Recorder`, `IncrementRecorder`, `DeferRecorder` traits — shared metric recording abstractions. `DefaultedUnknown<T>` wrapper encodes `None` as `"unknown"` in Prometheus labels.
- `src/telemetry.rs`: `setup_logging()` — configures tracing-subscriber with Istio-compatible formatting (plain or JSON via `LOG_FORMAT` env var). `set_level()`/`get_current_loglevel()` enable runtime log level changes. Default filter: `hickory_server::server=off,info`.
- `src/admin.rs`: `Service` — admin HTTP server with endpoints: `/config_dump`, `/logging`, `/quitquitquit`, `/debug/pprof/profile` (Linux), `/debug/pprof/heap` (jemalloc), `/` (dashboard).
- `src/readiness.rs`: `Ready` — tracks pending startup tasks via `HashSet<String>` behind `Arc<Mutex>`. `BlockReady` guard removes task on drop. `/healthz/ready` returns 200 when all tasks complete.

## Patterns & Conventions

### Metric Registration
All metrics are registered with a `prometheus_client::registry::Registry`. The registry is partitioned:
- `sub_registry("istio")` creates an `istio_` prefix for all application metrics
- Connection metrics: `istio_tcp_connections_opened`, `istio_tcp_connections_closed`, `istio_tcp_received_bytes`, `istio_tcp_sent_bytes`
- DNS metrics: `istio_dns_requests`, `istio_dns_upstream_requests`, etc.
- Build info: `istio_build`
- Process metrics: `process_open_fds`, `process_max_fds` (no `istio_` prefix)

### Connection Metrics and Access Logging
`ConnectionResult` combines metric recording and access logging into a single object:
1. On creation: increments `connection_opens`, pre-fetches `Counter` handles for sent/recv bytes, emits `DEBUG` access log for "connection opened"
2. During connection: `increment_send()`/`increment_recv()` use atomic `AtomicU64` for local tracking plus direct `Counter::inc_by()` for the aggregated metric
3. On completion: `record()` increments `connection_close`, emits `INFO`/`ERROR` access log with bytes sent/recv, duration, and response flags
4. On drop without `record()`: automatically records with `ClosedFromDrain` error

Access logs use `target: "access"` with `parent: None` to bypass span context and use a flat structure with `src.*` and `dst.*` fields.

### CommonTrafficLabels
The `CommonTrafficLabels` struct carries 20+ labels matching Istio's standard traffic metric labels. Key design choices:
- `source_principal` is set from `DerivedWorkload` (TLS handshake identity), not from `Workload` (xDS state), because the TLS identity is most trustworthy
- `DefaultedUnknown<T>` encodes missing values as `"unknown"` rather than empty strings
- `OptionallyEncode<LocalityLabels>` omits locality labels entirely when not available, rather than encoding empty values
- `ResponseFlags` encodes as `"-"` (none), `"DENY"` (auth policy), `"CONNECT"` (connection failure), `"TLS_FAILURE"`, `"H2_HANDSHAKE_FAILURE"`, `"NETWORK_POLICY"`, or `"IDENTITY_ERROR"`

### Log Formatting
Two formats configured via `LOG_FORMAT` environment variable:
- **Plain** (`IstioFormat`): `<timestamp>\t<level>\t<target>\t<message>\t<fields>` — matches Istio's standard log format
- **JSON** (`IstioJsonFormat`): `{"level":"info","time":"...","scope":"...","message":"..."}` — structured JSON with scope as target

The log target is stripped of the `ztunnel::` prefix for brevity. Span fields are included as `:<span_name>{fields}` in plain format and nested JSON objects in JSON format.

### Dynamic Log Level
The admin server's `/logging` endpoint supports runtime log level changes:
- `POST /logging?level=debug` — sets global level
- `POST /logging?level=ztunnel::proxy=debug,info` — sets module-specific levels
- `POST /logging?reset=true` — resets to default
- `POST /logging` — lists current level

Uses `tracing_subscriber::reload::Handle` to swap the filter without restarting. `hickory_server::server` is always set to `off` by default because it's noisy.

### Readiness System
`Ready` uses a `HashSet<String>` behind `Arc<Mutex>`:
- `register_task("name")` adds a task and returns `BlockReady`
- Dropping `BlockReady` removes the task
- `BlockReady::subtask()` creates nested dependencies
- `/healthz/ready` returns 200 when the set is empty, 500 with pending task names otherwise
- Task completion logs include elapsed time since `APPLICATION_START_TIME`

### Admin Config Dump
`/config_dump` serializes the entire proxy state as JSON:
- `DemandProxyState` (all workloads, services, policies)
- `Config` (runtime configuration)
- `BuildInfo` (version information)
- Certificate dump: identity, state (Available/Initializing/Unavailable), PEM-encoded cert chains and roots with serial numbers and validity dates
- Custom `AdminHandler` extensions (e.g., in-pod mode state)

## Gotchas
- **`CommonTrafficLabels` retains ~600 bytes per connection**: The full label set is stored in `ConnectionResult` for the connection's lifetime. The TODO notes this could be optimized by pre-fetching metric handles at initialization.
- **Metric counter pre-fetching**: `ConnectionResult::new()` calls `get_or_create()` (~300ns) once to get the `Counter` handle, then uses direct atomic adds (~1ns) per byte increment. Do not replace this with repeated `get_or_create()` calls in the data path.
- **Istio byte counter flip**: Istio swaps sent/received bytes for `source` reporter. Access logs unflip this: `bytes_sent` for source reporter is actually `recv` counter. See `https://github.com/istio/istio/issues/32399`.
- **Access log on drop**: If `ConnectionResult` is dropped without calling `record()`, it automatically records with a `ClosedFromDrain` error. This is a safety net — always call `record()` explicitly.
- **pprof/heap endpoints are conditional**: CPU profiling (`/debug/pprof/profile`) only works on Linux with `pprof` crate (10-second profile at 1000 Hz). Heap profiling (`/debug/pprof/heap`) requires the `jemalloc` feature flag.
- **Non-blocking log writer**: `tracing_appender::non_blocking` with `lossy(false)` and 1000-line buffer. If the buffer fills, the writing thread blocks — this prevents log loss but can cause backpressure.
- **Log filter reload is additive by default**: `set_level(false, level)` appends to the current filter. Only `set_level(true, level)` resets first. Duplicate directives are handled by `filter::Targets::parse()`.
- **Process metrics read `/dev/fd`**: On non-Linux platforms, this path may not exist or behave differently.
- **OpenMetrics content negotiation**: The `/metrics` endpoint returns OpenMetrics format only when the `Accept` header contains `application/openmetrics-text`. Otherwise, it falls back to plain text Prometheus exposition format.

## Dependencies & Context
- **`prometheus_client`**: The metrics library used for all metric types (Counter, Gauge, Histogram, Family). Uses the `EncodeLabelSet` derive macro for label structs. Not the more common `prometheus` crate.
- **`tracing` / `tracing-subscriber`**: Structured logging framework. `tracing_subscriber::reload` enables runtime filter changes. `tracing_appender::non_blocking` provides async-safe stdout writing.
- **`hyper` (via `hyper_util`)**: Both admin and metrics servers use a shared `hyper_util::Server<T>` abstraction that binds HTTP, holds typed state, and supports drain.
- **`pprof` crate**: CPU profiling on Linux. Builds a profile guard, sleeps 10 seconds, generates pprof protobuf output.
- **`jemalloc_pprof`**: Heap profiling via jemalloc's `prof.dump`. Requires the `jemalloc` Cargo feature.
- **`chrono`**: Used in admin to format certificate timestamps as RFC3339.
- **Three HTTP servers**: ztunnel runs three separate HTTP servers — admin (`config.admin_addr`), metrics/stats (`config.stats_addr`), and readiness (`config.readiness_addr`). Each binds independently.

## Links
- [Proxy Data Plane](proxy-data-plane.md) -- connection metrics originate from proxy handlers
- [TLS and Crypto](tls-and-crypto.md) -- certificate dump in admin config_dump
- [DNS Resolution](dns-resolution.md) -- DNS-specific metrics
- [In-Pod Mode](inpod-mode.md) -- WorkloadManagerAdminHandler extends config_dump
- [src/proxy/metrics.rs](../../src/proxy/metrics.rs) -- connection metrics and access logging
- [src/admin.rs](../../src/admin.rs) -- admin API server
- [src/telemetry.rs](../../src/telemetry.rs) -- logging setup and runtime level control
