# Ztunnel Midstream Agent Instructions

This repository is the Red Hat midstream fork of [istio/ztunnel](https://github.com/istio/ztunnel),
maintained for [OpenShift Service Mesh (OSSM)](https://www.redhat.com/en/technologies/cloud-computing/openshift/what-is-openshift-service-mesh).

For details on how this fork relates to upstream, branch mapping, and the sync process,
see [docs/upstream.md](docs/upstream.md).

## Project Overview

Ztunnel is the node proxy for Istio Ambient mesh. It is a **Rust** project built on
**Tokio** async runtimes. It handles HBONE tunneling, mTLS, workload identity (SPIFFE),
DNS, and metrics for ambient mesh pods — without sidecar proxies.

Key design constraints:
- Intentionally narrow feature scope (no HTTP termination, no WASM, no ext_authz).
- Two isolated Tokio runtimes: **main** (admin/XDS, single-threaded) and **worker**
  (data plane, multi-threaded). See [ARCHITECTURE.md](ARCHITECTURE.md).
- OSSM adds FIPS compliance via OpenSSL; upstream uses rustls.

## Repository Layout

```
src/
  proxy/      # HBONE proxy, inbound/outbound traffic handling
  tls/        # TLS stack (rustls upstream, OpenSSL/FIPS in OSSM)
  identity/   # SPIFFE identity, certificate fetching
  xds/        # XDS client (workload/policy discovery from istiod)
  dns/        # DNS proxy
  inpod/      # In-pod traffic redirection
  metrics/    # Prometheus metrics
  config.rs   # Configuration (env vars, feature flags)
  app.rs      # Runtime initialization, startup
ossm/         # OSSM-specific CI scripts and merge helpers
docs/         # Midstream-specific documentation
```

## Setup

```bash
# Build
cargo build

# Build with OpenSSL (FIPS path used in OSSM)
cargo build --features tls-openssl

# Run tests
cargo test

# Run a specific test
cargo test <test_name>

# Lint
cargo clippy -- -D warnings

# Format
cargo fmt --check
```

## Key Ports

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full port table. Critical ones:

| Port  | Purpose                          |
|-------|----------------------------------|
| 15008 | HBONE inbound (must be allowed by NetworkPolicy) |
| 15001 | Outbound traffic capture         |
| 15000 | Admin (localhost only)           |

## OSSM-Specific Concerns

- **FIPS/OpenSSL**: OSSM builds ztunnel with `--features tls-openssl` instead of the upstream rustls.
  TLS-related changes must be tested against both feature flags.
- **OCP CI**: Prow jobs are defined in the [openshift/release](https://github.com/openshift/release) repository.
- **PR workflow**: see [docs/upstream.md](docs/upstream.md) for the upstream-first rule and OSSM-only annotation convention.

## OSSM-Only Annotation

Every code block that is OSSM-specific must be annotated:

```rust
// OSSM-only: <JIRA-KEY> <one-line reason>
```

Use `git grep "OSSM-only"` to locate all permanent patches.

## Code Quality

After any change, run:

```bash
cargo build && cargo test && cargo clippy -- -D warnings
```

All three must pass before submitting a PR.
