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
    - id: dependencies--context
      heading: "## Dependencies & Context"
    - id: links
      heading: "## Links"
  watch_paths:
    - "Cargo.toml"
    - "Makefile"
    - "Makefile.core.mk"
    - "Makefile.overrides.mk"
    - "Containerfile"
    - "scripts/release.sh"
    - "scripts/test-with-coverage.sh"
    - "ossm/ci/pre-submit.sh"
    - "ossm/ci/post-submit.sh"
    - "tests/direct.rs"
    - "tests/namespaced.rs"
  stale_flags: []
---

# Build and Testing

> This doc covers ztunnel's build system, Cargo features, Makefile targets, container builds,
> CI pipelines, and test infrastructure. This OSSM fork exclusively builds with the OpenSSL
> backend (`--no-default-features -F tls-openssl`). For runtime behavior of the proxy, see
> [proxy-data-plane.md](proxy-data-plane.md). For TLS details, see [tls-and-crypto.md](tls-and-crypto.md).

## Key Entry Points
- `Cargo.toml`: Package definition (edition 2024, MSRV 1.90), feature flags, dependencies, build profiles.
- `Makefile`: Top-level entry point. Delegates to `Makefile.core.mk` for local builds or `common/scripts/run.sh` for containerized builds (controlled by `BUILD_WITH_CONTAINER`).
- `Makefile.core.mk`: Core build targets: `build`, `test`, `lint`, `check`, `check-features`, `presubmit`, `release`, `format`, `gen`, `cve-check`, `license-check`.
- `Makefile.overrides.mk`: OSSM-specific overrides — defaults `BUILD_WITH_CONTAINER=1`, adds `--privileged` and netns volume mounts.
- `Containerfile`: Minimal container image — copies `out/rust/release/ztunnel` binary into `gcr.io/istio-release/base` image.
- `scripts/release.sh`: Upstream release build and upload to GCS. Use `TLS_MODE=openssl` or invoke OSSM CI scripts directly.
- `ossm/ci/pre-submit.sh`: OSSM pre-submit — `cargo build --release --features tls-openssl --no-default-features`.
- `ossm/ci/post-submit.sh`: OSSM post-submit — builds with tls-openssl, uploads binary to GCS (`maistra-prow-testing` bucket).
- `tests/direct.rs`: Unit/integration tests that run without network namespaces. Test lifecycle, connections, config dump, DNS, proxy modes.
- `tests/namespaced.rs`: Integration tests using real Linux network namespaces. Test HBONE, mTLS, waypoints, double-HBONE, policies, load balancing, shutdown behavior.

## Patterns & Conventions

### Cargo Feature Flags
This fork uses a single TLS feature:
- `tls-openssl`: Uses system OpenSSL via `rustls-openssl`. **Always pass `--no-default-features -F tls-openssl`** to all cargo commands (build, test, check, clippy). The upstream default `tls-aws-lc` is not used.
- `jemalloc`: Enables jemalloc allocator with profiling support (`tikv-jemallocator` + `jemalloc_pprof`).
- `testing`: Enables test utility code (mock secret managers, test helpers). Automatically enabled for dev dependencies via the `ztunnel` self-dependency.

Other TLS features (`tls-aws-lc`, `tls-ring`, `tls-boring`) exist in `Cargo.toml` for upstream compatibility but are not used in this fork.

### TLS Mode Selection in Makefiles
`Makefile.core.mk` reads `TLS_MODE` environment variable. For this fork, always set `TLS_MODE=openssl`:
- `openssl` → `--no-default-features -F tls-openssl`
- unset → falls through to default features (`tls-aws-lc`), which is **not what you want** in this fork

Common build commands for this fork:
```
TLS_MODE=openssl make build
TLS_MODE=openssl make test
cargo build --no-default-features -F tls-openssl
cargo test --no-default-features -F tls-openssl
```

### Build Profiles
- `release`: `opt-level=3`, `codegen-units=1`, `lto=true` — fully optimized, slow build.
- `quick-release`: Inherits release but `codegen-units=16`, `lto=false`, `incremental=true` — faster iteration.
- `bench`: Inherits `quick-release`.
- `symbols-release`: Inherits release with `debug=true` for profiling.

### Test Architecture
Two test crate files exist in `tests/`:

**`tests/direct.rs`** — runs without special privileges:
- Tests proxy lifecycle, shutdown, connections, config dump, DNS resolution
- Uses `test_config()` to create a local ztunnel instance with mock identity
- Run with `cargo test --no-default-features -F tls-openssl`

**`tests/namespaced.rs`** — requires Linux `--privileged` and network namespaces:
- Guard: `#[cfg(all(test, target_os = "linux"))]`
- Uses `setup_netns_test!` macro to create `WorkloadManager` with real network namespaces
- Tests run workloads as isolated namespaces with `Namespace::run()` which spawns threads in the target netns
- Supports `Shared` and `Dedicated` test modes
- Initializes once via `#[ctor::ctor]` calling `initialize_namespace_tests()`
- Tests cover: captured/uncaptured traffic, waypoints (workload/service/hostname), double-HBONE, load balancing, RBAC policies, trust domain mismatch, shutdown, certificate lifecycle

### Containerized Build
When `BUILD_WITH_CONTAINER=1` (default in OSSM overrides), the Makefile delegates all targets to `common/scripts/run.sh` which runs the build inside a Docker container. The container gets:
- `--privileged` flag (needed for namespace tests)
- `-v /fake/path/does/not/exist:/var/run/netns` (Linux: mount point for network namespaces)
- `-v /dev/null:/run/xtables.lock` (iptables lock file)

### OSSM CI Pipeline
- **Pre-submit** (`ossm/ci/pre-submit.sh`): Builds release binary with `tls-openssl`. No tests.
- **Post-submit** (`ossm/ci/post-submit.sh`): Builds release binary with `tls-openssl`, uploads to `gs://maistra-prow-testing/ztunnel/ztunnel-${SHA}-${ARCH}`. Supports `amd64` and `arm64`.

### Presubmit Target
`make presubmit` is the upstream comprehensive CI gate: sets `RUSTFLAGS=-D warnings` (deny all warnings), then runs `check-features`, `test`, `lint`, and `gen-check`. For this fork, use `TLS_MODE=openssl make presubmit` or run the OSSM CI scripts directly.

## Gotchas
- **Namespaced tests need `--privileged`**: The `Makefile.overrides.mk` adds `--privileged` to Docker. Without it, `setns()` and network namespace creation fail. This gives the container more privilege than strictly necessary (see `moby/moby#42441`).
- **Always use `--no-default-features -F tls-openssl`**: Both CI scripts hardcode this. Running `cargo build` without these flags will build with `tls-aws-lc` (upstream default), which is incorrect for this fork.
- **`testing` feature is not default**: It's enabled via a self-dependency in `[dev-dependencies]`: `ztunnel = { path = ".", features = ["testing"] }`. This ensures test utilities are available in integration tests but not in production builds.
- **Binary output path**: Cargo outputs to `out/rust/release/ztunnel` (via `CARGO_TARGET_DIR` set by `common/scripts/setup_env.sh`), not the default `target/release/ztunnel`. The Containerfile, release script, and CI scripts all reference this path.
- **No test target in OSSM CI**: `ossm/ci/pre-submit.sh` (runs on-PR) and `post-submit.sh` (runs on-push) only build, they do not run tests. Tests require a privileged container, which is not available in the GitHub CI environment used for these scripts.
- **`gen-check` depends on fuzz crate**: `make gen` updates the fuzz crate's Cargo.lock (`cd fuzz; cargo update ztunnel`). `gen-check` then verifies no uncommitted changes via `check-clean-repo`.
- **Clippy lints configuration**: `assigning_clones = "allow"` and `borrow_interior_mutable_const = "allow"` / `declare_interior_mutable_const = "allow"` — the latter is needed for the `strng` interned string type used throughout the codebase.
- **Protobuf code generation**: `tonic-build` and `prost-build` are build dependencies — protobuf compilation happens at build time via `build.rs`.
- **Platform-specific dependencies**: `netns-rs` and `pprof` are Linux-only (`target.'cfg(target_os = "linux")'.dependencies`).

## Dependencies & Context
- **Istio common-files**: The `Makefile` is copied from `istio/common-files` repo. Updates via `make update-common`. Contains shared CI scripts, linting, and environment setup.
- **Build container**: The containerized build environment provides the Rust toolchain, protobuf compiler, and other build tools. Controlled by `BUILD_WITH_CONTAINER`.
- **OSSM downstream fork**: This is the OpenShift Service Mesh fork of upstream `istio/ztunnel`. The `ossm/ci/` directory contains OSSM-specific CI scripts that target `maistra-prow-testing` GCS bucket.
- **`rustls-openssl` from git**: This fork pins `rustls-openssl` to a git revision (`tofay/rustls-openssl` rev `a21035c`) rather than a crates.io release, to include patches not yet published upstream.
- **Container base image**: Uses `gcr.io/istio-release/base:master-*` as the base, which provides distroless runtime environment.
- **Prow CI**: OSSM uses Prow for CI (`maistra-prow-testing` GCS project, `GOOGLE_APPLICATION_CREDENTIALS` for auth). Post-submit uploads binary artifacts to GCS for consumption by the build pipeline.
- **Fuzz testing**: A separate `fuzz/` directory exists (referenced in `check-features` and `gen` targets) using `RUSTFLAGS="--cfg fuzzing"`.

## Links
- [TLS and Crypto](tls-and-crypto.md) -- OpenSSL crypto backend and TLS runtime behavior
- [In-Pod Mode](inpod-mode.md) -- namespace tests exercise in-pod proxy lifecycle
- [Proxy Data Plane](proxy-data-plane.md) -- integration tests verify proxy connection behavior
- [Cargo.toml](../../Cargo.toml) -- package definition, features, dependencies
- [Makefile.core.mk](../../Makefile.core.mk) -- core build and test targets
- [tests/namespaced.rs](../../tests/namespaced.rs) -- network-namespace integration tests
