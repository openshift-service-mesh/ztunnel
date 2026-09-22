# Code Style — ztunnel midstream

## Primary references

- **AGENTS.md § Repository Layout** — key modules and their responsibilities
- **[ARCHITECTURE.md](../../ARCHITECTURE.md)** — threading model (main vs worker runtimes), port layout
- **[docs/upstream.md](../../docs/upstream.md)** — OSSM-only annotation convention and upstream-first rule

## Rules

- Follow upstream ztunnel Rust style: `rustfmt` for formatting, `cargo clippy -- -D warnings` for lints.
- Do **not** mix rustls and OpenSSL code paths without feature-flag gating (`#[cfg(feature = "tls-openssl")]`).
- Changes to the **main runtime** (admin, XDS) must not affect data-plane latency on the **worker runtime**.
  The two Tokio runtimes are intentionally isolated — see ARCHITECTURE.md.
- Keep OSSM-specific code minimal and always annotated with `// OSSM-only: <JIRA-KEY> <reason>`.
- Do not introduce new Cargo dependencies without opening an upstream issue first.
