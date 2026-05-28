# gitops-promoter: Manual PR Merge Status Lag

## Observed Behavior

When a PR is manually merged on GitHub (outside of gitops-promoter's auto-merge), the
`PromotionStrategy` status for that environment shows `open` for one full polling cycle
(~1 minute) before transitioning to `externallyMergedOrClosed`. During that window,
downstream environments are correctly processed (their PRs created or auto-merged), but the
merged environment's own PR state is stale.

## Root Cause

Two separate reconcile loops are involved, and they cannot complete atomically in a single
webhook-triggered pass.

**Pass 1 — CTP reconciler (triggered by push webhook):**

When the PR is manually merged on GitHub, GitHub sends a push event to the active branch
(`environment/production/prod-1` in our case). The webhook handler receives it and enqueues
the `ChangeTransferPolicy` (CTP) for reconciliation. The CTP reconciler calls
`setPullRequestState`, which reads the `PullRequest` k8s object to copy its state into the
CTP status. At this point, the `PullRequest` k8s object still shows `state: open` — the PR
reconciler hasn't run yet. So the CTP status remains stale. Meanwhile, `calculateStatus`
correctly detects the new active branch SHAs and proceeds to process downstream environments
(creating/auto-merging prod-2, prod-3).

**Pass 2 — PR reconciler (scheduled, not webhook-driven):**

The `PullRequest` reconciler runs on its own schedule. It calls `provider.FindOpen()` on the
GitHub API, discovers the PR is gone, sets `ExternallyMergedOrClosed=true` on the
`PullRequest` k8s object, then re-triggers the CTP reconciler (via `.Owns(&PullRequest{})`).
The CTP reconciler runs again and the status is finally updated.

The gap between pass 1 and pass 2 is one polling interval — 1 minute by default.

## Related Issues

- **[#360 — SCM Pull Request Change Webhook support](https://github.com/argoproj-labs/gitops-promoter/issues/360)**  
  The tracking issue for this gap. Maintainer (zachaller) confirms: *"we do not reconcile
  pull requests on say a merge or a close of a PR on the SCM."* Open as of 2026-05-28.

- **[#827 — UI Extension: PR chip not showing if PR is manually merged](https://github.com/argoproj-labs/gitops-promoter/issues/827)**  
  A related symptom: the UI PR chip disappears/is incorrect after a manual merge, for the
  same underlying reason.

## How to Fix

The fix requires changes in gitops-promoter itself. The webhook handler
(`internal/webhookreceiver/server.go`) currently only processes push events — it filters on
the presence of a `pusher` field in the GitHub payload. `pull_request` events (action:
`closed`, `merged: true`) don't have that field and are silently dropped.

**Proposed approach:**

1. Subscribe to `pull_request` events in the GitHub App (checkbox on the webhook settings
   page).

2. Extend `findChangeTransferPolicy` (or add a parallel handler) in
   `internal/webhookreceiver/server.go` to handle `pull_request` payloads with
   `action: closed` / `merged: true`. On match, directly enqueue the corresponding
   `PullRequest` k8s object for reconciliation rather than the CTP.

3. The PR reconciler then runs immediately (within seconds), sets
   `ExternallyMergedOrClosed=true`, and re-triggers the CTP reconciler via `.Owns()`. The
   status update completes within seconds of the merge instead of waiting up to 1 minute.

**Why two passes are still needed:**

The CTP reconciler reads from the `PullRequest` k8s object, not directly from the GitHub
API. Even with webhook support, the PR reconciler must run first to update the k8s object
before the CTP can reflect the correct state. This is by design (the k8s object is the
source of truth for state). The webhook just collapses the wait from "next polling interval"
to "next event loop tick".

## Impact in This Demo

The lag is cosmetic for the demo pipeline: downstream promotions (prod-2, prod-3) trigger
correctly in the same pass. The only visible effect is that `status.sh` shows prod-1 as
`PR:open` for ~1 minute after manual merge. No correctness issue.
