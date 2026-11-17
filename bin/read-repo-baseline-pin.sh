#!/usr/bin/env bash
# read-repo-baseline-pin.sh — print the containers-db commit stibbons'
# repo-baseline is vendored from, fail-closed.
#
# Usage: bin/read-repo-baseline-pin.sh [SOURCE]
#   (default: crates/stibbons/assets/repo-baseline/SOURCE)
#
# SOURCE is written by bin/sync-repo-baseline.sh as exactly one line,
# `containers-db <40-hex sha>` (#1748). CI fetches that commit for two checks
# — the re-vendor round trip (tests/unit/sync-repo-baseline.sh) and the
# render.sh parity test (stibbons' matches_baseline_render_sh, #1754) — and
# both ci.yml steps call this script so the rule lives in one place.
#
# The value goes into a checkout `ref:` / `git fetch`, so it must be a full
# commit SHA: a branch or tag is a moving ref, a short SHA is ambiguous, and
# anything else could be parsed as an option.
#
# Prints the SHA on stdout and exits 0; prints a `::error::` line and exits 1
# otherwise (nothing on stdout).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_file="${1:-$here/../crates/stibbons/assets/repo-baseline/SOURCE}"

if [ ! -r "$source_file" ] || [ -d "$source_file" ]; then
    printf '::error::cannot read %s\n' "$source_file" >&2
    exit 1
fi

# `grep -c ''` counts a final line with no trailing newline too.
lines=$(command grep -c '' "$source_file" || true)
if [ "$lines" -ne 1 ]; then
    printf '::error::%s must be exactly one line, found %s\n' "$source_file" "$lines" >&2
    exit 1
fi

line=$(command cat "$source_file")
if ! [[ "$line" =~ ^containers-db\ ([0-9a-f]{40})$ ]]; then
    printf "::error::%s is not 'containers-db <full commit sha>': '%s'\n" \
        "$source_file" "$line" >&2
    exit 1
fi

printf '%s\n' "${BASH_REMATCH[1]}"
