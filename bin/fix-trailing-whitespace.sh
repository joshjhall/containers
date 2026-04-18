#!/usr/bin/env bash
# Pre-commit hook: remove trailing whitespace from lines in text files.
# Auto-fixes in place. Exit 1 = changes made, exit 0 = clean.
set -euo pipefail

fixed=0
for f in "$@"; do
    [ -f "$f" ] || continue
    # -I skips binary files; -q returns success if any text line matched
    /usr/bin/grep -Iq . "$f" 2>/dev/null || continue
    if /usr/bin/grep -qE '[[:space:]]+$' "$f"; then
        /usr/bin/sed -i -E 's/[[:space:]]+$//' "$f"
        echo "Fixed: $f"
        fixed=1
    fi
done

exit "$fixed"
