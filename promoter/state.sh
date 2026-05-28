#!/bin/bash
# Usage: ./promoter/state.sh
# Shows which dry SHA is deployed on each environment branch, using git only.
# Requires: git with fetch access to origin.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
REMOTE="${REMOTE:-origin}"

BRANCHES=(
  environment/integration/main
  environment/stage/main
  environment/production/prod-1
  environment/production/prod-2
  environment/production/prod-3
)

git fetch "$REMOTE" --quiet 2>/dev/null || true

printf "%-30s %-12s %-50s %s\n" "ENVIRONMENT" "DRY SHA" "SUBJECT" "PROMOTED AT"
printf "%-30s %-12s %-50s %s\n" "------------------------------" "------------" "--------------------------------------------------" "-------------------"

for branch in "${BRANCHES[@]}"; do
  ref="$REMOTE/$branch"
  if ! git rev-parse --verify "$ref" &>/dev/null; then
    printf "%-30s %s\n" "$branch" "(branch not found)"
    continue
  fi

  dry_sha=""
  subject=""
  promoted_at=""

  # Try hydrator.metadata first (most reliable)
  metadata=$(git show "$ref:hydrator.metadata" 2>/dev/null || true)
  if [[ -n "$metadata" ]]; then
    dry_sha=$(echo "$metadata" | python3 -c "import sys,json; print(json.load(sys.stdin)['drySha'])" 2>/dev/null || true)
    subject=$(echo "$metadata" | python3 -c "import sys,json; print(json.load(sys.stdin)['subject'])" 2>/dev/null || true)
    promoted_at=$(echo "$metadata" | python3 -c "import sys,json; print(json.load(sys.stdin)['date'])" 2>/dev/null || true)
  fi

  # Fallback: parse the most recent hydrate commit subject
  if [[ -z "$dry_sha" ]]; then
    hydrate_line=$(git log --format="%s" "$ref" | grep "^hydrate " | head -1)
    if [[ -n "$hydrate_line" ]]; then
      dry_sha=$(echo "$hydrate_line" | sed 's/^hydrate .* from //')
      promoted_at=$(git log --format="%aI" --extended-regexp --grep="^hydrate " "$ref" | head -1)
    fi
  fi

  # Fallback: no promotion yet
  if [[ -z "$dry_sha" ]]; then
    dry_sha="-"
    subject="(not yet promoted)"
    promoted_at="-"
  fi

  if [[ "$dry_sha" != "-" && -z "$subject" ]]; then
    subject=$(git log --format="%s" -1 "$dry_sha" 2>/dev/null || echo "")
  fi

  env_short="${branch#environment/}"
  printf "%-30s %-12s %-50s %s\n" \
    "$env_short" \
    "${dry_sha:0:12}" \
    "${subject:0:50}" \
    "${promoted_at}"
done
