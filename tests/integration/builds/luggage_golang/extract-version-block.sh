#!/bin/bash
# Print lib/features/golang.sh's version block — input validation, the
# pre-1.22 floor, and the partial-version resolve — so a caller can source the
# code that ships instead of a copy of it (#1346).
#
# Shared by the unit suite (tests/unit/features/golang.sh, run_version_block,
# against a stub luggage) and the luggage_golang fixture (against the real
# `luggage resolve --json`), so the two cannot drift onto different
# extractions.
#
# Usage: extract-version-block.sh <golang.sh> [luggage-path]
#   luggage-path — replaces golang.sh's /usr/local/bin/luggage (optional;
#                  sed-special characters in it are escaped)
#
# The block runs from `validate_go_version` through the resolve block's
# closing `fi` — the second top-level `fi`, since validation uses `|| { }`,
# not if/fi. A block that never reaches that `fi` is refused rather than
# printed through EOF, so callers never source unrelated install code as the
# version block (#1372). The caller provides log_error/log_message and
# validate_go_version (lib/base/version-validation.sh), and sets GO_VERSION.
set -euo pipefail

script="$1"
luggage="${2:-/usr/local/bin/luggage}"

# `exit` in a rule still runs END, so `done` is what tells "stopped at the
# second fi" apart from "ran out of input".
rc=0
block=$(command awk '
    /^validate_go_version /{f=1}
    f{print}
    f && /^fi$/ && ++n==2{done=1; exit}
    END{if (f && !done) exit 2}
' "$script") || rc=$?
if [ -z "$block" ]; then
    echo "extract-version-block: no version block found in $script" >&2
    exit 1
fi
if [ "$rc" -ne 0 ]; then
    echo "extract-version-block: version block in $script never reaches its closing fi" >&2
    exit 1
fi
luggage_esc=$(printf '%s' "$luggage" | command sed 's/[\\#&]/\\&/g')
printf '%s\n' "$block" | command sed "s#/usr/local/bin/luggage#${luggage_esc}#g"
