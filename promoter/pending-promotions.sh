#!/bin/bash
# Usage: ./promoter/pending-promotions.sh
# Shows pending promotions: open PRs from proposed (-next) to active branches,
# with current vs incoming dry SHA and commit status gates.
# Requires: git with fetch access to origin, gh CLI with API access.

set -eo pipefail

REMOTE="${REMOTE:-origin}"
REPO="${REPO:-patjlm/gcp-hcp-gitops-promoter-demo}"

BRANCHES=(
  environment/integration/main
  environment/stage/main
  environment/production/prod-1
  environment/production/prod-2
  environment/production/prod-3
)

git fetch "$REMOTE" --quiet 2>/dev/null || true

# Fetch all open PRs in one API call
prs_json=$(gh api "repos/${REPO}/pulls?state=open&per_page=50" 2>/dev/null || echo "[]")

pending=0

for branch in "${BRANCHES[@]}"; do
  env_short="${branch#environment/}"
  next_branch="${branch}-next"
  active_ref="$REMOTE/$branch"
  next_ref="$REMOTE/$next_branch"

  # Check if proposed branch exists and differs from active
  if ! git rev-parse --verify "$next_ref" &>/dev/null; then
    continue
  fi
  if ! git rev-parse --verify "$active_ref" &>/dev/null; then
    continue
  fi

  # Get dry SHAs from both branches
  active_dry=""
  next_dry=""
  next_subject=""
  next_author=""

  metadata=$(git show "$active_ref:hydrator.metadata" 2>/dev/null || true)
  if [[ -n "$metadata" ]]; then
    active_dry=$(echo "$metadata" | python3 -c "import sys,json; print(json.load(sys.stdin)['drySha'])" 2>/dev/null || true)
  fi
  if [[ -z "$active_dry" ]]; then
    hydrate_line=$(git log --format="%s" "$active_ref" | grep "^hydrate " | head -1)
    if [[ -n "$hydrate_line" ]]; then
      active_dry=$(echo "$hydrate_line" | sed 's/^hydrate .* from //')
    fi
  fi

  metadata=$(git show "$next_ref:hydrator.metadata" 2>/dev/null || true)
  if [[ -n "$metadata" ]]; then
    next_dry=$(echo "$metadata" | python3 -c "import sys,json; print(json.load(sys.stdin)['drySha'])" 2>/dev/null || true)
    next_subject=$(echo "$metadata" | python3 -c "import sys,json; print(json.load(sys.stdin)['subject'])" 2>/dev/null || true)
    next_author=$(echo "$metadata" | python3 -c "import sys,json; print(json.load(sys.stdin)['author'])" 2>/dev/null || true)
  fi
  if [[ -z "$next_dry" ]]; then
    hydrate_line=$(git log --format="%s" "$next_ref" | grep "^hydrate " | head -1)
    if [[ -n "$hydrate_line" ]]; then
      next_dry=$(echo "$hydrate_line" | sed 's/^hydrate .* from //')
    fi
  fi

  # Skip if both branches are on the same dry SHA (nothing pending)
  if [[ "$active_dry" == "$next_dry" ]]; then
    continue
  fi

  # Find the PR for this branch pair
  pr_info=$(echo "$prs_json" | python3 -c "
import sys, json
prs = json.load(sys.stdin)
for p in prs:
    if p['base']['ref'] == '${branch}' and p['head']['ref'] == '${next_branch}':
        print(f'{p[\"number\"]}|{p[\"html_url\"]}|{p[\"title\"]}')
        break
" 2>/dev/null || true)

  pr_num=$(echo "$pr_info" | cut -d'|' -f1)
  pr_url=$(echo "$pr_info" | cut -d'|' -f2)
  pr_title=$(echo "$pr_info" | cut -d'|' -f3)

  if [[ -z "$pr_num" && "$active_dry" == "$next_dry" ]]; then
    continue
  fi

  pending=$((pending + 1))

  echo "--- ${env_short} ---"
  if [[ -n "$pr_num" ]]; then
    echo "  PR #${pr_num}: ${pr_title}"
    echo "  ${pr_url}"
  else
    echo "  (no PR yet — proposed branch ahead of active)"
  fi
  echo "  current: ${active_dry:0:12}  $(git log --format="%s" -1 "${active_dry}" 2>/dev/null || echo "")"
  echo "  pending: ${next_dry:0:12}  ${next_subject:-$(git log --format="%s" -1 "${next_dry}" 2>/dev/null || echo "")}"
  if [[ -n "$next_author" ]]; then
    echo "  author:  ${next_author}"
  fi

  # Fetch commit statuses on the proposed branch tip (gates for PR merge)
  next_sha=$(git rev-parse "$next_ref" 2>/dev/null)
  if [[ -n "$next_sha" ]]; then
    statuses=$(gh api "repos/${REPO}/commits/${next_sha}/status" 2>/dev/null || true)
    if [[ -n "$statuses" ]]; then
      status_count=$(echo "$statuses" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_count',0))" 2>/dev/null || echo "0")
      if [[ "$status_count" -gt 0 ]]; then
        echo "  commit statuses (proposed):"
        echo "$statuses" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('statuses', []):
    icon = {'success': '✓', 'pending': '⏳', 'failure': '✗'}.get(s['state'], '?')
    print(f'    {icon} {s[\"context\"]}: {s[\"state\"]}  ({s[\"description\"]})')
" 2>/dev/null
      fi
    fi
  fi

  # Fetch commit statuses on the active branch tip (gates for next env)
  active_sha=$(git rev-parse "$active_ref" 2>/dev/null)
  if [[ -n "$active_sha" ]]; then
    statuses=$(gh api "repos/${REPO}/commits/${active_sha}/status" 2>/dev/null || true)
    if [[ -n "$statuses" ]]; then
      status_count=$(echo "$statuses" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_count',0))" 2>/dev/null || echo "0")
      if [[ "$status_count" -gt 0 ]]; then
        echo "  commit statuses (active):"
        echo "$statuses" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('statuses', []):
    icon = {'success': '✓', 'pending': '⏳', 'failure': '✗'}.get(s['state'], '?')
    print(f'    {icon} {s[\"context\"]}: {s[\"state\"]}  ({s[\"description\"]})')
" 2>/dev/null
      fi
    fi
  fi
  echo
done

if [[ "$pending" -eq 0 ]]; then
  echo "No pending promotions — all environments are in sync."
fi
