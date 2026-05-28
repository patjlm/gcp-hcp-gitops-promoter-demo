#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

BRANCHES=(
  "environment/integration/main"
  "environment/stage/main"
  "environment/production/prod-1"
  "environment/production/prod-2"
  "environment/production/prod-3"
)

echo "=== Resetting all environment and proposed branches ==="

# Delete all proposed (-next) branches
echo "--- Deleting proposed branches ---"
proposed=$(git ls-remote origin 2>&1 | grep -- "-next" | awk '{print $2}' | sed 's|refs/heads/||' || true)
if [[ -n "$proposed" ]]; then
  for branch in $proposed; do
    echo "  Deleting $branch"
    git push origin --delete "$branch" 2>&1
  done
else
  echo "  No proposed branches to delete."
fi

# Delete all environment branches
echo "--- Deleting environment branches ---"
for branch in "${BRANCHES[@]}"; do
  if git ls-remote --exit-code origin "$branch" > /dev/null 2>&1; then
    echo "  Deleting $branch"
    git push origin --delete "$branch" 2>&1
  fi
done

# Recreate environment branches as empty orphans using a temporary clone
# (never touch the local worktree to avoid disrupting in-progress work)
echo "--- Creating fresh environment branches ---"
TMPCLONE=$(mktemp -d)
git clone --no-checkout --depth=1 "$(git remote get-url origin)" "$TMPCLONE" 2>&1
for branch in "${BRANCHES[@]}"; do
  echo "  Creating $branch"
  git -C "$TMPCLONE" checkout --orphan "$branch"
  git -C "$TMPCLONE" rm -rf . 2>/dev/null || true
  git -C "$TMPCLONE" -c commit.gpgsign=false commit --allow-empty -m "initialize $branch"
  git -C "$TMPCLONE" push origin "$branch" 2>&1
done
rm -rf "$TMPCLONE"

# Clean up stale CommitStatus CRs if kubectl is available
if command -v kubectl &> /dev/null && kubectl -n promoter-system get commitstatus &> /dev/null; then
  echo "--- Cleaning up CommitStatus CRs ---"
  kubectl -n promoter-system delete commitstatus --all 2>&1
fi

echo ""
echo "=== Reset complete ==="
echo "Push to main to trigger hydration."
