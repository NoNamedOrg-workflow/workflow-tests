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

. "$here/embedLib.sh"

usage() {
    echo "usage: buildInlineWorkflow.sh [--check] [outFile]" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check) checkOnly=1 ;;
        -*) usage ;;
        *) outFile=$1 ;;
    esac
    shift
done

emitWorkflow \
    buildInlineWorkflow.sh \
    "$checkOnly" \
    "$outFile" \
    "$templateFile" \
    "__CHECK_REBASE_SCRIPT__=$sourceDir/checkRebase.sh" \
    "__REPORT_REBASE_SCRIPT__=$sourceDir/reportRebase.sh"
