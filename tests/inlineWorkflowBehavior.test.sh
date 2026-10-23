#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# DIST_FILE lets a mutation run prove the cases can go red; the default is the committed workflow.
dist=${DIST_FILE:-$root/dist/enforceRebase.yml}
bashBin=${BASH_BIN:-bash}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

# The step under test is the real one, cut out of the generated YAML (no yq or ruby on the runner image we mimic).
# The run: text is the block at ten spaces that follows the step's "run: |" line; the strip undoes that indentation.
# The embedded scripts start with #!/usr/bin/env bash, so the bash under test must come first in PATH to run them.
mkdir -p "$work/bin"
ln -s "$(command -v "$bashBin")" "$work/bin/bash"

stepBody() {
    awk -v name="$1" '
        $0 ~ "- name: " name "$" { on = 1; next }
        on && /^      - name:/ { exit }
        on && /^        run: \|/ { body = 1; next }
        on && body { sub(/^          /, ""); print }
    ' "$dist"
}

commitFile() {
    echo "$2" > "$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -q -m "$2"
}

configure() {
    git -C "$1" config user.name tester
    git -C "$1" config user.email tester@example.com
    git -C "$1" config commit.gpgsign false
}

# A bare origin with main at one commit, plus a seed clone to move the base and a work clone for the pull request.
newRepo() {
    scene="$work/$1"
    mkdir -p "$scene/tmp"
    git init -q --bare -b main "$scene/origin.git"
    git clone -q "$scene/origin.git" "$scene/seed" 2> /dev/null
    configure "$scene/seed"
    commitFile "$scene/seed" base
    git -C "$scene/seed" push -q origin HEAD:refs/heads/main
    git clone -q "$scene/origin.git" "$scene/pr" 2> /dev/null
    configure "$scene/pr"
}

# runStep BASE: executes the extracted step the way the runner does (bash -e) inside the work clone.
runStep() {
    : > "$scene/out"
    headSha=$(git -C "$scene/pr" rev-parse HEAD)
    output=$(cd "$scene/pr" && env PATH="$work/bin:$PATH" BASE="$1" HEAD_SHA="$headSha" RUNNER_TEMP="$scene/tmp" GITHUB_OUTPUT="$scene/out" \
        "$bashBin" -e "$work/check.sh" 2>&1 < /dev/null)
    status=$?
}

# assert NAME COMMAND...: the command succeeding means the case passed.
assert() {
    local name=$1
    shift
    if "$@"; then
        passed=$((passed + 1))
        echo "PASS $name"
        return 0
    fi
    failed=$((failed + 1))
    echo "FAIL $name"
    echo "$output" | sed 's/^/    /'
}

isUnexpectedFailure() {
    [ "$status" -ne 0 ] && [ "$status" -ne 1 ] && ! grep -q '^ok=' "$scene/out"
}

verdict() {
    local name=$1 wantStatus=$2 wantOut=$3 wantText=$4 forbidden=${5:-}
    local problems=""
    [ "$status" -eq "$wantStatus" ] || problems="$problems exit $status (wanted $wantStatus);"
    [ -z "$wantOut" ] || grep -q -x -F -- "$wantOut" "$scene/out" || problems="$problems output file lacks $wantOut;"
    [ -z "$wantText" ] || echo "$output" | grep -q -F -- "$wantText" || problems="$problems text lacks '$wantText';"
    [ -z "$forbidden" ] || ! echo "$output" | grep -q -F -- "$forbidden" || problems="$problems text has '$forbidden';"
    if [ -z "$problems" ]; then
        passed=$((passed + 1))
        echo "PASS $name"
        return 0
    fi
    failed=$((failed + 1))
    echo "FAIL $name:$problems"
    echo "$output" | sed 's/^/    /'
}

stepBody "Check rebase" > "$work/check.sh"
[ -s "$work/check.sh" ] || { echo "FAIL could not cut the Check rebase step out of the generated workflow"; exit 1; }

for count in 1 2 3; do
    newRepo "linear$count"
    git -C "$scene/pr" checkout -q -b feature
    for n in $(seq 1 "$count"); do
        commitFile "$scene/pr" "work$n"
    done
    runStep main
    verdict "T-RF19-b/behavior-linear-$count a rebased branch with $count linear commit(s) passes" 0 "ok=true" "branch is rebased"
done

newRepo behind
git -C "$scene/pr" checkout -q -b feature
commitFile "$scene/pr" work
commitFile "$scene/seed" moved
commitFile "$scene/seed" movedAgain
git -C "$scene/seed" push -q origin HEAD:refs/heads/main
runStep main
verdict "T-RF19-b/behavior-behind a branch behind the base fails and says by how many" 0 "ok=false" "branch is 2 commit(s) behind"

newRepo merged
git -C "$scene/pr" checkout -q -b feature
commitFile "$scene/pr" work
commitFile "$scene/seed" moved
git -C "$scene/seed" push -q origin HEAD:refs/heads/main
git -C "$scene/pr" fetch -q origin
git -C "$scene/pr" merge -q --no-edit origin/main 2> /dev/null
runStep main
verdict "T-RF19-b/behavior-merge a branch with a merge commit fails and says so" 0 "ok=false" "merge commit"

newRepo unrelated
git -C "$scene/pr" checkout -q --orphan other
commitFile "$scene/pr" lonely
runStep main
verdict "T-RF19-b/behavior-orphan history without a common ancestor exits 2 and does not claim the base is ahead" 2 "" "no common ancestor" "behind"

newRepo shallow
rm -rf "$scene/pr"
git clone -q --depth 1 "file://$scene/origin.git" "$scene/pr" 2> /dev/null
runStep main
verdict "T-RF19-b/behavior-shallow a shallow clone exits 2 with its own message" 2 "" "shallow clone"

newRepo missingBase
git -C "$scene/pr" checkout -q -b feature
commitFile "$scene/pr" work
runStep gone
assert "T-RF19-b/behavior-unexpected an origin without the base branch fails unexpectedly (not exit 0 or 1) and writes no ok= line" isUnexpectedFailure
assert "T-RF19-b/behavior-unexpected-2 nothing is written to the output" test ! -s "$scene/out"

# The tag sits on an older commit than the branch of the same name: resolving the short name would call the branch behind.
newRepo tag
commitFile "$scene/seed" moved
git -C "$scene/seed" tag release "HEAD~1"
git -C "$scene/seed" push -q origin HEAD:refs/heads/release refs/tags/release
git -C "$scene/pr" fetch -q origin
git -C "$scene/pr" checkout -q -b feature origin/release
commitFile "$scene/pr" work
runStep release
verdict "T-RF19-b/behavior-tag a tag named like the base branch does not fool the verdict" 0 "ok=true" "branch is rebased"

hostile='$(touch${IFS}'"$work"'/pwned)'
newRepo hostile
git -C "$scene/seed" push -q origin "HEAD:refs/heads/$hostile"
git -C "$scene/pr" fetch -q origin
git -C "$scene/pr" checkout -q -b feature "origin/$hostile"
commitFile "$scene/pr" work
runStep "$hostile"
verdict "T-RF19-b/behavior-injection a base branch with shell syntax passes as plain text" 0 "ok=true" "branch is rebased"
assert "T-RF19-b/behavior-injection-2 nothing was executed" test ! -e "$work/pwned"

echo "inlineWorkflowBehavior: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
