#!/bin/bash
# rc-snippet.sh — Remove an exact multi-line block from a shell rc file (#1721)
#
# Sourced (never executed) by setup-gh and setup-glab to migrate the pre-#1711
# token-export block out of a persisted ~/.bashrc. Installed to
# /opt/container-runtime/lib/rc-snippet.sh. Pure bash + awk: setup-* runs on
# minimal images with no python.
#
# Functions:
#   rc_remove_block FILE TEXT - remove the first exact occurrence of the
#                               multi-line TEXT (and one blank line directly
#                               before it) from FILE. Only an exact, line-for-
#                               line match is removed; a hand-edited block is
#                               left untouched. One trailing newline on TEXT is
#                               ignored; an empty TEXT never matches.
#                               Returns:
#                                 0 - block removed
#                                 1 - nothing removed, FILE unchanged (no file,
#                                     empty TEXT, no match, mktemp failure)
#                                 2 - copy-back failed after FILE was truncated;
#                                     the complete edited content is kept at
#                                     $RC_REMOVE_BLOCK_KEPT so the caller can
#                                     warn (never deleted on this path).

[ -n "${_RC_SNIPPET_LOADED:-}" ] && return 0
_RC_SNIPPET_LOADED=1

rc_remove_block() {
    local rc="$1" text="$2"
    # shellcheck disable=SC2034  # output variable read by callers
    RC_REMOVE_BLOCK_KEPT=""
    text="${text%$'\n'}"
    [ -n "$text" ] && [ -f "$rc" ] || return 1
    # Cheap pre-check on the first line before reading the whole file in awk.
    command grep -qxF "${text%%$'\n'*}" "$rc" 2>/dev/null || return 1
    local tmp
    tmp=$(command mktemp "${rc}.XXXXXX") || return 1
    local removed=1
    if WANT="$text" command awk '
        BEGIN { n = split(ENVIRON["WANT"], want, "\n") }
        { line[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                hit = 1
                for (j = 1; j <= n; j++) if (i + j - 1 > NR || line[i + j - 1] != want[j]) { hit = 0; break }
                if (hit) { start = i; break }
            }
            if (!start) exit 1
            skip_from = start; if (start > 1 && line[start - 1] == "") skip_from = start - 1
            for (i = 1; i <= NR; i++) if (i < skip_from || i >= start + n) print line[i]
        }' "$rc" >"$tmp" 2>/dev/null; then
        # Rewrite in place (not mv) so the rc file keeps its inode, owner and
        # mode. The redirect truncates FILE first, so if cat then fails the
        # temp file is the only complete copy: keep it and report it.
        if ! command cat "$tmp" >"$rc"; then
            # shellcheck disable=SC2034  # output variable read by callers
            RC_REMOVE_BLOCK_KEPT="$tmp"
            return 2
        fi
        removed=0
    fi
    command rm -f "$tmp"
    return "$removed"
}
