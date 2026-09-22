# Upstream Sync Review — ztunnel midstream

Evaluate whether a set of changes is correctly annotated and ready for the midstream sync workflow.

## Step 1: Identify OSSM-only hunks

- Read each changed file.
- Flag any hunk that is OSSM-specific and lacks the `OSSM-only: <JIRA-KEY> <reason>` marker
  (using the correct comment syntax for the file type — see `.claude/rules/api-conventions.md`).
- Check for ungated OpenSSL/FIPS code that should be behind `#[cfg(feature = "tls-openssl")]`.

## Step 2: Upstream existence check

For every non-annotated hunk:

- Verify the equivalent fix exists (or has a tracking PR) in `github.com/istio/ztunnel`.
- If missing: flag as **upstream gap** and recommend opening an upstream issue or PR.

## Step 3: Feature flag check

- Confirm OSSM-specific TLS/OpenSSL changes are gated with `#[cfg(feature = "tls-openssl")]`.
- Confirm changes do not accidentally alter the rustls path.

## Step 4: Build and test check

Confirm the PR includes evidence that the following pass:

```bash
cargo build
cargo test
cargo test --features tls-openssl
cargo clippy -- -D warnings
```

## Step 5: Summary report

Produce a table:

| File | Hunk | OSSM-only annotated? | Feature-flag gated? | Upstream gap? |
|---|---|---|---|---|
