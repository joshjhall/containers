#!/usr/bin/env bash
# Pre-commit hook: ensure shell scripts have executable permission in git index.
# Uses git update-index (not just chmod) so the permission is actually committed.
set -euo pipefail

fixed=0
for f in "$@"; do
    mode=$(git ls-files -s "$f" 2>/dev/null | cut -d' ' -f1)
    if [ "$mode" = "100644" ]; then
        git update-index --chmod=+x "$f"
        chmod +x "$f" 2>/dev/null || true
        echo "Fixed: $f (100644 -> 100755)"
        fixed=1
    fi
done

exit "$fixed"
