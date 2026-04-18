#!/usr/bin/env bash
# Pre-commit hook: ensure text files end with exactly one newline.
# Strips any trailing blank lines, guarantees final '\n'. In-place fix.
# Exit 1 = changes made, exit 0 = clean.
set -euo pipefail

fixed=0
for f in "$@"; do
    [ -f "$f" ] || continue
    [ -s "$f" ] || continue                          # skip empty
    /usr/bin/grep -Iq . "$f" 2>/dev/null || continue # skip binary

    tmpfile=$(/usr/bin/mktemp "${f}.eof.XXXXXX")
    # awk reads each record (line without trailing \n); END trims trailing
    # empty records then prints the rest — `print` adds one \n per line, so
    # the file ends with exactly one newline.
    /usr/bin/awk '{ line[NR]=$0; n=NR } END {
        while (n > 0 && line[n] == "") n--
        for (i = 1; i <= n; i++) print line[i]
    }' "$f" >"$tmpfile"

    if ! /usr/bin/cmp -s "$f" "$tmpfile"; then
        chmod --reference="$f" "$tmpfile" 2>/dev/null || true
        /usr/bin/mv "$tmpfile" "$f"
        echo "Fixed: $f"
        fixed=1
    else
        /usr/bin/rm -f "$tmpfile"
    fi
done

exit "$fixed"
