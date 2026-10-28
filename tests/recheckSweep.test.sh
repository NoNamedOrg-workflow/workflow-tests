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
        [ -e "$STUB_FX/otherPost-$id" ] && { echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; }
        [ -e "$STUB_FX/archivedPost-$id" ] && { echo "gh: workflow was already archived (HTTP 403)" >&2; exit 1; }
        [ -e "$STUB_FX/alreadyPost-$id" ] && { echo "gh: This workflow is already running (HTTP 403)" >&2; exit 1; }
        [ -e "$STUB_FX/failPost-$id" ] && fail
        ;;
    */actions/runs/*)
        id=${path##*/}
        [ -e "$STUB_FX/failRun-$id" ] && fail
        [ -e "$STUB_FX/slowRead" ] && command -p sleep "$(cat "$STUB_FX/slowRead")"
        [ -f "$STUB_FX/runseq-$id" ] || exit 0
        # Each read of a run answers with the next state of its sequence and then repeats the last one.
        count=$(( $(cat "$STUB_FX/runcnt-$id" 2> /dev/null || echo 0) + 1 ))
        echo "$count" > "$STUB_FX/runcnt-$id"
        total=$(wc -l < "$STUB_FX/runseq-$id")
        [ "$count" -le "$total" ] || count=$total
        sed -n "${count}p" "$STUB_FX/runseq-$id"
        ;;
esac
exit 0
STUB

chmod +x "$work/bin/gh"

# The wait must never really sleep: the fake only records how long it was asked to.
cat > "$work/bin/sleep" <<'STUB'
#!/usr/bin/env bash
echo "sleep $*" >> "$STUB_SLEEPS"
exit 0
STUB
chmod +x "$work/bin/sleep"

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
    : > "$work/sleeps.log"
    rm -f /tmp/pwned "$fx"/runcnt-*
    output=$(cd "$work" && env -i PATH="$work/bin:$PATH" HOME="$work" STUB_LOG="$work/calls.log" STUB_FX="$fx" \
        STUB_SLEEPS="$work/sleeps.log" \
        GH_TOKEN="$token" REPO=o/r BASE=development "$@" "$bashBin" "$sweep" 2>&1)
    status=$?
    calls=$(cat "$work/calls.log")
    sleeps=$(cat "$work/sleeps.log")
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
expect "T-S1 a green check is replayed" 0
has "posts the rerun on the right run" "api -X POST repos/o/r/actions/runs/10/rerun --silent" "$calls"
countIs "exactly one rerun" "/rerun" 1 "$calls"
has "reports the replay" "#1: replayed run 10" "$output"
has "last line is the count" "replayed: 1" "$(echo "$output" | tail -n 1)"
lacks "the sweep writes nothing to the pull request" "issues/" "$calls"

reset
pulls "$(pr 1 "$(sha 1)")"
runsFor "$(sha 1)" "$(mkRun 10 1 2026-01-01T00:00:00Z completed failure 2026-01-01T00:00:00Z)"
run
expect "T-S2 a failed check is not replayed" 0
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
run WAIT_SECONDS=0
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
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")" "$(pr 3 "$(sha 3)")"
for n in 1 2 3; do
    runsFor "$(sha "$n")" "$(mkRun "$(( n * 10 ))" 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
done
touch "$fx/failPost-10"
run MAX_REPLAYS=2
expect "T-S10 a failing rerun warns, goes on, consumes the ceiling and is not counted" 0
has "warns" "::warning::#1: could not replay run 10" "$output"
has "tries the next" "runs/20/rerun" "$calls"
lacks "the ceiling stops the third attempt" "runs/30/rerun" "$calls"
countIs "two attempts" "/rerun" 2 "$calls"
has "reports the ceiling" "::warning::limit of 2 reruns reached" "$output"
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
for n in 1 2 3 4 5; do
    items+=("$(pr "$n" "$(sha "$n")")")
    runsFor "$(sha "$n")" "$(mkRun "$(( n * 10 ))" 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
    touch "$fx/failPost-$(( n * 10 ))"
done
pulls "${items[@]}"
run MAX_REPLAYS=2
expect "T-S11c reruns that fail exhaust the ceiling" 0
countIs "exactly two attempts" "/rerun" 2 "$calls"
countIs "a single limit warning" "::warning::limit of 2 reruns reached" 1 "$output"
has "no success is counted" "replayed: 0" "$(echo "$output" | tail -n 1)"

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
greenPr 1
pulls "$(pr 1 "$(sha 1)")"
run BASE=release/1
expect "T-S16 a base with a slash is passed as an argument, not in the URL" 0
has "base as -f argument" "-f base=release/1" "$calls"
has "clean path" "api -X GET repos/o/r/pulls -f state=open" "$calls"
lacks "no query string in the URL" "pulls?" "$calls"
has "page size" "-f per_page=100" "$calls"

reset
pulls "$(pr 1 '$(touch /tmp/pwned)')" "$(pr 2 "$(sha 2)")"
runsFor "$(sha 2)" "$(mkRun '"5;touch /tmp/pwned"' 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
run
expect "T-S17 hostile sha and run id are data, not code" 0
[ -e /tmp/pwned ] && { failed=$((failed + 1)); echo "FAIL T-S17 something was executed"; rm -f /tmp/pwned; }
has "the hostile sha goes out as data in a query argument" 'head_sha=$(touch /tmp/pwned)' "$calls"
has "the hostile run id goes out as one quoted argument" "actions/runs/5;touch /tmp/pwned/rerun" "$calls"

reset
pulls "$(pr 3 "$(sha 3)")"
runsFor "$(sha 3)" "$(mkRun 30 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z 'x"$(touch /tmp/pwned)')"
run WORKFLOW_PATH='x"$(touch /tmp/pwned)'
expect "T-S17b a hostile workflow path is data, not code" 0
[ -e /tmp/pwned ] && { failed=$((failed + 1)); echo "FAIL T-S17b something was executed"; rm -f /tmp/pwned; }
has "the hostile path matched as a plain string" "runs/30/rerun" "$calls"

reset
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")"
runsFor "$(sha 1)" "$(mkRun 10 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
touch "$fx/failPost-10" "$fx/failRuns-$(sha 2)"
run
expect "T-S18 the token never shows in the output" 0
lacks "no token in the output" "$token" "$output"
lacks "no token in the gh calls" "$token" "$calls"
touch "$fx/failPulls"
run
lacks "no token when the listing fails" "$token" "$output"

reset
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")"
echo 'this is not json' > "$fx/runs-$(sha 1).json"
runsFor "$(sha 2)" "$(mkRun 20 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
run
expect "T-S19 a runs answer that is not JSON warns and the other pull requests go on" 0
has "warns about #1" "::warning::#1: could not read its runs" "$output"
has "replays #2" "runs/20/rerun" "$calls"
countIs "one rerun only" "/rerun" 1 "$calls"

reset
echo 'this is not json' > "$fx/pulls.json"
run
expect "T-S20 a pull request listing that is not JSON warns and posts nothing" 0
has "warns" "::warning::could not read the pull request listing" "$output"
lacks "no rerun" "/rerun" "$calls"

reset
echo '{"message":"Not Found"}' > "$fx/pulls.json"
run
expect "T-S20b a listing object with an error message warns and posts nothing" 0
has "warns" "::warning::" "$output"
lacks "no rerun" "/rerun" "$calls"

reset
echo 'null' > "$fx/pulls.json"
run
expect "T-S20d a null listing warns and posts nothing" 0
has "warns" "::warning::" "$output"
lacks "no rerun" "/rerun" "$calls"

reset
echo '[1]' > "$fx/pulls.json"
run
expect "T-S20e a list whose items are not pull requests warns and posts nothing" 0
has "warns" "::warning::could not read the pull request listing" "$output"
lacks "no rerun" "/rerun" "$calls"

reset
pulls "$(pr 1 "$(sha 1)")"
runsFor "$(sha 1)" "$(mkRun 10 1 2026-01-01T00:00:00Z completed '' 2026-01-01T00:00:00Z)"
run
expect "T-S22 a completed run without a conclusion is treated as none" 0
has "says none" "#1 run 10 already none: nothing to change" "$output"
lacks "no rerun" "/rerun" "$calls"

reset
pulls "$(pr 1 "$(sha 1)")"
runsFor "$(sha 1)" "$(mkRun 10 1 2026-03-02T00:00:00Z completed failure 2026-03-02T00:00:00Z)"
run MODE=recover SINCE=2026-03-01T00:00:00Z
expect "T-S27 MODE and SINCE are not read any more: a failed run is never replayed" 0
lacks "no rerun" "/rerun" "$calls"
has "says nothing to change" "#1 run 10 already failure: nothing to change" "$output"

reset
greenPr 1
run REPO=norepo
expect "T-S28 REPO comes from the github context and is not validated by the script" 0
has "the repository is used as given" "api -X GET repos/norepo/pulls" "$calls"
has "the run is replayed" "runs/10/rerun" "$calls"

# The template validates waitSeconds before this script runs; the script itself trusts its settings.
reset
greenPr 1
run MAX_REPLAYS=0 WAIT_SECONDS=1000
expect "T-S29 the script validates no setting: odd numbers are used as given and never fail the sweep" 0
lacks "no configuration error" "recheckSweep:" "$output"
has "the ceiling still holds with a ceiling of zero" "::warning::limit of 0 reruns reached" "$output"
lacks "no rerun" "/rerun" "$calls"
has "counts zero" "replayed: 0" "$(echo "$output" | tail -n 1)"

# The runs of the second pass: runSeq gives the state of a run each time it is read (1st read, 2nd read, ...) and
# repeats the last one, so every round of the wait reads the next state.
runSeq() {
    local id=$1
    shift
    printf '%s\n' "$@" > "$fx/runseq-$id"
}

runState() {
    mkRun "$1" 1 2026-01-01T00:00:00Z "$2" "$3" 2026-01-01T00:00:00Z
}

# pendingPr N: pull request N whose only run (id N*10) is in progress when the sweep lists it.
pendingPr() {
    runsFor "$(sha "$1")" "$(runState "$(( $1 * 10 ))" in_progress '')"
}

queries() {
    echo "$calls" | grep -c -x -F -- "api -X GET repos/o/r/actions/runs/$1"
}

sleepCount() {
    echo "$sleeps" | grep -c '^sleep'
}

reset
pulls "$(pr 1 "$(sha 1)")"
pendingPr 1
runSeq 10 "$(runState 10 in_progress '')" "$(runState 10 in_progress '')" "$(runState 10 completed success)"
run WAIT_SECONDS=60 POLL_SECONDS=5
expect "T-W1 a run in progress that ends in success is replayed after waiting" 0
has "announces the wait" "::notice::#1 run 10 is in progress: waiting for it to finish" "$output"
has "replays the run" "api -X POST repos/o/r/actions/runs/10/rerun --silent" "$calls"
countIs "one rerun" "/rerun" 1 "$calls"
has "reports the replay" "#1: replayed run 10" "$output"
lacks "never lists the runs in progress" "status=in_progress" "$calls"
[ "$(queries 10)" -eq 3 ] || { failed=$((failed + 1)); echo "FAIL T-W1 run 10 read $(queries 10) time(s), wanted 3"; }
[ "$(sleepCount)" -eq 2 ] || { failed=$((failed + 1)); echo "FAIL T-W1 slept $(sleepCount) time(s), wanted 2"; }
has "sleeps the poll interval" "sleep 5" "$sleeps"
has "last line is the count" "replayed: 1" "$(echo "$output" | tail -n 1)"

reset
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")"
pendingPr 1
pendingPr 2
runSeq 10 "$(runState 10 in_progress '')" "$(runState 10 completed success)"
runSeq 20 "$(runState 20 completed success)"
run WAIT_SECONDS=60 POLL_SECONDS=5
expect "T-W1b several pending runs share one sleep per round" 0
has "the first round replays the one already done" "runs/20/rerun" "$calls"
has "the next round replays the other" "runs/10/rerun" "$calls"
lacks "never lists the runs in progress" "status=in_progress" "$calls"
[ "$(sleepCount)" -eq 1 ] || { failed=$((failed + 1)); echo "FAIL T-W1b slept $(sleepCount) time(s), wanted 1"; }
[ "$(queries 20)" -eq 1 ] || { failed=$((failed + 1)); echo "FAIL T-W1b a finished run was read again"; }
[ "$(queries 10)" -eq 2 ] || { failed=$((failed + 1)); echo "FAIL T-W1b the run still going was read $(queries 10) time(s), wanted 2"; }
has "counts both" "replayed: 2" "$(echo "$output" | tail -n 1)"

reset
pulls "$(pr 1 "$(sha 1)")"
pendingPr 1
runSeq 10 "$(runState 10 in_progress '')" "$(runState 10 completed failure)"
run WAIT_SECONDS=60 POLL_SECONDS=5
expect "T-W2 a pending run that ends in failure is not replayed" 0
lacks "no rerun" "/rerun" "$calls"
has "says nothing to change" "#1 run 10 finished failure: nothing to change" "$output"
lacks "never lists the runs in progress" "status=in_progress" "$calls"
[ "$(sleepCount)" -eq 1 ] || { failed=$((failed + 1)); echo "FAIL T-W2 slept $(sleepCount) time(s), wanted 1"; }
[ "$(queries 10)" -eq 2 ] || { failed=$((failed + 1)); echo "FAIL T-W2 read the run $(queries 10) time(s), wanted 2"; }
has "counts zero" "replayed: 0" "$(echo "$output" | tail -n 1)"

reset
pulls "$(pr 1 "$(sha 1)")"
pendingPr 1
runSeq 10 "$(runState 10 in_progress '')"
run WAIT_SECONDS=20 POLL_SECONDS=5
expect "T-W3 a run that stays in progress is warned about once and never replayed" 0
lacks "no rerun" "/rerun" "$calls"
countIs "a single warning" "::warning::" 1 "$output"
has "the warning counts the runs left" "::warning::1 run(s) still in progress after 20s: not replayed" "$output"
[ "$(queries 10)" -eq 4 ] || { failed=$((failed + 1)); echo "FAIL T-W3 read the run $(queries 10) time(s), wanted 4"; }
has "counts zero" "replayed: 0" "$(echo "$output" | tail -n 1)"

reset
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")"
pendingPr 1
pendingPr 2
runSeq 10 "$(runState 10 queued '')"
runSeq 20 "$(runState 20 in_progress '')"
run WAIT_SECONDS=10 POLL_SECONDS=5
expect "T-W3b a queued run read by the second pass also stays pending" 0
countIs "a single warning for both runs" "::warning::" 1 "$output"
has "counts both" "::warning::2 run(s) still in progress after 10s: not replayed" "$output"
[ "$(queries 10)" -eq 2 ] || { failed=$((failed + 1)); echo "FAIL T-W3b the queued run was read $(queries 10) time(s), wanted 2"; }
[ "$(queries 20)" -eq 2 ] || { failed=$((failed + 1)); echo "FAIL T-W3b the run in progress was read $(queries 20) time(s), wanted 2"; }


reset
pulls "$(pr 1 "$(sha 1)")"
pendingPr 1
runSeq 10 "$(runState 10 completed success)"
run WAIT_SECONDS=0
expect "T-W4 WAIT_SECONDS=0 skips the run in progress as before" 0
has "old notice" "::notice::#1 run 10 is in_progress: skipped" "$output"
lacks "no waiting notice" "waiting for it" "$output"
lacks "no read of the run" "actions/runs/10" "$calls"
lacks "no rerun" "/rerun" "$calls"
[ "$(sleepCount)" -eq 0 ] || { failed=$((failed + 1)); echo "FAIL T-W4 slept"; }

reset
pulls "$(pr 1 "$(sha 1)")"
runsFor "$(sha 1)" "$(runState 10 queued '')"
runSeq 10 "$(runState 10 completed success)"
run
expect "T-W5 a queued run is skipped without waiting" 0
has "queued notice" "::notice::#1 run 10 is queued: skipped" "$output"
lacks "no read of the run" "actions/runs/10" "$calls"
lacks "no rerun" "/rerun" "$calls"
[ "$(sleepCount)" -eq 0 ] || { failed=$((failed + 1)); echo "FAIL T-W5 slept"; }

reset
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")" "$(pr 3 "$(sha 3)")"
runsFor "$(sha 1)" "$(runState 10 completed success)"
pendingPr 2
pendingPr 3
runSeq 20 "$(runState 20 in_progress '')" "$(runState 20 completed success)"
runSeq 30 "$(runState 30 completed success)"
run MAX_REPLAYS=1 WAIT_SECONDS=60 POLL_SECONDS=5
expect "T-W6 the ceiling holds in the second pass" 0
has "the normal run used the ceiling" "runs/10/rerun" "$calls"
countIs "no post beyond the ceiling" "/rerun" 1 "$calls"
lacks "pending run 20 is not replayed" "runs/20/rerun" "$calls"
lacks "pending run 30 is not replayed" "runs/30/rerun" "$calls"
countIs "a single limit warning" "::warning::limit of 1 reruns reached" 1 "$output"
countIs "no other warning" "::warning::" 1 "$output"
has "counts the one replay" "replayed: 1" "$(echo "$output" | tail -n 1)"

reset
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")" "$(pr 4 "$(sha 4)")"
for n in 1 2 4; do
    pendingPr "$n"
done
touch "$fx/failRun-10"
runSeq 20 "this is not json"
runSeq 40 "$(runState 40 completed success)"
run WAIT_SECONDS=60 POLL_SECONDS=5
expect "T-W7 an unreadable run answer warns and the other pull requests go on" 0
has "failed read" "::warning::#1: could not read run 10" "$output"
has "invalid JSON" "::warning::#2: could not read run 20" "$output"
has "replays #4" "runs/40/rerun" "$calls"
countIs "one rerun only" "/rerun" 1 "$calls"
lacks "unreadable runs are not read again" "still in progress" "$output"
[ "$(queries 10)" -eq 1 ] || { failed=$((failed + 1)); echo "FAIL T-W7 an unreadable run was read again"; }

reset
pulls "$(pr 1 "$(sha 1)")"
pendingPr 1
runSeq 10 "$(runState 10 in_progress '')"
run WAIT_SECONDS=30 POLL_SECONDS=7
expect "T-W10 the rounds are WAIT_SECONDS / POLL_SECONDS rounded down" 0
[ "$(queries 10)" -eq 4 ] || { failed=$((failed + 1)); echo "FAIL T-W10 read the run $(queries 10) time(s), wanted 4"; }
[ "$(sleepCount)" -eq 3 ] || { failed=$((failed + 1)); echo "FAIL T-W10 slept $(sleepCount) time(s), wanted 3"; }
has "sleeps the poll interval" "sleep 7" "$sleeps"

run WAIT_SECONDS=4 POLL_SECONDS=5
expect "T-W10b a wait shorter than the poll interval has no rounds" 0
[ "$(queries 10)" -eq 0 ] || { failed=$((failed + 1)); echo "FAIL T-W10b read the run"; }
[ "$(sleepCount)" -eq 0 ] || { failed=$((failed + 1)); echo "FAIL T-W10b slept"; }
has "still warns about the run left" "::warning::1 run(s) still in progress after 4s: not replayed" "$output"

run WAIT_SECONDS=5 POLL_SECONDS=5
expect "T-W10c one round reads once and never sleeps" 0
[ "$(queries 10)" -eq 1 ] || { failed=$((failed + 1)); echo "FAIL T-W10c read the run $(queries 10) time(s), wanted 1"; }
[ "$(sleepCount)" -eq 0 ] || { failed=$((failed + 1)); echo "FAIL T-W10c slept"; }

reset
pulls "$(pr 1 "$(sha 1)")"
pendingPr 1
runSeq 10 "$(runState 10 in_progress '')"
run WAIT_SECONDS=30
expect "T-W16 the default poll interval is 10 seconds" 0
[ "$(queries 10)" -eq 3 ] || { failed=$((failed + 1)); echo "FAIL T-W16 read the run $(queries 10) time(s), wanted 3"; }
[ "$(sleepCount)" -eq 2 ] || { failed=$((failed + 1)); echo "FAIL T-W16 slept $(sleepCount) time(s), wanted 2"; }
has "sleeps ten seconds" "sleep 10" "$sleeps"


reset
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")"
runsFor "$(sha 1)" "$(mkRun 10 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
runsFor "$(sha 2)" "$(mkRun 20 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
touch "$fx/alreadyPost-10"
run MAX_REPLAYS=1
expect "T-A1 a rerun refused because the run is already running is benign and keeps the ceiling" 0
has "notice" "::notice::#1 run 10 is already being replayed: skipped" "$output"
lacks "no warning" "::warning::" "$output"
has "the next run still gets the only attempt" "runs/20/rerun" "$calls"
has "counts only the real replay" "replayed: 1" "$(echo "$output" | tail -n 1)"
lacks "does not say replayed for the refused one" "#1: replayed" "$output"
lacks "the raw gh message never shows" "This workflow is already running" "$output"
lacks "no HTTP text either" "HTTP 403" "$output"

reset
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")"
runsFor "$(sha 1)" "$(mkRun 10 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
runsFor "$(sha 2)" "$(mkRun 20 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
touch "$fx/failPost-10"
run MAX_REPLAYS=1
expect "T-A2 any other rerun failure still warns and consumes the ceiling" 0
has "warning" "::warning::#1: could not replay run 10" "$output"
lacks "no benign notice" "already being replayed" "$output"
lacks "the ceiling stopped the next run" "runs/20/rerun" "$calls"
has "limit warning" "::warning::limit of 1 reruns reached" "$output"
lacks "the raw gh message never shows" "HTTP 500" "$output"

reset
pulls "$(pr 1 "$(sha 1)")"
pendingPr 1
runSeq 10 "$(runState 10 in_progress '')" "$(runState 10 completed success)"
touch "$fx/alreadyPost-10"
run WAIT_SECONDS=60 POLL_SECONDS=5
expect "T-A3 a benign refusal in the second pass is a notice, not a warning" 0
has "notice" "::notice::#1 run 10 is already being replayed: skipped" "$output"
lacks "no warning" "::warning::" "$output"
has "counts zero" "replayed: 0" "$(echo "$output" | tail -n 1)"
lacks "the raw gh message never shows" "This workflow is already running" "$output"

reset
pulls "$(pr 1 "$(sha 1)")"
pendingPr 1
runSeq 10 "$(runState 10 in_progress '')"
echo 2 > "$fx/slowRead"
run WAIT_SECONDS=2 POLL_SECONDS=1
expect "T-W11 the wait stops at the real deadline even with rounds left" 0
[ "$(queries 10)" -eq 1 ] || { failed=$((failed + 1)); echo "FAIL T-W11 read the run $(queries 10) time(s), wanted 1"; }
has "warns about the run left" "::warning::1 run(s) still in progress after 2s: not replayed" "$output"
lacks "no rerun" "/rerun" "$calls"

reset
items=()
for n in $(seq 1 50); do
    items+=("$(pr "$n" "$(sha "$n")")")
    pendingPr "$n"
    runSeq "$(( n * 10 ))" \
        "$(runState "$(( n * 10 ))" in_progress '')" "$(runState "$(( n * 10 ))" in_progress '')" \
        "$(runState "$(( n * 10 ))" in_progress '')" "$(runState "$(( n * 10 ))" in_progress '')" \
        "$(runState "$(( n * 10 ))" in_progress '')" "$(runState "$(( n * 10 ))" completed success)"
done
pulls "${items[@]}"
run WAIT_SECONDS=30 POLL_SECONDS=5
expect "T-W12 fifty pending runs are each read once per round, so the cost is bounded by the rounds" 0
lacks "never lists the runs in progress" "status=in_progress" "$calls"
total=0
for n in $(seq 1 50); do
    total=$((total + $(queries "$(( n * 10 ))")))
done
[ "$total" -eq 300 ] || { failed=$((failed + 1)); echo "FAIL T-W12 read $total runs, wanted 300 (50 runs, 6 rounds)"; }
has "all fifty replayed" "replayed: 50" "$(echo "$output" | tail -n 1)"


reset
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")"
runsFor "$(sha 1)" "$(mkRun 10 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
runsFor "$(sha 2)" "$(mkRun 20 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
touch "$fx/otherPost-10"
run MAX_REPLAYS=1
expect "T-A4 a 403 that is not already running warns and consumes the ceiling" 0
has "warning" "::warning::#1: could not replay run 10" "$output"
lacks "no benign notice" "already being replayed" "$output"
lacks "the ceiling stopped the next run" "runs/20/rerun" "$calls"
lacks "the raw gh message never shows" "Resource not accessible" "$output"

reset
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")"
runsFor "$(sha 1)" "$(mkRun 10 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
runsFor "$(sha 2)" "$(mkRun 20 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
touch "$fx/archivedPost-10"
run MAX_REPLAYS=1
expect "T-A5 a failure that only says already is not benign" 0
has "warning" "::warning::#1: could not replay run 10" "$output"
lacks "no benign notice" "already being replayed" "$output"
lacks "the ceiling stopped the next run" "runs/20/rerun" "$calls"

reset
pulls "$(pr 1 "$(sha 1)")" "$(pr 2 "$(sha 2)")" "$(pr 3 "$(sha 3)")"
pendingPr 1
runSeq 10 "$(runState 10 completed success)"
runsFor "$(sha 2)" "$(mkRun 20 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
runsFor "$(sha 3)" "$(mkRun 30 1 2026-01-01T00:00:00Z completed success 2026-01-01T00:00:00Z)"
run MAX_REPLAYS=1
expect "T-W15 reaching the ceiling in the main pass ends the sweep without waiting" 0
countIs "a single limit warning" "::warning::limit of 1 reruns reached" 1 "$output"
countIs "one rerun only" "/rerun" 1 "$calls"
[ "$(queries 10)" -eq 0 ] || { failed=$((failed + 1)); echo "FAIL T-W15 waited for the pending run"; }
[ "$(sleepCount)" -eq 0 ] || { failed=$((failed + 1)); echo "FAIL T-W15 slept"; }

echo "recheckSweep: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
