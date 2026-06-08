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
    - "src/xds.rs"
    - "src/xds/client.rs"
    - "src/xds/types.rs"
    - "src/xds/metrics.rs"
    - "src/state.rs"
    - "src/state/workload.rs"
    - "src/state/service.rs"
    - "src/state/policy.rs"
    - "src/rbac.rs"
  stale_flags: []
---

# xDS and State Management

> This doc covers the xDS client (delta ADS), the in-memory proxy state (workloads, services,
> policies), RBAC enforcement, and load balancing. For how the proxy uses this state to route
> traffic, see [proxy-data-plane.md](proxy-data-plane.md). For TLS on the xDS connection,
> see [tls-and-crypto.md](tls-and-crypto.md).

## Key Entry Points
- `src/state.rs`: `ProxyState` (workloads, services, policies stores), `DemandProxyState` (adds on-demand fetching and DNS resolution), `ProxyStateManager` (creates xDS client or local config loader and wires up state). Contains RBAC evaluation logic in `DemandProxyState::assert_rbac()` and upstream resolution in `ProxyState::find_upstream()`.
- `src/xds.rs`: `ProxyStateUpdateMutator` applies xDS updates to `ProxyState`. Implements `Handler<XdsWorkload>`, `Handler<XdsAddress>`, and `Handler<XdsAuthorization>`. Also contains `LocalClient` for file-based config in testing.
- `src/xds/client.rs`: `AdsClient` — delta ADS gRPC client. Manages subscriptions, on-demand requests, reconnection with backoff, and NACK handling. `Config` builder pattern for registering type-specific handlers.
- `src/state/workload.rs`: `Workload` struct and `WorkloadStore` — indexed by UID and IP address. Defines `InboundProtocol`, `OutboundProtocol`, `NetworkMode`, `HealthStatus`, `Locality`, `GatewayAddress`, `ApplicationTunnel`.
- `src/state/service.rs`: `Service` struct and `ServiceStore` — indexed by VIP (NetworkAddress), CIDR VIP (NetworkCidr), and hostname. Services now support CIDR-based VIPs alongside exact-IP VIPs. `EndpointSet` maps workload UIDs to endpoints with port mappings.
- `src/state/policy.rs`: `PolicyStore` — stores RBAC `Authorization` policies indexed by namespace and key. Uses `watch::channel` to notify `PolicyWatcher` of changes.
- `src/rbac.rs`: `Authorization` and `RbacMatch` types for L4 RBAC policy evaluation. Supports allow/deny actions with namespace, global, and workload-selector scopes.

## Patterns & Conventions

### Delta ADS Protocol
The xDS client uses **delta ADS** (Aggregated Discovery Service), not SotW (State of the World). This means:
- Resources are sent incrementally (updates + removals) rather than full snapshots
- The client tracks `known_resources` per type URL
- On-demand requests use `resource_names_subscribe` to request specific resources by name
- NACKs are sent for individual resources that fail to decode or process, not for the entire response

### Three xDS Resource Types
1. `ADDRESS_TYPE` (`istio.io/address`): Carries both workloads and services in a union type (`XdsAddress`). Workloads are keyed by UID, services by `namespace/hostname`.
2. `AUTHORIZATION_TYPE` (`istio.io/authorization`): RBAC policies. These disable on-demand (`no_on_demand() -> true`) since policies must be fully loaded.
3. Workload type (legacy): Direct workload resources, handled by `Handler<XdsWorkload>`.

### State Store Architecture
`ProxyState` is behind `Arc<RwLock<ProxyState>>`:
- `WorkloadStore`: dual-indexed by `by_uid` (HashMap) and `by_addr` (HashMap of NetworkAddress to UID). Uses a `watch::Sender` to notify subscribers when workloads are added, enabling `wait_for_workload()`.
- `ServiceStore`: indexed by VIP (`by_vip`), hostname (`by_host`), and has `staged_services` for endpoints that arrive before their service.
- `PolicyStore`: indexed by key (`by_key`) and namespace (`by_namespace`). Uses `watch::channel` to notify `PolicyWatcher` in the connection manager.

### On-Demand Resource Fetching
`DemandProxyState` wraps `ProxyState` with a `Demander` (if xDS is configured). When a workload or address is not found locally:
1. `fetch_on_demand()` sends a subscription request via the xDS client
2. The client adds the resource name to `resource_names_subscribe` in the next delta request
3. The caller waits for the response via a oneshot channel
4. After receiving, the state is checked again

### RBAC Evaluation Order
`DemandProxyState::assert_rbac()` follows Istio's documented order:
1. Collect all DENY and ALLOW policies matching the destination workload (by namespace, global, and workload-selector)
2. If any DENY policy matches → deny
3. If no ALLOW policies exist → allow
4. If any ALLOW policy matches → allow
5. Otherwise → deny

### Load Balancing
`ProxyState::load_balance()` supports three modes via `LoadBalancerMode`:
- `Standard`: Random selection among healthy endpoints
- `Failover`: Rank endpoints by locality match (network, region, zone, subzone, node, cluster) and select from highest-ranked group
- `Strict`: Like failover but requires full match, otherwise no endpoint is selected
- `Passthrough`: Bypass load balancing, connect directly to the original destination

Endpoints are weighted by `workload.capacity` (as `u64`), using `choose_weighted()` from `rand`.

### XDS Update Processing Pattern
`Handler::handle()` receives an iterator of `XdsUpdate<T>` (either `Update` or `Remove`). The `ProxyStateUpdater` implementation:
1. Takes the write lock on `ProxyState`
2. Processes each update individually, collecting rejected configs
3. For authorization updates, sends a notification via `PolicyStore::send()` even if some configs were rejected (partial success)

## Gotchas
- **Workload removal clears certs**: When a workload is removed and it was the last one with that identity on the node, `CertFetcher::clear_cert()` is called. This doesn't happen during re-insertion (remove-before-insert pattern).
- **Staged services**: Endpoints may arrive before their service definition. `ServiceStore` stores these in `staged_services` and merges them when the service is later inserted.
- **On-demand is per-type**: Authorization policies have `no_on_demand() -> true`, meaning they are never fetched on-demand. Only address/workload types support on-demand.
- **WorkloadStore subscriber**: `WorkloadStore` uses a `watch::Sender<()>` to notify when workloads change. `wait_for_workload()` subscribes before checking state to avoid race conditions.
- **Service lookup order**: `find_address()` checks workloads first, then falls back to services. `find_hostname()` checks services first, then falls back to a slow O(n) workload scan.
- **DNS resolution for hostname workloads**: If a workload has a hostname but no IPs, `DemandProxyState` resolves it using `hickory_resolver`, preferring the same IP family as the original request.
- **Host network mode**: Workloads with `NetworkMode::HostNetwork` share IPs. When looking up by address for non-service traffic, ztunnel returns passthrough (no workload association) to avoid ambiguity.
- **xDS reconnection**: The ADS client reconnects with backoff on connection failures. Each reconnection re-subscribes to all known resource types and sends initial resource lists.

## Dependencies & Context
- **Delta ADS gRPC**: xDS protocol variant that sends incremental updates. Uses `tonic` for gRPC and `prost` for protobuf decoding. The proto definitions are in `proto/` (workload.proto, authorization.proto, xds.proto).
- **`DemandProxyState`**: The primary interface used by proxy components. It wraps the raw state with on-demand fetching and DNS resolution capabilities. Cloneable and thread-safe.
- **`ProxyStateManager`**: Top-level orchestrator created in `app.rs`. Creates either an `AdsClient` (when `xds_address` is configured) or a `LocalClient` (for file-based testing config). Produces the `DemandProxyState` used by all proxy listeners.
- **`hickory_resolver`**: DNS resolver used by `DemandProxyState` for resolving hostname-based workloads. Configured via `dns_resolver_cfg` and `dns_resolver_opts` from the proxy config.
- **`keyed_priority_queue`**: Not used here (used in identity manager), but the state module uses `rand::seq::IndexedRandom::choose_weighted` for load balancing.
- **Local config**: `LocalClient` loads workloads, services, and policies from YAML files or dynamic channels (for tests). It clears all state on reload.

## Links
- [Proxy Data Plane](proxy-data-plane.md) -- consumes state for routing decisions
- [TLS and Crypto](tls-and-crypto.md) -- xDS connection uses `TlsGrpcChannel`; cert pre-fetching triggered by workload updates
- [In-Pod Mode](inpod-mode.md) -- manages per-pod proxy instances that share the same state
- [Observability](observability.md) -- xDS metrics tracked in `src/xds/metrics.rs`
- [proto/workload.proto](../../proto/workload.proto) -- workload/service protobuf definitions
- [proto/authorization.proto](../../proto/authorization.proto) -- RBAC policy protobuf definitions
- [src/state.rs](../../src/state.rs) -- proxy state and RBAC evaluation
- [src/xds/client.rs](../../src/xds/client.rs) -- delta ADS client implementation
