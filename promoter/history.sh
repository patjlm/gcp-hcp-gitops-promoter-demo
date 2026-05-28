#!/bin/bash
# Usage: ./promoter/history.sh [SINCE]
# Shows promotion history across all environment branches.
# SINCE: git date format, e.g. "1d", "2h", "2026-05-28" (default: 1d)
# Requires: git with fetch access to origin.

set -euo pipefail

SINCE="${1:-1d}"
REMOTE="${REMOTE:-origin}"

BRANCHES=(
  environment/integration/main
  environment/stage/main
  environment/production/prod-1
  environment/production/prod-2
  environment/production/prod-3
)

git fetch "$REMOTE" --quiet 2>/dev/null || true

echo "Promotion history (since $SINCE)"
echo "================================"
echo

for branch in "${BRANCHES[@]}"; do
  ref="$REMOTE/$branch"
  if ! git rev-parse --verify "$ref" &>/dev/null; then
    continue
  fi

  env_short="${branch#environment/}"
  header_printed=false

  # Each promotion = one merge commit + one hydrate commit with the same dry SHA.
  # Walk merge commits for the PR number + date, extract dry SHA from the paired hydrate commit.
  # Fall back to bare hydrate commits for branches promoted without a PR (e.g. initial state).
  declare -A seen_shas

  while IFS='|' read -r merge_sha merge_date merge_subject; do
    [[ -z "$merge_sha" ]] && continue
    pr_num=$(echo "$merge_subject" | grep -oP '#\K[0-9]+' | head -1 || true)
    pr_num="${pr_num:--}"
    hydrate_s=$(git log --format="%s" "${merge_sha}^1..${merge_sha}" 2>/dev/null | grep "^hydrate " | head -1 || true)
    [[ -z "$hydrate_s" ]] && continue
    dry_sha=$(echo "$hydrate_s" | sed 's/^hydrate .* from //')
    [[ ${#dry_sha} -lt 7 ]] && continue
    seen_shas[$dry_sha]=1
    dry_subject=$(git log --format="%s" -1 "$dry_sha" 2>/dev/null || echo "")
    if ! $header_printed; then echo "--- ${env_short} ---"; header_printed=true; fi
    echo "  ${merge_date}  PR #${pr_num}  dry:${dry_sha:0:12}  ${dry_subject:0:60}"
  done < <(git log --merges --format="%H|%aI|%s" --since="$SINCE" "$ref" 2>/dev/null)

  # Hydrate-only commits not covered by a merge (first init or squash)
  while IFS='|' read -r commit_date commit_subject; do
    [[ -z "$commit_date" ]] && continue
    dry_sha=$(echo "$commit_subject" | sed 's/^hydrate .* from //')
    [[ ${#dry_sha} -lt 7 ]] && continue
    [[ -n "${seen_shas[$dry_sha]+x}" ]] && continue
    seen_shas[$dry_sha]=1
    dry_subject=$(git log --format="%s" -1 "$dry_sha" 2>/dev/null || echo "")
    if ! $header_printed; then echo "--- ${env_short} ---"; header_printed=true; fi
    echo "  ${commit_date}           dry:${dry_sha:0:12}  ${dry_subject:0:60}"
  done < <(git log --no-merges --extended-regexp --grep="^hydrate " --format="%aI|%s" --since="$SINCE" "$ref" 2>/dev/null)

  unset seen_shas

  if $header_printed; then
    echo
  fi
done

# Summary: are all environments on the same dry SHA?
echo "--- Sync check ---"
declare -A env_shas
all_same=true
prev_sha=""
for branch in "${BRANCHES[@]}"; do
  ref="$REMOTE/$branch"
  sha=""
  metadata=$(git show "$ref:hydrator.metadata" 2>/dev/null || true)
  if [[ -n "$metadata" ]]; then
    sha=$(echo "$metadata" | python3 -c "import sys,json; print(json.load(sys.stdin)['drySha'][:12])" 2>/dev/null || true)
  fi
  if [[ -z "$sha" ]]; then
    hydrate_line=$(git log --format="%s" "$ref" 2>/dev/null | grep "^hydrate " | head -1)
    if [[ -n "$hydrate_line" ]]; then
      sha=$(echo "$hydrate_line" | sed 's/^hydrate .* from //' | cut -c1-12)
    fi
  fi
  sha="${sha:--}"
  env_short="${branch#environment/}"
  env_shas["$env_short"]="$sha"
  if [[ -n "$prev_sha" && "$sha" != "$prev_sha" ]]; then
    all_same=false
  fi
  prev_sha="$sha"
done

if $all_same && [[ "$prev_sha" != "-" ]]; then
  echo "  All environments on the same dry SHA: $prev_sha"
else
  for env in "${!env_shas[@]}"; do
    printf "  %-30s %s\n" "$env" "${env_shas[$env]}"
  done | sort
fi
