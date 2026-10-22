#!/usr/bin/env bash
# Pure decision: exit 0 rebased, 1 policy failure, 2 unexpected input. Side effects live elsewhere so the
# same rule runs on a laptop and in CI.
set -euo pipefail
# canary: simulates an unexpected failure of the decision code
exit 3

if [ "$#" -lt 2 ]; then
    echo "usage: checkRebase.sh <baseSha> <headSha> [baseName]" >&2
    exit 2
fi

baseSha=$1
headSha=$2
baseName=${3:-base}

requireCommit() {
    git cat-file -e "$1^{commit}" 2>/dev/null && return 0
    echo "unknown commit: $1" >&2
    exit 2
}

requireCommit "$baseSha"
requireCommit "$headSha"

# A shallow history would make the lag and merge counts wrong, so refuse instead of guessing.
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
    echo "shallow clone: fetch the full history before checking" >&2
    exit 2
fi

if ! git merge-base "$baseSha" "$headSha" > /dev/null 2>&1; then
    echo "no common ancestor between $baseName and the branch" >&2
    exit 2
fi

reasons=()

merges=$(git rev-list --merges "$baseSha..$headSha")
if [ -n "$merges" ]; then
    count=$(echo "$merges" | wc -l | tr -d ' ')
    reasons+=("$count merge commit(s) on the branch: rebase it onto $baseName to remove them")
fi

if ! git merge-base --is-ancestor "$baseSha" "$headSha"; then
    lag=$(git rev-list --count "$headSha..$baseSha")
    reasons+=("branch is $lag commit(s) behind $baseName")
fi

if [ "${#reasons[@]}" -eq 0 ]; then
    echo "branch is rebased onto $baseName"
    exit 0
fi

printf '%s\n' "${reasons[@]}"
exit 1
