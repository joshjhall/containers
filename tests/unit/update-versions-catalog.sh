#!/usr/bin/env bash
# Unit tests: update-versions mirrors containers-db's catalog entry for a
# bumped luggage tool instead of keeping the one `luggage catalog add-version`
# generates.
#
# The generated entry carries today's timestamps, today as `released`, and no
# tested[] rows. Once the containers-db scanner published versions promptly,
# upstream already had every version auto-patch bumped to, so the generated
# entry always disagreed with it and the vendored-catalog drift gate red-lit
# the auto-patch branch (rust 1.99.0, 2026-10).
#
# Offline: CONTAINERS_DB_SRC points at a fixture checkout, so the HTTPS
# fallback is never taken.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "update-versions catalog mirror"

MIRROR_LIB="$PROJECT_ROOT/bin/lib/update-versions/catalog.sh"

# _write_entry <path> <tool> <version> <released>
_write_entry() {
    command mkdir -p "$(command dirname "$1")"
    command cat >"$1" <<EOF
{
  "tool": "$2",
  "version": "$3",
  "released": "$4",
  "tested": []
}
EOF
}

# Run mirror_upstream_catalog_entry for rust@1.99.0 against a vendored dir
# holding a "generated" entry (released 2099-01-01) and an upstream fixture
# checkout. Prints the vendored entry's resulting `released`.
_run_mirror() {
    local upstream="$1" vendored
    vendored="$(command mktemp -d)"
    _write_entry "$vendored/tools/rust/versions/1.99.0.json" rust 1.99.0 2099-01-01
    (
        YELLOW='' BLUE='' NC=''
        # shellcheck source=bin/lib/update-versions/catalog.sh
        source "$MIRROR_LIB"
        CONTAINERS_DB_SRC="$upstream" \
            mirror_upstream_catalog_entry rust 1.99.0 "$vendored" >/dev/null 2>&1
    )
    command jq -r '.released' "$vendored/tools/rust/versions/1.99.0.json"
    command rm -rf "$vendored"
}

test_upstream_entry_replaces_generated() {
    local upstream
    upstream="$(command mktemp -d)"
    _write_entry "$upstream/tools/rust/versions/1.99.0.json" rust 1.99.0 2026-10-01
    assert_equals "2026-10-01" "$(_run_mirror "$upstream")" \
        "vendored entry is containers-db's copy, not the generated one"
    command rm -rf "$upstream"
}

test_missing_upstream_keeps_generated() {
    local upstream
    upstream="$(command mktemp -d)"
    command mkdir -p "$upstream/tools/rust/versions"
    assert_equals "2099-01-01" "$(_run_mirror "$upstream")" \
        "no upstream entry keeps the generated one (the pin still needs it)"
    command rm -rf "$upstream"
}

test_mismatched_upstream_entry_is_rejected() {
    # A file at the right path whose content names another version must not
    # overwrite the entry: only a well-formed tool@version match is mirrored.
    local upstream
    upstream="$(command mktemp -d)"
    _write_entry "$upstream/tools/rust/versions/1.99.0.json" rust 1.98.1 2026-09-07
    assert_equals "2099-01-01" "$(_run_mirror "$upstream")" \
        "an upstream file for a different version is not mirrored"
    command rm -rf "$upstream"
}

test_mirror_strips_upstream_trailing_blank_line() {
    # containers-db files written by evidence ingest before the
    # evidence-merge.sh fix end in "}\n\n"; mirrored verbatim, one failed
    # end-of-file-fixer on the 2026-10-25 auto-patch branch.
    local upstream vendored tail_hex
    upstream="$(command mktemp -d)"
    vendored="$(command mktemp -d)"
    _write_entry "$upstream/tools/rust/versions/1.99.0.json" rust 1.99.0 2026-10-01
    command echo "" >>"$upstream/tools/rust/versions/1.99.0.json"
    _write_entry "$vendored/tools/rust/versions/1.99.0.json" rust 1.99.0 2099-01-01
    (
        YELLOW='' BLUE='' NC=''
        # shellcheck source=bin/lib/update-versions/catalog.sh
        source "$MIRROR_LIB"
        CONTAINERS_DB_SRC="$upstream" \
            mirror_upstream_catalog_entry rust 1.99.0 "$vendored" >/dev/null 2>&1
    )
    tail_hex="$(command tail -c 2 "$vendored/tools/rust/versions/1.99.0.json" | command od -An -tx1 | command tr -d ' \n')"
    assert_equals "2026-10-01" "$(command jq -r '.released' "$vendored/tools/rust/versions/1.99.0.json")" \
        "the upstream entry is still mirrored"
    assert_equals "7d0a" "$tail_hex" "mirrored entry ends in '}\\n', not a trailing blank line"
    command rm -rf "$upstream" "$vendored"
}

test_update_luggage_catalog_calls_mirror() {
    # The mirror only helps if the auto-patch path reaches it.
    assert_file_contains "$MIRROR_LIB" \
        'mirror_upstream_catalog_entry "$tool" "$version" "$catalog"' \
        "update_luggage_catalog mirrors after add-version"
}

run_test test_upstream_entry_replaces_generated "upstream entry replaces the generated one"
run_test test_missing_upstream_keeps_generated "missing upstream entry keeps the generated one"
run_test test_mismatched_upstream_entry_is_rejected "mismatched upstream entry is rejected"
run_test test_mirror_strips_upstream_trailing_blank_line "mirror strips an upstream trailing blank line"
run_test test_update_luggage_catalog_calls_mirror "update_luggage_catalog calls the mirror"

generate_report
