# Cherry-pick to release branch

Use this workflow to backport a commit from master to a release branch.

## Steps

1. **Identify the commit** to cherry-pick. Use the original (non-merge) commit SHA where possible.
   If you must use a merge commit, pass `-m 1` to specify the mainline parent:

   ```bash
   git cherry-pick -x -m 1 <merge-sha>
   ```

2. **Checkout the release branch**:

   ```bash
   git fetch midstream
   git checkout release-X.Y
   ```

3. **Cherry-pick**:

   ```bash
   git cherry-pick -x <sha>
   ```

   Resolve conflicts if needed. Keep `OSSM-only:` annotations (in their correct per-language syntax)
   and `#[cfg(feature = "tls-openssl")]` gates intact.

4. **Verify tests pass locally**:

   ```bash
   cargo build && cargo test && cargo test --features tls-openssl
   ```

5. **Push to your fork and open a PR** targeting `openshift-service-mesh/ztunnel:release-X.Y`.

   Title format: `<version>: <original title>` (e.g., `1.31: chore: update rustls-openssl`).
   Body format: `cherry-picked from: <sha>`.

   ```bash
   git push origin cherry-pick-<sha>-to-release-X.Y
   gh pr create --base release-X.Y \
     --title "X.Y: <original title>" \
     --body "cherry-picked from: <sha>"
   ```

6. **Reference the upstream PR** in the PR description if the change originated upstream.
