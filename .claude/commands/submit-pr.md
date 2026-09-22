# Submit PR — ztunnel midstream

Before opening or updating a pull request in this repository, verify:

## 1. Upstream-first check

- If the change is a bug fix or feature applicable to upstream ztunnel, open an upstream PR **first**.
- Reference the upstream PR in your OSSM PR description.

## 2. OSSM-only comment convention

All code that is OSSM-specific and not expected to exist upstream must be annotated:

Use the comment syntax for the file type (see `.claude/rules/api-conventions.md` for the full table):

- Rust: `// OSSM-only: <JIRA-KEY> <one-line reason>`
- Shell / YAML / TOML: `# OSSM-only: <JIRA-KEY> <one-line reason>`
- Markdown: `<!-- OSSM-only: <JIRA-KEY> <one-line reason> -->`

OpenSSL/FIPS-specific code must also be gated with `#[cfg(feature = "tls-openssl")]`.

## 3. Checklist

- [ ] OSSM-only comments present on all OSSM-specific hunks
- [ ] Upstream PR opened (if applicable) and linked
- [ ] `cargo build && cargo test && cargo clippy -- -D warnings` passing
- [ ] TLS changes tested with both rustls and `--features tls-openssl`
- [ ] CI passing (`prow.ci.openshift.org`)
