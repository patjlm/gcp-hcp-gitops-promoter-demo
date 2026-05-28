#!/usr/bin/env bash
# Poll the GitHub Events API every 60s, showing new events without duplicates.
# Usage: ./watch-gh-events.sh <owner/repo> [EventType ...]
# Example: ./watch-gh-events.sh openshift/hypershift PushEvent PullRequestEvent

set -uo pipefail

REPO="${1:?Usage: $0 <owner/repo> [EventType ...]}"
shift
FILTER_TYPES=("$@")
POLL_INTERVAL=60
BASE_URL="https://api.github.com/repos/$REPO/events"

TOKEN=$(gh auth token 2>/dev/null) || { echo "Error: run 'gh auth login' first" >&2; exit 1; }

declare -A seen_ids
ETAG=""

fmt_event() {
    local e="$1" type actor ts detail
    type=$(jq -r '.type' <<< "$e")
    actor=$(jq -r '.actor.login' <<< "$e")
    ts=$(jq -r '.created_at' <<< "$e")

    case "$type" in
        PushEvent)
            local ref n
            ref=$(jq -r '.payload.ref | ltrimstr("refs/heads/")' <<< "$e")
            n=$(jq -r '.payload.commits | length' <<< "$e")
            detail="$actor pushed $n commit(s) to $ref"
            ;;
        PullRequestEvent)
            local action num title head base
            action=$(jq -r '.payload.action' <<< "$e")
            num=$(jq -r '.payload.number' <<< "$e")
            title=$(jq -r '.payload.pull_request.title' <<< "$e")
            head=$(jq -r '.payload.pull_request.head.ref' <<< "$e")
            base=$(jq -r '.payload.pull_request.base.ref' <<< "$e")
            detail="PR #$num $action by $actor [$head → $base]: $title"
            ;;
        PullRequestReviewEvent)
            local num state head base
            num=$(jq -r '.payload.pull_request.number' <<< "$e")
            state=$(jq -r '.payload.review.state' <<< "$e")
            head=$(jq -r '.payload.pull_request.head.ref' <<< "$e")
            base=$(jq -r '.payload.pull_request.base.ref' <<< "$e")
            detail="PR #$num review $state by $actor [$head → $base]"
            ;;
        PullRequestReviewCommentEvent)
            local num
            num=$(jq -r '.payload.pull_request.number' <<< "$e")
            detail="PR #$num comment by $actor"
            ;;
        IssuesEvent)
            local action num title
            action=$(jq -r '.payload.action' <<< "$e")
            num=$(jq -r '.payload.issue.number' <<< "$e")
            title=$(jq -r '.payload.issue.title' <<< "$e")
            detail="Issue #$num $action by $actor: $title"
            ;;
        IssueCommentEvent)
            local num
            num=$(jq -r '.payload.issue.number' <<< "$e")
            detail="Issue #$num commented by $actor"
            ;;
        CreateEvent)
            local ref_type ref
            ref_type=$(jq -r '.payload.ref_type' <<< "$e")
            ref=$(jq -r '.payload.ref // ""' <<< "$e")
            detail="$actor created $ref_type${ref:+ $ref}"
            ;;
        DeleteEvent)
            local ref_type ref
            ref_type=$(jq -r '.payload.ref_type' <<< "$e")
            ref=$(jq -r '.payload.ref' <<< "$e")
            detail="$actor deleted $ref_type $ref"
            ;;
        ForkEvent)
            detail="$actor forked to $(jq -r '.payload.forkee.full_name' <<< "$e")"
            ;;
        WatchEvent)
            detail="$actor starred the repo"
            ;;
        ReleaseEvent)
            local action tag
            action=$(jq -r '.payload.action' <<< "$e")
            tag=$(jq -r '.payload.release.tag_name' <<< "$e")
            detail="$actor $action release $tag"
            ;;
        CheckRunEvent)
            local action name status conclusion sha branch prs
            action=$(jq -r '.payload.action' <<< "$e")
            name=$(jq -r '.payload.check_run.name' <<< "$e")
            status=$(jq -r '.payload.check_run.status' <<< "$e")
            conclusion=$(jq -r '.payload.check_run.conclusion // ""' <<< "$e")
            sha=$(jq -r '.payload.check_run.head_sha[:7]' <<< "$e")
            branch=$(jq -r '.payload.check_run.check_suite.head_branch // ""' <<< "$e")
            prs=$(jq -r '[.payload.check_run.pull_requests[].number] | if length > 0 then " on PR #" + (map(tostring) | join(", #")) else "" end' <<< "$e")
            if [[ "$action" == "completed" ]]; then
                detail="check [${conclusion:-$status}] '$name'$prs${branch:+ [$branch]} ($sha)"
            else
                detail="check [$status] '$name'$prs${branch:+ [$branch]} ($sha)"
            fi
            ;;
        CheckSuiteEvent)
            local action status conclusion branch prs
            action=$(jq -r '.payload.action' <<< "$e")
            status=$(jq -r '.payload.check_suite.status' <<< "$e")
            conclusion=$(jq -r '.payload.check_suite.conclusion // ""' <<< "$e")
            branch=$(jq -r '.payload.check_suite.head_branch // ""' <<< "$e")
            prs=$(jq -r '[.payload.check_suite.pull_requests[].number] | if length > 0 then " on PR #" + (map(tostring) | join(", #")) else "" end' <<< "$e")
            if [[ "$action" == "completed" ]]; then
                detail="suite [${conclusion:-$status}]$prs${branch:+ [$branch]}"
            else
                detail="suite [$status]$prs${branch:+ [$branch]}"
            fi
            ;;
        StatusEvent)
            local state context sha branches
            state=$(jq -r '.payload.state' <<< "$e")
            context=$(jq -r '.payload.context' <<< "$e")
            sha=$(jq -r '.payload.sha[:7]' <<< "$e")
            branches=$(jq -r '[.payload.branches[].name] | join(", ")' <<< "$e")
            detail="[$state] '$context'${branches:+ [$branches]} ($sha) by $actor"
            ;;
        *)
            detail="$actor"
            ;;
    esac

    printf '%s  %-34s  %s\n' "$ts" "$type" "$detail"
}

should_show() {
    [[ ${#FILTER_TYPES[@]} -eq 0 ]] && return 0
    local type="$1"
    for ft in "${FILTER_TYPES[@]}"; do [[ "$type" == "$ft" ]] && return 0; done
    return 1
}

# Fetch one page of events; mark all as seen; if display=true, print new ones
# in chronological order. Uses ETag to skip unchanged responses.
poll() {
    local display="${1:-true}"
    local body hdr
    body=$(mktemp) || return 1
    hdr=$(mktemp) || { rm -f "$body"; return 1; }

    local -a args=(
        -s -D "$hdr" -o "$body"
        -H "Authorization: Bearer $TOKEN"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )
    [[ -n "$ETAG" ]] && args+=(-H "If-None-Match: $ETAG")

    if ! curl "${args[@]}" "$BASE_URL?per_page=100"; then
        echo "[$(date -u +%FT%TZ)] curl error" >&2
        rm -f "$body" "$hdr"; return 1
    fi

    local status
    status=$(awk 'NR==1{print $2}' "$hdr")

    if [[ "$status" == "304" ]]; then
        [[ "$display" == true ]] && echo "[$(date -u +%T)Z] poll — no new events (304)" >&2
        rm -f "$body" "$hdr"; return 0
    fi

    if [[ "$status" != "200" ]]; then
        echo "[$(date -u +%T)Z] API error $status: $(jq -r '.message // "unknown"' "$body" 2>/dev/null)" >&2
        rm -f "$body" "$hdr"; return 1
    fi

    local new_etag
    new_etag=$(grep -i '^etag:' "$hdr" | tr -d '\r' | awk '{print $2}')
    [[ -n "$new_etag" ]] && ETAG="$new_etag"

    local -a new_events=()
    while IFS= read -r event; do
        local id type
        id=$(jq -r '.id' <<< "$event")
        type=$(jq -r '.type' <<< "$event")
        [[ -n "${seen_ids[$id]+_}" ]] && continue
        seen_ids[$id]=1
        should_show "$type" && new_events+=("$event")
    done < <(jq -c '.[]' "$body" 2>/dev/null)

    rm -f "$body" "$hdr"

    if [[ "$display" == true ]]; then
        local n=${#new_events[@]}
        if (( n == 0 )); then
            echo "[$(date -u +%T)Z] poll — no new events (200)" >&2
        else
            echo "[$(date -u +%T)Z] poll — $n new event(s)" >&2
            # API returns newest-first; reverse to print chronologically
            for (( i=n-1; i>=0; i-- )); do
                fmt_event "${new_events[$i]}"
            done
        fi
    fi
}

echo "Watching $REPO — polling every ${POLL_INTERVAL}s — Ctrl-C to stop"
[[ ${#FILTER_TYPES[@]} -gt 0 ]] && echo "Filtering: ${FILTER_TYPES[*]}"
echo

poll false  # baseline: mark current events as seen without displaying them

while true; do
    sleep "$POLL_INTERVAL"
    poll true
done
