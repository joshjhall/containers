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
# not linger. Run it after bumping LIBRARIAN_REF, then rebuild stibbons.
set -euo pipefail

src_root="${1:-/opt/librarian}"
templates="$src_root/plugins/dev-core/skills/repo-baseline/templates"
manifest="$templates/manifest.tsv"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="$here/../crates/stibbons/assets/repo-baseline"

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
    if [ ! -f "$templates/$source" ]; then
        printf 'sync-repo-baseline: manifest names a missing source: %s\n' "$source" >&2
        exit 2
    fi
    command mkdir -p "$stage/$(command dirname "$source")"
    command cp "$templates/$source" "$stage/$source"
done <"$manifest"

printf 'librarian %s\n' "$version" >"$stage/SOURCE"

command rm -rf "$dest"
command mkdir -p "$(command dirname "$dest")"
command cp -R "$stage" "$dest"
command chmod -R u+rwX,go+rX "$dest"
printf 'vendored repo-baseline templates from librarian %s into %s\n' "$version" "crates/stibbons/assets/repo-baseline"
