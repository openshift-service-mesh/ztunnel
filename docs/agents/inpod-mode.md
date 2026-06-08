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
    - "src/inpod.rs"
    - "src/inpod/workloadmanager.rs"
    - "src/inpod/statemanager.rs"
    - "src/inpod/netns.rs"
    - "src/inpod/protocol.rs"
    - "src/inpod/config.rs"
    - "src/inpod/packet.rs"
    - "src/inpod/admin.rs"
    - "src/inpod/metrics.rs"
  stale_flags: []
---

# In-Pod Mode

> This doc covers the in-pod (shared) proxy mode: how ztunnel receives workload
> assignments from the Istio CNI node agent, manages per-pod proxy instances, and creates
> sockets in pod network namespaces. For dedicated mode proxy operation, see
> [proxy-data-plane.md](proxy-data-plane.md).

## Key Entry Points
- `src/inpod.rs`: `init_and_new()` — verifies syscall capabilities (setns, SO_MARK), creates `WorkloadProxyManager`. Defines `WorkloadMessage` enum (AddWorkload, KeepWorkload, DelWorkload, WorkloadSnapshotSent).
- `src/inpod/workloadmanager.rs`: `WorkloadProxyManager` — main run loop. Connects to CNI node agent over Unix domain socket, handles reconnection with backoff, processes workload messages, manages readiness.
- `src/inpod/statemanager.rs`: `WorkloadProxyManagerState` — tracks per-workload proxy state. Creates proxies via `ProxyFactory`, handles snapshot reconciliation, retries failed proxy starts, drains workloads on removal.
- `src/inpod/protocol.rs`: `WorkloadStreamProcessor` — ZDS (Ztunnel Discovery Service) protocol implementation over Unix SeqPacket sockets. Sends hello/ack/nack, receives workload messages with network namespace FDs via `SCM_RIGHTS`.
- `src/inpod/netns.rs`: `InpodNetns` — wraps a network namespace FD. `run()` switches to the workload's netns via `setns()`, executes a closure, then switches back. Identity by inode+dev comparison.
- `src/inpod/config.rs`: `InPodConfig` — creates `InPodSocketFactory` that binds sockets within the pod's network namespace with SO_MARK. Optionally adds SO_REUSEPORT via `InPodSocketPortReuseFactory`.
- `src/inpod/packet.rs`: SeqPacket socket `bind()` and `connect()` functions using nix — standard Unix streams don't support SeqPacket.
- `src/inpod/admin.rs`: `WorkloadManagerAdminHandler` — tracks proxy states (Pending/Up) for the admin API. Uses reference counting to handle race between proxy task completion and factory notifications.

## Patterns & Conventions

### ZDS Protocol Flow
1. Ztunnel connects to the CNI node agent via Unix SeqPacket socket at `cfg.inpod_uds`
2. Sends `ZdsHello` with protocol version
3. Receives workload messages: `AddWorkload` (with netns FD via SCM_RIGHTS), `KeepWorkload`, `DelWorkload`, `WorkloadSnapshotSent`
4. Acknowledges each message with `Ack` or `Nack`
5. On `WorkloadSnapshotSent`, reconciles: drains any proxies not mentioned in the snapshot

### Snapshot Reconciliation
When reconnecting (e.g., after CNI node agent restart), the protocol replays the full workload set:
- `AddWorkload` messages arrive for each active workload (idempotent — skipped if proxy already running with same netns inode)
- `KeepWorkload` messages mark existing proxies to retain
- `WorkloadSnapshotSent` triggers `reconcile()` which drains any workloads not in `snapshot_names`

### Per-Workload Proxy Lifecycle
Each workload gets its own `drain::DrainTrigger`. On `AddWorkload`:
1. Create `InpodNetns` from the received FD
2. Build a `SocketFactory` that operates in the pod's network namespace
3. Call `ProxyFactory::new_proxies_from_factory()` with the pod-specific socket factory
4. Spawn the proxy and optional DNS proxy as Tokio tasks
5. Track in `workload_states` HashMap

On `DelWorkload`: drain the workload's proxy immediately (non-graceful).

### Failed Proxy Retry
If proxy creation fails (e.g., port conflict from a not-yet-drained old pod), the workload is placed in `pending_workloads`. A retry timer fires every 5 seconds (`RETRY_DURATION`). Once all pending workloads succeed, the retry timer is cleared and readiness is signaled.

### Network Namespace Socket Factory
`InPodSocketFactory` (`src/inpod/config.rs`) wraps `DefaultSocketFactory`:
- `tcp_bind()` / `udp_bind()`: calls `netns.run()` to temporarily switch to the pod's netns, create/bind the socket, then switch back. Also sets `SO_MARK` on each socket.
- `InPodSocketPortReuseFactory`: adds `SO_REUSEPORT` on bind operations. Controlled by `cfg.inpod_port_reuse`.

## Gotchas
- **CAP_NET_RAW and CAP_NET_ADMIN required**: `verify_syscalls()` checks both `setns()` and `SO_MARK` capabilities at startup, failing early if missing.
- **Netns identity by inode**: Two netns FDs are considered equal if they have the same `(inode, dev)`. When a pod sandbox is recreated (CNI failure), the new netns has a different inode, causing ztunnel to drain the old proxy and start a new one.
- **`setns()` switches the calling thread**: `InpodNetns::run()` calls `setns()` to the workload netns, runs the closure, then calls `setns()` back to the original netns. The second `setns()` panics on failure ("this must never fail") since being stuck in the wrong netns would be catastrophic.
- **SeqPacket sockets**: The ZDS protocol uses Unix SeqPacket sockets (not stream), which preserve message boundaries. Standard Rust `UnixStream` doesn't support SeqPacket, so `src/inpod/packet.rs` uses raw `nix` syscalls for socket creation.
- **SCM_RIGHTS for netns FDs**: The `AddWorkload` message carries the pod's network namespace FD via Unix domain socket ancillary data (`SCM_RIGHTS`). The protocol validates that exactly one FD is received and that it's a netns FD (via `NS_GET_NSTYPE` ioctl or nsfs check).
- **Readiness blocks until first snapshot**: The manager starts not-ready and only becomes ready after receiving `WorkloadSnapshotSent` with no pending proxy failures.
- **Reconnection backoff for announce errors**: If the initial `send_hello()` fails (could be CNI restart or protocol mismatch), backoff increases from 5ms to max 15s. Protocol errors (version mismatch) cause immediate shutdown.
- **read_message is not cancel-safe**: The `read_message_and_retry_proxies()` method pins the `readmsg` future and ensures it completes even when interleaved with retry timers.

## Dependencies & Context
- **Istio CNI node agent**: The counterpart that manages iptables rules and sends workload notifications to ztunnel over ZDS. Runs as a DaemonSet alongside ztunnel.
- **ZDS protocol** (`proto/zds.proto`): Custom protobuf protocol between ztunnel and the CNI node agent. Messages are framed by SeqPacket message boundaries, not length-prefixed.
- **`nix` crate**: Used extensively for `setns()`, `recvmsg()`/`sendmsg()` (SCM_RIGHTS), SeqPacket socket creation, and ioctl.
- **`hashbrown`**: Used instead of `std::collections::HashMap` in `WorkloadProxyManagerState` for `extract_if()` during reconciliation.
- **Shared vs Dedicated mode**: In shared mode (`ProxyMode::Shared`), ztunnel manages proxies for all pods on the node. In dedicated mode, each pod runs its own ztunnel instance and in-pod management is not used.

## Links
- [Proxy Data Plane](proxy-data-plane.md) -- proxy instances created by ProxyFactory for each workload
- [TLS and Crypto](tls-and-crypto.md) -- certificate pre-fetching triggered by new workload arrivals
- [DNS Resolution](dns-resolution.md) -- DNS proxy optionally created per workload
- [proto/zds.proto](../../proto/zds.proto) -- ZDS protocol definition
- [src/inpod/statemanager.rs](../../src/inpod/statemanager.rs) -- per-workload proxy lifecycle
- [src/inpod/netns.rs](../../src/inpod/netns.rs) -- network namespace switching
