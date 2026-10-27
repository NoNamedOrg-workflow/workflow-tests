#!/usr/bin/env bash
# Generates the reusable sweep workflow from the template and the tested script, so the embedded copy can never be
# edited by hand and --check turns any drift into a failure.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
templateFile=${TEMPLATE_FILE:-$here/sweepWorkflow.template.yml}
sourceDir=${SOURCE_DIR:-$root/.github/scripts}
outFile=$root/dist/reusableRebaseSweep.yml
checkOnly=0

. "$here/embedLib.sh"

usage() {
    echo "usage: buildSweepWorkflow.sh [--check] [outFile]" >&2
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
    buildSweepWorkflow.sh \
    "$checkOnly" \
    "$outFile" \
    "$templateFile" \
    "__RECHECK_SWEEP_SCRIPT__=$sourceDir/recheckSweep.sh"
