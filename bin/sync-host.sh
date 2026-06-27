#!/usr/bin/env bash
# sync-host.sh — refresh a bare-repo host's runtime working copies from origin/main.
#
# THE PROBLEM (issue #606). The worktree/golem flow runs on a BARE-repo host
# (`git rev-parse --is-bare-repository` → true). A bare repo has no work tree,
# so git NEVER checks files out: the on-disk runtime copies the host actually
# executes — `.claude/hooks/golem-notify.sh`, `justfile`, `bin/*` — are plain
# files hand-placed once and then frozen. When `main` advances (a golem PR
# merges), `git fetch` updates the object store but leaves those copies stale,
# so Claude keeps firing the pre-merge hook and `just` runs the pre-merge
# justfile — silently reverting fixes that already landed on `main`.
#
# THE FIX. `git checkout` can't help (no work tree to check out INTO), so we
# mirror the manual remedy from the issue: for every tracked file under the
# sync set, copy its `origin/main` blob onto disk. Enumerate with
# `git ls-tree -r origin/main -- <prefix>` (gives mode + blob sha + path),
# write each blob to its path with an atomic temp+rename, and set the
# executable bit from the tree mode (100755 → +x, 100644 → −x). This works
# identically on a bare host, a worktree, and a normal checkout — though on a
# normal checkout `git checkout`/`git pull` is the idiomatic path; this script
# exists for the bare host that has neither.
#
# MODES.
#   (default)  Refresh: fetch origin/main, then write every drifted file.
#   --check    Drift guard: report files whose on-disk content differs from
#              origin/main (or are missing) and exit 1 if any drift, WITHOUT
#              writing anything. Exit 0 when everything is in sync. Lets a
#              caller surface staleness instead of silently running stale code.
#   --no-fetch Skip the `git fetch origin main` (offline / hermetic tests;
#              compares against whatever origin/main already points at).
#
# SYNC SET. Defaults to the runtime copies the host executes — `.claude/hooks`,
# `justfile`, `bin`. Override by passing path prefixes as positional args
# (repo-root-relative), e.g. `sync-host.sh justfile` to refresh only that.
#
# Resolves the repo root bare-safely via bin/repo-root.sh (landed in #604);
# all paths are relative to that root, so the script works from any cwd.
#
# Usage: sync-host.sh [--check] [--no-fetch] [PREFIX ...]
# Exit:  0 = in sync / refreshed; 1 = drift found (--check) or a write failed;
#        2 = usage error or repo root unresolvable.
set -euo pipefail

# Default sync set: the runtime working copies a bare host actually executes.
DEFAULT_PREFIXES=(.claude/hooks justfile bin)

check_only=0
do_fetch=1
prefixes=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check) check_only=1 ;;
        --no-fetch) do_fetch=0 ;;
        --)
            shift
            break
            ;;
        -*)
            command echo "sync-host: unknown option '$1'" >&2
            command echo "Usage: sync-host.sh [--check] [--no-fetch] [PREFIX ...]" >&2
            exit 2
            ;;
        *) prefixes+=("$1") ;;
    esac
    shift
done
# Any remaining args after `--` are also prefixes.
while [ "$#" -gt 0 ]; do
    prefixes+=("$1")
    shift
done

if [ "${#prefixes[@]}" -eq 0 ]; then
    prefixes=("${DEFAULT_PREFIXES[@]}")
fi

# Resolve the main checkout root bare-safely (#604) and operate from there so
# every tracked path is root-relative regardless of the caller's cwd.
root="$(bash "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/repo-root.sh")" || {
    command echo "sync-host: could not resolve repository root" >&2
    exit 2
}
cd "$root"

if [ "$do_fetch" -eq 1 ]; then
    if ! git fetch origin main --quiet 2>/dev/null; then
        command echo "sync-host: 'git fetch origin main' failed (continuing against cached origin/main)" >&2
    fi
fi

# Confirm origin/main is resolvable before we enumerate against it.
if ! git rev-parse --verify --quiet origin/main >/dev/null; then
    command echo "sync-host: origin/main not found — fetch it first (or drop --no-fetch)" >&2
    exit 2
fi

drift=0   # count of files that differ from origin/main
updated=0 # count of files written this run
failed=0  # count of write failures

# Walk the sync set. `git ls-tree -r origin/main -- <prefix>` yields one line
# per tracked blob: "<mode> <type> <sha>\t<path>". A non-existent prefix simply
# yields nothing (no error), so a stale sync-set entry degrades to a no-op.
for prefix in "${prefixes[@]}"; do
    while IFS=$'\t' read -r meta path; do
        [ -n "$path" ] || continue
        mode="${meta%% *}" # e.g. 100644 or 100755
        sha="${meta##* }"  # blob object id

        # In sync iff the on-disk file exists and hashes to the same blob.
        on_disk_sha=""
        if [ -f "$path" ]; then
            on_disk_sha="$(git hash-object "$path" 2>/dev/null || true)"
        fi
        if [ "$on_disk_sha" = "$sha" ]; then
            continue
        fi

        drift=$((drift + 1))

        if [ "$check_only" -eq 1 ]; then
            if [ -z "$on_disk_sha" ]; then
                command echo "  DRIFT (missing): $path"
            else
                command echo "  DRIFT: $path"
            fi
            continue
        fi

        # Refresh: write the origin/main blob atomically (temp adjacent to the
        # target, on the same filesystem, then rename) so an interrupted write
        # can never leave a half-written runtime file the host then executes.
        dir="$(/usr/bin/dirname "$path")"
        /usr/bin/mkdir -p "$dir"
        tmp="$(/usr/bin/mktemp "${path}.sync-XXXXXX")"
        if git cat-file blob "$sha" >"$tmp" 2>/dev/null; then
            # Preserve the executable bit recorded in the tree (100755 → 0755).
            if [ "$mode" = "100755" ]; then
                /usr/bin/chmod 0755 "$tmp"
            else
                /usr/bin/chmod 0644 "$tmp"
            fi
            /usr/bin/mv "$tmp" "$path"
            command echo "  updated $path"
            updated=$((updated + 1))
        else
            /usr/bin/rm -f "$tmp"
            command echo "sync-host: failed to read blob for $path" >&2
            failed=$((failed + 1))
        fi
    done < <(git ls-tree -r origin/main -- "$prefix")
done

if [ "$check_only" -eq 1 ]; then
    if [ "$drift" -gt 0 ]; then
        command echo "sync-host: $drift file(s) drifted from origin/main — run 'just sync-host' to refresh" >&2
        exit 1
    fi
    command echo "sync-host: in sync with origin/main"
    exit 0
fi

if [ "$failed" -gt 0 ]; then
    command echo "sync-host: $failed file(s) failed to update" >&2
    exit 1
fi

if [ "$updated" -eq 0 ]; then
    command echo "sync-host: already in sync with origin/main"
else
    command echo "sync-host: refreshed $updated file(s) from origin/main"
fi
exit 0
