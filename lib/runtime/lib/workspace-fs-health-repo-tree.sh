#!/bin/bash
# workspace-fs-health-repo-tree.sh — per-repo-tree checks for 42-workspace-fs-health.sh
#
# SOURCE-ONLY. Sourced by lib/runtime/42-workspace-fs-health.sh, never executed
# directly and never sourced by anything else. Split out of that script in issue
# #1090 purely for size; the code below is unchanged by the move.
#
# Everything here acts on ONE repo root and then recurses into its submodules:
# the two repairs (core.ignorecase, stale symlink attributes), the two
# diagnostics (#977 symlink xattr ELOOP, #1086 stale index.lock), and the
# repair_repo_tree walk that runs them. Which roots get walked — workspace
# discovery, linked worktrees, dedup — stays in the main script.
#
# Reads these from the caller, all defined before the source line:
#   LOG_PREFIX, FIX_ENABLED, FS_CASE_STATE, FS_HEALTH_MAX_DEPTH
#   FS_HEALTH_STAT, FS_HEALTH_XATTR_PROBE      (injection seams)
#   fs_health_resolve, fs_health_seen, fs_health_mark_scanned
#                                              (called at run time, not load time)
#
# Runs inside the caller's process, so the caller's git-environment unset
# (#886/#894) covers every git call here too.
#
# shellcheck disable=SC2154  # globals are owned by the sourcing script

# ============================================================================
# Repair 1: align git core.ignorecase with the actual filesystem
# ============================================================================

# Args: $1 = repo root (superproject or a submodule worktree)
#
# The filesystem verdict is deliberately NOT re-detected per submodule: a
# submodule lives inside the superproject's worktree, so it is on the same
# mount by construction. Only the git config differs, and that is what this
# aligns — a submodule carries its own core.ignorecase, cloned from wherever it
# came from, and is equally wrong on a case-insensitive mount (#827).
check_ignorecase() {
    local root="$1"

    if [ "$FS_CASE_STATE" != "insensitive" ]; then
        return 0
    fi

    local current
    current=$(git -C "$root" config --get core.ignorecase 2>/dev/null) || true

    # Already correct — say nothing.
    if [ "$current" = "true" ]; then
        return 0
    fi

    local shown="${current:-unset}"
    command echo "$LOG_PREFIX $root is on a case-insensitive mount" >&2
    command echo "$LOG_PREFIX git core.ignorecase is '$shown' (incorrect for this mount)" >&2

    if [ "$FIX_ENABLED" != "true" ]; then
        command echo "$LOG_PREFIX SKIP_CASE_FIX=true — not changing it. To fix manually:" >&2
        command echo "$LOG_PREFIX   git -C $root config core.ignorecase true" >&2
        return 0
    fi

    if git -C "$root" config core.ignorecase true 2>/dev/null; then
        command echo "$LOG_PREFIX set core.ignorecase=true (opt out with SKIP_CASE_FIX=true)" >&2
    else
        command echo "$LOG_PREFIX Warning: could not write core.ignorecase (read-only .git?)" >&2
    fi
}

# ============================================================================
# Repair 2: refresh symlinks with stale filesystem attributes
# ============================================================================

# Classify a symlink's cached attributes.
#
# Args: $1 = absolute path to a symlink, $2 = its readlink target (non-empty)
# Prints the reason string and returns 0 when stale; returns 1 when healthy.
#
# Two independent arms, because the two observables decay for the same reason
# but are not known to decay together:
#
#   nlink=0    — impossible for a live symlink. A *broken* link (target does
#                not exist) still reports nlink=1, so this can never fire on
#                one, which is what makes it safe.
#
#   st_size=0  — what git actually keys on. It sizes a symlink from st_size
#                before reading the target, so a zero size makes git read zero
#                bytes and diff the link against the empty blob (issue #827
#                captured exactly that: ":120000 120000 681311eb 00000000 M").
#                A live symlink's st_size IS strlen(target), so size=0 paired
#                with a NON-EMPTY target is a self-contradiction — that pairing
#                is the whole guard, and it is why the caller resolves the
#                target before probing.
#
# #827 observed st_size=0 directly but relinked before sampling %h, so whether
# nlink had also decayed on those links is unconfirmed. Both arms are checked
# rather than assuming they move together: if they always do, the second arm
# costs one extra comparison; if they do not, it is the only thing that fires.
symlink_stale_reason() {
    local path="$1" target="$2"
    local nlink size

    # One stat for both values — the probe runs per tracked symlink per repo.
    read -r nlink size < <("$FS_HEALTH_STAT" -c '%h %s' "$path" 2>/dev/null) || return 1

    [ -n "$nlink" ] && [ -n "$size" ] || return 1

    if [ "$nlink" = "0" ]; then
        command printf '%s\n' "nlink=0"
        return 0
    fi

    if [ "$size" = "0" ] && [ -n "$target" ]; then
        command printf '%s\n' "st_size=0, target '$target'"
        return 0
    fi

    return 1
}

# Args: $1 = repo root, $2 = display prefix for log lines ("" for the
#       superproject, "containers/" for a submodule) so a path is unambiguous
#       once several roots are in play.
check_symlinks() {
    local root="$1" label_prefix="$2"
    local rel path target reason

    # Enumerate tracked symlinks straight from the index (mode 120000). Far
    # cheaper and more precise than walking the worktree, and it inherently
    # skips ignored/untracked links we have no business touching. `ls-files -s`
    # emits "<mode> <sha> <stage>\tpath", so the awk below splits on the tab to
    # keep paths containing spaces intact.
    #
    # This stops at a 160000 gitlink and does NOT descend into submodules —
    # that is the #827 bug. The caller supplies each submodule worktree as its
    # own root instead.
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        path="${root}/${rel}"

        [ -L "$path" ] || continue

        # Resolve the target BEFORE the staleness probe: the st_size arm is only
        # meaningful against a non-empty target, and a link we cannot read is
        # one we must not rewrite.
        target=$(/usr/bin/readlink "$path" 2>/dev/null) || continue
        [ -n "$target" ] || continue

        reason=$(symlink_stale_reason "$path" "$target") || continue

        command echo "$LOG_PREFIX ${label_prefix}${rel}: stale symlink attributes ($reason)" >&2

        if [ "$FIX_ENABLED" != "true" ]; then
            command echo "$LOG_PREFIX SKIP_CASE_FIX=true — not repairing. To fix manually:" >&2
            command echo "$LOG_PREFIX   ln -sfn $target $path" >&2
            continue
        fi

        # -n is load-bearing: without it, relinking a symlink that points at a
        # directory would create the new link *inside* that directory.
        # The target is unchanged, so content and git blob identity are intact.
        if /usr/bin/ln -sfn "$target" "$path" 2>/dev/null; then
            command echo "$LOG_PREFIX refreshed ${label_prefix}${rel} -> $target" >&2
        else
            command echo "$LOG_PREFIX Warning: could not refresh ${label_prefix}${rel} (read-only mount?)" >&2
        fi
    done < <(git -C "$root" ls-files -s 2>/dev/null |
        /usr/bin/awk -F'\t' '$1 ~ /^120000 / { print $2 }')

    return 0
}

# ============================================================================
# Symlink xattr ELOOP diagnostic (issue #977)
# ============================================================================
#
# DIAGNOSES ONLY — REPAIRS NOTHING. That is the whole design, not a shortcoming.
#
# On the virtiofs lower backing /workspace, llistxattr(2) returns ELOOP (40) for
# any symlink. BuildKit's context sender calls it on every path it walks, so
# `docker build` from the repo root dies before a single build step:
#
#   error from sender: failed to xattr .codegraph:
#     too many levels of symbolic links
#
# The real fix is --xattr-none on the bindfs overlay (lib/runtime/lib/
# setup-bindfs.sh), which makes bindfs answer with EOPNOTSUPP instead of
# relaying the ELOOP. But that is applied at ENTRYPOINT, so it only takes effect
# after a container RESTART and only on an image built after the fix. This probe
# exists for the gap: on a pre-fix image, or before the restart, it converts a
# cryptic BuildKit error into a named condition with the workaround attached.
#
# WHY THIS IS NOT PART OF check_symlinks(). It is a different failure class from
# the #827/#882 stale-attribute decay, and conflating them would do harm rather
# than nothing. That decay keys on nlink=0 / st_size=0 and is repaired by
# relinking. These symlinks report perfectly healthy metadata (nlink=1, size=9),
# and relinking provably does NOT help: a symlink created seconds ago inside the
# repo fails identically, because the condition belongs to the mount, not to the
# link. Folding this into symlink_stale_reason() would therefore misclassify it
# AND trigger a rewrite that cannot fix it.
#
# Args: $1 = repo root, $2 = display prefix for log lines.
check_symlink_xattr() {
    local root="$1" label_prefix="$2"
    local rel candidate rc=0

    # Probing ONE symlink is enough — the condition belongs to the mount, not to
    # any individual link, so probing every one would buy the same answer at a
    # syscall apiece. But it must be one that is actually a live symlink ON DISK:
    # the index and the working tree can disagree, and the entry that happens to
    # sort first is not guaranteed to be the live one. This repo's own documented
    # workaround for #977 REMOVES the tracked symlinks to get a build through, so
    # "in the index, absent from disk" is a state we actively tell people to
    # create. Keying the bail on the first entry alone would go silent there
    # while the remaining links still trip the condition — a false negative on an
    # affected repo, which is worse than no diagnostic at all.
    #
    # So: walk the tracked symlinks and stop at the first LIVE one. Costs one
    # lstat per dead entry, and in the healthy case still stops at entry 1.
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if [ -L "${root}/${candidate}" ]; then
            rel="$candidate"
            break
        fi
    done < <(git -C "$root" ls-files -s 2>/dev/null |
        /usr/bin/awk -F'\t' '$1 ~ /^120000 / { print $2 }')

    # No tracked symlink is live on disk — nothing this condition could affect.
    [ -n "$rel" ] || return 0

    if [ -n "$FS_HEALTH_XATTR_PROBE" ]; then
        "$FS_HEALTH_XATTR_PROBE" "${root}/${rel}" >/dev/null 2>&1 || rc=$?
    else
        command -v python3 >/dev/null 2>&1 || return 0
        python3 -c 'import os,sys
try:
    os.listxattr(sys.argv[1], follow_symlinks=False)
except OSError as e:
    sys.exit(1 if e.errno == 40 else 2)
except Exception:
    sys.exit(2)' "${root}/${rel}" >/dev/null 2>&1 || rc=$?
    fi

    # Healthy (0) and indeterminate (2) are both SILENT. This script is quiet
    # when it has nothing to say, and a probe that cannot run is not evidence of
    # the condition — reporting on 2 would cry wolf wherever python3 is absent.
    [ "$rc" = "1" ] || return 0

    command echo "$LOG_PREFIX ${label_prefix}${rel}: symlink xattr returns ELOOP — docker builds from this root will fail (issue #977)" >&2
    command echo "$LOG_PREFIX   BuildKit aborts with: error from sender: failed to xattr ... too many levels of symbolic links" >&2
    command echo "$LOG_PREFIX   Fixed by the bindfs --xattr-none overlay, which applies on container RESTART." >&2
    # The null separator is emitted as `printf "%s%c", $2, 0` and NOT as the
    # obvious `printf "%s\0", $2`: mawk (the default awk in these images)
    # silently DROPS a literal \0 from the format string, so that spelling
    # concatenates every path into one unsplittable argument and `xargs -0 rm`
    # then removes nothing at all — quietly, for every path, not just the ones
    # with spaces. `%c` with a 0 argument emits a real NUL on both mawk and
    # gawk. Verified by test_xattr_report_workaround_survives_a_path_with_spaces,
    # which RUNS this emitted line rather than pattern-matching it.
    command echo "$LOG_PREFIX   Until then, build with the tracked symlinks temporarily removed:" >&2
    command echo "$LOG_PREFIX     git -C $root ls-files -s | command awk -F'\\t' '\$1 ~ /^120000 / { printf \"%s%c\", \$2, 0 }' | xargs -0 rm -f" >&2
    command echo "$LOG_PREFIX     <run the build>, then: git -C $root checkout -- ." >&2

    return 0
}

# ============================================================================
# Diagnostic: stale index.lock left by a misreported rename (issue #1086)
# ============================================================================

# A lock older than this is not a live git operation. Index writes hold the
# lock for milliseconds; even a large rebase or `git add` of a big tree is done
# well inside ten minutes.
FS_HEALTH_INDEX_LOCK_STALE_SECS=600

# On Docker Desktop virtiofs, rename(2) is occasionally misreported: `mv
# index.lock index` returns an error although `index` already holds the new
# content, and `index.lock` then REAPPEARS and persists with those same bytes.
# Git's next exclusive create of the lock fails, and every later write dies with
# "Unable to create '.git/index.lock': File exists".
#
# Measured in-container with a probe that mirrors git's index write (exclusive
# create, write, rename over index), anomalies per 10,000 cycles:
#
#   raw virtiofs (bindfs unmounted in a private mount ns)         6, 10
#   bindfs overlay, current options                               18
#   bindfs + entry_timeout=0,attr_timeout=0,negative_timeout=0    22
#
# So the defect lives in the virtiofs layer, NOT in bindfs: disabling the FUSE
# caches does not help, and neither does BINDFS_SKIP_PATHS — the raw mount
# underneath fails the same way. Nothing in this image can make the rename
# reliable, which is why this is a DIAGNOSTIC and not a repair.
#
# It deliberately does not delete the lock. A lock can belong to a git process
# in another container sharing the mount, which no process check here can see,
# and the index next to a phantom lock may itself be damaged (#1086 once
# observed an emptied index staging every tracked file as a deletion) — removing
# the lock silently would let the next commit record that damage.
#
# Age, not pgrep, decides "stale": the hourly cron leg cannot attribute a git
# process to one repo, and the mtime answers the question on both legs.
#
# Args: $1 = repo root. No display prefix: the lock path is reported absolute.
check_stale_index_lock() {
    local root="$1"
    local git_dir lock quoted qroot mtime now age

    # --absolute-git-dir, not "$root/.git": in a linked worktree or submodule
    # .git is a FILE, and the lock lives in the git dir it points at.
    git_dir=$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null) || return 0
    lock="${git_dir}/index.lock"
    [ -e "$lock" ] || return 0

    mtime=$("$FS_HEALTH_STAT" -c '%Y' "$lock" 2>/dev/null) || return 0
    case "$mtime" in
        '' | *[!0-9]*) return 0 ;;
    esac
    now=$(/usr/bin/date +%s)
    age=$((now - mtime))
    # A future mtime (host/VM clock skew) gives a negative age and reads as
    # fresh. That errs toward silence, which is the safe side for advice that
    # ends in an rm.
    [ "$age" -ge "$FS_HEALTH_INDEX_LOCK_STALE_SECS" ] || return 0

    # %q everywhere the path is printed: the pasteable commands survive spaces
    # and quotes, and control characters in a crafted submodule path reach the
    # terminal escaped rather than raw.
    quoted=$(command printf '%q' "$lock")
    qroot=$(command printf '%q' "$root")

    command echo "$LOG_PREFIX stale git index lock (${age}s old): $quoted (issue #1086)" >&2
    command echo "$LOG_PREFIX   Git writes will fail with \"Unable to create '$quoted': File exists\"." >&2
    command echo "$LOG_PREFIX   Likely cause: the virtiofs host mount misreported a rename (Docker Desktop on macOS)." >&2
    command echo "$LOG_PREFIX   If no git command is running against this repo, remove it:" >&2
    command echo "$LOG_PREFIX     rm -f -- $quoted" >&2
    command echo "$LOG_PREFIX   Then check 'git -C $qroot status' BEFORE committing. If every tracked file shows" >&2
    command echo "$LOG_PREFIX   as a staged deletion, the index was emptied: rebuild it with 'git -C $qroot reset'" >&2
    command echo "$LOG_PREFIX   (keeps the working tree) — committing it would delete the whole tree." >&2

    return 0
}

# ============================================================================
# Repo traversal: superproject + every initialized submodule, recursively
# ============================================================================

# Run both repairs against one root, then recurse into its submodules.
#
# Args: $1 = repo root, $2 = display prefix for log lines, $3 = current depth
#
# Written as a manual gitlink walk rather than `git submodule foreach
# --recursive` on purpose: foreach spawns a shell per submodule, and both its
# failure semantics and its noise on uninitialized entries would need extra
# containment to satisfy "never fatal to startup, silent when healthy". This
# reuses the same `ls-files -s` idiom the symlink repair already relies on and
# keeps every failure path a local `continue`.
repair_repo_tree() {
    local root="$1" label_prefix="$2" depth="$3"
    local rel sub_root sub_resolved

    check_ignorecase "$root"
    check_symlinks "$root" "$label_prefix"
    check_symlink_xattr "$root" "$label_prefix"
    check_stale_index_lock "$root"

    # Containment backstop, not an expected condition.
    [ "$depth" -lt "$FS_HEALTH_MAX_DEPTH" ] || return 0

    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        sub_root="${root}/${rel}"

        # The gitlink is in the index whether or not the submodule was ever
        # initialized. An uninitialized (or empty) one has no .git, and this
        # single check is what makes it a silent non-event — no warning, no
        # error, nothing to fix. A submodule worktree's .git is a *file*
        # pointing into the superproject's .git/modules, so test -e, not -d.
        [ -e "${sub_root}/.git" ] || continue

        # Dedup is BIDIRECTIONAL (issue #828). Claiming the path stops depth-1
        # discovery from later emitting it as an independent top-level project;
        # the seen-check stops the reverse, where discovery got there first and
        # this walk would repair it a second time. Which of the two runs first
        # is decided by readdir order, so only checking one direction leaves the
        # duplicate to chance.
        sub_resolved=$(fs_health_resolve "$sub_root")
        fs_health_seen "$sub_resolved" && continue
        fs_health_mark_scanned "$sub_resolved"

        repair_repo_tree "$sub_root" "${label_prefix}${rel}/" "$((depth + 1))"
    done < <(git -C "$root" ls-files -s 2>/dev/null |
        /usr/bin/awk -F'\t' '$1 ~ /^160000 / { print $2 }')

    return 0
}
