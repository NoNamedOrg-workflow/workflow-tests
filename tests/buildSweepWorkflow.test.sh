#!/usr/bin/env bash
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
builder="$root/tools/buildSweepWorkflow.sh"
template="$root/tools/sweepWorkflow.template.yml"
dist="$root/dist/reusableRebaseSweep.yml"
caller="$root/tools/sweepCaller.example.yml"
script="$root/.github/scripts/recheckSweep.sh"
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

# The YAML is read by a real parser, so the tests judge what Actions will see and not how the text happens to look.
cat > "$work/inspect.rb" <<'RUBY'
require "yaml"

runStep = ARGV[0] == "run"
file = ARGV[1]
doc = YAML.safe_load(File.read(file))

def hashOf(value)
    return value if value.is_a?(Hash)
    return {}
end

def structureProblems(doc)
    found = []
    trigger = hashOf(doc["on"] || doc[true])
    inputs = hashOf(hashOf(trigger["workflow_call"])["inputs"])
    wanted = {"mode" => "base-moved", "windowHours" => "24", "workflowPath" => ".github/workflows/enforceRebase.yml"}
    found << "inputs" unless inputs.keys.sort == wanted.keys.sort
    found << "inputs" unless wanted.all? { |key, value| hashOf(inputs[key])["default"] == value }
    found << "inputs" unless inputs.values.all? { |input| hashOf(input)["type"] == "string" }
    found << "trigger" unless trigger.keys == ["workflow_call"]
    found << "name" unless doc["name"] == "Rebase Sweep (reusable)"
    found << "topPermissions" unless doc["permissions"] == {}
    jobs = hashOf(doc["jobs"])
    found << "oneJob" unless jobs.keys == ["sweep"]
    job = hashOf(jobs["sweep"])
    found << "jobPermissions" unless job["permissions"] == {"actions" => "write", "pull-requests" => "read"}
    expectedEnv = {
        "GH_TOKEN" => "${{ github.token }}",
        "REPO" => "${{ github.repository }}",
        "BASE" => "${{ github.ref_name }}",
        "MODE" => "${{ inputs.mode }}",
        "WINDOW_HOURS" => "${{ inputs.windowHours }}",
        "WORKFLOW_PATH" => "${{ inputs.workflowPath }}",
    }
    found << "env" unless job["env"] == expectedEnv
    found << "steps" unless job["steps"].is_a?(Array) && job["steps"].length == 1
    return found
end

def textProblems(text)
    found = []
    lines = text.lines.map(&:chomp)
    allowed = /\A      [A-Z_]+: \$\{\{ (github\.token|github\.repository|github\.ref_name|inputs\.(mode|windowHours|workflowPath)) \}\}\z/
    found << "uses" if lines.any? { |line| line =~ /\A\s*(- )?uses:/ }
    found << "eventData" if text =~ /github\.event|github\.head_ref/
    found << "secrets" if text =~ /secrets\./
    found << "expression" unless lines.select { |line| line.include?("${{") }.all? { |line| line =~ allowed }
    return found
end

if runStep
    print doc["jobs"]["sweep"]["steps"][0]["run"]
    exit 0
end

puts((structureProblems(doc) + textProblems(File.read(file))).uniq)
RUBY

problems() {
    ruby "$work/inspect.rb" problems "$1"
}

runBody() {
    ruby "$work/inspect.rb" run "$1"
}

# The heredoc of the embedded script, as the shell on the runner will receive it.
embeddedScript() {
    runBody "$1" | awk '
        index($0, "<<\x27RECHECK_SWEEP_SCRIPT_EOF\x27") { on = 1; next }
        on && $0 == "RECHECK_SWEEP_SCRIPT_EOF" { exit }
        on { print }
    '
}

copySources() {
    mkdir -p "$1"
    cp "$script" "$1/"
}

# mutateTemplate NAME AWKPROGRAM: a copy of the template changed by the program, for tests that must go red.
mutateTemplate() {
    awk "$2" "$template" > "$work/$1.template.yml"
}

buildFrom() {
    TEMPLATE_FILE="$work/$1.template.yml" "$bashBin" "$builder" "$work/$1.yml" > /dev/null 2>&1
}

# DRIFT
check "T-RF21-c/drift-1 --check passes on the committed dist" "$bashBin" "$builder" --check

copySources "$work/mutated"
echo "# drift" >> "$work/mutated/recheckSweep.sh"
cp "$dist" "$work/dist.before"
SOURCE_DIR="$work/mutated" "$bashBin" "$builder" --check > "$work/drift.out" 2>&1 < /dev/null
driftStatus=$?
check "T-RF21-c/drift-2 --check exits 1 when the source script changes" test "$driftStatus" -eq 1
check "T-RF21-c/drift-3 the drift message names the file" grep -q -F "$dist" "$work/drift.out"
check "T-RF21-c/drift-4 --check leaves the committed file byte-identical" cmp "$dist" "$work/dist.before"

sed 's/^name: .*/name: Altered/' "$dist" > "$work/altered.yml"
"$bashBin" "$builder" --check "$work/altered.yml" > /dev/null 2>&1
check "T-RF21-c/drift-5 --check exits 1 when the dist is altered" test "$?" -eq 1

embeddedScript "$dist" > "$work/embedded.out"
check "T-RF21-c/drift-6 the embedded script is byte-identical to recheckSweep.sh" cmp "$work/embedded.out" "$script"

# STRUCTURE: the committed file breaks no rule, and each mutated template trips the rule it targets.
problems "$dist" > "$work/problems.out"
check "T-RF21-d/shape-1 the committed workflow breaks no structure rule" test ! -s "$work/problems.out"
check "T-RF21-d/shape-2 the workflow holds no uses: line" test "$(grep -c -E '^\s*(- )?uses:' "$dist")" -eq 0
check "T-RF21-d/shape-3 no event data and no head_ref reach the file" \
    bash -c '! grep -q -E "github\.event|github\.head_ref" "$1"' _ "$dist"
check "T-RF21-d/shape-4 the expression opener appears only in env lines of allowed values" \
    bash -c '! grep -F "\${{" "$1" | grep -v -E "^      [A-Z_]+: \\$\{\{ (github\.token|github\.repository|github\.ref_name|inputs\.[a-zA-Z]+) \}\}$"' _ "$dist"
check "T-RF21-d/shape-5 the script is indented at ten spaces and blank lines stay empty" \
    bash -c '! grep -q -E "^ +$" "$1"' _ "$dist"

expectMutation() {
    local name=$1 rule=$2 program=$3
    mutateTemplate "$name" "$program"
    if ! buildFrom "$name"; then
        fail "T-RF21-d/mutant-$name the mutated template did not build, so the rule was not exercised"
        return 0
    fi
    problems "$work/$name.yml" > "$work/$name.problems"
    check "T-RF21-d/mutant-$name trips rule $rule" grep -q -x "$rule" "$work/$name.problems"
}

expectMutation noTopPermissions topPermissions '$0 != "permissions: {}" { print }'
expectMutation contentsWrite jobPermissions '{ print } /^    permissions:/ { print "      contents: write" }'
expectMutation checksWrite jobPermissions '{ print } /^    permissions:/ { print "      checks: write" }'
expectMutation prWrite jobPermissions '{ sub(/pull-requests: read/, "pull-requests: write"); print }'
expectMutation secretToken secrets '{ sub(/github\.token/, "secrets.PAT"); print }'
expectMutation secretTokenEnv env '{ sub(/github\.token/, "secrets.PAT"); print }'
expectMutation addUses uses '{ print } /^    steps:/ { print "      - uses: actions/checkout@v4" }'
expectMutation eventInRun eventData '{ print } /set -uo pipefail/ { print "          echo \"${{ github.event.pull_request.title }}\"" }'
expectMutation eventInRunExpr expression '{ print } /set -uo pipefail/ { print "          echo \"${{ github.event.pull_request.title }}\"" }'
expectMutation headRefInEnv eventData '{ sub(/github\.ref_name/, "github.head_ref"); print }'
expectMutation inputInRun expression '{ print } /set -uo pipefail/ { print "          echo \"${{ inputs.mode }}\"" }'
expectMutation wrongDefault inputs '{ sub(/default: base-moved/, "default: recover"); print }'

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
echo "RECHECK_SWEEP_SCRIPT_EOF" >> "$work/terminator/recheckSweep.sh"
refuse "T-RF21-c/refuse-1 a script containing the heredoc terminator" "heredoc terminator" "$work/terminator"

copySources "$work/expression"
printf '%s\n' 'echo "${{ github.token }}"' >> "$work/expression/recheckSweep.sh"
refuse "T-RF21-c/refuse-2 a script containing the expression opener" "expression opener" "$work/expression"

copySources "$work/noNewline"
printf 'echo last' >> "$work/noNewline/recheckSweep.sh"
refuse "T-RF21-c/refuse-3 a script without a final newline" "newline" "$work/noNewline"

copySources "$work/crlf"
printf 'echo crlf\r\n' >> "$work/crlf/recheckSweep.sh"
refuse "T-RF21-c/refuse-4 a script containing a carriage return" "carriage return" "$work/crlf"

copySources "$work/emptyScript"
: > "$work/emptyScript/recheckSweep.sh"
refuse "T-RF21-c/refuse-5 an empty script" "empty source script" "$work/emptyScript"

mkdir -p "$work/noScripts"
refuse "T-RF21-c/refuse-6 a missing source script" "missing source script" "$work/noScripts"

refuse "T-RF21-c/refuse-7 a missing template" "missing template" "$work/mutated" "$work/nope.yml"

copySources "$work/unreadable"
chmod 000 "$work/unreadable/recheckSweep.sh"
if [ -r "$work/unreadable/recheckSweep.sh" ]; then
    echo "SKIP T-RF21-c/refuse-8 an unreadable script (this user can read a mode 000 file, e.g. root)"
fi
if [ ! -r "$work/unreadable/recheckSweep.sh" ]; then
    refuse "T-RF21-c/refuse-8 an unreadable script" "unreadable source script" "$work/unreadable"
fi

mutateTemplate crlfTemplate '{ printf "%s\r\n", $0 }'
refuse "T-RF21-c/refuse-9 a template with CRLF line endings" "was not substituted" "$work/mutated" "$work/crlfTemplate.template.yml"

mutateTemplate indentedPlaceholder '{ sub(/^__RECHECK/, "  __RECHECK"); print }'
refuse "T-RF21-c/refuse-10 an indented placeholder" "was not substituted" "$work/mutated" "$work/indentedPlaceholder.template.yml"

mutateTemplate missingPlaceholder '$0 != "__RECHECK_SWEEP_SCRIPT__" { print }'
refuse "T-RF21-c/refuse-11 a template without the placeholder" "exactly once" "$work/mutated" "$work/missingPlaceholder.template.yml"

mutateTemplate repeatedPlaceholder '{ print } $0 == "__RECHECK_SWEEP_SCRIPT__" { print }'
refuse "T-RF21-c/refuse-12 a repeated placeholder" "exactly once" "$work/mutated" "$work/repeatedPlaceholder.template.yml"

# A sed that fails mid-render must stop the build instead of leaving a truncated workflow behind.
mkdir -p "$work/brokenBin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$work/brokenBin/sed"
chmod +x "$work/brokenBin/sed"
rm -f "$work"/refused.yml*
out=$(PATH="$work/brokenBin:$PATH" "$bashBin" "$builder" "$work/refused.yml" 2>&1 < /dev/null)
renderStatus=$?
check "T-RF21-c/refuse-13 a failing render exits 2" test "$renderStatus" -eq 2
check "T-RF21-c/refuse-14 a failing render writes no output and no success message" \
    bash -c 'test -z "$(ls "$1"/refused.yml* 2> /dev/null)" && ! echo "$2" | grep -q "^wrote"' _ "$work" "$out"
out=$(PATH="$work/brokenBin:$PATH" "$bashBin" "$builder" --check 2>&1 < /dev/null)
check "T-RF21-c/refuse-15 a failing render under --check exits 2, not 1" test "$?" -eq 2

# OUTPUT
"$bashBin" "$builder" "$work/first.yml" > /dev/null 2>&1
"$bashBin" "$builder" "$work/second.yml" > /dev/null 2>&1
check "T-RF21-c/out-1 two runs are identical" cmp "$work/first.yml" "$work/second.yml"
check "T-RF21-c/out-2 the explicit output equals the committed dist" cmp "$work/first.yml" "$dist"
check "T-RF21-c/out-3 no partial file is left next to the output" \
    bash -c '[ "$(ls "$1" | grep -c "first.yml.")" -eq 0 ]' _ "$work"
check "T-RF21-c/out-4 the builder is bash 3.2 compatible (no bash 4 features)" \
    bash -c '! grep -E "mapfile|readarray|declare -A|\$\{[a-zA-Z]+,,\}|\|&" "$1"' _ "$builder"

# BEHAVIOR of the run step: the real text cut out of the YAML, with a probe standing in for the swept script.
# The fake chmod swaps the freshly written script for a probe, so the step itself runs exactly as generated.
mkdir -p "$work/fakeBin"
cat > "$work/fakeBin/chmod" <<'FAKE'
#!/usr/bin/env bash
printf '#!/usr/bin/env bash\necho "probe SINCE=${SINCE-unset} MODE=$MODE"\n' > "$2"
exec /bin/chmod "$@"
FAKE
cat > "$work/fakeBin/date" <<'FAKE'
#!/usr/bin/env bash
echo "$@" >> "$FAKE_DATE_LOG"
echo 2026-01-01T00:00:00Z
FAKE
chmod +x "$work/fakeBin/chmod" "$work/fakeBin/date"

# runStep YAML MODE WINDOW_HOURS: leaves the output in $stepOut and the exit code in $stepStatus.
runStep() {
    local body="$work/step.sh"
    runBody "$1" > "$body"
    rm -rf "$work/scene"
    mkdir -p "$work/scene/tmp"
    : > "$work/date.log"
    stepOut=$(cd "$work/scene" && env PATH="$work/fakeBin:$PATH" MODE="$2" WINDOW_HOURS="$3" RUNNER_TEMP="$work/scene/tmp" \
        FAKE_DATE_LOG="$work/date.log" "$bashBin" -e "$body" 2>&1 < /dev/null)
    stepStatus=$?
}

# One word per violated behavior, so a mutated workflow can prove the cases are able to fail.
behaviorProblems() {
    runStep "$1" base-moved 24
    [ "$stepStatus" -eq 0 ] || echo baseMovedExit
    echo "$stepOut" | grep -q -x 'probe SINCE=unset MODE=base-moved' || echo baseMovedSince
    [ ! -s "$work/date.log" ] || echo baseMovedDate

    runStep "$1" recover 6
    [ "$stepStatus" -eq 0 ] || echo recoverExit
    echo "$stepOut" | grep -q -x 'probe SINCE=2026-01-01T00:00:00Z MODE=recover' || echo recoverSince
    grep -q -F -- '-6 hours' "$work/date.log" || echo recoverWindow

    local bad
    for bad in 0 abc '1; touch x' '' '-3' '007'; do
        runStep "$1" recover "$bad"
        [ "$stepStatus" -eq 2 ] || echo "invalidExit[$bad]"
        echo "$stepOut" | grep -q 'probe' && echo "invalidRanScript[$bad]"
        echo "$stepOut" | grep -q -F 'windowHours must be a positive integer' || echo "invalidMessage[$bad]"
        [ ! -e "$work/scene/x" ] || echo "invalidInjected[$bad]"
    done
    return 0
}

behaviorProblems "$dist" > "$work/behavior.out"
check "T-RF21-b/behavior-1 the run step handles both modes and refuses a bad window" test ! -s "$work/behavior.out"
[ -s "$work/behavior.out" ] && sed 's/^/    /' "$work/behavior.out"

runStep "$dist" base-moved 24
check "T-RF21-b/behavior-2 base-moved does not define SINCE" bash -c 'echo "$1" | grep -q -x "probe SINCE=unset MODE=base-moved"' _ "$stepOut"
runStep "$dist" recover 6
check "T-RF21-b/behavior-3 recover defines SINCE from the window" bash -c 'echo "$1" | grep -q "SINCE=2026-01-01T00:00:00Z"' _ "$stepOut"
runStep "$dist" recover '1; touch x'
check "T-RF21-b/behavior-4 an injected window exits 2 and runs nothing" test "$stepStatus" -eq 2 -a ! -e "$work/scene/x"

mutateTemplate noValidation '!/windowHours must be a positive integer/ { print }'
buildFrom noValidation
behaviorProblems "$work/noValidation.yml" > "$work/noValidation.problems"
check "T-RF21-b/mutant-noValidation the behavior cases fail when the window is not validated" test -s "$work/noValidation.problems"

mutateTemplate alwaysSince '{ sub(/\[ "\$MODE" = recover \]/, "true"); print }'
buildFrom alwaysSince
behaviorProblems "$work/alwaysSince.yml" > "$work/alwaysSince.problems"
check "T-RF21-b/mutant-alwaysSince the behavior cases fail when base-moved also computes SINCE" test -s "$work/alwaysSince.problems"

# CALLER EXAMPLE
cat > "$work/callerCheck.rb" <<'RUBY'
require "yaml"

doc = YAML.safe_load(File.read(ARGV[0]))
trigger = doc["on"] || doc[true]
found = []
found << "name" unless doc["name"] == "rebase-sweep"
found << "push" unless trigger["push"] == {"branches" => ["main"]}
mode = trigger["workflow_dispatch"]["inputs"]["mode"]
found << "dispatch" unless mode["type"] == "choice" && mode["options"] == ["base-moved", "recover"] && mode["default"] == "base-moved"
found << "topPermissions" unless doc["permissions"] == {}
job = doc["jobs"]["sweep"]
found << "uses" unless job["uses"] == "NoNamedOrg-workflow/workflow-tests/.github/workflows/reusableRebaseSweep.yml@main"
found << "with" unless job["with"] == {"mode" => "${{ inputs.mode || 'base-moved' }}"}
found << "jobPermissions" unless job["permissions"] == {"actions" => "write", "pull-requests" => "read"}
puts found
RUBY
ruby "$work/callerCheck.rb" "$caller" > "$work/caller.out" 2>&1
check "T-RF21-f/caller-1 the example parses and calls the reusable with the right inputs and permissions" test ! -s "$work/caller.out"
[ -s "$work/caller.out" ] && sed 's/^/    /' "$work/caller.out"

sed 's/actions: write/actions: read/' "$caller" > "$work/callerMutant.yml"
ruby "$work/callerCheck.rb" "$work/callerMutant.yml" > "$work/callerMutant.out" 2>&1
check "T-RF21-f/caller-2 the caller check fails when a permission changes" test -s "$work/callerMutant.out"

echo "buildSweepWorkflow: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
