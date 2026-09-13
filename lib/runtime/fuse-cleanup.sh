#!/bin/bash
# fuse-cleanup — remove stale .fuse_hidden* files from FUSE/bindfs mounts
#
# FUSE filesystems (including bindfs) cannot delete a file that a process still
# holds open, so they rename it to .fuse_hiddenXXXX until the last descriptor
# closes. An unclean process exit or container stop strands those files forever.
#
# This is the single implementation of that garbage collection. It has two
# callers, which used to carry two near-identical copies that had already
# drifted (issue #948):
#
#   - the boot pass, lib/runtime/lib/setup-bindfs.sh, once per container start
#   - the cron pass, /usr/local/bin/fuse-cleanup-cron, every 10 minutes
#
# Both copies bounded their walk at `-maxdepth 3`, and the two did not even
# agree on what depth 3 meant: the cron pass measured from each FUSE mount, the
# boot pass from a hardcoded /workspace and so burned one level on the <repo>
# directory before it started. A file four components below the mount — say
# plugins/<plugin>/scripts/.fuse_hiddenXXXX, the ordinary layout for a plugin
# marketplace repo — was reached by neither. The failure was invisible three
# ways: .fuse_hidden* is gitignored, the GC prints nothing when it cleans
# nothing, and a FLAT repo was swept correctly, so only nested layouts broke.
#
# The walk is therefore NOT depth-bounded at all. A depth limit is a guess about
# someone else's directory layout and cannot be right for every repo. The cost
# is bounded instead by pruning what is actually expensive — .git and
# node_modules, neither of which a FUSE rename target belongs in.
#
# Roots come from `findmnt -t fuse,fuse.bindfs` so that "the root" means the
# same thing in both callers. FUSE_CLEANUP_FALLBACK_ROOT covers the one case
# the boot pass handled that the cron pass did not: files stranded by a previous
# session that had FUSE when this one does not.
#
# Prints the number of files removed to stdout as a bare integer, so each caller
# can report in its own voice (the cron leg logs via syslog, the boot leg echoes)
# and so the walk itself is directly testable without a real FUSE mount.
#
# Environment:
#   FUSE_CLEANUP_DISABLE       - "true" to do nothing and exit 0
#   FUSE_CLEANUP_ROOTS         - newline-separated roots to sweep, overriding
#                                findmnt discovery entirely
#   FUSE_CLEANUP_FALLBACK_ROOT - directory to sweep when no FUSE mount is present
#   FUSE_CLEANUP_FINDMNT       - findmnt binary to use for discovery

set -uo pipefail

if [ "${FUSE_CLEANUP_DISABLE:-false}" = "true" ]; then
    echo 0
    exit 0
fi

# Root resolution, in precedence order: an explicit override, then findmnt
# discovery, then the caller's fallback.
#
# FUSE_CLEANUP_ROOTS exists so the walk can be exercised against a fixture
# without a real FUSE mount. It has to override discovery rather than merely
# fill in for it: a container whose own workspace IS a bindfs mount would
# otherwise have findmnt hand the tests the live tree to sweep.
fuse_roots="${FUSE_CLEANUP_ROOTS:-}"

# findmnt is absent on some minimal images; treat that the same as "no FUSE
# mounts" and let the fallback root decide. FUSE_CLEANUP_FINDMNT names the
# binary so a test can point discovery at a stub — overriding PATH does not
# work here, because BASH_ENV rc files reset PATH out from under the caller.
FINDMNT_BIN="${FUSE_CLEANUP_FINDMNT:-findmnt}"
if [ -z "$fuse_roots" ] && command -v "$FINDMNT_BIN" >/dev/null 2>&1; then
    fuse_roots=$("$FINDMNT_BIN" -n -r -o TARGET -t fuse,fuse.bindfs 2>/dev/null || true)
fi

# No live FUSE mount: sweep the fallback root if the caller named one and it
# exists. This is what lets the boot pass clear files a previous session left
# behind after its mounts went away.
if [ -z "$fuse_roots" ]; then
    fallback="${FUSE_CLEANUP_FALLBACK_ROOT:-}"
    if [ -n "$fallback" ] && [ -d "$fallback" ]; then
        fuse_roots="$fallback"
    else
        echo 0
        exit 0
    fi
fi

cleaned=0
while IFS= read -r root; do
    [ -z "$root" ] && continue
    [ -d "$root" ] || continue

    while IFS= read -r -d '' hidden_file; do
        # Skip files a running process still holds open — FUSE will clear those
        # itself when the last descriptor closes. Removing one early would yank
        # the file out from under a live reader.
        if command -v fuser >/dev/null 2>&1; then
            fuser "$hidden_file" >/dev/null 2>&1 && continue
        fi
        command rm -f "$hidden_file" 2>/dev/null && cleaned=$((cleaned + 1))
    done < <(command find "$root" \
        -name .git -prune -o \
        -name node_modules -prune -o \
        -name '.fuse_hidden*' -type f -print0 2>/dev/null)
done <<<"$fuse_roots"

echo "$cleaned"
