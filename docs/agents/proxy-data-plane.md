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
    - "src/proxy.rs"
    - "src/proxy/outbound.rs"
    - "src/proxy/inbound.rs"
    - "src/proxy/inbound_passthrough.rs"
    - "src/proxy/socks5.rs"
    - "src/proxy/connection_manager.rs"
    - "src/proxy/pool.rs"
    - "src/proxy/h2.rs"
    - "src/proxy/h2/client.rs"
    - "src/proxy/h2/server.rs"
    - "src/proxy/metrics.rs"
    - "src/proxy/util.rs"
    - "src/copy.rs"
    - "src/socket.rs"
    - "src/proxyfactory.rs"
  stale_flags: []
---

# Proxy Data Plane

> This doc covers the core proxy listeners (inbound, outbound, SOCKS5), HBONE tunneling,
> connection pooling, and bidirectional copy. For TLS/crypto providers, see [tls-and-crypto.md](tls-and-crypto.md).
> For xDS state that feeds routing decisions, see [xds-and-state.md](xds-and-state.md).

## Key Entry Points
- `src/proxy.rs`: Top-level `Proxy` struct that owns Inbound, InboundPassthrough, Outbound, and Socks5 listeners. Defines `SocketFactory` trait, `ProxyInputs`, error types, and the `freebind_connect()` function used by all proxy paths.
- `src/proxyfactory.rs`: `ProxyFactory` creates proxy instances with appropriate socket factories. Entry point for both dedicated mode and in-pod mode proxy creation. Also creates the ztunnel "self-proxy" listener for metrics HBONE termination (`create_ztunnel_self_proxy_listener()`).
- `src/proxy/outbound.rs`: `Outbound` listener on port 15001. Captures pod outbound traffic, resolves destinations via xDS state, and routes via TCP, HBONE, or double HBONE.
- `src/proxy/inbound.rs`: `Inbound` listener on port 15008. Terminates HBONE (HTTP/2 CONNECT over mTLS), validates destinations, enforces RBAC, and proxies to the local application.
- `src/proxy/inbound_passthrough.rs`: `InboundPassthrough` listener on port 15006. Handles plaintext inbound traffic without HBONE termination.
- `src/proxy/socks5.rs`: `Socks5` listener on port 15080. SOCKS5 proxy that resolves hostnames via the DNS resolver and delegates to `OutboundConnection::proxy_to()`.
- `src/proxy/pool.rs`: `WorkloadHBONEPool` — HTTP/2 connection pool for outbound HBONE. Multiplexes proxied connections over a smaller number of mTLS tunnels using `pingora_pool`.
- `src/proxy/connection_manager.rs`: `ConnectionManager` tracks live connections and `PolicyWatcher` reactively closes connections when RBAC policies change.
- `src/copy.rs`: `copy_bidirectional()` — custom zero-copy-friendly bidirectional data copy with adaptive buffer resizing (1KB → 16KB → 256KB).
- `src/socket.rs`: Linux-specific socket operations: `SO_ORIGINAL_DST`, `IP_TRANSPARENT`, `IP_FREEBIND`, `SO_MARK`, and a `Listener` wrapper that sets `NODELAY` and keepalive on accepted connections.

## Patterns & Conventions

### Outbound Routing Decision Tree
`OutboundConnection::build_request()` resolves the destination in a specific order:
1. Check if destination is a **service VIP** → look for a **service waypoint** → if found, route HBONE to the waypoint
2. If service waypoint is on a **different network** → use **double HBONE** through an east-west gateway
3. Resolve upstream via `fetch_upstream()` → check if upstream is on a different network → double HBONE through gateway
4. Check for a **workload waypoint** on the upstream (skip if source is already the waypoint)
5. Final destination: direct HBONE or TCP based on `InboundProtocol` of the upstream workload

### Three Outbound Protocols
- `OutboundProtocol::TCP`: Direct TCP connection, no tunneling. Used for workloads without HBONE support.
- `OutboundProtocol::HBONE`: Single HTTP/2 CONNECT tunnel with mTLS. Standard ambient mesh path.
- `OutboundProtocol::DOUBLEHBONE`: HBONE-in-HBONE for cross-network traffic through east-west gateways. The outer tunnel targets the gateway, the inner tunnel targets the actual destination.

### Connection Lifecycle Pattern
All listeners follow the same pattern in their `run()` method:
1. Wrap the accept loop in `run_with_drain()` for graceful shutdown
2. Accept connections in a loop, spawning a Tokio task per connection
3. Each task is wrapped in `tokio::select!` with a `force_shutdown` signal
4. The `drain` watcher is dropped when the task completes to signal completion
5. `assertions::size_between_ref()` checks the Future size at compile time to prevent stack bloat

### Adaptive Buffer Resizing in `copy_bidirectional`
The custom `CopyBuf` future in `src/copy.rs` starts with a 1KB buffer per connection to save memory for idle connections, then:
- After 128KB transferred → resize to ~16KB (matches TLS record size)
- After 10MB transferred → resize to ~256KB (jumbo mode for high-bandwidth connections)

This is inspired by Go's `crypto/tls` package approach. The `BufferedSplitter` trait provides a specialized `TcpStreamSplitter` that uses `TcpStream::into_split()` (lock-free) instead of generic `tokio::io::split()` (requires locking).

### Connection Tracking and Live RBAC
`ConnectionManager` maintains a `HashMap<InboundConnection, ConnectionDrain>` with reference counting. The `handle_connection!` macro races the proxied data flow against a drain watcher, so that `PolicyWatcher` can kill connections in-flight if RBAC policies change. Connections that become disallowed are drained immediately.

### Socket Factory Abstraction
`SocketFactory` trait (`src/proxy.rs:62`) abstracts TCP/UDP socket creation. Two implementations:
- `DefaultSocketFactory`: sets NODELAY, configurable keepalive, and TCP_USER_TIMEOUT
- `MarkSocketFactory`: wraps `DefaultSocketFactory` and adds `SO_MARK` for packet marking (used with iptables rules)

In-pod mode provides its own socket factory to create sockets within the pod's network namespace.

## Gotchas
- **Self-call prevention**: All listeners check `cfg.illegal_ports` to prevent recursive calls that could infinite-loop. The outbound also checks `dest_addr.ip().is_loopback()` in combination with illegal ports.
- **`freebind_connect` timeout**: All outbound TCP connections have a hard 10-second timeout (`CONNECTION_TIMEOUT`). If connecting to port 15008 times out, the error message hints at NetworkPolicy blocking HBONE.
- **PROXY protocol TLV**: Inbound uses a custom TLV type `0xD0` for source identity in the PROXY protocol header. This is a non-standard extension.
- **Inbound IP validation**: `validate_destination()` checks that the TCP destination IP matches the HBONE `:authority` IP unless the workload has an application tunnel or is acting as a waypoint. Mismatches are rejected with `IPMismatch`.
- **Double HBONE SANs split**: When using double HBONE, `upstream_sans` (for the gateway) and `final_sans` (for the actual workload) are different. The outer tunnel validates gateway identity, the inner tunnel validates the workload identity.
- **Future size assertions**: `assertions::size_between_ref()` is called on spawned connection handlers to catch memory regressions. If you add fields to connection state, these may fail at compile time.
- **`handle_connection!` is a macro**: Due to stack frame size issues with async functions, the RBAC drain-select pattern is a macro rather than a function. This saves ~1KB per connection.
- **Inbound self-proxy and `disable_inbound_freebind`**: When ztunnel proxies to its own endpoints (metrics), `disable_inbound_freebind` is set to `true` to avoid using the external client's IP as source for internal connections.

## Dependencies & Context
- **HBONE protocol**: HTTP/2 CONNECT-based tunneling, the core transport for Istio ambient mesh. All inbound mTLS traffic arrives on port 15008 as HBONE.
- **`pingora_pool`**: Cloudflare's Pingora connection pool crate, used for the `WorkloadHBONEPool`. The pool uses hash-based keying (DefaultHasher) with a deep-equality guard to prevent hash collisions from crossing workload streams. The pool uses per-key `tokio::sync::Mutex` locks to prevent thundering herd when many tasks request connections to the same destination simultaneously.
- **`h2` crate**: Low-level HTTP/2 implementation used directly (not through hyper) for both the HBONE client and server. Ping/pong health checking runs with 10s interval and 20s timeout per connection.
- **Waypoint proxies**: Ztunnel routes traffic through waypoints (Envoy-based L7 proxies) when workloads or services have waypoint configuration. The "sandwich" pattern means ztunnel → waypoint → ztunnel on the same node, using application tunnels (PROXY protocol) for the second hop.
- **East-West gateways**: Cross-network traffic uses double HBONE through designated gateway workloads. The outer HBONE carries the service hostname in the `:authority` header so the gateway can route without terminating the inner tunnel.
- **`ppp` crate**: Used for PROXY protocol v2 encoding in `write_proxy_protocol()`.
- **Tracing**: Each connection gets a `TraceParent` (W3C trace context format) either from the incoming HBONE headers or generated fresh for outbound. Baggage headers carry workload metadata.
- **Drain system**: `DrainWatcher`/`DrainTrigger` pairs provide graceful shutdown. The `run_with_drain()` function coordinates the accept loop shutdown with a configurable `self_termination_deadline`.

## Links
- [TLS and Crypto](tls-and-crypto.md) -- OpenSSL-backed TLS used by inbound/outbound HBONE connections
- [xDS and State Management](xds-and-state.md) -- workload/service/policy state that drives routing decisions
- [In-Pod Mode](inpod-mode.md) -- provides per-pod socket factories and proxy lifecycle
- [Observability](observability.md) -- metrics reported by `ConnectionResult` and `proxy::metrics`
- [ARCHITECTURE.md](../../ARCHITECTURE.md) -- threading model and port assignments
- [src/proxy.rs](../../src/proxy.rs) -- top-level proxy module
- [src/proxy/pool.rs](../../src/proxy/pool.rs) -- HBONE connection pool
- [src/copy.rs](../../src/copy.rs) -- bidirectional copy with adaptive buffers
