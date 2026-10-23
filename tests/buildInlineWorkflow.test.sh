#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
builder="$root/tools/buildInlineWorkflow.sh"
dist="$root/dist/enforceRebase.yml"
bashBin=${BASH_BIN:-bash}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

pass() {
    passed=$((passed + 1))
    echo "PASS $1"
}

fail() {
    failed=$((failed + 1))
    echo "FAIL $1"
}

# check NAME CONDITION...: the condition is a command whose success means the case passed.
check() {
    local name=$1
    shift
    if "$@" > /dev/null 2>&1; then
        pass "$name"
        return 0
    fi
    fail "$name"
}

# Cuts the lines of one embedded script back out of the YAML, undoing the block scalar indentation.
extractScript() {
    awk -v terminator="$1" '
        index($0, "<<\x27" terminator "\x27") { on = 1; next }
        on && $0 ~ "^ +" terminator "$" { exit }
        on { sub(/^          /, ""); print }
    ' "$dist"
}

# Same as extractScript but the YAML text of every run: block, to inspect what the shell receives.
runBlocks() {
    awk '
        /^ +run: \|/ { on = 1; next }
        on && /^ +- name:/ { on = 0 }
        on && /^ +[a-z-]+:/ { on = 0 }
        on { print }
    ' "$dist"
}

copySources() {
    mkdir -p "$1"
    cp "$root/.github/scripts/checkRebase.sh" "$root/.github/scripts/reportRebase.sh" "$1/"
}

# DRIFT
check "T-RF19-b/drift-1 --check passes on the committed dist" "$bashBin" "$builder" --check

copySources "$work/mutated"
echo "# drift" >> "$work/mutated/checkRebase.sh"
check "T-RF19-b/drift-2 --check fails when a source script changes" \
    bash -c '! SOURCE_DIR="$1" "$2" "$3" --check' _ "$work/mutated" "$bashBin" "$builder"

extractScript CHECK_REBASE_SCRIPT_EOF > "$work/check.out"
extractScript REPORT_REBASE_SCRIPT_EOF > "$work/report.out"
check "T-RF19-b/drift-3 embedded checkRebase.sh is byte-identical" cmp "$work/check.out" "$root/.github/scripts/checkRebase.sh"
check "T-RF19-b/drift-4 embedded reportRebase.sh is byte-identical" cmp "$work/report.out" "$root/.github/scripts/reportRebase.sh"

# STRUCTURE
check "T-RF19-b/shape-1 name" grep -q -x 'name: Enforce Rebase' "$dist"
check "T-RF19-b/shape-2 run-name" grep -q -x 'run-name: "CI: Enforce rebase before merge"' "$dist"
check "T-RF19-b/shape-3 only pull_request with the 4 types" \
    grep -q -x '    types: \[opened, synchronize, reopened, edited\]' "$dist"
check "T-RF19-b/shape-4 no workflow_call and no push trigger" bash -c '! grep -E "workflow_call|^  push:" "$1"' _ "$dist"
check "T-RF19-b/shape-5 permissions" bash -c 'grep -q -x "  contents: read" "$1" && grep -q -x "  pull-requests: write" "$1"' _ "$dist"
check "T-RF19-b/shape-6 concurrency group names workflow_ref and cancels" \
    bash -c 'grep -q "group: enforce-rebase-.*github.workflow_ref.*github.event.pull_request.number || github.ref" "$1" && grep -q "cancel-in-progress: true" "$1"' _ "$dist"
check "T-RF19-b/shape-7 a single job rebase-status" \
    bash -c '[ "$(sed -n "/^jobs:/,\$p" "$1" | grep -c -E "^  [a-z-]+:")" -eq 1 ] && grep -q -x "  rebase-status:" "$1"' _ "$dist"

uses=$(grep -c -E '^[[:space:]]*(- )?uses:' "$dist")
check "T-RF19-b/shape-8 exactly one uses: and it is the pinned checkout" \
    bash -c '[ "$1" -eq 1 ] && grep -q "uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0  # v7.0.0" "$2"' _ "$uses" "$dist"
check "T-RF19-b/shape-9 checkout takes the head sha with full history" \
    bash -c 'grep -q "ref: \${{ github.event.pull_request.head.sha }}" "$1" && grep -q "fetch-depth: 0" "$1"' _ "$dist"
check "T-RF19-b/shape-10 no github.event expression inside a run block" \
    bash -c '! grep -q "github\.event\." "$1"' _ <(runBlocks)
check "T-RF19-b/shape-11 the report step is non-blocking and receives REASON" \
    bash -c 'grep -q "continue-on-error: true" "$1" && grep -q "REASON=\$(cat \"\$RUNNER_TEMP/rebaseReason.txt\")" "$1"' _ "$dist"
check "T-RF19-b/shape-12 the failing step is gated on the check output" \
    grep -q "if: steps.check.outputs.ok == 'false'" "$dist"

# REFUSALS
refuse() {
    local name=$1 needle=$2 dir=$3 want=$4
    local out status
    out=$(SOURCE_DIR="$dir" TEMPLATE_FILE="${5:-$root/tools/inlineWorkflow.template.yml}" \
        "$bashBin" "$builder" "$work/refused.yml" 2>&1 < /dev/null)
    status=$?
    if [ "$status" -eq 2 ] && [ ! -e "$work/refused.yml" ] && echo "$out" | grep -q -F -- "$needle"; then
        pass "$name"
        return 0
    fi
    fail "$name (exit $status, wanted $want: $out)"
}

copySources "$work/terminator"
echo "CHECK_REBASE_SCRIPT_EOF" >> "$work/terminator/checkRebase.sh"
refuse "T-RF19-b/refuse-1 a script containing the heredoc terminator" "heredoc terminator" "$work/terminator" 2

copySources "$work/expression"
printf '%s\n' 'echo "${{ github.token }}"' >> "$work/expression/reportRebase.sh"
refuse "T-RF19-b/refuse-2 a script containing the expression opener" "expression opener" "$work/expression" 2

copySources "$work/marker"
printf '%s\n' '---' >> "$work/marker/reportRebase.sh"
refuse "T-RF19-b/refuse-3 a line starting with a YAML document marker" "document marker" "$work/marker" 2

copySources "$work/noNewline"
printf 'echo last' >> "$work/noNewline/reportRebase.sh"
refuse "T-RF19-b/refuse-4 a script without a final newline" "newline" "$work/noNewline" 2

mkdir -p "$work/empty"
refuse "T-RF19-b/refuse-5 a missing source script" "missing source script" "$work/empty" 2

refuse "T-RF19-b/refuse-6 a missing template" "missing template" "$work/mutated" 2 "$work/nope.yml"

# OUTPUT
"$bashBin" "$builder" "$work/first.yml" > /dev/null 2>&1
"$bashBin" "$builder" "$work/second.yml" > /dev/null 2>&1
check "T-RF19-b/out-1 two runs are identical" cmp "$work/first.yml" "$work/second.yml"
check "T-RF19-b/out-2 the explicit output equals the committed dist" cmp "$work/first.yml" "$dist"
check "T-RF19-b/out-3 no partial file is left next to the output" \
    bash -c '[ "$(ls "$1" | grep -c "first.yml.")" -eq 0 ]' _ "$work"
check "T-RF19-b/out-4 the builder is bash 3.2 compatible (no bash 4 features)" \
    bash -c '! grep -E "mapfile|readarray|declare -A|\$\{[a-zA-Z]+,,\}|\|&" "$1"' _ "$builder"

echo "buildInlineWorkflow: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
