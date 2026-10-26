#!/bin/bash
# Print lib/features/node.sh's version block — input validation, the
# pre-18 floor, and the partial-version resolve — so a caller can source the
# code that ships instead of a copy of it. The node twin of
# luggage_golang/extract-version-block.sh (#812).
#
# Shared by the unit suite (tests/unit/features/node.sh, run_version_block,
# against a stub luggage) and the luggage_node fixture (against the real
# `luggage resolve --json`), so the two cannot drift onto different
# extractions.
#
# Usage: extract-version-block.sh <node.sh> [luggage-path]
#   luggage-path — replaces node.sh's /usr/local/bin/luggage (optional;
#                  `\`, `#` and `&` in it are escaped for sed; a newline
#                  is not supported)
#
# The block runs from `validate_node_version` through the resolve block's
# closing `fi` — the second top-level `fi` (the first closes the pre-18
# floor check; validation uses `|| { }`, not if/fi). A block that never
# reaches that `fi` is refused rather than printed through EOF, so callers
# never source unrelated install code as the version block. The caller
# provides log_error/log_message and validate_node_version
# (lib/base/version-validation.sh), and sets NODE_VERSION.
set -euo pipefail

script="$1"
luggage="${2:-/usr/local/bin/luggage}"

# `exit` in a rule still runs END, so `done` is what tells "stopped at the
# second fi" apart from "ran out of input". END exits 3, not 2: awk itself
# exits 2 on a fatal error such as an unreadable file, and that must not be
# reported as a problem with the script's content.
rc=0
block=$(command awk '
    /^validate_node_version /{f=1}
    f{print}
    f && /^fi$/ && ++n==2{done=1; exit}
    END{if (f && !done) exit 3}
' "$script") || rc=$?
if [ "$rc" -eq 3 ]; then
    echo "extract-version-block: version block in $script never reaches its closing fi" >&2
    exit 1
fi
if [ "$rc" -ne 0 ]; then
    echo "extract-version-block: could not read $script (awk exit $rc)" >&2
    exit 1
fi
if [ -z "$block" ]; then
    echo "extract-version-block: no version block found in $script" >&2
    exit 1
fi
luggage_esc=$(printf '%s' "$luggage" | command sed 's/[\\#&]/\\&/g')
printf '%s\n' "$block" | command sed "s#/usr/local/bin/luggage#${luggage_esc}#g"
