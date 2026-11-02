#!/usr/bin/env bash
# Vendor librarian's repo-baseline scaffold templates into stibbons.
#
#   bin/sync-repo-baseline.sh [LIBRARIAN_ROOT]     (default: /opt/librarian)
#
# `stibbons setup standards` embeds crates/stibbons/assets/repo-baseline/ in
# its binary, so it works on a host with no librarian checkout (brew/apt/cargo
# installs). This script refreshes that copy from a librarian tree: it copies
# manifest.tsv plus every source file the manifest names, and records the
# librarian version in SOURCE. Files the manifest does not reference (the
# template README, the reference render.sh) are not copied — stibbons
# implements the manifest contract itself.
#
# Replaces the whole vendored directory, so a fragment librarian dropped does
# not linger. The weekly auto-patch runs it on every LIBRARIAN_REF bump
# (sync_repo_baseline in bin/lib/update-versions/repo-baseline.sh, #1543); run
# it by hand (`just sync-repo-baseline`) after a manual bump, then rebuild
# stibbons.
#
# LOCAL PATCH (SOURCE reads "+pygments-pin"): python/requirements.txt carries
# `pygments>=2.20.0`, which librarian 0.18.0 lacks. Without it the pre-push
# osv-scanner resolves pytest's pygments floor to 2.9.0 (PYSEC-2023-117,
# PYSEC-2026-2987). The script re-applies it — and the SOURCE suffix — only
# while upstream's requirements.txt names no pygments at all, so the patch
# drops itself once librarian ships the pin (joshjhall/librarian#1261).
#
# REPO_BASELINE_DEST overrides the destination (tests vendor into scratch).
set -euo pipefail

src_root="${1:-/opt/librarian}"
templates="$src_root/plugins/dev-core/skills/repo-baseline/templates"
manifest="$templates/manifest.tsv"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="${REPO_BASELINE_DEST:-$here/../crates/stibbons/assets/repo-baseline}"

if [ ! -f "$manifest" ]; then
    printf 'sync-repo-baseline: manifest not found: %s\n' "$manifest" >&2
    exit 2
fi

version="unknown"
if [ -f "$src_root/VERSION" ]; then
    version="$(command tr -d '[:space:]' <"$src_root/VERSION")"
fi

stage="$(command mktemp -d)"
trap 'command rm -rf "$stage"' EXIT

command cp "$manifest" "$stage/manifest.tsv"
while IFS="$(printf '\t')" read -r target _slice _when source || [ -n "${target:-}" ]; do
    case "$target" in '' | '#'*) continue ;; esac
    # Auto-patch feeds this a freshly cloned tree, so keep every copy inside
    # the templates dir: no absolute or `..` source, no symlink (cp would
    # dereference it and vendor whatever it points at).
    case "/$source/" in
        //* | */../*)
            printf 'sync-repo-baseline: manifest source escapes the templates dir: %s\n' "$source" >&2
            exit 2
            ;;
    esac
    if [ -L "$templates/$source" ]; then
        printf 'sync-repo-baseline: manifest source is a symlink: %s\n' "$source" >&2
        exit 2
    fi
    if [ ! -f "$templates/$source" ]; then
        printf 'sync-repo-baseline: manifest names a missing source: %s\n' "$source" >&2
        exit 2
    fi
    command mkdir -p "$stage/$(command dirname "$source")"
    command cp "$templates/$source" "$stage/$source"
done <"$manifest"

# Local patch: see the header. Applied only while upstream lacks any pygments
# requirement, so a librarian that pins it (at whatever floor) wins.
suffix=""
reqs="$stage/python/requirements.txt"
if [ -f "$reqs" ] && ! command grep -qiE '^[[:space:]]*pygments([^a-z0-9_.-]|$)' "$reqs"; then
    # Guarantee a trailing newline before appending, or the pin would be glued
    # onto upstream's last requirement.
    if [ -s "$reqs" ] && [ -n "$(command tail -c 1 "$reqs")" ]; then
        printf '\n' >>"$reqs"
    fi
    printf 'pygments>=2.20.0\n' >>"$reqs"
    suffix=" +pygments-pin"
fi

printf 'librarian %s%s\n' "$version" "$suffix" >"$stage/SOURCE"

command rm -rf "$dest"
command mkdir -p "$(command dirname "$dest")"
command cp -R "$stage" "$dest"
command chmod -R u+rwX,go+rX "$dest"
printf 'vendored repo-baseline templates from librarian %s%s into %s\n' "$version" "$suffix" "$dest"
