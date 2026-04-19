#!/usr/bin/env bash
# Unit tests for the cargo install policy in feature scripts.
#
# Policy: every `cargo install` invocation in lib/features/*.sh must be
# `--locked` and pin an explicit `@<version>` (typically via a shell var like
# `${CARGO_OUTDATED_VERSION}`). This prevents upstream crates.io drift from
# retroactively breaking a previously-working build (see the cargo-outdated
# 0.19.0 MSRV incident in commit 29e7e4d).

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Cargo install policy tests"

# Files that install cargo tools
CARGO_FILES=(
    "$PROJECT_ROOT/lib/features/rust.sh"
    "$PROJECT_ROOT/lib/features/rust-dev.sh"
)

# Every non-comment line containing `cargo install` must match:
#   cargo install --locked <crate>@${<VAR>_VERSION}
CARGO_INSTALL_REGEX='cargo install --locked [A-Za-z0-9_-]+@\$\{[A-Z_]+_VERSION\}'

test_cargo_install_uses_locked_and_pin() {
    local violations=0
    local line_no content
    for file in "${CARGO_FILES[@]}"; do
        if [ ! -f "$file" ]; then
            assert_true false "expected file missing: $file"
            continue
        fi
        # Match `cargo install` in non-comment lines, tolerating leading whitespace
        while IFS=: read -r line_no content; do
            # Skip commented lines (leading #, possibly after whitespace)
            if [[ "$content" =~ ^[[:space:]]*# ]]; then
                continue
            fi
            # Skip lines that aren't the actual invocation (e.g., log messages)
            if ! [[ "$content" =~ cargo[[:space:]]+install ]]; then
                continue
            fi
            if ! [[ "$content" =~ $CARGO_INSTALL_REGEX ]]; then
                echo "  violation: $file:$line_no: $content"
                violations=$((violations + 1))
            fi
        done < <(command grep -nE 'cargo[[:space:]]+install' "$file" || true)
    done
    if [ "$violations" -eq 0 ]; then
        assert_true true "all cargo install calls use --locked and @\${VAR_VERSION}"
    else
        assert_true false "$violations cargo install call(s) violate policy (see output above)"
    fi
}

test_no_soft_fail_on_cargo_install() {
    # `|| true` after a cargo install swallows failure and violates the
    # hard-fail policy. A regression in the pinned version should break CI,
    # not silently ship a container missing the tool.
    local violations=0
    local line_no content
    for file in "${CARGO_FILES[@]}"; do
        [ -f "$file" ] || continue
        while IFS=: read -r line_no content; do
            if [[ "$content" =~ ^[[:space:]]*# ]]; then
                continue
            fi
            if [[ "$content" =~ cargo[[:space:]]+install.*\|\|[[:space:]]+true ]]; then
                echo "  violation: $file:$line_no: $content"
                violations=$((violations + 1))
            fi
        done < <(command grep -nE 'cargo[[:space:]]+install' "$file" || true)
    done
    if [ "$violations" -eq 0 ]; then
        assert_true true "no cargo install is wrapped in || true"
    else
        assert_true false "$violations cargo install call(s) use || true (hard-fail policy)"
    fi
}

test_shared_version_vars_in_sync() {
    # cargo-watch and mdbook are pinned in both rust.sh and rust-dev.sh so
    # that each Docker RUN layer defines its own default. The two defaults
    # must agree or an override baked only into one layer will silently
    # install a different version in the other.
    local shared_vars=("CARGO_WATCH_VERSION" "MDBOOK_VERSION")
    local rust_sh="$PROJECT_ROOT/lib/features/rust.sh"
    local rust_dev_sh="$PROJECT_ROOT/lib/features/rust-dev.sh"
    local drift=0
    local v1 v2
    for var in "${shared_vars[@]}"; do
        v1=$(command grep -oE "${var}=\"\\\$\{${var}:-[^}]+\}" "$rust_sh" 2>/dev/null | command sed "s/.*:-//" | command tr -d '}' | command head -1)
        v2=$(command grep -oE "${var}=\"\\\$\{${var}:-[^}]+\}" "$rust_dev_sh" 2>/dev/null | command sed "s/.*:-//" | command tr -d '}' | command head -1)
        if [ -z "$v1" ] || [ -z "$v2" ]; then
            echo "  $var: missing in rust.sh='$v1' rust-dev.sh='$v2'"
            drift=$((drift + 1))
        elif [ "$v1" != "$v2" ]; then
            echo "  $var: rust.sh=$v1 vs rust-dev.sh=$v2"
            drift=$((drift + 1))
        fi
    done
    if [ "$drift" -eq 0 ]; then
        assert_true true "shared cargo version defaults agree between rust.sh and rust-dev.sh"
    else
        assert_true false "$drift shared cargo version default(s) disagree (see output above)"
    fi
}

run_test test_cargo_install_uses_locked_and_pin "cargo install uses --locked and @\${VAR_VERSION}"
run_test test_no_soft_fail_on_cargo_install "cargo install is not wrapped in || true"
run_test test_shared_version_vars_in_sync "shared cargo version defaults agree between rust.sh and rust-dev.sh"

generate_report
