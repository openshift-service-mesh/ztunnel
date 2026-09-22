# API Conventions — ztunnel midstream

## Upstream-first rule

Bug fixes and features that belong in upstream ztunnel must have an upstream PR opened **first**.
Do not merge OSSM patches for upstream issues without a tracking upstream PR.

## OSSM-only annotation

Every code block that is OSSM-specific must be annotated with the marker
`OSSM-only: <JIRA-KEY> <one-line reason>` using the comment syntax for that file type:

| File type | Syntax |
|---|---|
| Rust (`.rs`) | `// OSSM-only: <JIRA-KEY> <reason>` |
| Shell (`.sh`) | `# OSSM-only: <JIRA-KEY> <reason>` |
| YAML / TOML | `# OSSM-only: <JIRA-KEY> <reason>` |
| Markdown (`.md`) | `<!-- OSSM-only: <JIRA-KEY> <reason> -->` |

This annotation is mandatory — use `git grep "OSSM-only"` to audit all permanent patches.
Changes intended for upstream submission should reference the upstream issue in the commit
message instead of using an inline annotation.

## Feature flags

OSSM-specific behavior changes must be gated behind a Cargo feature flag where possible
(e.g., `#[cfg(feature = "tls-openssl")]`). Prefer feature flags over unconditional code changes
to keep the diff from upstream minimal.
