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
    - "src/dns.rs"
    - "src/dns/server.rs"
    - "src/dns/handler.rs"
    - "src/dns/forwarder.rs"
    - "src/dns/resolver.rs"
    - "src/dns/metrics.rs"
    - "src/dns/name_util.rs"
  stale_flags: []
---

# DNS Resolution

> This doc covers ztunnel's built-in DNS proxy: how it resolves Kubernetes service hostnames from
> local state, forwards unknown queries upstream, and handles search domain expansion. For the
> xDS state that feeds service/workload lookups, see [xds-and-state.md](xds-and-state.md).
> For how DNS proxies are created per-pod in shared mode, see [inpod-mode.md](inpod-mode.md).

## Key Entry Points
- `src/dns/server.rs`: `Server::new()` — binds TCP+UDP sockets via `SocketFactory`, creates the `Store` resolver and `hickory_server::ServerFuture`. `Server::run()` drives the server until drain.
- `src/dns/server.rs`: `Store` — the core `Resolver` implementation. Looks up hostnames against `DemandProxyState` (services by hostname, workloads by UID for headless), generates alias expansions, and falls back to upstream forwarding.
- `src/dns/server.rs`: `forwarder_for_mode()` — factory that creates a `SystemForwarder` with either per-pod dynamic search domains (shared mode) or static system search domains (dedicated mode).
- `src/dns/handler.rs`: `Handler` — hickory `RequestHandler` that dispatches `Query` opcodes to `Resolver::lookup()` and converts errors to appropriate DNS response codes.
- `src/dns/forwarder.rs`: `Forwarder` — wraps `hickory_resolver::Resolver` with a custom `RuntimeProviderAdaptor` that routes TCP/UDP through ztunnel's `SocketFactory` (enabling socket creation in pod network namespaces).
- `src/dns/resolver.rs`: `Resolver` trait and `Answer` type — abstraction over DNS resolution with an `is_authoritative` flag distinguishing locally-resolved from forwarded responses.
- `src/dns/metrics.rs`: `Metrics` — Prometheus counters/histograms: `dns_requests`, `dns_upstream_requests`, `dns_upstream_failures`, `dns_upstream_request_duration_seconds`.
- `src/dns/name_util.rs`: `has_domain()`, `trim_domain()` — helpers for checking and stripping DNS domain suffixes.
- `src/app.rs:58-226`: DNS proxy lifecycle — conditionally created when `config.dns_proxy` is true, registered as a readiness task, spawned in the data plane worker pool.

## Patterns & Conventions

### Resolution Flow
1. `Handler` receives a DNS request and calls `Store::lookup()`
2. `Store` identifies the source workload via `LocalWorkloadFetcher`; returns `ServFail` if unknown
3. Non-A/AAAA record types are immediately forwarded upstream
4. `find_server()` builds alias list from the requested name, trying Kubernetes FQDN expansions and search domain stripping, then looks up each alias (including wildcards) against `ServiceStore::get_by_host()`
5. If a service match is found, `get_addresses()` returns VIPs (normal services) or endpoint workload IPs (headless services), filtered by record type and client network
6. Addresses are shuffled randomly (`addrs.shuffle(&mut rng())`) for DNS-based load balancing
7. If the name was found via search domain stripping, a CNAME record maps the requested name to the canonical name, followed by A/AAAA records
8. If no match is found, the request is forwarded to the upstream `SystemForwarder`

### Kubernetes FQDN Expansion (`to_kube_fqdns`)
Short names are expanded to possible Kubernetes FQDNs based on label count:
- 1 label (`svc`): `svc.<client-ns>.svc.<cluster-domain>`
- 2 labels (`svc.ns`): `svc.ns.svc.<cluster-domain>` and `svc.ns.<client-ns>.svc.<cluster-domain>` (pod hostname form)
- 3 labels (`svc.ns.svc`): `svc.ns.svc.<cluster-domain>` (if third label is `svc`) and pod form
- 4 labels: pod hostname form only (if fourth label is `svc`)
- 5+ labels: no expansion (assumed to be FQDN already)

### Search Domain Handling
- **Shared mode**: Search domains are dynamically generated per-pod: `<ns>.svc.<cluster-domain>`, `svc.<cluster-domain>`, `<cluster-domain>`
- **Dedicated mode**: Static search domains from ztunnel's `/etc/resolv.conf`
- Search domains from the upstream resolver config are stripped before forwarding to avoid double-application

### Wildcard Matching
For a name like `www.example.com`, `get_wildcards()` generates: `[www.example.com, *.example.com, *.com]`. Each wildcard is checked against `ServiceStore` by hostname.

### Headless Service Resolution
Services with empty `vips` but a `.svc.cluster.local` hostname are treated as headless: `get_addresses()` resolves endpoint workload IPs via `WorkloadStore::find_uid()` instead of returning VIPs. `IpFamily` filtering on headless services prevents returning dual-stack pod IPs when the service is single-stack.

### Preferred Namespace Resolution
When multiple services share the same hostname across namespaces, resolution priority is:
1. Client's own namespace
2. `prefered_service_namespace` (configured per-server)
3. First match (non-deterministic)

### Forwarder Socket Integration
`RuntimeProviderAdaptor` implements hickory's `RuntimeProvider` to route upstream DNS connections through ztunnel's `SocketFactory`. This ensures DNS forwarding works correctly in pod network namespaces (in-pod mode) with proper `SO_MARK` and netns context. TCP connections use a 5-second connect timeout (`CONNECT_TIMEOUT`).

## Gotchas
- **Only A and AAAA records handled locally**: All other record types (NS, MX, SRV, TXT, etc.) are forwarded upstream without consulting local state. `is_record_type_supported()` is the gatekeeper.
- **IPv6 can be globally disabled**: When `ipv6_enabled` is false, AAAA records are suppressed even if services/workloads have IPv6 addresses. The server also calls `socket_factory.ipv6_enabled_localhost()` to auto-detect per-pod IPv6 support and downgrade the bind address.
- **Default TTL is 30 seconds**: All locally-resolved records use `DEFAULT_TTL_SECONDS = 30`, regardless of the service configuration.
- **No pod-level DNS for headless services**: Individual pod hostnames (`pod-hostname.pod-subdomain.ns.svc.cluster.local`) are not yet resolved — only the headless service name returns all endpoint IPs. See `TODO(https://github.com/istio/ztunnel/issues/1119)`.
- **Search domains are not read from pod spec**: In shared mode, search domains are hardcoded from cluster domain rather than read from the pod's actual `/etc/resolv.conf`. See `TODO(https://github.com/istio/ztunnel/issues/555)`.
- **Network-aware VIP filtering**: VIPs are only returned if the VIP's `network` matches the client workload's `network`. A service VIP on `nw2` will return empty records for a client on `nw1`.
- **Headless external ServiceEntry without `.svc.cluster.local`**: External headless services (e.g., `headless.example.com`) with no VIPs are filtered out because they don't match the `.svc.cluster.local` domain check. Their queries are forwarded upstream.
- **UDP response truncation**: Large responses (e.g., 256 A records) are automatically truncated by hickory's `ServerFuture` for UDP but sent in full over TCP.
- **EDNS max payload**: The response EDNS payload size is set to `max(client_edns_payload, 512)`.
- **DNS proxy waits for initial xDS sync**: The DNS proxy task blocks on `xds_rx.changed().await` in `app.rs` before starting, ensuring state is loaded before serving queries.

## Dependencies & Context
- **hickory-dns ecosystem**: `hickory_server::ServerFuture` for TCP/UDP server, `hickory_resolver` for upstream forwarding, `hickory_proto` for DNS types (Name, Record, RData). Formerly known as TrustDNS.
- **`DemandProxyState`**: The DNS `Store` reads services and workloads from the shared proxy state. Service lookups use `get_by_host()`; headless endpoints use `find_uid()`. State is accessed via `Arc<RwLock>`.
- **`SocketFactory` integration**: Both the DNS server binds and upstream forwarder connections go through `SocketFactory`, enabling correct operation in pod network namespaces with `SO_MARK`.
- **`LocalWorkloadFetcher`**: Identifies the source workload for each DNS request. In shared mode, this returns the workload associated with the pod whose DNS proxy this is. In dedicated mode, it's the single local workload.
- **Conditional creation**: DNS proxy is only created when `config.dns_proxy` is true. When enabled, it registers as a readiness dependency and runs in the data plane worker pool alongside proxy tasks.
- **Drain integration**: Server shuts down gracefully on `DrainMode::Graceful`, immediately otherwise. TCP request timeout is 5 seconds (`DEFAULT_TCP_REQUEST_TIMEOUT`).

## Links
- [xDS and State Management](xds-and-state.md) -- service/workload state that feeds DNS lookups
- [In-Pod Mode](inpod-mode.md) -- per-pod DNS proxy creation in shared mode
- [Proxy Data Plane](proxy-data-plane.md) -- SocketFactory used by DNS for socket creation
- [Observability](observability.md) -- DNS metrics exposed via the metrics endpoint
- [src/dns/server.rs](../../src/dns/server.rs) -- core DNS server and Store resolver
- [src/dns/forwarder.rs](../../src/dns/forwarder.rs) -- upstream DNS forwarding with SocketFactory integration
