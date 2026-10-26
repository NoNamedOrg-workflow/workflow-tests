#!/usr/bin/env bash
# Sourced by the workflow generators, never run: the checks and the render shared by every script-embedding template.

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

# requireSinglePlaceholder PLACEHOLDER TEMPLATE: one that is missing or repeated would ship a broken workflow.
requireSinglePlaceholder() {
    [ "$(grep -c -F "$1" "$2")" -eq 1 ] || fail "the template must hold the placeholder $1 exactly once"
}

# A placeholder that is indented or followed by a carriage return survives the render untouched.
requireSubstituted() {
    grep -q -F "$1" "$2" && fail "the placeholder $1 was not substituted: it must be alone on its line, with no carriage return"
    return 0
}

# renderTemplate TEMPLATE PLACEHOLDER=SCRIPT...: a failing indent must stop the render, or a truncated workflow would
# look like a finished one.
renderTemplate() {
    local templateFile=$1 line pair
    shift
    while IFS= read -r line; do
        for pair in "$@"; do
            [ "$line" = "${pair%%=*}" ] || continue
            indentScript "${pair#*=}" || return 1
            continue 2
        done
        printf '%s\n' "$line"
    done < "$templateFile"
}

# emitWorkflow BUILDER CHECK_ONLY OUT_FILE TEMPLATE PLACEHOLDER=SCRIPT...: writes OUT_FILE atomically, or with
# CHECK_ONLY=1 compares the render with it. --check renders to a scratch file too, so a failed render is reported as
# such and never as drift. The scratch path stays global because the EXIT trap outlives this function.
emitWorkflow() {
    local builderName=$1 checkOnly=$2 outFile=$3 templateFile=$4 pair
    shift 4
    [ -f "$templateFile" ] || fail "missing template: $templateFile"
    for pair in "$@"; do
        requireEmbeddable "${pair#*=}"
    done
    for pair in "$@"; do
        requireSinglePlaceholder "${pair%%=*}" "$templateFile"
    done

    if [ "$checkOnly" -eq 1 ]; then
        partial=$(mktemp "${TMPDIR:-/tmp}/embeddedWorkflow.XXXXXX") || fail "cannot create a scratch file"
    fi
    if [ "$checkOnly" -ne 1 ]; then
        mkdir -p "$(dirname "$outFile")"
        partial=$(mktemp "$outFile.XXXXXX") || fail "cannot write next to $outFile"
    fi
    trap 'rm -f "$partial"' EXIT
    renderTemplate "$templateFile" "$@" > "$partial" || fail "rendering failed"
    for pair in "$@"; do
        requireSubstituted "${pair%%=*}" "$partial"
    done

    if [ "$checkOnly" -eq 1 ]; then
        if ! cmp -s "$partial" "$outFile"; then
            echo "$outFile is out of date: run tools/$builderName" >&2
            exit 1
        fi
        echo "$outFile is up to date"
        exit 0
    fi
    chmod 644 "$partial"
    mv "$partial" "$outFile"
    echo "wrote $outFile"
    exit 0
}
