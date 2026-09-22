# Upstream Relationship

## Overview

This repository is the Red Hat midstream fork of [istio/ztunnel](https://github.com/istio/ztunnel).
It is maintained at
[openshift-service-mesh/ztunnel](https://github.com/openshift-service-mesh/ztunnel) and carries
OpenShift Service Mesh (OSSM) specific patches on top of the upstream ztunnel codebase.

The midstream fork tracks upstream ztunnel release branches and adds changes required for
OpenShift integration, FIPS compliance (OpenSSL TLS backend), OSSM-specific bug fixes,
and CI configuration.

## Repository Structure

| Role      | URL                                                      |
|-----------|----------------------------------------------------------|
| Upstream  | <https://github.com/istio/ztunnel>                       |
| Midstream | <https://github.com/openshift-service-mesh/ztunnel>      |

## Branch Mapping

Each midstream branch tracks the same-named upstream branch.

| Midstream Branch | Upstream Branch | OSSM Release |
|------------------|-----------------|--------------|
| `master`         | `master`        | (next)       |
| `release-1.24`   | `release-1.24`  | OSSM 3.0     |
| `release-1.26`   | `release-1.26`  | OSSM 3.1     |
| `release-1.27`   | `release-1.27`  | OSSM 3.2     |
| `release-1.28`   | `release-1.28`  | OSSM 3.3     |
| `release-1.30`   | `release-1.30`  | OSSM 3.4     |
| `release-1.31`   | `release-1.31`  | OSSM 3.5     |

## Contribution Workflow

1. **Prefer upstream first.** Changes that are not OSSM-specific should be proposed as pull
   requests to [istio/ztunnel](https://github.com/istio/ztunnel). Once merged upstream,
   they will be synced into the midstream fork.
2. **OSSM-specific changes** (OpenSSL/FIPS patches, OCP CI config, OSSM-only features)
   go directly to this midstream repository.
3. Bug fixes that affect both upstream and midstream should land upstream first to avoid
   long-lived divergence.

## Sync Process

Upstream changes are brought into midstream through periodic merges and targeted cherry-picks,
orchestrated by `ossm/merge_upstream.sh`.

- An automator bot performs routine merges from upstream branches into the corresponding
  midstream branches.
- When the bot merge produces conflicts or when specific commits need to be pulled ahead of
  a full merge, maintainers perform manual cherry-picks.
- After a sync, CI (Prow) runs on the midstream branch to validate that OSSM patches still
  apply cleanly and all tests pass.

## Coding Conventions

- Follow the coding style and conventions of the upstream ztunnel project (Rust, `rustfmt`, `clippy`).
- OSSM-specific patches must be kept as small and isolated as possible.
- Do not modify upstream code unnecessarily; prefer additive changes or feature-flag gating.

### Labeling permanent OSSM changes

Changes that are intentional, permanent divergences from upstream must be annotated so they
survive future merges without confusion:

```rust
// OSSM-only: <JIRA-KEY> <short reason>
```

Example:

```rust
// OSSM-only: OSSM-12345 FIPS compliance requires OpenSSL instead of rustls
```

Use `git grep "OSSM-only"` to find all permanent patches quickly.

Changes intended for upstream contribution should reference the upstream issue or PR in the
commit message rather than in a code comment.

## PR Process

| Target            | Where to open the PR                                    |
|-------------------|---------------------------------------------------------|
| Community feature | <https://github.com/istio/ztunnel>                      |
| OSSM-only change  | <https://github.com/openshift-service-mesh/ztunnel>     |

All PRs are gated by CI (Prow). Reference the relevant JIRA issue in the PR description.

## CI Configuration

Prow CI job definitions are located in the
[openshift/release](https://github.com/openshift/release) repository under
`ci-operator/config/openshift-service-mesh/ztunnel/`.
