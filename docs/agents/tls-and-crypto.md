---
scribe:
  scan: "c0eb538903d7019b3401d4c399e9641f0e0c4eff"
  freshness: 100
  human_input: 20
  completeness: 100
  inferred_sections:
    - id: key-entry-points
      heading: "## Key Entry Points"
    - id: patterns--conventions
      heading: "## Patterns & Conventions"
    - id: gotchas
      heading: "## Gotchas"
    - id: links
      heading: "## Links"
  watch_paths:
    - "src/tls.rs"
    - "src/tls/lib.rs"
    - "src/tls/workload.rs"
    - "src/tls/certificate.rs"
    - "src/tls/control.rs"
    - "src/tls/csr.rs"
    - "src/tls/crl.rs"
    - "src/tls/mock.rs"
    - "src/identity.rs"
    - "src/identity/manager.rs"
    - "src/identity/caclient.rs"
    - "src/identity/auth.rs"
    - "src/cert_fetcher.rs"
  stale_flags: []
---

# TLS and Crypto

> This doc covers TLS via rustls with the OpenSSL crypto backend, certificate management,
> SPIFFE identity, and the CA client. This OSSM fork exclusively uses the `tls-openssl` feature.
> For how TLS connections are established in the proxy, see [proxy-data-plane.md](proxy-data-plane.md).
> For control plane xDS connections, see [xds-and-state.md](xds-and-state.md).

## Key Entry Points
- `src/tls/lib.rs`: Crypto provider selection via `provider()` function. Defines `CRYPTO_PROVIDER` string and `tls_versions()` for TLS 1.2/1.3 support. The code contains four feature-gated implementations (`tls-aws-lc`, `tls-ring`, `tls-boring`, `tls-openssl`) inherited from upstream, but this fork exclusively builds with `tls-openssl`, which selects `rustls-openssl` as the crypto backend.
- `src/tls/certificate.rs`: `WorkloadCertificate` — holds leaf cert, chain, private key, and root store. `server_config(crl_manager)` builds inbound TLS config with optional CRL checking; `client_config(identity)` builds raw `ClientConfig`; `outbound_connector(identity)` wraps it in `OutboundConnector`. Certificate refresh at half-life via `refresh_at()`.
- `src/tls/crl.rs`: `CrlManager` — watches a directory for CRL PEM files, hot-reloads them via `notify` debouncer. `get_crl_ders()` returns current CRLs for use in `WebPkiClientVerifier`. Fail-open for unknown revocation status.
- `src/tls/workload.rs`: `InboundAcceptor` (TLS server), `OutboundConnector` (TLS client), `IdentityVerifier` (custom SPIFFE URI SAN verification), `TrustDomainVerifier` (inbound trust domain enforcement).
- `src/tls/control.rs`: `ControlPlaneAuthentication` and `TlsGrpcChannel` for control plane gRPC connections to istiod. `RootCertManager` watches CA root cert file for changes and signals channel rebuild. `grpc_connector()` creates the hyper-based gRPC client.
- `src/tls/csr.rs`: CSR generation, feature-gated per crypto backend.
- `src/identity/manager.rs`: `SecretManager` — certificate caching and lifecycle. `Worker` runs a background task managing fetch/refresh/forget with priority queuing. `Identity` is the SPIFFE identity type (`spiffe://{td}/ns/{ns}/sa/{sa}`).
- `src/identity/caclient.rs`: `CaClient` — gRPC client for Istio's certificate authority (istiod). Sends `IstioCertificateRequest` with CSR, validates returned certificate SANs. Supports impersonated identity for shared mode.
- `src/cert_fetcher.rs`: `CertFetcher` trait for proactive certificate pre-fetching. `CertFetcherImpl` only pre-fetches for local-node workloads in shared mode.

## Patterns & Conventions

### Crypto via Rustls
All crypto goes through `rustls` with a pluggable `CryptoProvider`. The `provider()` function in `src/tls/lib.rs` returns the provider based on the active Cargo feature. The codebase retains four feature-gated backends from upstream (`tls-aws-lc`, `tls-ring`, `tls-boring`, `tls-openssl`), but this fork only builds and tests with `tls-openssl`, which uses `rustls-openssl` to delegate cryptographic operations to the system OpenSSL. Cipher suites default to TLS 1.3 `AES_256_GCM_SHA384` and `AES_128_GCM_SHA256`; TLS 1.2 (when `TLS12_ENABLED`) adds `ECDHE_ECDSA_WITH_AES_*` and `ECDHE_RSA_WITH_AES_*` suites. The `MESH_CIPHER_SUITES` environment variable (OSSM-specific, OpenSSL only) overrides the TLS 1.3 cipher suite list at startup — comma-separated names like `TLS_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256`.

### CRL (Certificate Revocation List) Support
`CrlManager` (`src/tls/crl.rs`) watches a directory for CRL PEM files and hot-reloads them using the `notify` crate with debouncing. `server_config()` in `WorkloadCertificate` passes CRLs to `WebPkiClientVerifier` for inbound connections. Revocation checking is fail-open (`allow_unknown_revocation_status`). Outbound CRL checking is not yet implemented.

### PQC (Post-Quantum Cryptography) Support
When `PQC_ENABLED` is true, the `tls-openssl` backend requires OpenSSL >= 3.5.0 at both compile and runtime; panics otherwise.

### Custom SPIFFE SAN Verification
Rustls doesn't natively validate URI SANs. `IdentityVerifier` in `src/tls/workload.rs` implements `ServerCertVerifier` with custom SAN checking: it verifies the cert chain against the root store, then extracts SPIFFE URIs from x509 SAN extensions and matches against expected identities. Similarly, `TrustDomainVerifier` wraps the standard `ClientCertVerifier` to add trust domain checks on inbound connections.

### Certificate Lifecycle in SecretManager
`SecretManager` (`src/identity/manager.rs`) manages certificate caching:
1. Certificates are requested via `fetch_certificate(id)` with a `Priority` (Background, Warmup, RealTime)
2. A `Worker` background task processes requests using a `KeyedPriorityQueue` — RealTime requests jump ahead of Background
3. Certificates are cached in `HashMap<Identity, CertChannel>` with `watch::channel` for async notification
4. Certificates refresh at half-life (`not_before + (not_after - not_before) / 2`)
5. On fetch failure, existing valid certificates are retained until expiry; retry uses per-identity exponential backoff (500ms initial, 150s max)
6. Concurrency is capped at 8 concurrent CA requests

### Certificate Pre-fetching
`CertFetcherImpl` (`src/cert_fetcher.rs`) proactively fetches certificates for workloads on the local node that support HBONE. This reduces first-request latency. Only active in `ProxyMode::Shared`.

### Root Cert Hot-Reload
`RootCertManager` (`src/tls/control.rs`) watches the CA root cert's parent directory for filesystem changes (handles Kubernetes ConfigMap atomic symlink swaps). When a change is detected, the gRPC channel to istiod is rebuilt on the next `fetch_certificate` call. Uses a 2-second debounce via the `notify` crate.

## Gotchas
- **TLS session resumption is disabled** for outbound workload connections (`cc.resumption = Resumption::disabled()`) and SNI is also disabled (`cc.enable_sni = false`) since ztunnel uses dummy IP addresses for SNI.
- **ALPN is always `h2`** for both server and client workload configs. This is hardcoded, not configurable.
- **CSR generation is not pluggable**: CSR generation in `src/tls/csr.rs` uses direct crypto library calls guarded by `cfg` features, not the rustls provider abstraction. Each backend has its own CSR implementation; in this fork, the `tls-openssl` path uses the `openssl` crate directly.
- **`TLS12_ENABLED`, `PQC_ENABLED`, and `MESH_CIPHER_SUITES` are runtime flags** (from environment/config), not compile-time features. The cipher suites and key exchange groups are selected at process startup based on these flags.
- **CRL checking is fail-open**: `allow_unknown_revocation_status()` means certificates with unknown revocation status (e.g., no CRL covers that CA) are accepted. Only explicitly revoked certificates are rejected.
- **CRL is inbound-only**: CRL support is wired into `server_config()` for inbound connections. Outbound CRL checking (`client_config`) is not yet implemented.
- **Impersonated identity**: In shared mode (`enable_impersonated_identity = true`), the CA client includes `ImpersonatedIdentity` metadata in the CSR request so istiod issues certificates for specific workload identities. The response SAN is validated to match the requested identity.
- **`OutboundConnector::connect()` uses a dummy IP** (`0.0.0.0`) for the `ServerName` because actual SAN verification is done by the custom `IdentityVerifier`, not by rustls's built-in hostname verification.
- **Root cert chain splitting**: The Istio CA API returns a flat cert chain where the last entry may contain multiple concatenated root certificates. `WorkloadCertificate::new()` handles this by splitting and parsing them individually.
- **gRPC keepalive settings** for the CA connection match Istio's Envoy bootstrap: 300s keepalive time, 75s interval, 9 retries, 5s connect timeout.

## Dependencies & Context
- **TLS 1.2 exists for FIPS mode**: TLS 1.2 support (`TLS12_ENABLED` flag) exists specifically because istiod (Go) cannot explicitly configure TLS 1.3 cipher suites when FIPS is enabled, so it falls back to TLS 1.2. Without this flag, ztunnel couldn't communicate with istiod in FIPS mode.
- **rustls**: Core TLS library with pluggable crypto providers. All TLS operations go through rustls — no direct OpenSSL TLS calls for the connection layer.
- **`rustls-openssl`**: The crypto backend used by this fork. Provides OpenSSL-based cryptographic operations to rustls. Built with `features = ["tls12"]` for TLS 1.2 support.
- **Other crypto backends (present in code, not used)**: The codebase also contains feature-gated support for `aws-lc-rs` (upstream default), `ring` (pure Rust), and `boring-rustls-provider` (FIPS via BoringSSL). These exist for upstream compatibility but are not built or tested in this fork.
- **SPIFFE identity**: All mesh identities are SPIFFE URIs: `spiffe://{trust_domain}/ns/{namespace}/sa/{service_account}`. Parsed via `Identity::from_str()` and stored as the `Identity` enum.
- **Istio CA (istiod)**: Certificate signing happens via gRPC (`IstioCertificateService.CreateCertificate`). The CSR is generated locally, sent to istiod, and the signed certificate chain is returned.
- **`x509_parser`**: Used for parsing X.509 certificates, extracting SANs, and validating expiration.
- **`openssl` / `openssl-sys`**: Direct OpenSSL bindings used for CSR generation in `src/tls/csr.rs`.
- **`tls-listener`**: Provides the `AsyncTls` trait used by `InboundAcceptor` to accept TLS connections on the inbound listener.
- **`keyed_priority_queue`**: Used by the `Worker` for priority-based certificate fetch scheduling.
- **`notify`**: Filesystem watcher for CA root cert rotation detection.

## Links
- [Proxy Data Plane](proxy-data-plane.md) -- uses TLS for inbound/outbound HBONE connections
- [xDS and State Management](xds-and-state.md) -- control plane connection uses `TlsGrpcChannel`
- [Build and Testing](build-and-testing.md) -- build with `--no-default-features -F tls-openssl`
- [src/tls/lib.rs](../../src/tls/lib.rs) -- crypto provider selection
- [src/identity/manager.rs](../../src/identity/manager.rs) -- certificate lifecycle management
- [src/identity/caclient.rs](../../src/identity/caclient.rs) -- CA gRPC client
