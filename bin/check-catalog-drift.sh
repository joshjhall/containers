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
#   - A version with no upstream counterpart is allowed ONLY when it is the
#     tool's live pin — `ARG <TOOL>_VERSION=` in the --dockerfile — which may
#     briefly run ahead of the upstream scanner. It is skipped with a
#     `::warning::` (printed even under --quiet). Any other vendored-only
#     version is drift: an unbounded skip let 1.97.0-1.98.1 diverge for four
#     months behind a stalled scanner (containers-db#90, #1102) while this
#     check stayed green. Without --dockerfile there is no pin, so every
#     vendored-only version fails. A vendored-only TOOL is still reported and
#     skipped.
#   - Index files are compared field-by-field: available[] and
#     default_version describe what THIS catalog holds and legitimately differ.
#     minimum_recommended is NOT exempt: luggage enforces it as the support
#     floor (resolving below it fails), so a vendored floor that disagreed with
#     upstream silently changed which versions install (#1115: vendored 1.82.0
#     vs upstream 1.93.0 refused the first evidence run). `activity` is skipped: it is the scanner's bookkeeping
#     (scanned_at, release/commit signals), rewritten upstream on every scan
#     that adds a version, so comparing it red-lit every branch after each
#     scan, exactly the churn tested[] caused. Every other field must match.
#   - Version files are compared without tested[]. That is CI evidence, not
#     install data: evidence-run appends to it upstream on every merged
#     evidence PR, so comparing it red-lit every branch here until someone
#     re-mirrored by hand. Its only reader, `luggage reconcile`, fetches the
#     published evidence itself and warns when it has to fall back to the
#     vendored copy.
#   - crates/luggage/testdata/fixtures-catalog/ is exempt by design and is not
#     passed to this script — it carries edge cases (an unsupported platform
#     cell, a distinctly-named musl method) that exist purely so the hermetic
#     crates/luggage/tests/cli.rs suite can assert on them.
#
# Usage: check-catalog-drift.sh --vendored <dir> --upstream <dir>
#                               [--dockerfile <path>] [--quiet]
# Exit:  0 clean, 1 drift found, 2 usage/IO error.

set -uo pipefail

VENDORED=""
UPSTREAM=""
DOCKERFILE=""
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
        --dockerfile)
            DOCKERFILE="${2:-}"
            shift 2
            ;;
        --quiet)
            QUIET=true
            shift
            ;;
        -h | --help)
            command sed -n '2,53p' "$0"
            exit 0
            ;;
        *)
            command echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ -z "$VENDORED" ] || [ -z "$UPSTREAM" ]; then
    command echo "usage: $0 --vendored <dir> --upstream <dir> [--dockerfile <path>] [--quiet]" >&2
    exit 2
fi

if [ -n "$DOCKERFILE" ] && [ ! -r "$DOCKERFILE" ]; then
    command echo "ERROR: --dockerfile is not readable: $DOCKERFILE" >&2
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
readonly LOCAL_FIELDS='["available","default_version"]'

# Version-file fields excluded from the comparison (see the header).
readonly EVIDENCE_FIELDS='["tested"]'

# Index fields excluded because the upstream scanner rewrites them on every
# scan (see the header). Not install data.
readonly SCANNER_FIELDS='["activity"]'

compared=0
skipped=0
failures=0
report=""

# say <message> — progress output, suppressed under --quiet.
say() {
    [ "$QUIET" = true ] || command echo "$1"
}

# live_pin <tool> — print the tool's `ARG <TOOL>_VERSION=` default from
# --dockerfile, or nothing when there is no Dockerfile or no such ARG.
live_pin() {
    [ -n "$DOCKERFILE" ] || return 0
    local var
    var="$(command printf '%s' "$1" | command tr '[:lower:]-' '[:upper:]_')_VERSION"
    command sed -n -E "s/^ARG ${var}=\"?([^\" ]+)\"?[[:space:]]*\$/\\1/p" "$DOCKERFILE" |
        command sed -n '1p'
}

# add_report <message> — accumulate a failure detail for the final block.
add_report() {
    report="${report}${1}"$'\n'
}

# canonical_diff <upstream-json> <vendored-json> <label>
# Emits a unified diff of the two canonicalized documents, or nothing when they
# match. `jq -S` sorts keys and normalizes whitespace, so indentation or key
# order alone never fails the check — only real content differences do.
# EVIDENCE_FIELDS are dropped from both sides first.
canonical_diff() {
    local up="$1" ven="$2" label="$3"
    local strip='delpaths([$skip[] | [.]])'
    command diff -u \
        --label "upstream/$label" --label "vendored/$label" \
        <(command jq -S --argjson skip "$EVIDENCE_FIELDS" "$strip" "$up" 2>/dev/null) \
        <(command jq -S --argjson skip "$EVIDENCE_FIELDS" "$strip" "$ven" 2>/dev/null)
}

# compare_index <upstream-index> <vendored-index> <tool>
# Field-by-field comparison that tolerates the catalog-local fields.
compare_index() {
    local up="$1" ven="$2" tool="$3"
    local keys key up_val ven_val found=0

    keys="$(command jq -r --argjson local "$LOCAL_FIELDS" --argjson scan "$SCANNER_FIELDS" \
        '[keys[]] | map(select(. as $k | ($local + $scan) | index($k) | not)) | .[]' \
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

    pin="$(live_pin "$tool")"

    for version_file in "$tool_dir"versions/*.json; do
        [ -f "$version_file" ] || continue
        version_name="$(command basename "$version_file")"
        upstream_version="$upstream_tool/versions/$version_name"
        label="$tool/versions/$version_name"

        if [ ! -f "$upstream_version" ]; then
            if [ -n "$pin" ] && [ "${version_name%.json}" = "$pin" ]; then
                skipped=$((skipped + 1))
                # Not routed through say(): an allowed skip must stay visible
                # under --quiet, or it is indistinguishable from a pass.
                command echo "::warning::$label is vendored-only (live pin, not yet upstream); publish it to containers-db"
            else
                failures=$((failures + 1))
                add_report "  $label: vendored-only and not the live pin${pin:+ ($pin)}; publish it upstream (containers-db) or remove it"
            fi
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
command echo "$compared entries compared, $skipped skipped (vendored-only tool or live pin), $failures drifted"

[ "$failures" -eq 0 ] || exit 1
exit 0
