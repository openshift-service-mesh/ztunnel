# Sync Check — classify a change as OSSM-specific or upstream candidate

Answer these questions to determine how a change should be handled.
See [docs/upstream.md](../../docs/upstream.md) for the contribution workflow.

## Step 1: Is this change OSSM-specific by nature?

Examples: OCP CI config, OpenSSL/FIPS TLS backend, OSSM branding, Red Hat compliance patches.

→ If YES: annotate with `OSSM-only: <JIRA-KEY> <reason>` using the correct comment syntax for
the file type (see `.claude/rules/api-conventions.md`). Gate TLS changes behind
`#[cfg(feature = "tls-openssl")]`. No upstream PR needed. Stop.

## Step 2: Does the equivalent fix already exist in upstream ztunnel?

Check: <https://github.com/istio/ztunnel>

→ If YES: cherry-pick or rebase from upstream rather than rewriting. Reference the upstream
commit in the PR description.

## Step 3: Does this change belong upstream but no PR exists yet?

→ Open an upstream PR first. Once merged upstream, cherry-pick into midstream and note the
upstream PR in the description.

## Summary

| Situation | Action |
|---|---|
| OSSM-specific forever | Annotate `OSSM-only:` (language-aware syntax), feature-flag if TLS |
| Already upstream | Cherry-pick / rebase from upstream |
| Belongs upstream, not yet merged | Open upstream PR first |
