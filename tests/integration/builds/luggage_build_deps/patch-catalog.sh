#!/usr/bin/env bash
# Patch a COPY of the vendored luggage catalog for the apt/rpm build-dep
# removal fixtures (#1632). Never run against crates/luggage/testdata/catalog
# itself — the Dockerfiles run it on the copy inside a throwaway stage.
#
# No debian/rhel method in the catalog declares a `purpose: build`
# dependency, yet luggage removes build-only packages after ANY method kind
# (installer/mod.rs run_stages). So this adds them to node's prebuilt
# binary-tarball methods: the removal path runs with no compile step.
#
# Usage: patch-catalog.sh MODE CATALOG_DIR OVERLAY_DIR NODE_VERSION
#   MODE happy         make + patch, both `purpose: build` (removable)
#   MODE refuse-debian file (default purpose) + libmagic `purpose: build`;
#                      file depends on libmagic1t64, so dpkg must refuse
#   MODE refuse-rhel   zip (default purpose) + unzip `purpose: build`;
#                      zip requires unzip, so rpm must refuse
#
# Overlay tools (system_package index files) are copied in; for a tool the
# catalog already has, only the overlay's platform mappings are merged, so
# the vendored entry's other fields stay as they were.

set -euo pipefail

if [ "$#" -ne 4 ]; then
    command echo "usage: $0 MODE CATALOG_DIR OVERLAY_DIR NODE_VERSION" >&2
    exit 2
fi
mode="$1" catalog="$2" overlay="$3" node_version="$4"

case "$mode" in
    happy) deps='[{"tool":"make","purpose":"build"},{"tool":"patch","purpose":"build"}]' ;;
    refuse-debian) deps='[{"tool":"file"},{"tool":"libmagic","purpose":"build"}]' ;;
    refuse-rhel) deps='[{"tool":"zip"},{"tool":"unzip","purpose":"build"}]' ;;
    *)
        command echo "unknown mode: $mode" >&2
        exit 2
        ;;
esac

for src in "$overlay"/tools/*/index.json; do
    tool=$(command basename "$(command dirname "$src")")
    dest="$catalog/tools/$tool/index.json"
    if [ -f "$dest" ]; then
        jq --slurpfile o "$src" \
            '.system_package.platforms += $o[0].system_package.platforms' \
            "$dest" >"$dest.new"
        command mv "$dest.new" "$dest"
    else
        command mkdir -p "$catalog/tools/$tool"
        command cp "$src" "$dest"
    fi
done

version_file="$catalog/tools/node/versions/$node_version.json"
if [ ! -f "$version_file" ]; then
    command echo "no catalog entry for node $node_version: $version_file" >&2
    exit 1
fi

# Both per-arch tarball methods, so the fixture behaves the same on an amd64
# CI runner and an arm64 workstation. Fail rather than patch nothing if the
# catalog renames them: a silent no-op would let every removal assertion
# pass vacuously on an image with no build deps at all.
targets='["node-tarball-amd64","node-tarball-arm64"]'
found=$(jq --argjson t "$targets" \
    '[.install_methods[] | select(.name as $n | $t | index($n))] | length' "$version_file")
if [ "$found" != "2" ]; then
    command echo "expected 2 node tarball methods in $version_file, found $found" >&2
    exit 1
fi

jq --argjson t "$targets" --argjson d "$deps" \
    '.install_methods |= map(if (.name as $n | $t | index($n)) then .dependencies += $d else . end)' \
    "$version_file" >"$version_file.new"
command mv "$version_file.new" "$version_file"

command echo "patched node $node_version tarball methods ($mode): $deps"
