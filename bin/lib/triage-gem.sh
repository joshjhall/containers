#!/bin/bash
# gitlab-triage pin extraction
#
# Description:
#   The single reader for the gitlab-triage version in .gitlab/triage/Gemfile
#   and its Gemfile.lock. Used by regen-triage-lock.sh, check-versions.sh and
#   the test suites that assert the two agree — one implementation, so a format
#   change cannot leave a stale copy silently disagreeing (#989).
#
#   Both readers print nothing and return 0 when there is no match or the file
#   is missing. Under `set -euo pipefail` a grep miss would otherwise fail the
#   `v=$(...)` assignment and abort the caller before it can explain why (#988);
#   callers decide what an empty result means with `[ -n "$v" ]`.
#
#   Deliberately does not `set -euo pipefail`: test suites source this with
#   their own shell options.
#
# Usage:
#   source "${BIN_DIR}/lib/triage-gem.sh"
#   pin=$(triage_gemfile_version .gitlab/triage/Gemfile)
#   locked=$(triage_lock_version .gitlab/triage/Gemfile.lock)

# Header guard to prevent multiple sourcing
if [ -n "${_BIN_LIB_TRIAGE_GEM_SH_INCLUDED:-}" ]; then
    return 0
fi
readonly _BIN_LIB_TRIAGE_GEM_SH_INCLUDED=1

# triage_gemfile_version FILE — the X in `gem "gitlab-triage", "X"`. First
# match only, like the lock reader: a caller's `[ "$a" = "$b" ]` must never
# compare a multi-line value (bundler rejects a duplicated gem anyway).
triage_gemfile_version() {
    { command grep -E '^gem "gitlab-triage"' "$1" 2>/dev/null || true; } |
        command head -1 |
        command sed -E 's/.*,[[:space:]]*"([^"]+)".*/\1/'
}

# triage_lock_version FILE — the resolved version from the specs entry
# `    gitlab-triage (X)`. The specs section precedes DEPENDENCIES, so the first
# match is the resolution, not the `gitlab-triage (= X)` requirement line.
triage_lock_version() {
    { command grep -E '^[[:space:]]+gitlab-triage \(' "$1" 2>/dev/null || true; } |
        command head -1 |
        command sed -E 's/.*\(([^)]+)\).*/\1/'
}
