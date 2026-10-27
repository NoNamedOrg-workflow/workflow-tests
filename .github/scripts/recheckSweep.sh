#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C

workflowPath=${WORKFLOW_PATH:-.github/workflows/enforceRebase.yml}
mode=${MODE:-base-moved}
since=${SINCE:-}
maxReplays=${MAX_REPLAYS:-50}
waitSeconds=${WAIT_SECONDS-120}
pollSeconds=${POLL_SECONDS-5}
replayed=0
attempts=0
# Lines of "number id" for the runs that were in progress when listed and may still be reading an older base.
pending=

# The sweep runs on every push to the default branch, so a bad setting is the only thing allowed to fail it.
abort() {
    echo "recheckSweep: $1" >&2
    exit 2
}

timestampPattern='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

validateConfig() {
    [[ "${REPO:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || abort "REPO must be owner/repo"
    # A dot segment would climb out of repos/ in the API path.
    [ "${REPO%%/*}" != . ] && [ "${REPO%%/*}" != .. ] && [ "${REPO#*/}" != . ] && [ "${REPO#*/}" != .. ] \
        || abort "REPO must be owner/repo"
    [ -n "${BASE:-}" ] || abort "BASE is required"
    [ "$mode" = base-moved ] || [ "$mode" = recover ] || abort "MODE must be base-moved or recover"
    [[ "$maxReplays" =~ ^[1-9][0-9]*$ ]] || abort "MAX_REPLAYS must be a positive integer"
    [[ "$waitSeconds" =~ ^(0|[1-9][0-9]{0,2})$ ]] && [ "$waitSeconds" -le 600 ] \
        || abort "WAIT_SECONDS must be an integer from 0 to 600"
    [[ "$pollSeconds" =~ ^[1-9][0-9]?$ ]] && [ "$pollSeconds" -le 60 ] \
        || abort "POLL_SECONDS must be an integer from 1 to 60"
    [ "$mode" = recover ] || return 0
    [[ "$since" =~ $timestampPattern ]] || abort "SINCE must be YYYY-MM-DDTHH:MM:SSZ in recover mode"
}

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
        | [(.id | tostring), (.status | tostring), (.updated_at | tostring | select(. != "") // "null"), (.conclusion // "none")]
        | @tsv'
}

selectBaseMoved() {
    local number=$1 id=$2 conclusion=$4
    [ "$conclusion" = success ] && return 0
    echo "#$number run $id already $conclusion: nothing to change"
    return 1
}

selectRecover() {
    local number=$1 id=$2 updated=$3 conclusion=$4
    case "$conclusion" in
        failure | timed_out | cancelled) ;;
        *)
            echo "#$number run $id already $conclusion: nothing to change"
            return 1
            ;;
    esac
    if [[ ! "$updated" =~ $timestampPattern ]]; then
        echo "::notice::#$number run $id has no valid update time: skipped"
        return 1
    fi
    [[ "$updated" < "$since" ]] || return 0
    echo "::notice::#$number run $id older than $since: skipped"
    return 1
}

# A run in progress may have read the base before the push that started this sweep, so it is awaited, not skipped.
# A queued run reads the live base when it starts, after that push, so it never goes stale.
shouldWait() {
    local id=$1 status=$2
    [ "$mode" = base-moved ] && [ "$status" = in_progress ] && [ "$waitSeconds" -gt 0 ] && [[ "$id" =~ ^[0-9]+$ ]]
}

shouldReplay() {
    local number=$1 id=$2 status=$3 updated=$4 conclusion=$5
    if shouldWait "$id" "$status"; then
        echo "::notice::#$number run $id is in progress: waiting for it to finish"
        pending="$pending$number $id"$'\n'
        return 1
    fi
    if [ "$status" != completed ]; then
        echo "::notice::#$number run $id is $status: skipped"
        return 1
    fi
    [ "$mode" = recover ] && { selectRecover "$number" "$id" "$updated" "$conclusion"; return $?; }
    selectBaseMoved "$number" "$id" "$updated" "$conclusion"
}

# Returns 3 when the ceiling is reached so the caller stops the whole sweep.
replay() {
    local number=$1 id=$2 failure
    if [ "$attempts" -ge "$maxReplays" ]; then
        echo "::warning::limit of $maxReplays reruns reached"
        return 3
    fi
    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
        echo "::warning::#$number: run id is not numeric: skipped"
        return 0
    fi
    attempts=$((attempts + 1))
    # Sweeps of two pushes run side by side: GitHub refuses a rerun of a run already rerunning, which is no failure.
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
    echo "$raw" | jq -er 'select(type == "object" and (.status | type) == "string") | [.status, (.conclusion // "none")] | @tsv'
}

# One round over the pending runs; keeps in pending only those still running. Returns 3 when the ceiling is reached.
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
        [ "$code" -ne 3 ] || { pending=; return 3; }
    done <<< "$pending"
    pending=$remaining
}

# Rounds are counted, not timed, so a fake sleep makes the wait deterministic and the loop always ends.
waitPending() {
    local rounds=$((waitSeconds / pollSeconds)) round=0 left
    while [ "$round" -lt "$rounds" ] && [ -n "$pending" ]; do
        [ "$round" -eq 0 ] || sleep "$pollSeconds"
        round=$((round + 1))
        pollPending || return 0
    done
    [ -n "$pending" ] || return 0
    left=$(printf '%s' "$pending" | grep -c .)
    echo "::warning::$left run(s) still in progress after ${waitSeconds}s: not replayed"
}

replayPull() {
    local number=$1 sha=$2 raw runs id status updated conclusion
    if [[ ! "$number" =~ ^[0-9]+$ ]] || [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        echo "::warning::skipped a pull request with a malformed number or sha"
        return 0
    fi
    raw=$(listRuns "$sha") || { echo "::warning::#$number: could not read its runs"; return 0; }
    runs=$(echo "$raw" | latestRuns) || { echo "::warning::#$number: could not read its runs"; return 0; }
    [ -n "$runs" ] || { echo "::notice::#$number has no check run yet: skipped"; return 0; }
    while IFS=$'\t' read -r id status updated conclusion; do
        shouldReplay "$number" "$id" "$status" "$updated" "$conclusion" || continue
        replay "$number" "$id" || return $?
    done <<< "$runs"
}

main() {
    local pulls prs total number sha
    validateConfig
    pulls=$(listPulls) || { echo "::warning::could not list the open pull requests"; return 0; }
    echo "$pulls" | jq -e 'type == "array"' > /dev/null \
        || { echo "::warning::could not read the pull request listing"; return 0; }
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
