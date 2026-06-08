# ztunnel-ossm — Agentic Documentation Hub

Ztunnel is the node proxy component of Istio ambient mesh, providing transparent L4 traffic handling with mTLS via HBONE tunneling. This is the OpenShift Service Mesh (OSSM) downstream fork.

## Quick Reference

- **Language:** Rust (edition 2024, MSRV 1.90)
- **Build:** `cargo build --no-default-features -F tls-openssl` / `TLS_MODE=openssl make build` (container builds via `BUILD_WITH_CONTAINER=1`)
- **Test:** `cargo test --no-default-features -F tls-openssl` / `TLS_MODE=openssl make test` (namespaced tests require `--privileged`)
- **TLS backend:** OpenSSL (via `rustls-openssl`). This OSSM fork exclusively uses the `tls-openssl` feature.

## Documentation Topics

- [Proxy Data Plane](docs/agents/proxy-data-plane.md) — Inbound/outbound proxy, HBONE, SOCKS5, connection pooling
- [TLS and Crypto](docs/agents/tls-and-crypto.md) — TLS via rustls+OpenSSL, certificates, identity/auth
- [xDS and State Management](docs/agents/xds-and-state.md) — xDS client, workload/policy/service state
- [In-Pod Mode](docs/agents/inpod-mode.md) — Network namespace management, in-pod workload lifecycle
- [DNS Resolution](docs/agents/dns-resolution.md) — DNS forwarding, resolution, and server
- [Observability](docs/agents/observability.md) — Metrics, telemetry, admin server, readiness
- [Build and Testing](docs/agents/build-and-testing.md) — Cargo features, Makefiles, CI, Docker, test infrastructure

## Conventions

- See individual topic files for area-specific patterns
- Status dashboard: [docs/agents/STATUS.md](docs/agents/STATUS.md)
