#!/usr/bin/env bash
# Unit tests: the VENDORED luggage catalog must stay valid and in sync.
#
# crates/luggage/testdata/catalog is what production ships — the Dockerfile
# COPYs it to /opt/containers-db, so every `luggage install` in a feature
# script resolves against it. Entries reach it by hand-mirroring from the
# sibling containers-db, and nothing checked the copy until issue #815. That
# had already cost correctness: the vendored rust entries were missing
# install_methods[].invoke.env (CARGO_HOME/RUSTUP_HOME) and every rhel
# support-matrix row.
#
# `just db-validate-vendored` is the full local check. This test exists so the
# same checks run in CI's existing "Run Tests" job (ci.yml) with no new
# workflow, and in the pre-push hook.
#
# Network split — deliberate, and the reason this is worth a test rather than
# just a recipe: the schema half shells out to `npx ajv` and needs the network,
# so it skips when offline or under SKIP_NETWORK_TESTS=1 (the pre-push runner
# sets that; see tests/framework.sh:network_tests_disabled). The drift and
# structural halves need only jq and run UNCONDITIONALLY — drift is the
# higher-value check and the one a hand-mirroring slip actually trips, so it
# must keep gating offline pushes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Vendored luggage catalog tests"

VENDORED="$PROJECT_ROOT/crates/luggage/testdata/catalog"
FIXTURES="$PROJECT_ROOT/crates/luggage/testdata/fixtures-catalog"
NEGATIVE="$PROJECT_ROOT/crates/luggage/testdata/_negative"
DRIFT_SCRIPT="$PROJECT_ROOT/bin/check-catalog-drift.sh"

# The containers-db checkout to compare against.
#
# NOT ${CONTAINERS_DB:-...}: inside these dev containers that variable is set to
# /opt/containers-db (Dockerfile ENV) and points at the image's own COPY of the
# vendored snapshot — comparing the catalog against itself would pass
# vacuously. Honour an explicit CONTAINERS_DB_SRC override, else the sibling
# checkout.
UPSTREAM_DB="${CONTAINERS_DB_SRC:-$PROJECT_ROOT/../containers-db}"

# _dockerfile_rust_pin — the repo Dockerfile's RUST_VERSION default, parsed
# the way live_pin parses it (quotes and trailing whitespace stripped, first
# match only), so a guard comparing against it agrees with the script.
_dockerfile_rust_pin() {
    command sed -n -E 's/^ARG RUST_VERSION="?([^"[:space:]]+)"?[[:space:]]*$/\1/p' \
        "$PROJECT_ROOT/Dockerfile" | command sed -n '1p'
}

# True when the upstream catalog and jq are both available.
upstream_available() {
    [ -d "$UPSTREAM_DB/tools" ] && command -v jq >/dev/null 2>&1
}

# Skip locally, FAIL in CI.
#
# A drift check that silently skips is worse than no check: a skip renders
# identically to a pass in the summary, so the gap #815 exists to close would
# sit un-executed on every run. Same rule (and same reason) as the yq-backed
# tests in tests/unit/gitlab-templates.sh — see #768. CI provides the checkout
# via the "Checkout containers-db" step in .github/workflows/ci.yml.
require_upstream_in_ci() {
    local reason="$1"
    if [ "${CI:-false}" = "true" ]; then
        fail_test "$reason — required in CI, cannot silently skip (see .github/workflows/ci.yml)"
    else
        skip_test "$reason"
    fi
}

# True when ajv can actually run: network allowed, schemas present, npx here.
ajv_available() {
    ! network_tests_disabled &&
        [ -d "$UPSTREAM_DB/schema" ] &&
        command -v npx >/dev/null 2>&1
}

# Same skip-locally / fail-in-CI rule as require_upstream_in_ci, with one
# carve-out: SKIP_NETWORK_TESTS is a deliberate opt-out (the pre-push runner
# sets it), so honour it even under CI rather than turning an intentional
# offline run into a failure. Everything else — missing npx, missing schemas —
# is a broken CI setup and must be loud.
require_ajv_in_ci() {
    local reason="$1"
    if [ "${CI:-false}" = "true" ] && ! network_tests_disabled; then
        fail_test "$reason — required in CI, cannot silently skip (see .github/workflows/ci.yml)"
    else
        skip_test "$reason"
    fi
}

# ajv invocation with the same pins and mandatory flags the justfile bakes into
# AJV_CLI_VERSION / AJV_FORMATS_VERSION / AJV_FLAGS. Keep in sync with justfile.
run_ajv() {
    command npx --yes -p ajv-cli@5.0.0 -p ajv-formats@3.0.1 -- ajv validate \
        --spec=draft2020 -c ajv-formats "$@"
}

# ---------------------------------------------------------------------------
# Drift — runs offline, gates every push
# ---------------------------------------------------------------------------

test_vendored_matches_upstream() {
    if ! upstream_available; then
        require_upstream_in_ci "no containers-db checkout at $UPSTREAM_DB (set CONTAINERS_DB_SRC)"
        return 0
    fi

    local output rc=0
    output="$(command bash "$DRIFT_SCRIPT" --vendored "$VENDORED" \
        --upstream "$UPSTREAM_DB" --dockerfile "$PROJECT_ROOT/Dockerfile" 2>&1)" || rc=$?

    if [ "$rc" -ne 0 ]; then
        fail_test "drift against $UPSTREAM_DB:"$'\n'"$output"
    else
        # An allowed live-pin skip passes, but must not pass unseen (#1102).
        command printf '%s\n' "$output" | command grep '^::warning::' >&2 || true
    fi
    return 0
}

# A check that never fires is indistinguishable from a clean tree. Stage each
# schema-VALID drift fixture over the real 1.96.0 entry in a throwaway copy and
# require the comparison to reject it.
test_drift_fixtures_are_rejected() {
    if ! upstream_available; then
        require_upstream_in_ci "no containers-db checkout at $UPSTREAM_DB (set CONTAINERS_DB_SRC)"
        return 0
    fi

    local accepted="" misstaged="" checked=0 index_checked=0 vonly_checked=0
    local fixture staged target version pin
    pin="$(_dockerfile_rust_pin)"
    shopt -s nullglob
    for fixture in "$NEGATIVE"/drift-*.json; do
        checked=$((checked + 1))

        # Route each fixture to the catalog path it perturbs. The drift check
        # has two comparison paths — compare_index (field-by-field, for tool
        # indexes) and canonical_diff (whole-document, for version files) — so
        # staging every fixture at one path would leave the other unproven.
        # drift-vendored-only-* is staged as a NEW version file, exercising the
        # live-pin gate (#1284) — mirrors just/db.just db-validate-vendored.
        case "$(basename "$fixture")" in
            drift-index-*)
                target="tools/rust/index.json"
                index_checked=$((index_checked + 1))
                ;;
            drift-vendored-only-*)
                version="$(command jq -r .version "$fixture")"
                target="tools/rust/versions/$version.json"
                vonly_checked=$((vonly_checked + 1))
                # Overwriting a real entry, or matching the pin, would make it
                # fail (or pass) for a reason other than the one it exists for.
                if [ -e "$VENDORED/$target" ] || [ "$version" = "$pin" ]; then
                    misstaged="$misstaged $(basename "$fixture")"
                    continue
                fi
                ;;
            *) target="tools/rust/versions/1.96.0.json" ;;
        esac

        staged="$TEST_TEMP_DIR/staged-$(basename "$fixture" .json)"
        command mkdir -p "$staged"
        command cp -r "$VENDORED"/. "$staged/"
        command cp "$fixture" "$staged/$target"
        if command bash "$DRIFT_SCRIPT" --vendored "$staged" \
            --upstream "$UPSTREAM_DB" --dockerfile "$PROJECT_ROOT/Dockerfile" \
            --quiet >/dev/null 2>&1; then
            accepted="$accepted $(basename "$fixture")"
        fi
        command rm -rf "$staged"
    done
    shopt -u nullglob

    if [ "$checked" -eq 0 ]; then
        fail_test "no drift-*.json fixtures in $NEGATIVE — the drift check is unproven"
    elif [ "$index_checked" -eq 0 ]; then
        fail_test "no drift-index-*.json fixture in $NEGATIVE — compare_index's branches are unproven"
    elif [ "$vonly_checked" -eq 0 ]; then
        fail_test "no drift-vendored-only-*.json fixture in $NEGATIVE — the live-pin gate is unproven"
    elif [ -n "$misstaged" ]; then
        fail_test "drift-vendored-only fixture(s) name an existing version or the live pin ($pin):$misstaged"
    elif [ -n "$accepted" ]; then
        fail_test "drift check ACCEPTED fixture(s) it must reject:$accepted"
    fi
    return 0
}

# _mini_catalog <dir> <released> <tested-json>
# A one-version catalog, so the evidence-exclusion tests below run offline and
# do not depend on what the real containers-db happens to hold.
_mini_catalog() {
    command mkdir -p "$1/tools/rust/versions"
    command printf '{"id":"rust","available":[{"version":"1.0.0"}]}\n' \
        >"$1/tools/rust/index.json"
    command printf '{"tool":"rust","version":"1.0.0","released":"%s","tested":%s}\n' \
        "$2" "$3" >"$1/tools/rust/versions/1.0.0.json"
}

test_drift_ignores_tested_evidence() {
    # Evidence-run appends tested[] rows upstream on every merged evidence PR;
    # comparing them red-lit every branch here until a manual re-mirror.
    local up="$TEST_TEMP_DIR/ev-up" ven="$TEST_TEMP_DIR/ev-ven"
    _mini_catalog "$up" 2026-10-01 '[{"os":"debian","arch":"amd64","result":"pass"}]'
    _mini_catalog "$ven" 2026-10-01 '[]'
    local rc=0
    command bash "$DRIFT_SCRIPT" --vendored "$ven" --upstream "$up" --quiet >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "a tested[]-only difference is not drift"
    command rm -rf "$up" "$ven"
}

test_drift_ignores_scanner_activity() {
    # The upstream scanner rewrites index.json `activity` (scanned_at, signals)
    # on every scan that adds a version; that is bookkeeping, not install data.
    local up="$TEST_TEMP_DIR/act-up" ven="$TEST_TEMP_DIR/act-ven"
    _mini_catalog "$up" 2026-10-01 '[]'
    _mini_catalog "$ven" 2026-10-01 '[]'
    command printf '{"id":"rust","available":[{"version":"1.0.0"}],"activity":{"scanned_at":"2026-10-12T21:41:59Z"}}\n' \
        >"$up/tools/rust/index.json"
    command printf '{"id":"rust","available":[{"version":"1.0.0"}],"activity":{"scanned_at":"2026-04-27T22:00:00Z"}}\n' \
        >"$ven/tools/rust/index.json"
    local rc=0
    command bash "$DRIFT_SCRIPT" --vendored "$ven" --upstream "$up" --quiet >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "an activity-only index difference is not drift"

    # ...but a real index field still is.
    command printf '{"id":"rust","available":[{"version":"1.0.0"}],"license":"MIT"}\n' >"$up/tools/rust/index.json"
    command printf '{"id":"rust","available":[{"version":"1.0.0"}],"license":"GPL-3.0"}\n' >"$ven/tools/rust/index.json"
    rc=0
    command bash "$DRIFT_SCRIPT" --vendored "$ven" --upstream "$up" --quiet >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "a non-activity index difference is still drift"
    command rm -rf "$up" "$ven"
}

test_drift_gates_the_support_floor() {
    # minimum_recommended is enforced by luggage (below it fails), so a vendored
    # floor that disagrees with upstream changes what installs: #1115's
    # vendored 1.82.0 vs upstream 1.93.0 refused the first evidence run.
    local up="$TEST_TEMP_DIR/floor-up" ven="$TEST_TEMP_DIR/floor-ven"
    _mini_catalog "$up" 2026-10-01 '[]'
    _mini_catalog "$ven" 2026-10-01 '[]'
    command printf '{"id":"rust","available":[{"version":"1.0.0"}],"minimum_recommended":"1.93.0"}\n' >"$up/tools/rust/index.json"
    command printf '{"id":"rust","available":[{"version":"1.0.0"}],"minimum_recommended":"1.82.0"}\n' >"$ven/tools/rust/index.json"
    local rc=0
    command bash "$DRIFT_SCRIPT" --vendored "$ven" --upstream "$up" --quiet >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "a differing minimum_recommended is drift"

    # default_version stays catalog-local (only applies to version-less installs).
    command printf '{"id":"rust","available":[{"version":"1.0.0"}],"default_version":"1.95.0"}\n' >"$up/tools/rust/index.json"
    command printf '{"id":"rust","available":[{"version":"1.0.0"}],"default_version":"1.99.0"}\n' >"$ven/tools/rust/index.json"
    rc=0
    command bash "$DRIFT_SCRIPT" --vendored "$ven" --upstream "$up" --quiet >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "a differing default_version is not drift"
    command rm -rf "$up" "$ven"
}

test_drift_still_catches_install_data() {
    # The exclusion must stay scoped to tested[]: the same pair with a real
    # field difference still fails.
    local up="$TEST_TEMP_DIR/id-up" ven="$TEST_TEMP_DIR/id-ven"
    _mini_catalog "$up" 2026-10-01 '[{"os":"debian","arch":"amd64","result":"pass"}]'
    _mini_catalog "$ven" 2026-10-12 '[]'
    local rc=0
    command bash "$DRIFT_SCRIPT" --vendored "$ven" --upstream "$up" --quiet >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "a non-evidence difference is still drift"
    command rm -rf "$up" "$ven"
}

# _vendored_only_pair <up> <ven> <pin>
# Identical mini catalogs, plus a vendored-only 1.1.0 and a Dockerfile pinning
# RUST_VERSION=<pin> at <ven>/Dockerfile.
_vendored_only_pair() {
    _mini_catalog "$1" 2026-10-01 '[]'
    _mini_catalog "$2" 2026-10-01 '[]'
    command printf '{"tool":"rust","version":"1.1.0","released":"2026-10-01","tested":[]}\n' \
        >"$2/tools/rust/versions/1.1.0.json"
    command printf 'FROM debian\nARG RUST_VERSION=%s\n' "$3" >"$2/Dockerfile"
}

test_drift_allows_live_pin_vendored_only() {
    # The live pin may run briefly ahead of the upstream scanner — visibly.
    local up="$TEST_TEMP_DIR/pin-up" ven="$TEST_TEMP_DIR/pin-ven"
    _vendored_only_pair "$up" "$ven" 1.1.0
    local output rc=0
    output="$(command bash "$DRIFT_SCRIPT" --vendored "$ven" --upstream "$up" \
        --dockerfile "$ven/Dockerfile" --quiet 2>&1)" || rc=$?
    assert_equals "0" "$rc" "a vendored-only version equal to the live pin is allowed"
    assert_contains "$output" "::warning::rust/versions/1.1.0.json is vendored-only" \
        "the allowed skip is warned about even under --quiet"
    command rm -rf "$up" "$ven"
}

test_drift_rejects_non_pin_vendored_only() {
    # #1102: 1.97.0-1.98.1 sat vendored-only for four months behind a stalled
    # scanner while this check printed "4 skipped, 0 drifted".
    local up="$TEST_TEMP_DIR/nopin-up" ven="$TEST_TEMP_DIR/nopin-ven"
    _vendored_only_pair "$up" "$ven" 9.9.9
    local output rc=0
    output="$(command bash "$DRIFT_SCRIPT" --vendored "$ven" --upstream "$up" \
        --dockerfile "$ven/Dockerfile" --quiet 2>&1)" || rc=$?
    assert_equals "1" "$rc" "a vendored-only version that is not the live pin is drift"
    assert_contains "$output" \
        "rust/versions/1.1.0.json: vendored-only and not the live pin (9.9.9); publish it upstream" \
        "the failure names the version, the pin, and the fix"
    command rm -rf "$up" "$ven"
}

test_drift_rejects_vendored_only_without_pin_source() {
    # No --dockerfile means no pin: forgetting the flag must not re-open the skip.
    local up="$TEST_TEMP_DIR/nosrc-up" ven="$TEST_TEMP_DIR/nosrc-ven"
    _vendored_only_pair "$up" "$ven" 1.1.0
    local rc=0
    command bash "$DRIFT_SCRIPT" --vendored "$ven" --upstream "$up" --quiet >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "without --dockerfile every vendored-only version is drift"

    rc=0
    command bash "$DRIFT_SCRIPT" --vendored "$ven" --upstream "$up" \
        --dockerfile "$ven/missing-Dockerfile" --quiet >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "an unreadable --dockerfile is a usage error, not a pass"
    command rm -rf "$up" "$ven"
}

test_drift_reads_quoted_live_pin() {
    # live_pin accepts a quoted default and trailing whitespace; both must still
    # resolve to the bare version, or the live pin would be reported as drift.
    local up="$TEST_TEMP_DIR/qpin-up" ven="$TEST_TEMP_DIR/qpin-ven" line output rc
    _vendored_only_pair "$up" "$ven" 1.1.0
    for line in 'ARG RUST_VERSION="1.1.0"  ' $'ARG RUST_VERSION=1.1.0\t '; do
        command printf 'FROM debian\n%s\n' "$line" >"$ven/Dockerfile"
        rc=0
        output="$(command bash "$DRIFT_SCRIPT" --vendored "$ven" --upstream "$up" \
            --dockerfile "$ven/Dockerfile" --quiet 2>&1)" || rc=$?
        assert_equals "0" "$rc" "pin read from [$line] allows its vendored-only version"
        assert_contains "$output" "::warning::rust/versions/1.1.0.json is vendored-only" \
            "pin read from [$line] is warned about"
    done
    command rm -rf "$up" "$ven"
}

test_drift_no_matching_arg_has_no_pin_suffix() {
    # A Dockerfile with only near-miss ARGs yields no pin: the version is drift
    # and the message must not carry an empty or wrong "(pin)" suffix.
    local up="$TEST_TEMP_DIR/noarg-up" ven="$TEST_TEMP_DIR/noarg-ven" output rc=0
    _vendored_only_pair "$up" "$ven" 1.1.0
    command printf 'FROM debian\nARG RUSTUP_VERSION=1.1.0\nARG GO_VERSION=1.1.0\n  ARG RUST_VERSION=1.1.0\n' \
        >"$ven/Dockerfile"
    output="$(command bash "$DRIFT_SCRIPT" --vendored "$ven" --upstream "$up" \
        --dockerfile "$ven/Dockerfile" --quiet 2>&1)" || rc=$?
    assert_equals "1" "$rc" "no matching ARG means no pin, so a vendored-only version is drift"
    assert_contains "$output" \
        "rust/versions/1.1.0.json: vendored-only and not the live pin; publish it upstream" \
        "with no pin the message has no (pin) suffix"
    assert_not_contains "$output" "live pin (" "no pin is named when none was found"
    assert_not_contains "$output" "::warning::" "nothing is skipped when there is no pin"
    command rm -rf "$up" "$ven"
}

test_drift_reads_real_dockerfile_pin() {
    # The recipe's pin source is the repo Dockerfile. Prove offline that its
    # actual ARG RUST_VERSION line is the form live_pin reads — otherwise a
    # reformatted ARG would only surface via the CI-only upstream comparison.
    local pin up="$TEST_TEMP_DIR/real-up" output rc=0
    pin="$(_dockerfile_rust_pin)"
    if [ -z "$pin" ] || [ ! -f "$VENDORED/tools/rust/versions/$pin.json" ]; then
        fail_test "Dockerfile RUST_VERSION pin [$pin] has no vendored entry"
        return 0
    fi
    command mkdir -p "$up"
    command cp -r "$VENDORED"/. "$up/"
    command rm "$up/tools/rust/versions/$pin.json"

    output="$(command bash "$DRIFT_SCRIPT" --vendored "$VENDORED" --upstream "$up" \
        --dockerfile "$PROJECT_ROOT/Dockerfile" --quiet 2>&1)" || rc=$?
    assert_equals "0" "$rc" "the real Dockerfile's pin ($pin) is read as the live pin"
    assert_contains "$output" "::warning::rust/versions/$pin.json is vendored-only" \
        "the real pin's vendored-only skip is warned about"

    rc=0
    command bash "$DRIFT_SCRIPT" --vendored "$VENDORED" --upstream "$up" --quiet >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "the same catalog pair is drift without --dockerfile"
    command rm -rf "$up"
}

# ---------------------------------------------------------------------------
# Structure — offline, catches a mis-staged catalog before the schema pass
# ---------------------------------------------------------------------------

# Every version in available[] must have a file, and every file must be listed.
# `luggage catalog add-version` keeps these together; a hand edit can desync
# them, and the resulting "no version matches spec" only surfaces mid-build.
test_index_matches_versions_on_disk() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available"
        return 0
    fi

    local mismatches="" catalog tool_dir listed on_disk default problems
    shopt -s nullglob
    for catalog in "$VENDORED" "$FIXTURES"; do
        for tool_dir in "$catalog"/tools/*/; do
            [ -f "$tool_dir/index.json" ] || continue

            listed="$(command jq -r '.available // [] | .[].version' "$tool_dir/index.json" | command sort)"
            on_disk=""
            if [ -d "$tool_dir/versions" ]; then
                on_disk="$(
                    for f in "$tool_dir"versions/*.json; do
                        [ -f "$f" ] || continue
                        command basename "$f" .json
                    done | command sort
                )"
            fi

            problems=""
            missing="$(command comm -23 <(command printf '%s\n' "$listed") <(command printf '%s\n' "$on_disk") | command tr '\n' ',' | command sed 's/,$//')"
            unlisted="$(command comm -13 <(command printf '%s\n' "$listed") <(command printf '%s\n' "$on_disk") | command tr '\n' ',' | command sed 's/,$//')"
            [ -n "$missing" ] && problems="listed but absent: $missing"
            [ -n "$unlisted" ] && problems="${problems:+$problems; }present but unlisted: $unlisted"

            default="$(command jq -r '.default_version // empty' "$tool_dir/index.json")"
            if [ -n "$default" ] && [ -n "$listed" ] &&
                ! command grep -qxF "$default" <<<"$listed"; then
                problems="${problems:+$problems; }default_version $default not in available[]"
            fi

            if [ -n "$problems" ]; then
                mismatches="$mismatches"$'\n'"  ${tool_dir}: $problems"
            fi
        done
    done
    shopt -u nullglob

    if [ -n "$mismatches" ]; then
        fail_test "index/versions desync:$mismatches"
    fi
    return 0
}

# The production catalog ships; the fixtures catalog must not leak into it.
# Guards the split introduced by #815 — the drift check would also flag a
# re-added edge case, but this names the reason directly.
test_no_fixture_leakage_into_production() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available"
        return 0
    fi

    local leaks="" version_file found
    shopt -s nullglob
    for version_file in "$VENDORED"/tools/*/versions/*.json; do
        found="$(command jq -r '
            [ (.support_matrix // [])[]
              | select((.tracking_url // "") | test("example\\.test"))
              | "placeholder tracking_url (fixture-only)" ]
            + [ (.install_methods // [])[]
              | select((.name // "") | endswith("-musl"))
              | "fixture-only method name " + .name ]
            | .[]' "$version_file")"
        if [ -n "$found" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] && leaks="$leaks"$'\n'"  ${version_file}: $line"
            done <<<"$found"
        fi
    done
    shopt -u nullglob

    if [ -n "$leaks" ]; then
        fail_test "tests-only fixtures found in the shipped catalog:$leaks"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Schema — needs `npx ajv`, so network-gated
# ---------------------------------------------------------------------------

test_catalogs_validate_against_schemas() {
    if ! ajv_available; then
        require_ajv_in_ci "ajv unavailable (SKIP_NETWORK_TESTS, missing npx, or no schemas at $UPSTREAM_DB/schema); drift check still ran"
        return 0
    fi

    local failures="" spec schema pattern catalog
    # The fixtures catalog is checked too: it is no longer production data, but
    # it is still catalog-shaped, and a malformed fixture would make the
    # crates/luggage/tests/cli.rs failures inscrutable.
    for spec in "tool:index.json" "version:versions/*.json"; do
        schema="${spec%%:*}"
        pattern="${spec#*:}"
        for catalog in "$VENDORED" "$FIXTURES"; do
            if ! run_ajv -s "$UPSTREAM_DB/schema/${schema}.schema.json" \
                -d "$catalog/tools/*/$pattern" >/dev/null 2>&1; then
                failures="$failures ${catalog##*/}/tools/*/${pattern}"
            fi
        done
    done

    if [ -n "$failures" ]; then
        fail_test "schema validation failed for:$failures (run: just db-validate-vendored)"
    fi
    return 0
}

test_schema_fixtures_are_rejected() {
    if ! ajv_available; then
        require_ajv_in_ci "ajv unavailable (SKIP_NETWORK_TESTS, missing npx, or no schemas at $UPSTREAM_DB/schema)"
        return 0
    fi

    local accepted="" checked=0 fixture
    shopt -s nullglob
    for fixture in "$NEGATIVE"/schema-*.json; do
        checked=$((checked + 1))
        if run_ajv -s "$UPSTREAM_DB/schema/version.schema.json" \
            -d "$fixture" >/dev/null 2>&1; then
            accepted="$accepted $(basename "$fixture")"
        fi
    done
    shopt -u nullglob

    if [ "$checked" -eq 0 ]; then
        fail_test "no schema-*.json fixtures in $NEGATIVE — the schema check is unproven"
    elif [ -n "$accepted" ]; then
        fail_test "ajv ACCEPTED negative fixture(s):$accepted"
    fi
    return 0
}

run_test "test_vendored_matches_upstream" "vendored catalog matches containers-db"
run_test "test_drift_fixtures_are_rejected" "drift check rejects planted drift fixtures"
run_test "test_drift_ignores_tested_evidence" "drift check ignores tested[] evidence"
run_test "test_drift_still_catches_install_data" "drift check still catches install-data differences"
run_test "test_drift_ignores_scanner_activity" "drift check ignores scanner activity, not other index fields"
run_test "test_drift_gates_the_support_floor" "drift check gates minimum_recommended, not default_version"
run_test "test_drift_allows_live_pin_vendored_only" "drift check allows the live pin ahead of upstream, with a warning"
run_test "test_drift_rejects_non_pin_vendored_only" "drift check rejects a vendored-only version that is not the live pin"
run_test "test_drift_rejects_vendored_only_without_pin_source" "drift check rejects vendored-only versions when no pin source is given"
run_test "test_drift_reads_quoted_live_pin" "drift check reads a quoted / trailing-whitespace live pin"
run_test "test_drift_no_matching_arg_has_no_pin_suffix" "drift check names no pin when the Dockerfile has no matching ARG"
run_test "test_drift_reads_real_dockerfile_pin" "drift check reads the repo Dockerfile's live pin"
run_test "test_index_matches_versions_on_disk" "index available[] agrees with versions/"
run_test "test_no_fixture_leakage_into_production" "no tests-only fixtures in shipped catalog"
run_test "test_catalogs_validate_against_schemas" "catalogs validate against JSON schemas"
run_test "test_schema_fixtures_are_rejected" "ajv rejects schema negative fixtures"

generate_report
