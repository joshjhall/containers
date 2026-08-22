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
    output="$(command bash "$DRIFT_SCRIPT" \
        --vendored "$VENDORED" --upstream "$UPSTREAM_DB" 2>&1)" || rc=$?

    if [ "$rc" -ne 0 ]; then
        fail_test "drift against $UPSTREAM_DB:"$'\n'"$output"
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

    local accepted="" checked=0 index_checked=0 fixture staged target
    shopt -s nullglob
    for fixture in "$NEGATIVE"/drift-*.json; do
        checked=$((checked + 1))

        # Route each fixture to the catalog path it perturbs. The drift check
        # has two comparison paths — compare_index (field-by-field, for tool
        # indexes) and canonical_diff (whole-document, for version files) — so
        # staging every fixture at one path would leave the other unproven.
        case "$(basename "$fixture")" in
            drift-index-*)
                target="tools/rust/index.json"
                index_checked=$((index_checked + 1))
                ;;
            *) target="tools/rust/versions/1.96.0.json" ;;
        esac

        staged="$TEST_TEMP_DIR/staged-$(basename "$fixture" .json)"
        command mkdir -p "$staged"
        command cp -r "$VENDORED"/. "$staged/"
        command cp "$fixture" "$staged/$target"
        if command bash "$DRIFT_SCRIPT" --vendored "$staged" \
            --upstream "$UPSTREAM_DB" --quiet >/dev/null 2>&1; then
            accepted="$accepted $(basename "$fixture")"
        fi
        command rm -rf "$staged"
    done
    shopt -u nullglob

    if [ "$checked" -eq 0 ]; then
        fail_test "no drift-*.json fixtures in $NEGATIVE — the drift check is unproven"
    elif [ "$index_checked" -eq 0 ]; then
        fail_test "no drift-index-*.json fixture in $NEGATIVE — compare_index's branches are unproven"
    elif [ -n "$accepted" ]; then
        fail_test "drift check ACCEPTED fixture(s) it must reject:$accepted"
    fi
    return 0
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
                ! command printf '%s\n' "$listed" | command grep -qxF "$default"; then
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
run_test "test_index_matches_versions_on_disk" "index available[] agrees with versions/"
run_test "test_no_fixture_leakage_into_production" "no tests-only fixtures in shipped catalog"
run_test "test_catalogs_validate_against_schemas" "catalogs validate against JSON schemas"
run_test "test_schema_fixtures_are_rejected" "ajv rejects schema negative fixtures"

generate_report
