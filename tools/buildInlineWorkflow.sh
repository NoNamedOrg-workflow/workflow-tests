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
# A line starting with --- or ... is refused because it would read as a YAML document marker if indentation were lost.
requireEmbeddable() {
    local file=$1
    [ -f "$file" ] || fail "missing source script: $file"
    [ -n "$(tail -c 1 "$file")" ] && fail "$file must end with a newline: the heredoc adds one, so the copy would differ"
    grep -q -F '_SCRIPT_EOF' "$file" && fail "$file contains a heredoc terminator (_SCRIPT_EOF): the embedded copy would end early"
    grep -q -F '${{' "$file" && fail "$file contains the expression opener: GitHub Actions would evaluate it inside the workflow"
    grep -q -E '^(---|\.\.\.)' "$file" && fail "$file has a line starting with a YAML document marker"
    return 0
}

render() {
    local line
    while IFS= read -r line; do
        case "$line" in
            __CHECK_REBASE_SCRIPT__) indentScript "$sourceDir/checkRebase.sh" ;;
            __REPORT_REBASE_SCRIPT__) indentScript "$sourceDir/reportRebase.sh" ;;
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

if [ "$checkOnly" -eq 1 ]; then
    if ! render | cmp -s - "$outFile"; then
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
chmod 644 "$partial"
mv "$partial" "$outFile"
echo "wrote $outFile"
