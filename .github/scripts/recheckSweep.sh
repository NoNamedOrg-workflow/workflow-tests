#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C

workflowPath=${WORKFLOW_PATH:-.github/workflows/enforceRebase.yml}
mode=${MODE:-base-moved}
since=${SINCE:-}
maxReplays=${MAX_REPLAYS:-50}
replayed=0

# The sweep runs on every push to the default branch, so a bad setting is the only thing allowed to fail it.
abort() {
    echo "recheckSweep: $1" >&2
    exit 2
}

validateConfig() {
    [[ "${REPO:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || abort "REPO must be owner/repo"
    [ -n "${BASE:-}" ] || abort "BASE is required"
    [ "$mode" = base-moved ] || [ "$mode" = recover ] || abort "MODE must be base-moved or recover"
    [[ "$maxReplays" =~ ^[1-9][0-9]*$ ]] || abort "MAX_REPLAYS must be a positive integer"
    [ "$mode" = recover ] || return 0
    [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || abort "SINCE must be YYYY-MM-DDTHH:MM:SSZ in recover mode"
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
        | [(.id | tostring), (.status | tostring), (.updated_at | tostring), (.conclusion // "none")]
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
    [[ "$updated" < "$since" ]] || return 0
    echo "::notice::#$number run $id older than $since: skipped"
    return 1
}

shouldReplay() {
    local number=$1 id=$2 status=$3 updated=$4 conclusion=$5
    if [ "$status" != completed ]; then
        echo "::notice::#$number run $id is $status: skipped"
        return 1
    fi
    [ "$mode" = recover ] && { selectRecover "$number" "$id" "$updated" "$conclusion"; return $?; }
    selectBaseMoved "$number" "$id" "$updated" "$conclusion"
}

# Returns 3 when the ceiling is reached so the caller stops the whole sweep.
replay() {
    local number=$1 id=$2
    if [ "$replayed" -ge "$maxReplays" ]; then
        echo "::warning::limit of $maxReplays reruns reached"
        return 3
    fi
    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
        echo "::warning::#$number: run id is not numeric: skipped"
        return 0
    fi
    if ! gh api -X POST "repos/$REPO/actions/runs/$id/rerun" --silent; then
        echo "::warning::#$number: could not replay run $id"
        return 0
    fi
    echo "#$number: replayed run $id"
    replayed=$((replayed + 1))
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
    prs=$(echo "$pulls" | jq -r '.[] | [(.number | tostring), (.head.sha | tostring)] | @tsv') \
        || { echo "::warning::could not read the pull request listing"; return 0; }
    total=$(echo "$pulls" | jq 'length')
    [ "$total" -lt 100 ] || echo "::notice::100 open pull requests: the rest is not re-evaluated"
    while IFS=$'\t' read -r number sha; do
        [ -n "$number" ] || continue
        replayPull "$number" "$sha" || break
    done <<< "$prs"
}

main
echo "replayed: $replayed"
exit 0
