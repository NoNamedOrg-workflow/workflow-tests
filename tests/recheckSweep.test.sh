#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
sweep="$root/.github/scripts/recheckSweep.sh"
bashBin=${BASH_BIN:-bash}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
token=ghs_TestOnlyTokenValue0123456789
checkPath=.github/workflows/enforceRebase.yml
fx="$work/fx"

# Only the external edge is faked: a gh that logs each call, serves fixtures per endpoint and can fail per endpoint.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
fail() {
    echo "gh: HTTP 500" >&2
    exit 1
}
path=${4:-}
case "$path" in
    */pulls)
        [ -e "$STUB_FX/failPulls" ] && fail
        cat "$STUB_FX/pulls.json"
        ;;
    */actions/runs)
        sha=
        for arg in "$@"; do
            case "$arg" in
                head_sha=*) sha=${arg#head_sha=} ;;
            esac
        done
        [ -e "$STUB_FX/failRuns-$sha" ] && fail
        [ -f "$STUB_FX/runs-$sha.json" ] && { cat "$STUB_FX/runs-$sha.json"; exit 0; }
        echo '{"workflow_runs":[]}'
        ;;
    */rerun)
        id=${path%/rerun}
        id=${id##*/}
        [ -e "$STUB_FX/failPost-$id" ] && fail
        ;;
esac
exit 0
STUB
chmod +x "$work/bin/gh"

sha() {
    printf '%040d' "$1"
}

pr() {
    printf '{"number":%s,"head":{"sha":"%s"},"draft":%s}' "$1" "$2" "${3:-false}"
}

pulls() {
    local out="[" sep="" item
    for item in "$@"; do
        out="$out$sep$item"
        sep=,
    done
    echo "$out]" > "$fx/pulls.json"
}

mkRun() {
    jq -cn \
        --argjson id "$1" \
        --argjson wf "$2" \
        --arg created "$3" \
        --arg status "$4" \
        --arg conclusion "$5" \
        --arg updated "$6" \
        --arg path "${7:-$checkPath}" \
        '{id: $id, workflow_id: $wf, created_at: $created, status: $status, conclusion: ($conclusion | select(. != "") // null),
        updated_at: $updated, path: $path}'
}

runsFor() {
    local target=$1
    shift
    printf '%s\n' "$@" | jq -s '{workflow_runs: .}' > "$fx/runs-$target.json"
}

greenPr() {
    pulls "$(pr "$1" "$(sha "$1")")"
    runsFor "$(sha "$1")" "$(mkRun "$(( $1 * 10 ))" 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
}

run() {
    : > "$work/calls.log"
    rm -f /tmp/pwned
    output=$(cd "$work" && env -i PATH="$work/bin:$PATH" HOME="$work" STUB_LOG="$work/calls.log" STUB_FX="$fx" \
        GH_TOKEN="$token" REPO=o/r BASE=development "$@" "$bashBin" "$sweep" 2>&1)
    status=$?
    calls=$(cat "$work/calls.log")
}

reset() {
    rm -rf "$fx"
    mkdir -p "$fx"
}

expect() {
    local name=$1 wantStatus=$2
    if [ "$status" -eq "$wantStatus" ]; then
        passed=$((passed + 1))
        echo "PASS $name"
        return 0
    fi
    failed=$((failed + 1))
    echo "FAIL $name (exit $status, wanted $wantStatus)"
    echo "$output" | sed 's/^/    /' | head -12
}

has() {
    local name=$1 pattern=$2 text=$3
    echo "$text" | grep -q -F -- "$pattern" && return 0
    failed=$((failed + 1))
    echo "FAIL $name: missing '$pattern'"
    echo "$text" | sed 's/^/    /' | head -12
}

lacks() {
    local name=$1 pattern=$2 text=$3
    echo "$text" | grep -q -F -- "$pattern" || return 0
    failed=$((failed + 1))
    echo "FAIL $name: unexpected '$pattern'"
    echo "$text" | sed 's/^/    /' | head -12
}

countIs() {
    local name=$1 pattern=$2 want=$3 text=$4 got
    got=$(echo "$text" | grep -c -F -- "$pattern")
    [ "$got" -eq "$want" ] && return 0
    failed=$((failed + 1))
    echo "FAIL $name: '$pattern' appears $got time(s), wanted $want"
}

reset
greenPr 1
run
expect "T-S1 a green check is replayed in base-moved mode" 0
has "posts the rerun on the right run" "api -X POST repos/o/r/actions/runs/10/rerun --silent" "$calls"
countIs "exactly one rerun" "/rerun" 1 "$calls"
has "reports the replay" "#1: replayed run 10" "$output"
has "last line is the count" "replayed: 1" "$(echo "$output" | tail -n 1)"
lacks "the sweep writes nothing to the pull request" "issues/" "$calls"

reset
pulls "$(pr 1 "$(sha 1)")"
runsFor "$(sha 1)" "$(mkRun 10 1 2026-01-01T00:00:00Z completed failure 2026-01-01T00:00:00Z)"
run
expect "T-S2 a failed check is not replayed in base-moved mode" 0
lacks "no rerun" "/rerun" "$calls"
has "says nothing to change" "#1 run 10 already failure: nothing to change" "$output"
has "counts zero" "replayed: 0" "$output"

reset
pulls "$(pr 1 "$(sha 1)")"
run
expect "T-S3 a pull request without a run is noticed and skipped" 0
has "notice" "::notice::#1 has no check run yet: skipped" "$output"
lacks "no rerun" "/rerun" "$calls"

reset
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")" "$(pr 3 "$(sha 3)")"
runsFor "$(sha 1)" "$(mkRun 10 1 2026-01-01T00:00:00Z in_progress '' 2026-01-01T00:00:00Z)"
runsFor "$(sha 2)" "$(mkRun 20 1 2026-01-01T00:00:00Z queued '' 2026-01-01T00:00:00Z)"
runsFor "$(sha 3)" "$(mkRun 30 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
run
expect "T-S4 a run still in flight is noticed and skipped, the others go on" 0
has "in_progress notice" "::notice::#1 run 10 is in_progress: skipped" "$output"
has "queued notice" "::notice::#2 run 20 is queued: skipped" "$output"
lacks "in-flight run 10 is not replayed" "runs/10/rerun" "$calls"
lacks "in-flight run 20 is not replayed" "runs/20/rerun" "$calls"
has "the next pull request is still replayed" "runs/30/rerun" "$calls"

reset
pulls "$(pr 1 "$(sha 1)" true)"
runsFor "$(sha 1)" "$(mkRun 10 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
run
expect "T-S5 a draft pull request is replayed too" 0
has "draft run replayed" "runs/10/rerun" "$calls"

reset
pulls "$(pr 1 "$(sha 1)")"
runsFor "$(sha 1)" \
    "$(mkRun 22 2 2026-02-02T00:00:00Z completed success 2026-02-02T00:00:00Z)" \
    "$(mkRun 21 2 2026-02-01T00:00:00Z completed failure 2026-02-01T00:00:00Z)" \
    "$(mkRun 11 1 2026-02-01T00:00:00Z completed success 2026-02-01T00:00:00Z)" \
    "$(mkRun 12 1 2026-02-02T00:00:00Z completed failure 2026-02-02T00:00:00Z)"
run
expect "T-S6 two workflow ids on one path: the latest run of each is handled" 0
has "latest of the second id is replayed" "runs/22/rerun" "$calls"
lacks "older success of the first id is not replayed" "runs/11/rerun" "$calls"
lacks "older failure of the second id is not replayed" "runs/21/rerun" "$calls"
lacks "latest failure of the first id is not replayed" "runs/12/rerun" "$calls"
has "the latest failure is reported" "#1 run 12 already failure: nothing to change" "$output"
countIs "one rerun only" "/rerun" 1 "$calls"

reset
pulls "$(pr 1 "$(sha 1)")"
runsFor "$(sha 1)" "$(mkRun 10 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z .github/workflows/other.yml)"
run
expect "T-S7 a run of another workflow path is ignored" 0
lacks "no rerun" "/rerun" "$calls"
has "counts as no check run" "#1 has no check run yet: skipped" "$output"

reset
greenPr 1
touch "$fx/failPulls"
run
expect "T-S8 a failing listing only warns and replays nothing" 0
has "warns" "::warning::" "$output"
lacks "no rerun" "/rerun" "$calls"
lacks "does not read runs either" "actions/runs" "$calls"

reset
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")"
runsFor "$(sha 2)" "$(mkRun 20 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
touch "$fx/failRuns-$(sha 1)"
run
expect "T-S9 a failing runs read warns and the other pull requests go on" 0
has "warns about #1" "::warning::#1: could not read its runs" "$output"
has "replays #2" "runs/20/rerun" "$calls"

reset
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")"
runsFor "$(sha 1)" "$(mkRun 10 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
runsFor "$(sha 2)" "$(mkRun 20 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
touch "$fx/failPost-10"
run
expect "T-S10 a failing rerun warns, goes on and is not counted" 0
has "warns" "::warning::#1: could not replay run 10" "$output"
has "tries the next" "runs/20/rerun" "$calls"
has "counts only the success" "replayed: 1" "$(echo "$output" | tail -n 1)"
lacks "the failed one is not reported as replayed" "#1: replayed" "$output"

reset
items=()
for n in 1 2 3 4 5; do
    items+=("$(pr "$n" "$(sha "$n")")")
    runsFor "$(sha "$n")" "$(mkRun "$(( n * 10 ))" 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
done
pulls "${items[@]}"
run MAX_REPLAYS=2
expect "T-S11 the ceiling stops the sweep" 0
countIs "exactly two reruns" "/rerun" 2 "$calls"
countIs "a single limit warning" "::warning::limit of 2 reruns reached" 1 "$output"
has "counts the ceiling" "replayed: 2" "$(echo "$output" | tail -n 1)"

run MAX_REPLAYS=5
expect "T-S11b exactly at the ceiling there is no warning" 0
countIs "five reruns" "/rerun" 5 "$calls"
lacks "no limit warning" "limit of" "$output"

reset
items=()
for n in $(seq 1 100); do
    items+=("$(pr "$n" "$(sha "$n")")")
done
pulls "${items[@]}"
run
expect "T-S12 a full page of 100 pull requests is noticed" 0
has "notice about the rest" "::notice::100 open pull requests: the rest is not re-evaluated" "$output"

pulls "${items[@]:0:99}"
run
expect "T-S12b 99 pull requests raise no page notice" 0
lacks "no page notice" "the rest is not re-evaluated" "$output"

reset
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")" "$(pr 3 "$(sha 3)")" "$(pr 4 "$(sha 4)")" "$(pr 5 "$(sha 5)")"
runsFor "$(sha 1)" "$(mkRun 10 1 2026-03-02T00:00:00Z completed failure 2026-03-02T00:00:00Z)"
runsFor "$(sha 2)" "$(mkRun 20 1 2026-03-02T00:00:00Z completed timed_out 2026-03-02T00:00:00Z)"
runsFor "$(sha 3)" "$(mkRun 30 1 2026-03-02T00:00:00Z completed cancelled 2026-03-02T00:00:00Z)"
runsFor "$(sha 4)" "$(mkRun 40 1 2026-02-01T00:00:00Z completed failure 2026-02-01T00:00:00Z)"
runsFor "$(sha 5)" "$(mkRun 50 1 2026-03-02T00:00:00Z completed success 2026-03-02T00:00:00Z)"
run MODE=recover SINCE=2026-03-01T00:00:00Z
expect "T-S13 recover replays failures inside the window only" 0
has "failure replayed" "runs/10/rerun" "$calls"
has "timed_out replayed" "runs/20/rerun" "$calls"
has "cancelled replayed" "runs/30/rerun" "$calls"
lacks "failure before SINCE not replayed" "runs/40/rerun" "$calls"
lacks "success not replayed" "runs/50/rerun" "$calls"
has "reports the old one" "#4 run 40 older than 2026-03-01T00:00:00Z: skipped" "$output"
has "reports the success" "#5 run 50 already success: nothing to change" "$output"
has "counts three" "replayed: 3" "$(echo "$output" | tail -n 1)"

reset
pulls "$(pr 1 "$(sha 1)")"
runsFor "$(sha 1)" "$(mkRun 10 1 2026-03-02T00:00:00Z completed neutral 2026-03-02T00:00:00Z)"
run MODE=recover SINCE=2026-03-01T00:00:00Z
expect "T-S13b recover leaves other conclusions alone" 0
lacks "no rerun" "/rerun" "$calls"

reset
greenPr 1
for bad in REPO=norepo REPO='o/r;id' MODE=weird MODE=recover "MODE=recover SINCE=2026-03-01" "MODE=recover SINCE=ontem" \
    MAX_REPLAYS=0 MAX_REPLAYS=abc MAX_REPLAYS=-3 BASE=; do
    run $bad
    expect "T-S14 invalid configuration '$bad' exits 2" 2
    [ -z "$calls" ] || { failed=$((failed + 1)); echo "FAIL T-S14 '$bad' called gh: $calls"; }
    has "'$bad' says why on stderr" "recheckSweep:" "$output"
done

reset
pulls \
    "$(pr '"7;id"' "$(sha 1)")" \
    "$(pr 8 zzzz)" \
    "$(pr 9 ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD)" \
    "$(pr null "$(sha 3)")" \
    "$(pr 10 "$(sha 10)")"
runsFor "$(sha 10)" "$(mkRun 100 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
run
expect "T-S15 malformed number or sha is warned about and skipped" 0
countIs "four warnings" "::warning::" 4 "$output"
countIs "runs are read for the valid pull request only" "-X GET repos/o/r/actions/runs" 1 "$calls"
has "the valid pull request is replayed" "runs/100/rerun" "$calls"

reset
greenPr 1
pulls "$(pr 1 "$(sha 1)")"
run BASE=release/1
expect "T-S16 a base with a slash is passed as an argument, not in the URL" 0
has "base as -f argument" "-f base=release/1" "$calls"
has "clean path" "api -X GET repos/o/r/pulls -f state=open" "$calls"
lacks "no query string in the URL" "pulls?" "$calls"
has "page size" "-f per_page=100" "$calls"

reset
pulls "$(pr 1 '$(touch /tmp/pwned)')" "$(pr 2 "$(sha 2)")" "$(pr 3 "$(sha 3)")"
runsFor "$(sha 2)" "$(mkRun '"5;touch /tmp/pwned"' 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
runsFor "$(sha 3)" "$(mkRun 30 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z 'x"$(touch /tmp/pwned)')"
run WORKFLOW_PATH='x"$(touch /tmp/pwned)'
expect "T-S17 hostile payload and path are data, not code" 0
[ -e /tmp/pwned ] && { failed=$((failed + 1)); echo "FAIL T-S17 something was executed"; rm -f /tmp/pwned; }
lacks "hostile run id is not replayed" "runs/5" "$calls"
has "the hostile path matched as a plain string" "runs/30/rerun" "$calls"
has "the hostile sha was refused" "::warning::" "$output"

reset
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")"
runsFor "$(sha 1)" "$(mkRun 10 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
touch "$fx/failPost-10" "$fx/failRuns-$(sha 2)"
run
expect "T-S18 the token never shows in the output" 0
lacks "no token in the output" "$token" "$output"
lacks "no token in the gh calls" "$token" "$calls"
run REPO=bad
lacks "no token on a configuration error" "$token" "$output"

echo "recheckSweep: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
