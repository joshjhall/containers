#!/usr/bin/env bash
# Unit tests: CI runs on pinned runner images and downloads tools robustly (#1607).
#
# The v4.22.1 auto-patch release failed three ways in one weekend, and none of
# them was the version bump:
#   - GitHub moved `ubuntu-latest` from 24.04 to 26.04, which brought bash 5.3
#     (`cd ""` became an error, #1598) and apt shellcheck 0.11.0 (new SC2232,
#     #1599). Neither change went through a PR.
#   - `releases/download` URLs returned 504 for hours, and every workflow
#     `curl` was a bare `curl -fsSL` with no retry.
#
# These rows keep it that way:
#   - no `*-latest` runner label (runs-on, matrix os, or the evidence-run
#     arch_plumbing table that feeds runs-on);
#   - both Linux release-binaries legs, and both evidence-run arch runners, on
#     the same Ubuntu release;
#   - every runner label actionlint can't vouch for is declared in
#     .github/actionlint.yaml (otherwise the lint sweep fails);
#   - every workflow `curl` retries, and every release download goes through
#     bin/fetch-release-asset.sh;
#   - CI's shellcheck is the pinned, checksum-verified release, not apt's.
#
# Run via: ./tests/run_unit_tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "CI runner pins + download robustness (#1607)"

# shellcheck source=tests/framework/helpers/required-checks.sh
source "$SCRIPT_DIR/../framework/helpers/required-checks.sh"

# Overridable so a mutation check can point the suite at a scratch copy;
# never mutate the tracked files to prove a row bites.
WORKFLOWS_DIR="${WORKFLOWS_DIR:-$PROJECT_ROOT/.github/workflows}"
ACTIONLINT_CONFIG="${ACTIONLINT_CONFIG:-$PROJECT_ROOT/.github/actionlint.yaml}"
EVIDENCE_MATRIX_LIB="${EVIDENCE_MATRIX_LIB:-$PROJECT_ROOT/bin/lib/evidence-matrix.sh}"
DEV_TOOLS="$PROJECT_ROOT/lib/features/dev-tools.sh"
CHECKSUMS="${CHECKSUMS:-$PROJECT_ROOT/lib/checksums.json}"

# GitHub-hosted labels actionlint 1.7.12 already knows. A label in use that
# is neither here nor in .github/actionlint.yaml fails actionlint's
# runner-label rule — this row reports it with a clearer message, and
# without needing actionlint installed.
ACTIONLINT_KNOWN_LABELS="macos-26 macos-26-intel macos-15 macos-14 windows-2025 windows-2022 windows-11-arm ubuntu-24.04 ubuntu-24.04-arm ubuntu-22.04 ubuntu-22.04-arm ubuntu-slim"

# _workflow_files — every workflow file, one per line.
_workflow_files() {
    command find "$WORKFLOWS_DIR" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | command sort
}

# _runner_labels <file> — "<file>: <label>" for every literal runner label:
# each job's runs-on (string or list) plus every matrix `os` value (plain
# list or include entries). A templated runs-on (`${{ matrix.os }}`) is
# skipped here — its values are the matrix entries, which are listed.
_runner_labels() {
    local f="$1"
    run_yq '
      [ (.jobs[] | .["runs-on"] | select(. != null) | (select(tag == "!!seq") | .[]) // .),
        (.jobs[] | .strategy.matrix.os // [] | .[]),
        (.jobs[] | .strategy.matrix.include // [] | .[] | .os | select(. != null)) ]
      | .[] | select(tag == "!!str") | select(test("\\$\\{\\{") | not)
    ' "$f"
}

# _arch_plumbing_runners <file> — the runner label (first word) of each
# amd64/arm64 arm of an arch_plumbing table, as "<arch> <runner>".
_arch_plumbing_runners() {
    command sed -nE 's/^[[:space:]]*(amd64|arm64)\) echo "([^ ]+) .*/\1 \2/p' "$1"
}

test_no_latest_runner_labels() {
    require_yq || return 0
    local f label violations=0 seen=0
    while IFS= read -r f; do
        while IFS= read -r label; do
            [ -n "$label" ] || continue
            seen=$((seen + 1))
            case "$label" in
                *-latest | *-latest-*)
                    /usr/bin/echo "  ${f##*/}: runs on '$label'"
                    violations=$((violations + 1))
                    ;;
            esac
        done < <(_runner_labels "$f")
    done < <(_workflow_files)

    # Guard against a parser that silently finds nothing (it would "pass").
    assert_greater_than "$seen" 20 "found the workflows' runner labels ($seen)"
    assert_equals "0" "$violations" \
        "no workflow job or matrix leg uses a *-latest runner label"
}

# A plain-text backstop for shapes the yq walk can't see (a label inside a
# string, a new matrix key name). Comments are ignored.
test_no_latest_label_anywhere_in_workflows() {
    local hits
    hits=$(command grep -nE '\b(ubuntu|macos|windows)-latest\b' "$WORKFLOWS_DIR"/*.yml |
        command grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
    if [ -n "$hits" ]; then
        /usr/bin/echo "$hits" | command sed 's/^/  /'
    fi
    assert_empty "$hits" "no non-comment workflow line names a *-latest runner"
}

test_evidence_arch_plumbing_pinned_and_matched() {
    local src rows amd arm
    for src in "$WORKFLOWS_DIR/evidence-run.yml" "$EVIDENCE_MATRIX_LIB"; do
        rows=$(_arch_plumbing_runners "$src")
        amd=$(/usr/bin/awk '$1 == "amd64" { print $2 }' <<<"$rows")
        arm=$(/usr/bin/awk '$1 == "arm64" { print $2 }' <<<"$rows")
        assert_matches "$amd" '^ubuntu-[0-9]+\.[0-9]+$' \
            "${src##*/}: amd64 evidence runner is a pinned Ubuntu label (got '$amd')"
        assert_equals "${amd}-arm" "$arm" \
            "${src##*/}: arm64 evidence runner is the same Ubuntu release as amd64"
    done
}

test_release_binaries_linux_legs_match() {
    require_yq || return 0
    local f="$WORKFLOWS_DIR/release-binaries.yml" amd arm
    amd=$(run_yq '.jobs.build.strategy.matrix.include[] | select(.target == "x86_64-unknown-linux-musl") | .os' "$f") || amd=""
    arm=$(run_yq '.jobs.build.strategy.matrix.include[] | select(.target == "aarch64-unknown-linux-musl") | .os' "$f") || arm=""
    assert_matches "$amd" '^ubuntu-[0-9]+\.[0-9]+$' \
        "release-binaries amd64 builds on a pinned Ubuntu label (got '$amd')"
    assert_equals "${amd}-arm" "$arm" \
        "release-binaries arm64 builds on the same Ubuntu release as amd64"
}

test_runner_labels_known_to_actionlint() {
    require_yq || return 0
    local f label declared violations=0
    declared=$(run_yq '.["self-hosted-runner"].labels // [] | .[]' "$ACTIONLINT_CONFIG") || declared=""
    while IFS= read -r f; do
        while IFS= read -r label; do
            [ -n "$label" ] || continue
            case $'\n'"$declared"$'\n' in
                *$'\n'"$label"$'\n'*) continue ;;
            esac
            case " $ACTIONLINT_KNOWN_LABELS " in
                *" $label "*) continue ;;
            esac
            /usr/bin/echo "  ${f##*/}: '$label' is unknown to actionlint and not in ${ACTIONLINT_CONFIG##*/}"
            violations=$((violations + 1))
        done < <(_runner_labels "$f")
    done < <(_workflow_files)
    assert_equals "0" "$violations" \
        "every runner label is known to actionlint or declared in .github/actionlint.yaml"
}

# _curl_lines — "<file>:<line>:<command>" for every non-comment `curl` call,
# with backslash-continued lines joined: the flags and the URL usually sit on
# continuation lines, so a per-line grep would miss both.
_curl_lines() {
    local f
    while IFS= read -r f; do
        command awk -v file="$f" '
            /^[[:space:]]*#/ && cmd == "" { next }
            {
                if (cmd == "") { start = FNR; cmd = $0 } else { cmd = cmd " " $0 }
                if (cmd ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", cmd); next }
                if (cmd ~ /(^|[[:space:];|&(])curl[[:space:]]/) { print file ":" start ":" cmd }
                cmd = ""
            }
        ' "$f"
    done < <(_workflow_files)
}

test_every_curl_retries() {
    local line violations=0 seen=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        seen=$((seen + 1))
        case "$line" in
            *--retry*) ;;
            *)
                /usr/bin/echo "  ${line#"$WORKFLOWS_DIR"/} — no --retry"
                violations=$((violations + 1))
                ;;
        esac
    done < <(_curl_lines)
    assert_equals "0" "$violations" "every workflow curl call passes --retry ($seen calls)"
}

# wget's defaults retry nothing useful for an HTTP 5xx, and the curl row above
# cannot see it — so workflow downloads use curl (whose retries this suite
# checks) and wget is not used at all.
# _wget_lines — "<file>:<line>:<text>" for every non-comment wget call in the
# workflow files (both extensions). Reads WGET_SCAN_FILES when set, so the
# positive control below can aim the same matcher at a fixture.
_wget_lines() {
    local -a files
    if [ -n "${WGET_SCAN_FILES:-}" ]; then
        files=("$WGET_SCAN_FILES")
    else
        mapfile -t files < <(_workflow_files)
    fi
    [ "${#files[@]}" -gt 0 ] || return 0
    command grep -nHE '(^|[[:space:];|&(])wget([[:space:]]|$)' "${files[@]}" |
        command grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true
}

test_no_wget_downloads() {
    # Positive control: the matcher must flag a real wget line and a bare
    # `wget` at end of line, and ignore a commented one — otherwise a regex
    # typo would make the row below pass vacuously.
    local fixture="$TEST_TEMP_DIR/wget-fixture.yml" found
    printf '%s\n' '          wget -qO- https://example.invalid/key' \
        '          sudo wget' \
        '          # wget https://example.invalid/commented' >"$fixture"
    found=$(WGET_SCAN_FILES="$fixture" _wget_lines | command wc -l)
    assert_equals "2" "${found//[[:space:]]/}" "the wget matcher flags real calls and skips comments"

    local hits
    hits=$(_wget_lines)
    if [ -n "$hits" ]; then
        /usr/bin/echo "$hits" | command sed "s|^$WORKFLOWS_DIR/|  |"
    fi
    assert_empty "$hits" "no workflow downloads with wget"
}

# Release assets must go through the helper (retries + gh API fallback +
# cache), not curl — even a retrying curl has no fallback for an hours-long
# releases/download outage.
test_release_downloads_use_helper() {
    local hits
    # evidence-run's ccache fetch is deliberately best-effort (it falls back
    # to an uncached build), so a retrying curl is enough there.
    hits=$(_curl_lines | command grep -F '/releases/download/' |
        command grep -v 'ccache/ccache/releases/download' || true)
    if [ -n "$hits" ]; then
        /usr/bin/echo "$hits" | command sed "s|^$WORKFLOWS_DIR/|  |"
    fi
    assert_empty "$hits" \
        "release assets are fetched via bin/fetch-release-asset.sh, not curl"
}

# The toolchain cache persists across runs (and PR runs can write it), so an
# unverified asset in it would be reused until a pin changed. Every helper call
# must pass --sha256 so the helper verifies cache hits and downloads alike.
test_every_helper_fetch_is_verified() {
    local hits seen
    seen=$(command grep -c 'fetch-release-asset.sh --sha256' "$WORKFLOWS_DIR"/*.yml |
        /usr/bin/awk -F: '{ n += $2 } END { print n + 0 }')
    hits=$(command grep -nE '(^|[[:space:]])bin/fetch-release-asset\.sh([[:space:]]|$)' "$WORKFLOWS_DIR"/*.yml |
        command grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' |
        command grep -v -- '--sha256' || true)
    if [ -n "$hits" ]; then
        /usr/bin/echo "$hits" | command sed "s|^$WORKFLOWS_DIR/|  |"
    fi
    assert_greater_than "$seen" 2 "found the verified helper calls ($seen)"
    assert_empty "$hits" "every bin/fetch-release-asset.sh call passes --sha256"
}

# Every lint-toolchain asset ci.yml installs must have its pinned amd64
# checksum recorded, or the install step hard-fails at run time.
test_lint_toolchain_checksums_recorded() {
    local tool var version sha missing=0
    for tool in lefthook:LEFTHOOK_VERSION shellcheck:SHELLCHECK_VERSION rumdl:RUMDL_VERSION \
        dprint:DPRINT_VERSION shfmt:SHFMT_VERSION conform:CONFORM_VERSION taplo:TAPLO_VERSION \
        just:JUST_VERSION actionlint:ACTIONLINT_VERSION; do
        var="${tool#*:}"
        tool="${tool%%:*}"
        version=$(command sed -nE "s/^${var}=\"\\\$\{${var}:-([^}]*)\}\"$/\1/p" "$DEV_TOOLS")
        sha=$(command jq -r --arg t "$tool" --arg v "$version" \
            '.tools[$t].versions[$v].checksums.amd64.sha256 // empty' "$CHECKSUMS")
        if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
            /usr/bin/echo "  $tool ${version:-<unparsed>}: no amd64 sha256 in lib/checksums.json"
            missing=$((missing + 1))
        fi
        if ! command grep -qE "^[[:space:]]*fetch_tool ${tool} " "$WORKFLOWS_DIR/ci.yml"; then
            /usr/bin/echo "  $tool: ci.yml does not install it through fetch_tool"
            missing=$((missing + 1))
        fi
    done
    assert_equals "0" "$missing" "every lint-toolchain asset is checksum-pinned and fetched verified"
}

test_ci_toolchain_cache_wired() {
    require_yq || return 0
    local f="$WORKFLOWS_DIR/ci.yml" restore save restore_idx save_idx last_fetch_idx
    restore=$(run_yq '[.jobs.test.steps[] | .uses // ""] | to_entries | .[] | select(.value | test("^actions/cache/restore@")) | .key' "$f") || restore=""
    save=$(run_yq '[.jobs.test.steps[] | .uses // ""] | to_entries | .[] | select(.value | test("^actions/cache/save@")) | .key' "$f") || save=""
    last_fetch_idx=$(run_yq '[.jobs.test.steps[] | .run // ""] | to_entries | map(select(.value | test("fetch-release-asset"))) | .[-1].key' "$f") || last_fetch_idx=""
    restore_idx="${restore:-}"
    save_idx="${save:-}"
    assert_not_empty "$restore_idx" "ci.yml test job restores the toolchain cache"
    assert_not_empty "$save_idx" "ci.yml test job saves the toolchain cache"
    assert_not_empty "$last_fetch_idx" "ci.yml test job fetches via bin/fetch-release-asset.sh"
    [ -n "$restore_idx" ] && [ -n "$save_idx" ] && [ -n "$last_fetch_idx" ] || return 0
    assert_true "[ $restore_idx -lt $last_fetch_idx ]" \
        "the cache is restored before the downloads"
    assert_true "[ $save_idx -gt $last_fetch_idx ]" \
        "the cache is saved after the last download"
    # The save must not sit behind a lint/test step that can fail, or a red
    # run never warms the cache.
    local between
    between=$(run_yq "[.jobs.test.steps[$((last_fetch_idx + 1)):$save_idx][] | .name] | .[]" "$f") || between="?"
    assert_empty "$between" "nothing runs between the last download and the cache save"
}

# The ShellCheck version used to follow the runner image (apt). It must be the
# dev-tools.sh pin, verified against lib/checksums.json.
test_ci_shellcheck_is_pinned_and_verified() {
    local f="$WORKFLOWS_DIR/ci.yml" step version sha
    if command grep -qE 'apt-get install[^#]*\bshellcheck\b' "$f"; then
        assert_true false "ci.yml must not apt-install shellcheck (version follows the runner image)"
    else
        assert_true true "ci.yml does not apt-install shellcheck"
    fi
    step=$(command awk '
        /- name: Install lint toolchain/ { inside = 1; next }
        inside && /^[[:space:]]*- name:/ { exit }
        inside { print }
    ' "$f")
    assert_contains "$step" "SHELLCHECK_VERSION" "the lint install reads SHELLCHECK_VERSION"
    assert_contains "$step" "fetch_tool shellcheck" \
        "shellcheck is installed through the checksum-verifying fetch_tool"
    assert_contains "$step" '.tools[$t].versions[$v].checksums.amd64.sha256' \
        "fetch_tool looks each checksum up in lib/checksums.json"
    assert_contains "$step" 'fetch-release-asset.sh --sha256' \
        "fetch_tool hands the checksum to the helper to verify"

    version=$(command sed -nE 's/^SHELLCHECK_VERSION="\$\{SHELLCHECK_VERSION:-([^}]*)\}"$/\1/p' "$DEV_TOOLS")
    assert_matches "$version" '^[0-9]+\.[0-9]+\.[0-9]+$' \
        "dev-tools.sh pins SHELLCHECK_VERSION as X.Y.Z (got '$version')"
    sha=$(command jq -r --arg v "$version" \
        '.tools.shellcheck.versions[$v].checksums.amd64.sha256 // empty' "$CHECKSUMS")
    assert_matches "$sha" '^[0-9a-f]{64}$' \
        "lib/checksums.json records an amd64 sha256 for shellcheck $version"
}

test_shellcheck_registered_for_auto_patch() {
    assert_file_contains "$PROJECT_ROOT/bin/check-versions.sh" \
        '_add_feature_version SHELLCHECK_VERSION "shellcheck" "dev-tools.sh"' \
        "bin/check-versions.sh tracks SHELLCHECK_VERSION"
    assert_file_contains "$PROJECT_ROOT/bin/update-checksums.sh" \
        '"shellcheck|SHELLCHECK_VERSION|lib/features/dev-tools.sh|' \
        "bin/update-checksums.sh records checksums for a shellcheck bump"
}

run_test test_no_latest_runner_labels "no runs-on / matrix os uses a *-latest label"
run_test test_no_latest_label_anywhere_in_workflows "no non-comment workflow line names a *-latest runner"
run_test test_evidence_arch_plumbing_pinned_and_matched "evidence runners pinned, arm64 matches amd64's Ubuntu release"
run_test test_release_binaries_linux_legs_match "release-binaries Linux legs share one Ubuntu release"
run_test test_runner_labels_known_to_actionlint "runner labels are known to actionlint or declared"
run_test test_every_curl_retries "every workflow curl retries"
run_test test_no_wget_downloads "workflows download with retrying curl, not wget"
run_test test_release_downloads_use_helper "release assets download via bin/fetch-release-asset.sh"
run_test test_every_helper_fetch_is_verified "every helper fetch passes --sha256"
run_test test_lint_toolchain_checksums_recorded "every lint-toolchain asset is checksum-pinned"
run_test test_ci_toolchain_cache_wired "ci.yml restores, then saves, the toolchain cache around the downloads"
run_test test_ci_shellcheck_is_pinned_and_verified "CI shellcheck is the pinned, checksum-verified release"
run_test test_shellcheck_registered_for_auto_patch "shellcheck pin is visible to auto-patch"

generate_report
