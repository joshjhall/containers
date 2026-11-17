#!/usr/bin/env bash
# Vendor containers-db's repo-baseline scaffold templates into stibbons.
#
#   bin/sync-repo-baseline.sh [SHA] [CONTAINERS_DB_REPO]
#
# `stibbons setup standards` embeds crates/stibbons/assets/repo-baseline/ in
# its binary, so it works on a host with no containers-db checkout
# (brew/apt/cargo installs). containers-db owns the baseline
# (`baseline/templates/`, joshjhall/containers-db#558); this script refreshes
# the embedded copy from it at a pinned commit.
#
# SHA must be a full 40-hex commit — never a branch, tag or short SHA, so the
# vendored bytes are reproducible. Omitted, it defaults to the SHA already
# recorded in SOURCE (a plain re-sync of the current pin). CONTAINERS_DB_REPO
# (argument or env var) defaults to $CONTAINERS_DB when that is a git
# checkout, else the containers-db sibling of the main checkout.
#
# Content is read from the commit with `git archive`, never the working tree,
# so an uncommitted edit in the checkout cannot leak in. If the commit is not
# present locally, fetch it first (`git -C <repo> fetch`).
#
# Only manifest.tsv and the sources it names are copied; the template README
# and the reference render.sh are not — stibbons implements the manifest
# contract itself. The whole vendored directory is replaced, so a fragment
# upstream dropped does not linger. SOURCE records `containers-db <sha>`; no
# local patch is carried. Bump the pin by hand (`just sync-repo-baseline
# <sha>`), then rebuild stibbons.
#
# REPO_BASELINE_DEST overrides the destination (tests vendor into scratch).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="${REPO_BASELINE_DEST:-$here/../crates/stibbons/assets/repo-baseline}"

sha="${1:-}"
repo="${2:-${CONTAINERS_DB_REPO:-}}"
if [ -z "$repo" ]; then
    # $CONTAINERS_DB counts only when it is a git checkout: inside the image it
    # names the vendored catalog snapshot (/opt/containers-db), not a repo.
    if [ -n "${CONTAINERS_DB:-}" ] && command git -C "$CONTAINERS_DB" rev-parse --git-dir >/dev/null 2>&1; then
        repo="$CONTAINERS_DB"
    else
        # Sibling of the main checkout — resolved through the common git dir so
        # a run from .worktrees/<name> still finds it.
        common="$(command git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
        repo="$(command dirname "$(command dirname "${common:-$here/../.git}")")/containers-db"
    fi
fi

if [ -z "$sha" ]; then
    if [ -f "$dest/SOURCE" ]; then
        read -r origin pinned _ <"$dest/SOURCE" || true
        if [ "${origin:-}" = containers-db ]; then
            sha="${pinned:-}"
        fi
    fi
    if [ -z "$sha" ]; then
        printf 'sync-repo-baseline: no SHA given and %s/SOURCE names no containers-db pin\n' "$dest" >&2
        exit 2
    fi
fi

if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'sync-repo-baseline: SHA must be a full 40-hex commit (no branch, tag or short SHA): %s\n' "$sha" >&2
    exit 2
fi

if ! command git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'sync-repo-baseline: not a git checkout of containers-db: %s\n' "$repo" >&2
    exit 2
fi
if ! command git -C "$repo" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    printf 'sync-repo-baseline: commit %s not found in %s (try: git -C %s fetch)\n' "$sha" "$repo" "$repo" >&2
    exit 2
fi

stage="$(command mktemp -d)"
trap 'command rm -rf "$stage"' EXIT

# Extract the committed templates tree into scratch; the working tree is never
# read. Symlinks survive as symlinks, so the guards below still see them.
command mkdir -p "$stage/src" "$stage/out"
if ! command git -C "$repo" archive --format=tar "$sha" baseline/templates |
    command tar -x -C "$stage/src"; then
    printf 'sync-repo-baseline: %s has no baseline/templates\n' "$sha" >&2
    exit 2
fi

templates="$stage/src/baseline/templates"
manifest="$templates/manifest.tsv"
out="$stage/out"

if [ ! -f "$manifest" ]; then
    printf 'sync-repo-baseline: manifest not found at %s: baseline/templates/manifest.tsv\n' "$sha" >&2
    exit 2
fi

templates_real="$(command realpath "$templates")"
command cp "$manifest" "$out/manifest.tsv"
while IFS="$(printf '\t')" read -r target _slice _when source || [ -n "${target:-}" ]; do
    case "$target" in '' | '#'*) continue ;; esac
    # Keep every copy inside the templates dir: no absolute or `..` source, no
    # symlink (cp would dereference it and vendor whatever it points at).
    case "/$source/" in
        //* | */../*)
            printf 'sync-repo-baseline: manifest source escapes the templates dir: %s\n' "$source" >&2
            exit 2
            ;;
    esac
    # -L catches a symlinked file; the resolved-path prefix check also catches
    # a symlinked directory partway along the path.
    if [ -L "$templates/$source" ] || {
        [ -e "$templates/$source" ] &&
            case "$(command realpath "$templates/$source")/" in
                "$templates_real"/*) false ;;
                *) true ;;
            esac
    } then
        printf 'sync-repo-baseline: manifest source is a symlink: %s\n' "$source" >&2
        exit 2
    fi
    if [ ! -f "$templates/$source" ]; then
        printf 'sync-repo-baseline: manifest names a missing source: %s\n' "$source" >&2
        exit 2
    fi
    command mkdir -p "$out/$(command dirname "$source")"
    command cp "$templates/$source" "$out/$source"
done <"$manifest"

printf 'containers-db %s\n' "$sha" >"$out/SOURCE"

command rm -rf "$dest"
command mkdir -p "$(command dirname "$dest")"
command cp -R "$out" "$dest"
command chmod -R u+rwX,go+rX "$dest"
printf 'vendored repo-baseline templates from containers-db %s into %s\n' "$sha" "$dest"
