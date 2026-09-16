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
# Removing the depth bound also removed the only thing that bounded how long a
# single sweep could run (issue #950). The cron leg fires every 10 minutes and
# the boot pass can fire concurrently at startup, so on a large tree whose
# expensive directories are neither .git nor node_modules (target/, .venv/,
# vendor/, a plugin marketplace) two unbounded walks of the same tree can
# overlap. The sweep therefore takes a NON-BLOCKING flock: a second invocation
# that finds the lock held reports 0 and exits 0 rather than queueing.
#
# Non-blocking is the right shape rather than a shortcut. The overlap is pure
# resource contention — each `rm -f` is idempotent and the `fuser` guard already
# protects a live reader — so a skipped sweep loses nothing that the next tick
# 10 minutes later will not pick up. Queueing (`flock -w`) would instead stack
# cron invocations behind a slow walk on exactly the tree where the walk is
# already slow, which is the failure this guards against.
#
# Prints the number of files removed to stdout as a bare integer, so each caller
# can report in its own voice (the cron leg logs via syslog, the boot leg echoes)
# and so the walk itself is directly testable without a real FUSE mount.
#
# Three of the variables below can REDIRECT the walk, and this script runs
# root-privileged from the boot leg with no depth bound — so whatever names its
# roots names the scope of a recursive `rm -f`. They are testing seams only, and
# BOTH production callers unset them before invoking this script (#953):
#
#   - the boot pass, lib/runtime/lib/setup-bindfs.sh, in a subshell
#   - the cron pass, the wrapper heredoc in lib/features/bindfs.sh
#
# The boundary is at the CALLER rather than here on purpose. Validating a root
# in this script (say, against `findmnt -T`) would still accept an
# attacker-chosen live mount — and on a container whose own workspace is a
# bindfs mount, that check passes for the very tree the seam exists to keep
# tests away from. An in-script allow-flag would be no better: it is just a
# second env var, settable by anyone who can set the first. A variable the
# caller dropped cannot be read by the process that does the deleting, which is
# the only version of this that actually holds.
#
# Nothing here enforces that, and nothing can: this script cannot tell an
# injected root from a test's. The tests for the neutralization therefore live
# with the callers, not with this file.
#
# Environment:
#   FUSE_CLEANUP_DISABLE       - "true" to do nothing and exit 0. An operator
#                                control, NOT a testing seam — production keeps it
#   FUSE_CLEANUP_ROOTS         - newline-separated roots to sweep, overriding
#                                findmnt discovery entirely. TEST-ONLY SEAM:
#                                unset by both production callers (#953)
#   FUSE_CLEANUP_FALLBACK_ROOT - directory to sweep when no FUSE mount is
#                                present. TEST-ONLY SEAM as an inherited value:
#                                the boot leg drops any ambient value and then
#                                sets /workspace itself (#953)
#   FUSE_CLEANUP_FINDMNT       - findmnt binary to use for discovery. TEST-ONLY
#                                SEAM: a stub printing / redirects the walk just
#                                as ROOTS would, so it is unset alongside it
#   FUSE_CLEANUP_LOCK          - lock file serializing concurrent sweeps
#                                (default /etc/container/lock/fuse-cleanup.lock)

set -uo pipefail

if [ "${FUSE_CLEANUP_DISABLE:-false}" = "true" ]; then
    echo 0
    exit 0
fi

# ---------------------------------------------------------------------------
# Overlap guard (issue #950)
# ---------------------------------------------------------------------------
# The lock lives in /etc/container/lock, NOT /tmp, for the reasons worked out
# for claude-setup.lock (#943): /tmp is world-writable, so any local process
# could pre-plant the path and hold the lock. That directory is created
# root-owned 0755 at build time and the lock file inside it 0666, so any runtime
# UID can open it — the container user is remapped after build (Zed adopts the
# host UID), so the runtime UID is not knowable here.
#
# EVERY failure to take the lock degrades to sweeping unlocked rather than
# exiting non-zero. Unlocked is the pre-existing behavior and is merely
# contended, never incorrect; refusing to sweep would turn a cost concern into
# the stranded-file bug #948 fixed. The one case that is NOT a failure —
# the lock is held by a live sweep — is the skip.
FUSE_CLEANUP_LOCK="${FUSE_CLEANUP_LOCK:-/etc/container/lock/fuse-cleanup.lock}"

# Returns 0 when the caller should sweep, 1 when another sweep holds the lock.
# The fd stays open for the life of the script, so the lock is released by exit
# (including a kill) with no trap to leak.
_acquire_sweep_lock() {
    local lock_path="$1"

    # No hard dependency on util-linux: Alpine ships only the busybox applet and
    # ubi-minimal may omit flock entirely. Sweeping unlocked there is exactly
    # what this script did before #950.
    command -v flock >/dev/null 2>&1 || return 0

    # Defence in depth only, and deliberately TOCTOU-racy: the root-owned parent
    # is the real control. This branch is what fires if the path is ever moved
    # somewhere writable again.
    [ -L "$lock_path" ] && return 0

    # Kept on its own line so an unopenable path (no /etc/container/lock on a
    # bare host or in the unit suite) is caught here rather than aborting.
    #
    # The brace group carries the 2>/dev/null, NOT the exec itself: redirections
    # are processed left to right, so `exec 201>bad 2>/dev/null` fails on 201>
    # BEFORE the stderr redirect is in effect and the diagnostic leaks to the
    # caller's stderr anyway (verified). A brace group is not a subshell, so
    # fd 201 still lands in this shell.
    { exec 201>"$lock_path"; } 2>/dev/null || return 0

    # -n: report and move on rather than queueing behind the slow walk.
    flock -n 201 || return 1
    return 0
}

if ! _acquire_sweep_lock "$FUSE_CLEANUP_LOCK"; then
    # Another sweep is mid-walk. Its `rm -f` calls cover this tree too, so there
    # is nothing for this invocation to do and nothing to report as an error.
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
