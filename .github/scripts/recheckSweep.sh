#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C

workflowPath=${WORKFLOW_PATH:-.github/workflows/enforceRebase.yml}
maxReplays=${MAX_REPLAYS:-50}
waitSeconds=${WAIT_SECONDS-120}
pollSeconds=${POLL_SECONDS-10}
replayed=0
attempts=0
# "number id" lines of the runs that were in progress when listed.
pending=

listPulls() {
    gh api -X GET "repos/$REPO/pulls" -f state=open -f base="$BASE" -f per_page=100
}

listRuns() {
    gh api -X GET "repos/$REPO/actions/runs" -f head_sha="$1" -f event=pull_request -f per_page=50
}

# The ruleset run and the repository's own run share a path but not a workflow_id, so each id keeps its latest run.
latestRuns() {
    jq -r --arg path "$workflowPath" '
        [.workflow_runs[] | select(.path == $path)]
        | group_by(.workflow_id)
        | map(sort_by(.created_at) | last)
        | .[]
        | [(.id | tostring), (.status | tostring), (.conclusion // "none")]
        | @tsv'
}

# A run in progress may have read the base before the push that started this sweep, so it is awaited, not skipped.
# A queued run reads the live base when it starts, after that push, so it never goes stale.
shouldWait() {
    local id=$1 status=$2
    [ "$status" = in_progress ] && [ "$waitSeconds" -gt 0 ]
}

shouldReplay() {
    local number=$1 id=$2 status=$3 conclusion=$4
    if shouldWait "$id" "$status"; then
        echo "::notice::#$number run $id is in progress: waiting for it to finish"
        pending="$pending$number $id"$'\n'
        return 1
    fi
    if [ "$status" != completed ]; then
        echo "::notice::#$number run $id is $status: skipped"
        return 1
    fi
    [ "$conclusion" = success ] && return 0
    echo "#$number run $id already $conclusion: nothing to change"
    return 1
}

# Returns 3 when the ceiling is reached so the caller stops the whole sweep.
replay() {
    local number=$1 id=$2 failure
    if [ "$attempts" -ge "$maxReplays" ]; then
        echo "::warning::limit of $maxReplays reruns reached"
        return 3
    fi
    attempts=$((attempts + 1))
    # The stderr is only matched, never printed.
    if ! failure=$(gh api -X POST "repos/$REPO/actions/runs/$id/rerun" --silent 2>&1); then
        if [[ "$failure" == *"already running"* ]]; then
            attempts=$((attempts - 1))
            echo "::notice::#$number run $id is already being replayed: skipped"
            return 0
        fi
        echo "::warning::#$number: could not replay run $id"
        return 0
    fi
    echo "#$number: replayed run $id"
    replayed=$((replayed + 1))
}

readRunState() {
    local raw
    raw=$(gh api -X GET "repos/$REPO/actions/runs/$1") || return 1
    echo "$raw" | jq -er '[.status, (.conclusion // "none")] | @tsv'
}

# One round over the pending runs: each is read on its own and only those still running stay in pending.
pollPending() {
    local remaining="" number id state status conclusion code
    while read -r number id; do
        [ -n "$id" ] || continue
        if ! state=$(readRunState "$id"); then
            echo "::warning::#$number: could not read run $id"
            continue
        fi
        read -r status conclusion <<< "$state"
        if [ "$status" != completed ]; then
            remaining="$remaining$number $id"$'\n'
            continue
        fi
        if [ "$conclusion" != success ]; then
            echo "#$number run $id finished $conclusion: nothing to change"
            continue
        fi
        replay "$number" "$id"
        code=$?
        [ "$code" -ne 3 ] || return 3
    done <<< "$pending"
    pending=$remaining
}

# The clock also bounds the time spent in the calls themselves, which the rounds alone do not.
waitPending() {
    local rounds=$((waitSeconds / pollSeconds)) round=0 started=$SECONDS left
    while [ "$round" -lt "$rounds" ] && [ -n "$pending" ] && [ $((SECONDS - started)) -lt "$waitSeconds" ]; do
        [ "$round" -eq 0 ] || sleep "$pollSeconds"
        round=$((round + 1))
        pollPending || return 0
    done
    [ -n "$pending" ] || return 0
    left=$(printf '%s' "$pending" | grep -c .)
    echo "::warning::$left run(s) still in progress after ${waitSeconds}s: not replayed"
}

replayPull() {
    local number=$1 sha=$2 raw runs id status conclusion
    raw=$(listRuns "$sha") || { echo "::warning::#$number: could not read its runs"; return 0; }
    runs=$(echo "$raw" | latestRuns) || { echo "::warning::#$number: could not read its runs"; return 0; }
    [ -n "$runs" ] || { echo "::notice::#$number has no check run yet: skipped"; return 0; }
    while IFS=$'\t' read -r id status conclusion; do
        shouldReplay "$number" "$id" "$status" "$conclusion" || continue
        replay "$number" "$id" || return $?
    done <<< "$runs"
}

main() {
    local pulls prs total number sha
    pulls=$(listPulls) || { echo "::warning::could not list the open pull requests"; return 0; }
    prs=$(echo "$pulls" | jq -r '.[] | [(.number | tostring), (.head.sha | tostring)] | @tsv') \
        || { echo "::warning::could not read the pull request listing"; return 0; }
    total=$(echo "$pulls" | jq 'length')
    [ "$total" -lt 100 ] || echo "::notice::100 open pull requests: the rest is not re-evaluated"
    while IFS=$'\t' read -r number sha; do
        [ -n "$number" ] || continue
        replayPull "$number" "$sha" || return 0
    done <<< "$prs"
    waitPending
}

main
echo "replayed: $replayed"
exit 0
