#!/usr/bin/env bash
# Generates the single-file workflow from the template and the tested scripts, so the embedded copies can never be
# edited by hand and --check turns any drift into a failure.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
templateFile=${TEMPLATE_FILE:-$here/inlineWorkflow.template.yml}
sourceDir=${SOURCE_DIR:-$root/.github/scripts}
outFile=$root/dist/enforceRebase.yml
checkOnly=0

usage() {
    echo "usage: buildInlineWorkflow.sh [--check] [outFile]" >&2
    exit 2
}

fail() {
    echo "$1" >&2
    exit 2
}

# Block scalar content sits at ten spaces; blank lines stay empty so no trailing whitespace is created.
indentScript() {
    sed '/^$/!s/^/          /' "$1"
}

# A heredoc would end early on its terminator, and "${{" would be evaluated by Actions before the shell sees it.
# YAML normalises a carriage return, so the embedded copy would differ from the source it is supposed to equal.
requireEmbeddable() {
    local file=$1
    [ -f "$file" ] || fail "missing source script: $file"
    [ -r "$file" ] || fail "unreadable source script: $file"
    [ -s "$file" ] || fail "empty source script: $file"
    [ -n "$(tail -c 1 "$file")" ] && fail "$file must end with a newline: the heredoc adds one, so the copy would differ"
    grep -q "$(printf '\r')" "$file" && fail "$file contains a carriage return: YAML would normalise it and the copy would differ"
    grep -q -F '_SCRIPT_EOF' "$file" && fail "$file contains a heredoc terminator (_SCRIPT_EOF): the embedded copy would end early"
    grep -q -F '${{' "$file" && fail "$file contains the expression opener: GitHub Actions would evaluate it inside the workflow"
    return 0
}

# A placeholder that is missing, repeated, indented or followed by a carriage return would ship a broken workflow.
requireSinglePlaceholder() {
    [ "$(grep -c -F "$1" "$templateFile")" -eq 1 ] || fail "the template must hold the placeholder $1 exactly once"
}

requireSubstituted() {
    grep -q -F "$1" "$2" && fail "the placeholder $1 was not substituted: it must be alone on its line, with no carriage return"
    return 0
}

# A failing indent must stop the render, or a truncated workflow would look like a finished one.
render() {
    local line
    while IFS= read -r line; do
        case "$line" in
            __CHECK_REBASE_SCRIPT__) indentScript "$sourceDir/checkRebase.sh" || return 1 ;;
            __REPORT_REBASE_SCRIPT__) indentScript "$sourceDir/reportRebase.sh" || return 1 ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$templateFile"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check) checkOnly=1 ;;
        -*) usage ;;
        *) outFile=$1 ;;
    esac
    shift
done

[ -f "$templateFile" ] || fail "missing template: $templateFile"
requireEmbeddable "$sourceDir/checkRebase.sh"
requireEmbeddable "$sourceDir/reportRebase.sh"
requireSinglePlaceholder __CHECK_REBASE_SCRIPT__
requireSinglePlaceholder __REPORT_REBASE_SCRIPT__

# --check renders to a scratch file too, so a failed render is reported as such and never as drift.
if [ "$checkOnly" -eq 1 ]; then
    partial=$(mktemp "${TMPDIR:-/tmp}/inlineWorkflow.XXXXXX") || fail "cannot create a scratch file"
    trap 'rm -f "$partial"' EXIT
    render > "$partial" || fail "rendering failed"
    requireSubstituted __CHECK_REBASE_SCRIPT__ "$partial"
    requireSubstituted __REPORT_REBASE_SCRIPT__ "$partial"
    if ! cmp -s "$partial" "$outFile"; then
        echo "$outFile is out of date: run tools/buildInlineWorkflow.sh" >&2
        exit 1
    fi
    echo "$outFile is up to date"
    exit 0
fi

mkdir -p "$(dirname "$outFile")"
partial=$(mktemp "$outFile.XXXXXX") || fail "cannot write next to $outFile"
trap 'rm -f "$partial"' EXIT
render > "$partial" || fail "rendering failed"
requireSubstituted __CHECK_REBASE_SCRIPT__ "$partial"
requireSubstituted __REPORT_REBASE_SCRIPT__ "$partial"
chmod 644 "$partial"
mv "$partial" "$outFile"
echo "wrote $outFile"
