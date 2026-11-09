#!/usr/bin/env bash
# Unit tests: every dependency a VENDORED version file declares must map to a
# system_package for each distro it applies to.
#
# Split out of vendored-catalog.sh (#1556); the guard itself came from #1526,
# where alpine node-source dependencies shipped with no system_package entries
# and every alpine node evidence cell failed. It shares only $VENDORED and the
# test framework with the drift, index and schema tests there.
#
# Needs only jq, so it runs UNCONDITIONALLY — offline and under the pre-push
# runner's SKIP_NETWORK_TESTS=1 alike.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Vendored catalog dependency guard tests"

VENDORED="$PROJECT_ROOT/crates/luggage/testdata/catalog"

# dependency_gaps <catalog-dir> — print one `<dep>/<os>` line per distinct
# dependency a version file declares for a distro that <catalog-dir> cannot
# map to a package.
#
# luggage resolves install_methods[].dependencies[] to host packages via the
# catalog's `system_package` blocks (crates/luggage/src/sysdeps.rs) and,
# in strict mode, refuses the install when any id is unmapped. That is how
# #1526 shipped: every vendored node version's alpine `node-source` method
# named gxx/make/linux_headers/python3/libstdcxx/libgcc, none were mirrored,
# and every alpine node evidence cell failed. The drift check could not see it
# because it does not walk upstream-only tools.
#
# A dependency applies to each distro in its method's platform.os (string or
# array), narrowed by its own `platforms` selectors — `distro` or
# `distro:release`, the same rule as sysdeps::selector_matches. Only the distro
# half matters here: package names are keyed by distro, not release.
#
# Fails (non-zero, message on stderr) rather than printing nothing when jq
# cannot evaluate the catalog: `install_methods` or a method's `dependencies`
# present but not an array, a dependency that is not an object with a
# string `tool`, `platforms` that is not an array of strings, or a method declaring
# dependencies with no platform.os (its distros, and so its gaps, would be
# unknowable), or a catalog with no version files at all. An empty result
# must only ever mean "no gaps".
dependency_gaps() {
    local catalog="$1" map raw
    shopt -s nullglob
    local indexes=("$catalog"/tools/*/index.json)
    local versions=("$catalog"/tools/*/versions/*.json)
    shopt -u nullglob
    # No version files means nothing was checked, not that nothing is missing
    # (a wrong catalog path would otherwise read as a clean catalog).
    if [ "${#versions[@]}" -eq 0 ]; then
        command echo "dependency_gaps: no tools/*/versions/*.json under $catalog" >&2
        return 1
    fi

    map='{}'
    if [ "${#indexes[@]}" -gt 0 ]; then
        # Keyed on the system_package block, not on `kind`: sysdeps resolves
        # any catalog tool that carries one, so the guard must agree.
        map="$(command jq -cs '
            map(select(.system_package != null)
                | {key: .id, value: ((.system_package.platforms // {}) | keys)})
            | from_entries' "${indexes[@]}")" || {
            command echo "dependency_gaps: cannot read system_package entries under $catalog" >&2
            return 1
        }
    fi

    raw="$(command jq -r --argjson m "$map" '
        input_filename as $f
        # Absent/null containers mean "none"; any other non-array must error.
        # `[]` on an object iterates its values, so without these checks
        # `"dependencies":{"x":{...}}` would be checked as a valid list.
        # Test with == null, not `//`, so `false` is rejected, not swallowed.
        | (if .install_methods == null then [] else .install_methods end) as $ims
        | if ($ims | type) != "array"
          then error("\($f): install_methods is not an array")
          else . end
        | $ims[]
        | (if .dependencies == null then [] else .dependencies end) as $deps
        | if ($deps | type) != "array"
          then error("\($f): method \(.name // "?") dependencies is not an array")
          else . end
        | ((.platform.os // []) | if type == "string" then [.] else . end) as $oses
        # Empty, non-array, or non-string-element os all leave the distros of
        # the method unknowable: an empty $oses would silently check nothing.
        | if ($deps | length) > 0
             and (($oses | type) != "array" or ($oses | length) == 0
                  or any($oses[]; type != "string"))
          then error("\($f): method \(.name // "?") declares dependencies but no platform.os")
          else . end
        | $deps[] as $d
        # Absent/null `platforms` means "no selectors"; anything else must be
        # an array of strings. Test with == null, never `//`: `//` also
        # swallows `false`, which would read as "applies everywhere".
        | if ($d | type) != "object" or ($d.tool | type) != "string"
             or ($d.platforms != null
                 and (($d.platforms | type) != "array"
                      or any($d.platforms[]; type != "string")))
          then error("\($f): malformed dependency \($d | tojson)")
          else . end
        | $oses[] as $os
        | select($d.platforms == null
                 or any($d.platforms[]; split(":")[0] == $os))
        | select((($m[$d.tool] // []) | index($os)) == null)
        | "\($d.tool)/\($os)"' "${versions[@]}")" || {
        command echo "dependency_gaps: jq failed evaluating version files under $catalog" >&2
        return 1
    }
    [ -n "$raw" ] || return 0
    command sort -u <<<"$raw"
}

test_vendored_dependencies_resolve() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available"
        return 0
    fi

    local gaps
    if ! gaps="$(dependency_gaps "$VENDORED")"; then
        fail_test "dependency_gaps could not evaluate the vendored catalog (see stderr) — refusing to read that as no gaps"
        return 0
    fi
    if [ -n "$gaps" ]; then
        fail_test "vendored dependencies with no system_package mapping (dep/os) — mirror them from containers-db:"$'\n'"$(command sed 's/^/  /' <<<"$gaps")"
    fi
    return 0
}

# The guard must discriminate: drop one mirrored entry from a scratch copy and
# it has to name exactly that gap, so a jq slip that prints nothing cannot pass.
test_dependency_guard_catches_missing_entry() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available"
        return 0
    fi

    # Fixture preconditions on the LIVE catalog. The mutations below assume
    # gxx maps only alpine (so dropping it is exactly one gap) and libatomic
    # maps rhel (so dropping that distro is exactly one gap). If the catalog
    # changes, say so — do not let it read as a guard regression.
    if ! command jq -e '.system_package.platforms | keys == ["alpine"]' \
        "$VENDORED/tools/gxx/index.json" >/dev/null 2>&1; then
        fail_test "fixture changed: vendored tools/gxx is missing or no longer maps only alpine — update this test's fixture, not the guard"
        return 0
    fi
    if ! command jq -e '.system_package.platforms | has("rhel")' \
        "$VENDORED/tools/libatomic/index.json" >/dev/null 2>&1; then
        fail_test "fixture changed: vendored tools/libatomic is missing or no longer maps rhel — update this test's fixture, not the guard"
        return 0
    fi

    # run_test calls this in an `||` context, so set -e is off in here: every
    # setup step must check itself or a failure would surface as a guard bug.
    local scratch gaps rc problems=""
    scratch="$(command mktemp -d)" || {
        fail_test "setup: mktemp -d failed"
        return 0
    }
    # Self-clearing: a RETURN trap is global and would otherwise re-fire on
    # every later function return in this shell.
    # shellcheck disable=SC2064  # expand $scratch now, not at return time
    trap "command rm -rf '$scratch'; trap - RETURN" RETURN
    command cp -R "$VENDORED/tools" "$scratch/tools" ||
        {
            fail_test "setup: copying the vendored catalog to $scratch failed"
            return 0
        }

    # Whole entry missing (gxx is alpine-only, checked above).
    command rm -rf "$scratch/tools/gxx" ||
        {
            fail_test "setup: removing tools/gxx from the scratch catalog failed"
            return 0
        }
    rc=0
    gaps="$(dependency_gaps "$scratch")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        problems="$problems"$'\n'"  whole-entry removal: exit $rc on a well-formed scratch catalog"
    elif [ "$gaps" != "gxx/alpine" ]; then
        problems="$problems"$'\n'"  whole-entry removal: want exactly gxx/alpine, got: ${gaps:-<nothing>}"
    fi
    command cp -R "$VENDORED/tools/gxx" "$scratch/tools/gxx" ||
        {
            fail_test "setup: restoring tools/gxx in the scratch catalog failed"
            return 0
        }

    # Partially mirrored entry: one distro dropped from a multi-distro
    # mapping. libatomic's consumers target debian/ubuntu/rhel (rhel mapping
    # checked above).
    local lib="$scratch/tools/libatomic/index.json"
    command jq 'del(.system_package.platforms.rhel)' "$VENDORED/tools/libatomic/index.json" >"$lib" ||
        {
            fail_test "setup: dropping libatomic's rhel mapping in the scratch catalog failed"
            return 0
        }
    rc=0
    gaps="$(dependency_gaps "$scratch")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        problems="$problems"$'\n'"  partial-entry removal: exit $rc on a well-formed scratch catalog"
    elif [ "$gaps" != "libatomic/rhel" ]; then
        problems="$problems"$'\n'"  partial-entry removal: want exactly libatomic/rhel, got: ${gaps:-<nothing>}"
    fi

    # Exact match: the gap must be reported, and nothing else may be.
    if [ -n "$problems" ]; then
        fail_test "dependency guard did not name the removed mapping:$problems"
    fi
    return 0
}

# _write_sys <catalog> <id> <json platforms object> — a minimal system_package.
_write_sys() {
    command mkdir -p "$1/tools/$2"
    command printf '{"id":"%s","kind":"system_package","system_package":{"platforms":%s}}\n' \
        "$2" "$3" >"$1/tools/$2/index.json"
}

# Selector narrowing and the fail-loud path, on a synthetic catalog the real
# one cannot exercise: array platform.os, a `distro:release` selector, a
# selector excluding a distro, and malformed inputs that must error, not pass.
test_dependency_guard_selectors_and_errors() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available"
        return 0
    fi

    local cat gaps rc problems=""
    cat="$(command mktemp -d)" || {
        fail_test "setup: mktemp -d failed"
        return 0
    }
    # Self-clearing RETURN trap, as in test_dependency_guard_catches_missing_entry.
    # shellcheck disable=SC2064  # expand $cat now, not at return time
    trap "command rm -rf '$cat'; trap - RETURN" RETURN
    _write_sys "$cat" debonly '{"debian":{"name":"d"}}'
    _write_sys "$cat" alponly '{"alpine":{"name":"a"}}'
    # Not kind=system_package but carries a block: sysdeps resolves it, so
    # the guard must too (no gap reported for it below).
    command mkdir -p "$cat/tools/other"
    command printf '%s\n' '{"id":"other","kind":"runtime","system_package":{"platforms":{"debian":{"name":"o"}}}}' \
        >"$cat/tools/other/index.json"
    # system_package with no `platforms` maps no distro: every use is a gap.
    command mkdir -p "$cat/tools/bare"
    command printf '%s\n' '{"id":"bare","system_package":{}}' >"$cat/tools/bare/index.json"
    command mkdir -p "$cat/tools/t/versions"
    # debian+alpine method:
    #   debonly (no selector)        -> gap on alpine only
    #   alponly scoped "debian:12"   -> applies to debian only -> gap debian
    #   alponly scoped "alpine"      -> applies to alpine only -> mapped, no gap
    #   ghost   scoped "rhel"        -> rhel not in method os  -> not checked
    #   other   scoped "debian"      -> non-system_package kind, mapped -> no gap
    #   nowhere scoped []            -> applies to nothing (as sysdeps) -> no gap;
    #                                   unmapped everywhere, so "[] = all" would
    #                                   surface nowhere/debian + nowhere/alpine
    #   bare    scoped "alpine"      -> block without platforms -> gap alpine
    # plus two methods with no platform.os, valid and adding no gap: one with
    # no dependencies key, one with `"dependencies": []`.
    command printf '%s\n' '{"install_methods":[{"name":"nodeps"},{"name":"emptydeps","dependencies":[]},{"name":"m","platform":{"os":["debian","alpine"]},"dependencies":[
        {"tool":"debonly"},
        {"tool":"other","platforms":["debian"]},
        {"tool":"alponly","platforms":["debian:12"]},
        {"tool":"alponly","platforms":["alpine"]},
        {"tool":"ghost","platforms":["rhel"]},
        {"tool":"nowhere","platforms":[]},
        {"tool":"bare","platforms":["alpine"]}]}]}' >"$cat/tools/t/versions/1.0.0.json"

    rc=0
    gaps="$(dependency_gaps "$cat")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        problems="$problems"$'\n'"  well-formed synthetic catalog: exit $rc"
    elif [ "$gaps" != $'alponly/debian\nbare/alpine\ndebonly/alpine' ]; then
        problems="$problems"$'\n'"  selector narrowing: got [${gaps//$'\n'/, }], want [alponly/debian, bare/alpine, debonly/alpine]"
    fi

    # Each malformed shape must make dependency_gaps fail, never print nothing,
    # and fail for the INTENDED reason: every case names a tool the catalog
    # maps, so only the matching guard branch should reject it. Pairs are
    # "<expected stderr marker>|<version file body>".
    local case marker bad err
    for case in \
        'malformed dependency|{"install_methods":[{"name":"m","platform":{"os":"alpine"},"dependencies":["debonly"]}]}' \
        'malformed dependency|{"install_methods":[{"name":"m","platform":{"os":"alpine"},"dependencies":[{"tool":"debonly","platforms":"alpine"}]}]}' \
        'malformed dependency|{"install_methods":[{"name":"m","platform":{"os":"alpine"},"dependencies":[{"tool":"debonly","platforms":[12]}]}]}' \
        'malformed dependency|{"install_methods":[{"name":"m","platform":{"os":"alpine"},"dependencies":[{"tool":"debonly","platforms":false}]}]}' \
        'declares dependencies but no platform.os|{"install_methods":[{"name":"m","dependencies":[{"tool":"debonly"}]}]}' \
        'declares dependencies but no platform.os|{"install_methods":[{"name":"m","platform":{"os":[]},"dependencies":[{"tool":"debonly"}]}]}' \
        'declares dependencies but no platform.os|{"install_methods":[{"name":"m","platform":{"os":{"x":"alpine"}},"dependencies":[{"tool":"debonly"}]}]}' \
        'declares dependencies but no platform.os|{"install_methods":[{"name":"m","platform":{"os":[1]},"dependencies":[{"tool":"debonly"}]}]}' \
        'dependencies is not an array|{"install_methods":[{"name":"m","platform":{"os":"alpine"},"dependencies":{"x":{"tool":"debonly"}}}]}' \
        'dependencies is not an array|{"install_methods":[{"name":"m","platform":{"os":"alpine"},"dependencies":"debonly"}]}' \
        'dependencies is not an array|{"install_methods":[{"name":"m","platform":{"os":"alpine"},"dependencies":false}]}' \
        'install_methods is not an array|{"install_methods":{}}' \
        'install_methods is not an array|{"install_methods":false}' \
        'malformed dependency|{"install_methods":[{"name":"m","platform":{"os":"alpine"},"dependencies":[{"tool":5}]}]}' \
        'jq failed evaluating version files|not json'; do
        marker="${case%%|*}"
        bad="${case#*|}"
        command printf '%s\n' "$bad" >"$cat/tools/t/versions/1.0.0.json"
        if err="$(dependency_gaps "$cat" 2>&1 >/dev/null)"; then
            problems="$problems"$'\n'"  accepted malformed input: $bad"
        elif [[ "$err" != *"$marker"* ]]; then
            problems="$problems"$'\n'"  rejected for the wrong reason (want '$marker'): $bad -> $err"
        fi
    done
    # An unreadable index.json must fail at the system_package map step. The
    # version file is valid and its dependency mapped, so no later branch can
    # be the one that rejects it — only the map step's own guard can.
    command printf '%s\n' '{"install_methods":[{"name":"m","platform":{"os":"alpine"},"dependencies":[{"tool":"alponly"}]}]}' \
        >"$cat/tools/t/versions/1.0.0.json"
    command mkdir -p "$cat/tools/broken"
    command printf '%s\n' 'not json' >"$cat/tools/broken/index.json"
    if err="$(dependency_gaps "$cat" 2>&1 >/dev/null)"; then
        problems="$problems"$'\n'"  accepted an unreadable tools/broken/index.json"
    elif [[ "$err" != *"cannot read system_package entries"* ]]; then
        problems="$problems"$'\n'"  unreadable index.json rejected for the wrong reason: $err"
    fi
    command rm -rf "$cat/tools/broken"
    # A catalog with no version files must not read as "no gaps".
    command rm -rf "$cat/tools/t/versions"
    if err="$(dependency_gaps "$cat" 2>&1 >/dev/null)"; then
        problems="$problems"$'\n'"  accepted a catalog with no version files"
    elif [[ "$err" != *"no tools/*/versions/*.json"* ]]; then
        problems="$problems"$'\n'"  empty catalog rejected for the wrong reason: $err"
    fi

    if [ -n "$problems" ]; then
        fail_test "dependency_gaps misbehaved:$problems"
    fi
    return 0
}

run_test "test_vendored_dependencies_resolve" "every vendored dependency maps to a system package for its distros"
run_test "test_dependency_guard_catches_missing_entry" "dependency guard names a removed system_package entry"
run_test "test_dependency_guard_selectors_and_errors" "dependency guard narrows by selectors and fails loud on malformed input"

generate_report
