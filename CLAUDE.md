@include AGENTS.md

# Claude-Specific Instructions

## Build Commands

Always use the OpenSSL backend. Never run bare `cargo build` or `cargo test` — the default feature (`tls-aws-lc`) is wrong for this fork.

```
cargo build --no-default-features -F tls-openssl
cargo test --no-default-features -F tls-openssl
cargo clippy --no-default-features -F tls-openssl
TLS_MODE=openssl make build
TLS_MODE=openssl make test
```

## Before Making Changes

- Read the relevant topic file in `docs/agents/` before touching a subsystem. It lists entry points, patterns, and gotchas that will save you from common mistakes.
- This is an OSSM downstream fork of upstream `istio/ztunnel`. Be aware of what is upstream code vs OSSM-specific (e.g., `MESH_CIPHER_SUITES` env var, `ossm/ci/` scripts, `rustls-openssl` git pin).

## Code Style

- Follow existing patterns in the file you're editing. The codebase uses `strng` (interned strings) extensively — don't replace with `String`.
- No unnecessary abstractions. This is a performance-critical proxy.
- Clippy allows `borrow_interior_mutable_const` and `declare_interior_mutable_const` for the `strng` type — don't try to "fix" these.

## Testing

- `tests/direct.rs` — runs without privileges, safe to run anywhere.
- `tests/namespaced.rs` — requires Linux `--privileged` container with network namespace support. Don't expect these to pass in unprivileged environments.
- Always add `--no-default-features -F tls-openssl` to test commands.

## Things to Avoid

- Do not change the TLS feature flags or add `tls-aws-lc`/`tls-ring`/`tls-boring` to build commands. This fork only supports OpenSSL.
- Do not run `cargo build` without `--no-default-features -F tls-openssl`.
- Do not modify files under `common/` — these are synced from `istio/common-files` via `make update-common`.
