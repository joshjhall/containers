#!/usr/bin/env bash
# Unit tests for the cargo install policy in feature scripts.
#
# Policy: every cargo tool install in lib/features/*.sh must be `--locked` and
# pin an explicit `@<version>` (typically via a shell var like
# `${CARGO_OUTDATED_VERSION}`). This prevents upstream crates.io drift from
# retroactively breaking a previously-working build (see the cargo-outdated
# 0.19.0 MSRV incident in commit 29e7e4d).
#
# Tools are installed with `cargo binstall` (prebuilt, checksum-verified
# binaries) rather than `cargo install` (compile from source) to keep cold CI
# builds under the timeout (#517). The policy applies to BOTH verbs. Because the
# `--locked --no-confirm` flags are centralised in a wrapper (cargo_binstall_tool
# in rust-dev.sh, the `binstall()` shell function in rust.sh), the checks below
# are split: literal `cargo (install|binstall)` invocations must carry
# `--locked`, and every pinned-crate call site (`<crate>@${VAR}`) must use a
# `_VERSION` variable.

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

# A literal `cargo install`/`cargo binstall` invocation must carry `--locked`.
CARGO_LOCKED_REGEX='cargo (install|binstall)( .*)? --locked'
# A pinned-crate call site (`<crate>@<pin>`) must pin via a `_VERSION` variable.
# Matches both direct invocations and wrapper-function call sites, e.g.
#   cargo binstall --locked cargo-watch@${CARGO_WATCH_VERSION}
#   cargo_binstall_tool "cargo-watch@${CARGO_WATCH_VERSION}"
#   binstall mdbook@${MDBOOK_VERSION}
CARGO_PIN_REGEX='[A-Za-z0-9_-]+@\$\{[A-Z_]+_VERSION\}'
# Candidate install lines: the literal cargo (b)install verb, or a project
# wrapper (cargo_binstall_tool / the rust.sh `binstall` shell function).
CARGO_INSTALL_CANDIDATE='cargo[[:space:]]+(install|binstall)([[:space:]]|$)|cargo_binstall_tool[[:space:]]|(^|[[:space:]])binstall[[:space:]]'

# _is_prose_or_def — true for lines that mention the verb but don't invoke it:
# comments, log/echo/printf prose, or the wrapper-function *definitions*
# (which legitimately contain `cargo binstall ... "$@"` with no crate pin).
_is_prose_or_def() {
    local content="$1"
    [[ "$content" =~ ^[[:space:]]*# ]] && return 0
    [[ "$content" =~ (log_[a-z_]+|echo|printf)[[:space:]]+[\"\'] ]] && return 0
    [[ "$content" =~ (binstall|cargo_binstall_tool)\(\)[[:space:]]*\{ ]] && return 0
    return 1
}

test_cargo_install_uses_locked_and_pin() {
    local violations=0
    local line_no content
    for file in "${CARGO_FILES[@]}"; do
        if [ ! -f "$file" ]; then
            assert_true false "expected file missing: $file"
            continue
        fi
        while IFS=: read -r line_no content; do
            _is_prose_or_def "$content" && continue
            # Skip lines that aren't a real install invocation/call site.
            if ! [[ "$content" =~ cargo[[:space:]]+(install|binstall)([[:space:]]|$) ]] &&
                ! [[ "$content" =~ cargo_binstall_tool[[:space:]] ]] &&
                ! [[ "$content" =~ (^|[[:space:]])binstall[[:space:]] ]]; then
                continue
            fi
            # A literal `cargo (install|binstall)` invocation must carry --locked.
            # (Wrapper call sites centralise --locked, so only check the literal verb.)
            if [[ "$content" =~ cargo[[:space:]]+(install|binstall)([[:space:]]|$) ]]; then
                if ! [[ "$content" =~ $CARGO_LOCKED_REGEX ]]; then
                    echo "  violation (missing --locked): $file:$line_no: $content"
                    violations=$((violations + 1))
                    continue
                fi
            fi
            # If the line names a specific crate (`name@...`), the pin must be a
            # `_VERSION` variable. Wrapper definitions forwarding `"$@"` have no
            # literal crate@ and were already filtered out above.
            if [[ "$content" =~ [A-Za-z0-9_-]+@ ]]; then
                if ! [[ "$content" =~ $CARGO_PIN_REGEX ]]; then
                    echo "  violation (unpinned crate): $file:$line_no: $content"
                    violations=$((violations + 1))
                fi
            fi
        done < <(command grep -nE "$CARGO_INSTALL_CANDIDATE" "$file" || true)
    done
    if [ "$violations" -eq 0 ]; then
        assert_true true "all cargo (b)install calls use --locked and @\${VAR_VERSION}"
    else
        assert_true false "$violations cargo (b)install call(s) violate policy (see output above)"
    fi
}

test_no_soft_fail_on_cargo_install() {
    # `|| true` after a cargo (b)install swallows failure and violates the
    # hard-fail policy. A regression in the pinned version should break CI,
    # not silently ship a container missing the tool.
    local violations=0
    local line_no content
    for file in "${CARGO_FILES[@]}"; do
        [ -f "$file" ] || continue
        while IFS=: read -r line_no content; do
            _is_prose_or_def "$content" && continue
            if [[ "$content" =~ cargo[[:space:]]+(install|binstall)[[:space:]].*\|\|[[:space:]]+true ]] ||
                [[ "$content" =~ (cargo_binstall_tool|[[:space:]]binstall)[[:space:]].*\|\|[[:space:]]+true ]]; then
                echo "  violation: $file:$line_no: $content"
                violations=$((violations + 1))
            fi
        done < <(command grep -nE "$CARGO_INSTALL_CANDIDATE" "$file" || true)
    done
    if [ "$violations" -eq 0 ]; then
        assert_true true "no cargo (b)install is wrapped in || true"
    else
        assert_true false "$violations cargo (b)install call(s) use || true (hard-fail policy)"
    fi
}

test_shared_version_vars_in_sync() {
    # cargo-watch, mdbook, and cargo-binstall are pinned in both rust.sh and
    # rust-dev.sh so that each Docker RUN layer defines its own default. The two
    # defaults must agree or an override baked only into one layer will silently
    # install a different version in the other.
    local shared_vars=("CARGO_WATCH_VERSION" "MDBOOK_VERSION" "CARGO_BINSTALL_VERSION")
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

test_filters_reject_prose_and_plurals() {
    # Regression (issue #385): log/echo/printf prose containing "cargo install"
    # text, and plural/gerund forms like "cargo installs", must not be treated
    # as policy candidates. This tests the two filter primitives used in the
    # scan loops above: the tightened grep (word-boundary after `install`) and
    # the prose-skip for log_*/echo/printf calls.
    local line

    # Plural/gerund forms — tightened grep must reject at the candidate stage.
    local prose_plurals=(
        'log_message "Installing deps for cargo installs"'
        'echo "cargo installing foo"'
    )
    for line in "${prose_plurals[@]}"; do
        if [[ "$line" =~ cargo[[:space:]]+install([[:space:]]|$) ]]; then
            assert_true false "tightened grep must reject plural/gerund: $line"
            return
        fi
    done

    # Real "cargo install" text inside a log/echo/printf string — prose-skip
    # must fire. (These also pre-match the tightened grep.)
    local prose_real=(
        'log_message "Run cargo install foo to add tools"'
        'echo "cargo install bar was run"'
        'printf "run cargo install baz\n"'
    )
    for line in "${prose_real[@]}"; do
        if ! [[ "$line" =~ cargo[[:space:]]+install([[:space:]]|$) ]]; then
            assert_true false "prose-real fixture should pre-match grep: $line"
            return
        fi
        if ! [[ "$line" =~ (log_[a-z_]+|echo|printf)[[:space:]]+[\"\'] ]]; then
            assert_true false "prose-skip must match log/echo/printf: $line"
            return
        fi
    done

    # Real invocations — grep must still match, prose-skip must NOT fire.
    local real=(
        'cargo install --locked foo@${FOO_VERSION}'
        'cargo install foo'
        '    cargo install bar --locked'
        'su - user -c "cargo install --locked baz@${BAZ_VERSION}"'
    )
    for line in "${real[@]}"; do
        if ! [[ "$line" =~ cargo[[:space:]]+install([[:space:]]|$) ]]; then
            assert_true false "tightened grep must still match real: $line"
            return
        fi
        if [[ "$line" =~ (log_[a-z_]+|echo|printf)[[:space:]]+[\"\'] ]]; then
            assert_true false "prose-skip must not match real: $line"
            return
        fi
    done

    assert_true true "filters correctly distinguish real cargo install invocations from prose"
}

test_binstall_candidate_matching() {
    # The policy now covers `cargo binstall` and the project wrappers
    # (cargo_binstall_tool, the rust.sh `binstall` shell function). Verify the
    # candidate matcher, the --locked check, the pin check, and the def-skip all
    # behave on representative lines — without depending on the live scripts.
    local line

    # Wrapper *definitions* must be skipped (they forward "$@", no crate pin).
    local defs=(
        'cargo_binstall_tool() {'
        '    binstall() { cargo binstall --locked --no-confirm "$@"; }'
    )
    for line in "${defs[@]}"; do
        if ! _is_prose_or_def "$line"; then
            assert_true false "wrapper definition must be skipped: $line"
            return
        fi
    done

    # Wrapper *call sites* with a proper pin must pass both checks.
    local good=(
        'cargo_binstall_tool "cargo-watch@${CARGO_WATCH_VERSION}"'
        '    binstall mdbook@${MDBOOK_VERSION}'
        'cargo binstall --locked --no-confirm sccache@${SCCACHE_VERSION}'
    )
    for line in "${good[@]}"; do
        if _is_prose_or_def "$line"; then
            assert_true false "real call site must not be skipped: $line"
            return
        fi
        if [[ "$line" =~ cargo[[:space:]]+(install|binstall)([[:space:]]|$) ]] &&
            ! [[ "$line" =~ $CARGO_LOCKED_REGEX ]]; then
            assert_true false "literal binstall must satisfy --locked check: $line"
            return
        fi
        if [[ "$line" =~ [A-Za-z0-9_-]+@ ]] && ! [[ "$line" =~ $CARGO_PIN_REGEX ]]; then
            assert_true false "pinned call site must satisfy pin check: $line"
            return
        fi
    done

    # An unpinned crate must FAIL the pin check.
    line='cargo_binstall_tool "cargo-watch@8.5.3"'
    if [[ "$line" =~ $CARGO_PIN_REGEX ]]; then
        assert_true false "literal-version pin must be rejected: $line"
        return
    fi

    # A literal binstall missing --locked must FAIL the locked check.
    line='cargo binstall --no-confirm sccache@${SCCACHE_VERSION}'
    if [[ "$line" =~ $CARGO_LOCKED_REGEX ]]; then
        assert_true false "binstall without --locked must be rejected: $line"
        return
    fi

    assert_true true "binstall verb and wrappers are correctly classified"
}

run_test test_cargo_install_uses_locked_and_pin "cargo (b)install uses --locked and @\${VAR_VERSION}"
run_test test_no_soft_fail_on_cargo_install "cargo (b)install is not wrapped in || true"
run_test test_shared_version_vars_in_sync "shared cargo version defaults agree between rust.sh and rust-dev.sh"
run_test test_filters_reject_prose_and_plurals "filters reject log/echo/printf prose and plural forms"
run_test test_binstall_candidate_matching "binstall verb and project wrappers are correctly classified"

generate_report
