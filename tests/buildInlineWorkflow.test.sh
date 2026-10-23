#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
builder="$root/tools/buildInlineWorkflow.sh"
template="$root/tools/inlineWorkflow.template.yml"
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

# check NAME COMMAND...: the command succeeding means the case passed.
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

# The text of every run: block. A block ends at the first non-blank line indented less than its content.
runBlocks() {
    awk '
        /^ +run: \|/ { on = 1; next }
        on && $0 != "" { match($0, /^ */); if (RLENGTH < 10) on = 0 }
        on { print }
    ' "$1"
}

# The lines of one top-level block, without comments and blank lines.
blockOf() {
    awk -v key="$1" '
        $0 == key ":" { on = 1; next }
        on && /^[^ #]/ { exit }
        on && NF && $0 !~ /^ *#/ { print }
    ' "$2"
}

# One word per violated rule, so a mutation test can name the rule it must trip.
problems() {
    local file=$1 want
    grep -q -x 'name: Enforce Rebase' "$file" || echo name
    grep -q -x 'run-name: "CI: Enforce rebase before merge"' "$file" || echo runName

    want=$(printf '%s\n' '  pull_request:' '    types: [opened, synchronize, reopened, edited]')
    [ "$(blockOf on "$file")" = "$want" ] || echo trigger

    want=$(printf '%s\n' '  contents: read' '  pull-requests: write')
    [ "$(blockOf permissions "$file")" = "$want" ] || echo permissions

    grep -q 'group: enforce-rebase-.*github.workflow_ref.*github.event.pull_request.number || github.ref' "$file" || echo concurrency
    grep -q -x '  cancel-in-progress: true' "$file" || echo cancel

    [ "$(blockOf jobs "$file" | grep -c -E '^  [a-z-]+:')" -eq 1 ] || echo oneJob
    grep -q -x '  rebase-status:' "$file" || echo jobId

    want=$(printf '%s\n' \
        '      - name: Checkout the pull request head' \
        '      - name: Check rebase' \
        '      - name: Report on the pull request' \
        '      - name: Fail when the branch is not rebased')
    [ "$(grep '^      - ' "$file")" = "$want" ] || echo steps

    [ "$(grep -c -E '^ *(- )?uses:' "$file")" -eq 1 ] || echo oneUses
    grep -q 'uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0  # v7.0.0$' "$file" || echo pinnedCheckout
    grep -q -x '          ref: ${{ github.event.pull_request.head.sha }}' "$file" || echo checkoutRef
    grep -q -x '          fetch-depth: 0' "$file" || echo fullHistory

    [ -n "$(runBlocks "$file")" ] || echo emptyRunBlocks
    runBlocks "$file" | grep -q -F '${{' && echo expressionInRun
    grep -q -E '^ +run: [^|]' "$file" && echo inlineRun

    grep -q 'continue-on-error: true' "$file" || echo reportBlocking
    grep -q 'REASON=$(cat "$RUNNER_TEMP/rebaseReason.txt")' "$file" || echo reasonMissing
    grep -q "if: steps.check.outputs.ok == 'false'" "$file" || echo failGate
    return 0
}

copySources() {
    mkdir -p "$1"
    cp "$root/.github/scripts/checkRebase.sh" "$root/.github/scripts/reportRebase.sh" "$1/"
}

# mutateTemplate NAME AWKPROGRAM: a copy of the template changed by the program, for tests that must go red.
mutateTemplate() {
    awk "$2" "$template" > "$work/$1.template.yml"
}

buildFrom() {
    TEMPLATE_FILE="$work/$1.template.yml" "$bashBin" "$builder" "$work/$1.yml" > /dev/null 2>&1
}

# DRIFT
check "T-RF19-b/drift-1 --check passes on the committed dist" "$bashBin" "$builder" --check

copySources "$work/mutated"
echo "# drift" >> "$work/mutated/checkRebase.sh"
cp "$dist" "$work/dist.before"
SOURCE_DIR="$work/mutated" "$bashBin" "$builder" --check > "$work/drift.out" 2>&1 < /dev/null
driftStatus=$?
check "T-RF19-b/drift-2 --check exits 1 when a source script changes" test "$driftStatus" -eq 1
check "T-RF19-b/drift-3 the drift message names the file" grep -q -F "$dist" "$work/drift.out"
check "T-RF19-b/drift-4 --check leaves the committed file byte-identical" cmp "$dist" "$work/dist.before"

extractScript CHECK_REBASE_SCRIPT_EOF > "$work/check.out"
extractScript REPORT_REBASE_SCRIPT_EOF > "$work/report.out"
check "T-RF19-b/drift-5 embedded checkRebase.sh is byte-identical" cmp "$work/check.out" "$root/.github/scripts/checkRebase.sh"
check "T-RF19-b/drift-6 embedded reportRebase.sh is byte-identical" cmp "$work/report.out" "$root/.github/scripts/reportRebase.sh"

# STRUCTURE: the committed file breaks no rule, and each mutated template trips the rule it targets.
problems "$dist" > "$work/problems.out"
check "T-RF19-b/shape-1 the committed workflow breaks no structure rule" test ! -s "$work/problems.out"

expectMutation() {
    local name=$1 rule=$2 program=$3
    mutateTemplate "$name" "$program"
    if ! buildFrom "$name"; then
        fail "T-RF19-b/mutant-$name the mutated template did not build, so the rule was not exercised"
        return 0
    fi
    problems "$work/$name.yml" > "$work/$name.problems"
    check "T-RF19-b/mutant-$name trips rule $rule" grep -q -x "$rule" "$work/$name.problems"
}

expectMutation targetEvent trigger '{ sub(/^  pull_request:/, "  pull_request_target:"); print }'
expectMutation pushTrigger trigger '{ print } /^on:/ { print "  push:" }'
expectMutation workflowCall trigger '{ print } /^on:/ { print "  workflow_call:" }'
expectMutation fewerTypes trigger '{ sub(/, edited/, ""); print }'
expectMutation issuesWrite permissions '{ print } /^permissions:/ { print "  issues: write" }'
expectMutation idToken permissions '{ print } /^permissions:/ { print "  id-token: write" }'
expectMutation writeContents permissions '{ sub(/contents: read/, "contents: write"); print }'
expectMutation headRefInRun expressionInRun '/^          exit 1$/ { print "          echo \"${{ github.head_ref }}\"" } { print }'
expectMutation inlineRunText inlineRun '{ sub(/^        run: \|$/, "        run: echo hi"); print }'
expectMutation extraStep steps '/^      - name: Report on/ { print "      - name: Extra"; print "        run: echo hi"; print "" } { print }'
expectMutation secondUses oneUses '/^      - name: Report on/ { print "      - name: Extra"; print "        uses: actions/cache@v4"; print "" } { print }'
expectMutation noWorkflowRef concurrency '{ sub(/github.workflow_ref/, "github.sha"); print }'
expectMutation secondJob oneJob '{ print } END { print "  other:"; print "    runs-on: ubuntu-latest" }'
expectMutation unpinnedCheckout pinnedCheckout '{ sub(/9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0/, "v7"); print }'

# REFUSALS: exit 2, a message naming the cause and no output file at all (not even a partial one).
refuse() {
    local name=$1 needle=$2 dir=$3 templateFile=${4:-$template}
    local out status
    rm -f "$work"/refused.yml*
    out=$(SOURCE_DIR="$dir" TEMPLATE_FILE="$templateFile" "$bashBin" "$builder" "$work/refused.yml" 2>&1 < /dev/null)
    status=$?
    if [ "$status" -eq 2 ] && [ -z "$(ls "$work"/refused.yml* 2> /dev/null)" ] && echo "$out" | grep -q -F -- "$needle"; then
        pass "$name"
        return 0
    fi
    fail "$name (exit $status, wanted 2: $out)"
}

copySources "$work/terminator"
echo "CHECK_REBASE_SCRIPT_EOF" >> "$work/terminator/checkRebase.sh"
refuse "T-RF19-b/refuse-1 a script containing the heredoc terminator" "heredoc terminator" "$work/terminator"

copySources "$work/expression"
printf '%s\n' 'echo "${{ github.token }}"' >> "$work/expression/reportRebase.sh"
refuse "T-RF19-b/refuse-2 a script containing the expression opener" "expression opener" "$work/expression"

copySources "$work/noNewline"
printf 'echo last' >> "$work/noNewline/reportRebase.sh"
refuse "T-RF19-b/refuse-3 a script without a final newline" "newline" "$work/noNewline"

copySources "$work/crlf"
printf 'echo crlf\r\n' >> "$work/crlf/reportRebase.sh"
refuse "T-RF19-b/refuse-4 a script containing a carriage return" "carriage return" "$work/crlf"

copySources "$work/emptyScript"
: > "$work/emptyScript/checkRebase.sh"
refuse "T-RF19-b/refuse-5 an empty script" "empty source script" "$work/emptyScript"

mkdir -p "$work/noScripts"
refuse "T-RF19-b/refuse-6 a missing source script" "missing source script" "$work/noScripts"

refuse "T-RF19-b/refuse-7 a missing template" "missing template" "$work/mutated" "$work/nope.yml"

copySources "$work/unreadable"
chmod 000 "$work/unreadable/checkRebase.sh"
if [ -r "$work/unreadable/checkRebase.sh" ]; then
    echo "SKIP T-RF19-b/refuse-8 an unreadable script (this user can read a mode 000 file, e.g. root)"
fi
if [ ! -r "$work/unreadable/checkRebase.sh" ]; then
    refuse "T-RF19-b/refuse-8 an unreadable script" "unreadable source script" "$work/unreadable"
fi

mutateTemplate crlfTemplate '{ printf "%s\r\n", $0 }'
refuse "T-RF19-b/refuse-9 a template with CRLF line endings" "was not substituted" "$work/mutated" "$work/crlfTemplate.template.yml"

mutateTemplate indentedPlaceholder '{ sub(/^__CHECK/, "  __CHECK"); print }'
refuse "T-RF19-b/refuse-10 an indented placeholder" "was not substituted" "$work/mutated" "$work/indentedPlaceholder.template.yml"

mutateTemplate missingPlaceholder '$0 != "__REPORT_REBASE_SCRIPT__" { print }'
refuse "T-RF19-b/refuse-11 a template without a placeholder" "exactly once" "$work/mutated" "$work/missingPlaceholder.template.yml"

mutateTemplate repeatedPlaceholder '{ print } $0 == "__CHECK_REBASE_SCRIPT__" { print }'
refuse "T-RF19-b/refuse-12 a repeated placeholder" "exactly once" "$work/mutated" "$work/repeatedPlaceholder.template.yml"

# A sed that fails mid-render must stop the build instead of leaving a truncated workflow behind.
mkdir -p "$work/brokenBin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$work/brokenBin/sed"
chmod +x "$work/brokenBin/sed"
rm -f "$work"/refused.yml*
out=$(PATH="$work/brokenBin:$PATH" "$bashBin" "$builder" "$work/refused.yml" 2>&1 < /dev/null)
renderStatus=$?
check "T-RF19-b/refuse-13 a failing render exits 2" test "$renderStatus" -eq 2
check "T-RF19-b/refuse-14 a failing render writes no output and no success message" \
    bash -c 'test -z "$(ls "$1"/refused.yml* 2> /dev/null)" && ! echo "$2" | grep -q "^wrote"' _ "$work" "$out"
out=$(PATH="$work/brokenBin:$PATH" "$bashBin" "$builder" --check 2>&1 < /dev/null)
check "T-RF19-b/refuse-15 a failing render under --check exits 2, not 1" test "$?" -eq 2

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
