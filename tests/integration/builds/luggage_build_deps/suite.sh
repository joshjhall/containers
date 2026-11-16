#!/usr/bin/env bash
# Shared body of the apt/rpm luggage build-dep removal suites (#1632).
# Sourced by test_luggage_build_deps_{debian,rhel}.sh after the framework is
# initialised. The caller passes, to bd_run_suite:
#
#   BD_DISTRO        debian | rhel — picks the Dockerfile and the presence probe
#   BD_DEPENDENT     the default-purpose package that depends on BD_REFUSED
#   BD_REFUSED       the `purpose: build` package the manager must refuse
#   BD_REFUSAL_TEXT  the manager's own refusal wording, expected in stderr
#
# Two images per suite: MODE=happy (build deps declared, removable) and
# MODE=refuse (a build dep something installed still needs). See the
# Dockerfiles for what each mode patches into the catalog.

BD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BD_NODE_VERSION="26.13.0"
# Optional: a mutation check rebuilds the fixture from a scratch copy of the
# repo and points the suite at it, with its own cargo cache id so the mutant
# binary never lands in the normal fixtures' target dir.
BD_TARGET_CACHE="${LUGGAGE_TARGET_CACHE:-luggage-build-deps-target}"

# bd_present_cmd PKG — a container command printing `pkg-present-PKG`,
# `pkg-absent-PKG`, or `pkg-inconclusive-PKG ...`. The inconclusive token
# matches neither expectation, so every assertion fails on it.
#
# Absent must mean "removed", not "could not tell", or a happy-path absence
# assertion passes for the wrong reason. Two guards, because neither manager
# can be trusted to fail on a broken database on its own (verified
# 2026-11-16): dpkg-query reads a MISSING /var/lib/dpkg/status as an empty
# database and answers "no packages found"; rpm -q against a WIPED
# /var/lib/rpm answers the exact "package X is not installed".
#   1. Control: the same query must first see `bash` installed. bash is in
#      both base images and is never a declared dep, so a database that
#      cannot see it cannot be trusted to say anything is absent.
#   2. Only the manager's own unambiguous answer counts (mirroring luggage's
#      fail-closed presence_from_output, sysremove.rs):
#        dpkg-query: rc 0 + `installed` = present; rc 0 + `not-installed` /
#                    `config-files`, or rc 1 + "no packages found matching"
#                    = absent.
#        rpm -q:     rc 0 = present; rc 1 + "package PKG is not installed"
#                    = absent.
bd_present_cmd() {
    local pkg="$1" query
    case "$BD_DISTRO" in
        debian)
            # q P — prints P's verdict word: present | absent | inconclusive.
            query="q() { local out rc; out=\$(dpkg-query -W -f='\${db:Status-Status}' \"\$1\" 2>&1); rc=\$?; if [ \$rc -eq 0 ] && [ \"\$out\" = installed ]; then echo present; elif { [ \$rc -eq 0 ] && { [ \"\$out\" = not-installed ] || [ \"\$out\" = config-files ]; }; } || { [ \$rc -eq 1 ] && [[ \$out == *'no packages found matching'* ]]; }; then echo absent; else echo \"inconclusive rc=\$rc \$out\"; fi; }"
            ;;
        rhel)
            query="q() { local out rc; out=\$(rpm -q \"\$1\" 2>&1); rc=\$?; if [ \$rc -eq 0 ]; then echo present; elif [ \$rc -eq 1 ] && [ \"\$out\" = \"package \$1 is not installed\" ]; then echo absent; else echo \"inconclusive rc=\$rc \$out\"; fi; }"
            ;;
    esac
    printf '%s' "$query; c=\$(q bash); if [ \"\$c\" != present ]; then echo \"pkg-inconclusive-$pkg control-bash=\$c\"; else v=\$(q $pkg); case \"\$v\" in present|absent) echo pkg-\$v-$pkg ;; *) echo \"pkg-inconclusive-$pkg \$v\" ;; esac; fi"
}

bd_build() {
    local mode="$1" image="$2"
    # Built once per mode per run: every test re-calls this. The marker
    # records the OUTCOME, failure included, so a broken build is attempted
    # and its full output reported once — by the first test of that mode.
    # Later tests of the mode return 1 without re-building; run_test (same
    # shell, framework.sh) still fails each of them as "returned 1 without
    # recording a verdict" (#1002), so none can pass on a missing image.
    local marker="BD_BUILT_$mode"
    case "${!marker:-}" in
        ok) return 0 ;;
        failed) return 1 ;;
    esac
    if assert_build_succeeds "$BD_FIXTURE" \
        --build-arg NODE_VERSION="$BD_NODE_VERSION" \
        --build-arg MODE="$mode" \
        --build-arg LUGGAGE_TARGET_CACHE="$BD_TARGET_CACHE" \
        -t "$image"; then
        printf -v "$marker" '%s' ok
        return 0
    fi
    printf -v "$marker" '%s' failed
    return 1
}

bd_cleanup() {
    docker rmi -f "$BD_HAPPY_IMAGE" "$BD_REFUSE_IMAGE" >/dev/null 2>&1 || true
}

# ─── happy: build deps installed for the method, then removed ───

test_bd_node_runs_without_build_deps() {
    bd_build happy "$BD_HAPPY_IMAGE" || return
    assert_command_in_container "$BD_HAPPY_IMAGE" "node --version" "v${BD_NODE_VERSION}"
}

test_bd_build_deps_removed() {
    bd_build happy "$BD_HAPPY_IMAGE" || return
    # One package per assertion so a failure names the one left behind.
    local pkg
    for pkg in make patch; do
        assert_command_in_container "$BD_HAPPY_IMAGE" "$(bd_present_cmd "$pkg")" "pkg-absent-$pkg"
    done
    # The binaries themselves, not just the package records. One at a time:
    # `command -v a b` succeeds if either resolves.
    for pkg in make patch; do
        assert_command_in_container "$BD_HAPPY_IMAGE" \
            "command -v $pkg >/dev/null && echo bin-present-$pkg || echo bin-absent-$pkg" \
            "bin-absent-$pkg"
    done
}

test_bd_report_records_removed() {
    bd_build happy "$BD_HAPPY_IMAGE" || return
    # Exactly the two, in declaration order — the closing `]` rules out a
    # third entry riding along.
    assert_command_in_container "$BD_HAPPY_IMAGE" \
        "command tr -d ' \n' < /var/log/luggage/node-report.json | command grep -o '\"removed_build_dependencies\":\[[^]]*\]'" \
        '"removed_build_dependencies":["make","patch"]'
}

# ─── refuse: a build dep something installed still needs ───

test_bd_refusal_fails_loudly() {
    bd_build refuse "$BD_REFUSE_IMAGE" || return
    # The install exited non-zero. A token, not the raw code: "1" would match
    # as a substring of "10" or a timestamp.
    assert_command_in_container "$BD_REFUSE_IMAGE" \
        "rc=\$(command cat /var/log/luggage/install.rc); [ \"\$rc\" -ne 0 ] && echo install-failed || echo install-succeeded-rc-\$rc" \
        "install-failed"
    # It failed for the refusal, naming the refused package, in the manager's
    # own words — not some unrelated earlier-stage failure.
    assert_command_in_container "$BD_REFUSE_IMAGE" \
        "command grep -qF 'could not remove build dependencies: $BD_REFUSED' /var/log/luggage/install.stderr && echo names-refused || echo missing-refusal" \
        "names-refused"
    assert_command_in_container "$BD_REFUSE_IMAGE" \
        "command grep -qF '$BD_REFUSAL_TEXT' /var/log/luggage/install.stderr && echo manager-refused || echo no-manager-refusal" \
        "manager-refused"
    # Classified as a cleanup failure, not infra (#1668).
    assert_command_in_container "$BD_REFUSE_IMAGE" \
        "command tr -d ' \n' < /var/log/luggage/node-report.json | command grep -o '\"error_class\":\"[a-z_]*\"'" \
        '"error_class":"post_install"'
}

test_bd_refusal_does_not_cascade() {
    bd_build refuse "$BD_REFUSE_IMAGE" || return
    # The heart of refuse-don't-cascade: the dependent is still installed,
    # and so is the build dep the manager refused to take from under it.
    assert_command_in_container "$BD_REFUSE_IMAGE" "$(bd_present_cmd "$BD_DEPENDENT")" "pkg-present-$BD_DEPENDENT"
    assert_command_in_container "$BD_REFUSE_IMAGE" "$(bd_present_cmd "$BD_REFUSED")" "pkg-present-$BD_REFUSED"
    # And the report does not claim a removal that did not happen. grep's
    # exit is split three ways: 1 (read the report, no key) is the only pass;
    # 2 (missing/unreadable report) must not read as "nothing claimed".
    assert_command_in_container "$BD_REFUSE_IMAGE" \
        "command grep -q removed_build_dependencies /var/log/luggage/node-report.json; case \$? in 0) echo claims-removal ;; 1) echo no-removal-claimed ;; *) echo report-unreadable ;; esac" \
        "no-removal-claimed"
}

bd_run_suite() {
    BD_DISTRO="$1" BD_DEPENDENT="$2" BD_REFUSED="$3" BD_REFUSAL_TEXT="$4"
    BD_FIXTURE="$BD_DIR/Dockerfile.luggage-build-deps-$BD_DISTRO"
    BD_HAPPY_IMAGE="test-luggage-build-deps-$BD_DISTRO-happy-$$"
    BD_REFUSE_IMAGE="test-luggage-build-deps-$BD_DISTRO-refuse-$$"
    run_test test_bd_node_runs_without_build_deps "node runs with its build deps removed"
    run_test test_bd_build_deps_removed "purpose: build packages removed"
    run_test test_bd_report_records_removed "InstallReport records the removed build deps"
    run_test test_bd_refusal_fails_loudly "a refused build dep fails the install loudly"
    run_test test_bd_refusal_does_not_cascade "a refused build dep cascades nothing"
    bd_cleanup
}
