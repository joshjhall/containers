#!/usr/bin/env bash
# read-librarian-pin.sh — print the Dockerfile's librarian pin, fail-closed.
#
# Usage: bin/read-librarian-pin.sh [DOCKERFILE]   (default: ./Dockerfile)
#
# CI checks librarian out at the Dockerfile's `ARG LIBRARIAN_REF=` so its gates
# run the SAME librarian the dev image ships. Two ci.yml steps read that pin;
# both call this script so the rule lives in one place (#1555).
#
# Exactly one `ARG LIBRARIAN_REF=` line must exist. A bare `sed -n … | grep -q`
# accepted a Dockerfile with two such lines — `grep -q` passes if ANY line
# matches — and wrote a multi-line `ref=` into $GITHUB_OUTPUT. The value must
# also be a vX.Y.Z release tag (CLAUDE.md: LIBRARIAN_REF is a signed tag)
# before it reaches a checkout `ref:`.
#
# Prints the ref on stdout and exits 0; prints a `::error::` line and exits 1
# otherwise.
set -euo pipefail

dockerfile="${1:-Dockerfile}"

if [ ! -r "$dockerfile" ]; then
    printf '::error::cannot read %s\n' "$dockerfile" >&2
    exit 1
fi

# One element per matching line. Docker instructions are case-insensitive and
# may be indented, so `  arg LIBRARIAN_REF=...` is a pin too and must be
# counted; a bare `ARG LIBRARIAN_REF` (re-declaration, no `=`) sets no value
# and is not. A read loop rather than `mapfile` keeps this working on bash 3.2
# (macOS). `|| true`: zero matches is handled below as its own error.
refs=()
while IFS= read -r line; do
    refs+=("$line")
done < <(command sed -nE 's/^[[:space:]]*[Aa][Rr][Gg][[:space:]]+LIBRARIAN_REF=//p' "$dockerfile" | command tr -d '"' || true)

count=${#refs[@]}
if [ "$count" -ne 1 ]; then
    printf '::error::expected exactly one ARG LIBRARIAN_REF line in %s, found %d\n' \
        "$dockerfile" "$count" >&2
    exit 1
fi

ref="${refs[0]}"
if ! [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf "::error::ARG LIBRARIAN_REF in %s is not a vX.Y.Z tag: '%s'\n" \
        "$dockerfile" "$ref" >&2
    exit 1
fi

printf '%s\n' "$ref"
