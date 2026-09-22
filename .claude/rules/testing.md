# Testing — ztunnel midstream

## Unit tests

- Standard Rust tests (`#[test]`, `#[tokio::test]`).
- Run: `cargo test`
- Run a specific test: `cargo test <test_name>`

## Integration tests

- Located in `tests/` directory.
- Run: `cargo test --test <suite>`

## Feature-flag testing

OSSM builds with OpenSSL; upstream uses rustls. Test both paths for TLS-related changes:

```bash
cargo test
cargo test --features tls-openssl
```

## CI

- OCP E2E run by Prow on `prow.ci.openshift.org`.
- Do not break upstream tests — all midstream changes must pass the upstream test suite.

## Rules

- Never skip a failing test by commenting it out — open an issue and mark with `#[ignore = "issue #N"]`.
- OSSM-specific test cases should be gated with `#[cfg(feature = "tls-openssl")]` or placed in
  separate test files with a `# OSSM-only: <JIRA-KEY> <reason>` header comment (shell-style for
  `.sh` test helpers; `// OSSM-only:` for `.rs` test files).
