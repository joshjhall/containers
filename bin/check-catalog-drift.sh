#!/usr/bin/env bash
# Compare the vendored luggage catalog against the upstream containers-db one.
#
# crates/luggage/testdata/catalog is what production ships — the Dockerfile
# COPYs it to /opt/containers-db, so every `luggage install` in a feature script
# resolves against it. Entries reach it by hand-mirroring from containers-db,
# and until issue #815 nothing checked the copy. That had already cost
# correctness: the vendored rust entries were missing
# install_methods[].invoke.env (CARGO_HOME/RUSTUP_HOME) and every rhel
# support-matrix row.
#
# This script fails when a tool+version present in BOTH catalogs disagrees, so
# a future mirroring slip is caught at push time rather than at container-build
# time (or, worse, by installing something subtly wrong).
#
# Only jq is required — deliberately no network. The schema half of
# `just db-validate-vendored` needs `npx ajv` and therefore the network, but
# drift is the higher-value check and must keep working offline: the pre-push
# hook runs with SKIP_NETWORK_TESTS=1.
#
# Scope rules:
#   - Versions with no upstream counterpart (a pin newer than upstream, e.g.
#     the live ARG RUST_VERSION) are REPORTED and skipped, never silently
#     ignored.
#   - Index files are compared field-by-field: available[], default_version,
#     and minimum_recommended describe what THIS catalog holds and legitimately
#     differ. Every other field must match.
#   - crates/luggage/testdata/fixtures-catalog/ is exempt by design and is not
#     passed to this script — it carries edge cases (an unsupported platform
#     cell, a distinctly-named musl method) that exist purely so the hermetic
#     crates/luggage/tests/cli.rs suite can assert on them.
#
# Usage: check-catalog-drift.sh --vendored <dir> --upstream <dir> [--quiet]
# Exit:  0 clean, 1 drift found, 2 usage/IO error.

set -uo pipefail

VENDORED=""
UPSTREAM=""
QUIET=false

while [ $# -gt 0 ]; do
    case "$1" in
        --vendored)
            VENDORED="${2:-}"
            shift 2
            ;;
        --upstream)
            UPSTREAM="${2:-}"
            shift 2
            ;;
        --quiet)
            QUIET=true
            shift
            ;;
        -h | --help)
            command sed -n '2,34p' "$0"
            exit 0
            ;;
        *)
            command echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ -z "$VENDORED" ] || [ -z "$UPSTREAM" ]; then
    command echo "usage: $0 --vendored <dir> --upstream <dir> [--quiet]" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    command echo "ERROR: jq is required" >&2
    exit 2
fi

for pair in "VENDORED:$VENDORED" "UPSTREAM:$UPSTREAM"; do
    label="${pair%%:*}"
    dir="${pair#*:}"
    if [ ! -d "$dir/tools" ]; then
        command echo "ERROR: $label catalog has no tools/ directory: $dir" >&2
        exit 2
    fi
done

# Index fields describing this catalog's own contents rather than the tool, so
# they are expected to differ between the two copies.
readonly LOCAL_FIELDS='["available","default_version","minimum_recommended"]'

compared=0
skipped=0
failures=0
report=""

# say <message> — progress output, suppressed under --quiet.
say() {
    [ "$QUIET" = true ] || command echo "$1"
}

# add_report <message> — accumulate a failure detail for the final block.
add_report() {
    report="${report}${1}"$'\n'
}

# canonical_diff <upstream-json> <vendored-json> <label>
# Emits a unified diff of the two canonicalized documents, or nothing when they
# match. `jq -S` sorts keys and normalizes whitespace, so indentation or key
# order alone never fails the check — only real content differences do.
canonical_diff() {
    local up="$1" ven="$2" label="$3"
    command diff -u \
        --label "upstream/$label" --label "vendored/$label" \
        <(command jq -S . "$up" 2>/dev/null) \
        <(command jq -S . "$ven" 2>/dev/null)
}

# compare_index <upstream-index> <vendored-index> <tool>
# Field-by-field comparison that tolerates the catalog-local fields.
compare_index() {
    local up="$1" ven="$2" tool="$3"
    local keys key up_val ven_val found=0

    keys="$(command jq -r --argjson local "$LOCAL_FIELDS" \
        '[keys[]] | map(select(. as $k | $local | index($k) | not)) | .[]' \
        "$up" "$ven" 2>/dev/null | command sort -u)"

    while IFS= read -r key; do
        [ -n "$key" ] || continue

        # Presence is probed with has() rather than by comparing against a
        # sentinel string — any sentinel could collide with a field whose real
        # value happens to equal it.
        local up_has ven_has
        up_has="$(command jq -r --arg k "$key" 'has($k)' "$up")"
        ven_has="$(command jq -r --arg k "$key" 'has($k)' "$ven")"

        if [ "$ven_has" = "false" ]; then
            found=$((found + 1))
            add_report "  $tool/index.json: missing field \`$key\` (present upstream)"
            continue
        fi
        if [ "$up_has" = "false" ]; then
            found=$((found + 1))
            add_report "  $tool/index.json: extra field \`$key\` (absent upstream)"
            continue
        fi

        up_val="$(command jq -S --arg k "$key" '.[$k]' "$up")"
        ven_val="$(command jq -S --arg k "$key" '.[$k]' "$ven")"

        if [ "$up_val" = "$ven_val" ]; then
            continue
        fi
        found=$((found + 1))
        add_report "  $tool/index.json: field \`$key\` differs"
        add_report "$(command diff -u \
            --label "upstream/$key" --label "vendored/$key" \
            <(command printf '%s\n' "$up_val") \
            <(command printf '%s\n' "$ven_val") | command sed 's/^/    /')"
    done <<<"$keys"

    return "$found"
}

shopt -s nullglob

for tool_dir in "$VENDORED"/tools/*/; do
    [ -d "$tool_dir" ] || continue
    tool="$(command basename "$tool_dir")"
    upstream_tool="$UPSTREAM/tools/$tool"

    if [ ! -d "$upstream_tool" ]; then
        skipped=$((skipped + 1))
        say "SKIP $tool/ — no upstream counterpart (vendored-only tool)"
        continue
    fi

    if [ -f "$tool_dir/index.json" ] && [ -f "$upstream_tool/index.json" ]; then
        compare_index "$upstream_tool/index.json" "$tool_dir/index.json" "$tool"
        found=$?
        failures=$((failures + found))
        compared=$((compared + 1))
        [ "$found" -eq 0 ] && say "OK   $tool/index.json"
    fi

    for version_file in "$tool_dir"versions/*.json; do
        [ -f "$version_file" ] || continue
        version_name="$(command basename "$version_file")"
        upstream_version="$upstream_tool/versions/$version_name"
        label="$tool/versions/$version_name"

        if [ ! -f "$upstream_version" ]; then
            skipped=$((skipped + 1))
            say "SKIP $label — vendored-only version (no upstream entry)"
            continue
        fi

        compared=$((compared + 1))
        if delta="$(canonical_diff "$upstream_version" "$version_file" "$label")" &&
            [ -z "$delta" ]; then
            say "OK   $label"
        else
            failures=$((failures + 1))
            add_report "  $label: differs from upstream"
            add_report "$(command printf '%s\n' "$delta" | command sed 's/^/    /')"
        fi
    done
done

shopt -u nullglob

if [ -n "$report" ]; then
    command echo ""
    command echo "DRIFT DETECTED — vendored catalog disagrees with containers-db:"
    command echo ""
    command printf '%s' "$report"
    command echo ""
    command echo "The vendored catalog is what the image ships. Re-mirror the entry from"
    command echo "$UPSTREAM, or — if the divergence is deliberate and test-only — move it"
    command echo "to crates/luggage/testdata/fixtures-catalog/ instead."
fi

command echo ""
command echo "$compared entries compared, $skipped skipped, $failures drifted"

[ "$failures" -eq 0 ] || exit 1
exit 0
