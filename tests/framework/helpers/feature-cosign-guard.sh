#!/usr/bin/env bash
# Shared harness that drives a feature script's require_cosign guard at runtime.
#
# SOURCE-ONLY: defines test functions but runs none until a suite calls
# register_cosign_guard_tests. It lives under tests/framework/ so that
# run_unit_tests.sh (which discovers suites under tests/unit/) never runs it.
#
# Sourced by tests/unit/features/{docker,kubernetes}.sh, which call
# register_cosign_guard_tests. Both feature scripts
# end their cosign section with
#
#     require_cosign || {
#         log_feature_end
#         exit 1
#     }
#
# and a static grep only proves that text is written (#941). This runs the real
# script as a process — under its own `set -euo pipefail` — and reports its
# exit status, so a refactor that swallows the exit is caught.
#
# How the build-time environment is faked:
#   - /tmp/build-scripts/ is rewritten to a sandbox holding empty stubs for the
#     sourced helpers, except cosign-require.sh, which is the REAL file.
#     shared/export-utils.sh, which cosign-require.sh sources, is stubbed too.
#   - The stub feature-header.sh defines log_message/log_error/log_warning to
#     echo, so the guard's messages reach the output for assertions.
#   - PATH holds only the sandbox bin dir, and command_not_found_handle turns
#     every other external tool and unstubbed helper (apt_install, curl, gpg,
#     verify_download_or_fail, ...) into a successful no-op that drains its
#     stdin — a stub that never reads would SIGPIPE the writer of an
#     `echo ... | tee` pipeline under pipefail. The build steps
#     before the guard therefore run without network access.
#   - The inner shell starts under `env -i`: the test framework `export -f`s
#     ~90 functions (setup, run_test, assert_*, ...), and inheriting them
#     would let a pre-guard call resolve to a real framework function instead
#     of the no-op.
#   - The copy is truncated at the guard's closing brace, which must be a
#     column-0 `}` alone on its line, within 3 lines of the first
#     `require_cosign ||` — anything looser could end at an unrelated `}`
#     further down or keep code after the brace. It ends with
#     `echo PAST_GUARD; exit 0`, so nothing after the guard runs on the host.
#
# What it does NOT neutralize, and therefore refuses or relies on (every
# executed file — the copy and the copied guard — is scanned by
# _cosign_guard_scan_safe):
#   - Redirections. bash opens a `>`/`>>` target BEFORE resolving the command,
#     so `command tee >/etc/x` creates /etc/x even though tee is a no-op. Any
#     write redirection whose target is not exactly /dev/null or an fd
#     (`2>&1`, `>&-`) is refused.
#   - Commands the stub PATH cannot intercept: eval, exec, enable,
#     `command -p`, `hash -p`, and an absolute path in command position
#     (/usr/bin/curl is not a lookup and runs for real). All refused.
#   - Running as root. The scan is the only thing between a missed write and
#     a real system path, so uid 0 is refused outright.
#   - Residual, not scanned: `.`/`source` of a host file (docker.sh reads
#     /etc/os-release), `cd`, `printf -v`/`read` into variables, an absolute
#     path reached through a variable (`"$x" args`), and quotes nested inside
#     a multi-line `$(...)`, which the comment-skip tracker does not model.
#     None writes outside the sandbox today; keep the pre-guard code to
#     bare-name tool calls.

# run_feature_cosign_guard <feature-script> <mode> [--mutate]
#
# <mode>:
#   absent   — no cosign on PATH (the base install did not happen)
#   shadowed — a cosign on PATH that is not the base install (#940)
#   present  — a cosign on PATH that the copied guard accepts as the base
#              install; the positive control that the harness reaches and
#              passes the guard
# --mutate replaces the guard's `exit 1` with a no-op `:` in the scratch copy —
# the mutant a discriminating test must reject. Production files are never
# edited.
#
# Prints the script's output followed by a final "rc=<exit status>" line.
run_feature_cosign_guard() {
    local script="$1" mode="$2" mutate="${3:-}"
    local dir rc=0 helper
    # A missing script must not run as an empty file: report a status no
    # assertion expects, so both the pass and fail cases fail.
    if [ ! -f "$script" ]; then
        command printf 'missing script: %s\nrc=missing\n' "$script"
        return 0
    fi
    # Without the guard there is nothing to truncate at, and running the whole
    # script on the test host is not an option.
    if ! command grep -q '^require_cosign ||' "$script"; then
        command printf 'guard not found in: %s\nrc=missing\n' "$script"
        return 0
    fi
    # The redirection scan below is the only barrier between a missed write
    # and a real system path; as root nothing else would stop it.
    if [ "$(command id -u)" = "0" ]; then
        command printf 'refusing to run as root: %s\nrc=missing\n' "$script"
        return 0
    fi
    dir=$(command mktemp -d)
    command mkdir -p "$dir/bin" "$dir/build-scripts/base" "$dir/build-scripts/shared"

    for helper in feature-header apt-utils retry-utils checksum-fetch \
        download-verify checksum-verification cache-utils path-utils; do
        : >"$dir/build-scripts/base/$helper.sh"
    done
    # cosign-require.sh sources this when present; without it, its fallback
    # resolves through the no-op `dirname` to the host's /shared/.
    : >"$dir/build-scripts/shared/export-utils.sh"
    command cat >"$dir/build-scripts/base/feature-header.sh" <<'STUB'
log_message() { echo "$*"; }
log_error() { echo "ERROR: $*"; }
log_warning() { echo "WARNING: $*"; }
STUB

    # The real guard, with its build-scripts paths pointed at the sandbox. In
    # "present" mode the pinned base path is widened to the stub, which is the
    # only way a test host can satisfy it.
    command sed "s|/tmp/build-scripts/|$dir/build-scripts/|g" \
        "$PROJECT_ROOT/lib/base/cosign-require.sh" >"$dir/build-scripts/base/cosign-require.sh"
    if [ "$mode" = "present" ]; then
        command sed -i "s|^_COSIGN_BASE_PATH=.*|_COSIGN_BASE_PATH=\"$dir/bin/cosign\"|" \
            "$dir/build-scripts/base/cosign-require.sh"
    fi

    if [ "$mode" = "present" ] || [ "$mode" = "shadowed" ]; then
        command printf '#!/bin/sh\necho "cosign 0.0.0"\n' >"$dir/bin/cosign"
        command chmod +x "$dir/bin/cosign"
    fi
    # kubernetes.sh verifies k9s and helm with `command -v` and exits 1 before
    # the cosign section if either is missing.
    for helper in k9s helm; do
        command printf '#!/bin/sh\necho "%s 0.0.0"\n' "$helper" >"$dir/bin/$helper"
        command chmod +x "$dir/bin/$helper"
    done

    # Copy up to the guard's closing brace, optionally no-op its exit, then
    # mark the far side. The brace must be a column-0 `}` alone on its line
    # (`} && x` would keep x), within 3 lines of the first
    # `require_cosign ||` (a repeat must not restart the window); past that the
    # guard is not the expected shape and the next column-0 `}` could belong to
    # unrelated post-guard code. awk
    # stops printing rather than exiting: an early exit would close the pipe on
    # a still-writing sed, and SIGPIPE fails the caller's pipefail.
    command sed "s|/tmp/build-scripts/|$dir/build-scripts/|g" "$script" |
        command awk -v mutate="$mutate" '
            done || bad { next }
            /^require_cosign \|\|/ && !in_guard { in_guard = 1; start = NR }
            in_guard && NR - start > 3 { bad = 1; next }
            in_guard && mutate == "--mutate" { sub(/exit 1/, ":") }
            { print }
            in_guard && /^}[[:space:]]*$/ { done = 1 }
            END { exit !done }
        ' >"$dir/feature-script" || {
        # No column-0 `}` closed the guard within 3 lines (a one-line
        # `require_cosign || exit 1`, an indented brace, a longer block): the
        # copy could run code past the guard on the host. Refuse, with a
        # status no assertion expects.
        command printf 'guard not truncatable in: %s\nrc=missing\n' "$script"
        command rm -rf "$dir"
        return 0
    }
    echo 'echo PAST_GUARD; exit 0' >>"$dir/feature-script"

    # Refuse any write redirection to a real path (bash opens the target
    # before command lookup, so the no-op handler cannot stop it) and any
    # command the stub PATH cannot intercept.
    if ! _cosign_guard_scan_safe "$dir/feature-script" \
        "$dir/build-scripts/base/cosign-require.sh" 2>&1; then
        command printf 'unsafe construct in: %s\nrc=missing\n' "$script"
        command rm -rf "$dir"
        return 0
    fi

    # shellcheck disable=SC2016 # expanded by the inner bash, not here
    /usr/bin/env -i HOME="$dir" PATH="$dir/bin" USERNAME="testuser" /bin/bash -c '
        command_not_found_handle() {
            local _line
            while IFS= read -r _line; do :; done
            return 0
        }
        source "$1"
    ' feature-script "$dir/feature-script" </dev/null 2>&1 || rc=$?
    command printf 'rc=%s\n' "$rc"
    command rm -rf "$dir"
}

# _cosign_guard_scan_safe <file>...
#
# Succeeds when no scanned line in the given files
#   - redirects output to anything but /dev/null or an fd duplication (`2>&1`,
#     `>&2`, `>&-`), each matched up to a word end so `>&2foo` and
#     `>/dev/nullX` (real files) are not mistaken for them;
#   - uses eval, exec, enable, `command -p` or `hash -p`, which run code or
#     real tools the stub PATH cannot intercept (eval also rebuilds a `>` at
#     runtime, e.g. from `$(printf '\076')`);
#   - has an absolute path in command position (/usr/bin/sudo would run for
#     real, and as a sudo-group user defeat the uid-0 refusal).
# Prints each offending line to stderr. Deliberately coarse: a `>` inside a
# string or `[ a > b ]` also trips it, which is a refusal, never a missed write.
#
# A `#` line is skipped as a comment only from a clean state: no open quote,
# backtick or `$(`, not after a backslash-continued line or a line that opens
# a command substitution, and not after a here-document. Otherwise a string
# such as `x="` / `#"; echo d >f` would hide its second line. The state is a
# simple tracker (it does not model quotes nested inside `$(...)`); where it
# is wrong it scans a line it could have skipped, never the reverse.
_cosign_guard_scan_safe() {
    ! command awk '
        # Advance the quote state across s, stopping at an unquoted `#` that
        # starts a word (the rest of the line is a comment).
        function track(s,    i, c, n) {
            n = length(s); hit_comment = 0
            for (i = 1; i <= n; i++) {
                c = substr(s, i, 1)
                if (q == 0 && c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:];|&(]/)) {
                    hit_comment = 1; return
                }
                if (c == "\\" && q != 1) { i++; continue }
                if (c == "\047" && q != 2) q = q ? 0 : 1
                else if (c == "\"" && q != 1) q = q ? 0 : 2
                else if (c == "`" && q != 1) bt = !bt
                else if (q != 1 && c == "$" && substr(s, i + 1, 1) == "(") { depth++; i++ }
                else if (q == 0 && c == ")" && depth > 0) depth--
            }
        }
        function refuse(why) { print FILENAME ":" FNR ": " why ": " $0 > "/dev/stderr"; bad = 1 }
        FNR == 1 { q = 0; bt = 0; depth = 0; cont = 0; subst = 0; heredoc = 0 }
        {
            clean = q == 0 && !bt && depth == 0 && !cont && !subst && !heredoc
            if (clean && /^[[:space:]]*#/) next
            line = $0
            # Drop the benign forms, then look for any write redirection left.
            gsub(/[0-9]*>>?[[:space:]]*\/dev\/null([[:space:];|&)]|$)/, " ", line)
            gsub(/[0-9]*>&([0-9]+-?|-)([[:space:];|&)]|$)/, " ", line)
            if (line ~ />/) refuse("write redirection")
            if ($0 ~ /(^|[^[:alnum:]_.-])(eval|exec|enable)([^[:alnum:]_.-]|$)/) refuse("eval/exec/enable")
            if ($0 ~ /(^|[^[:alnum:]_.-])(command|hash)[[:space:]]+-[[:alnum:]]*p/) refuse("command -p/hash -p")
            # Command position: a line start (unless it continues a quote or a
            # backslash-continued command, where it is an argument), after a
            # control operator, or after a keyword that takes a command.
            if ((q == 0 && !cont && $0 ~ /^[[:space:]]*["\047]?\//) ||
                $0 ~ /[;&|({!`][[:space:]]*["\047]?\// ||
                $0 ~ /(^|[^[:alnum:]_.-])(then|do|else|elif|if|while|until|time)[[:space:]]+["\047]?\//)
                refuse("absolute-path command")
            if ($0 ~ /<</ && $0 !~ /<<</) heredoc = 1
            track($0)
            subst = $0 ~ /\$\(|`/
            cont = !hit_comment && match($0, /\\+$/) && RLENGTH % 2 == 1
        }
        END { exit !bad }
    ' "$@"
}

# Last line of run_feature_cosign_guard output is "rc=<exit status>".
_cosign_guard_rc() {
    command printf '%s\n' "$1" | command tail -n 1
}

# The runtime tests, against $COSIGN_GUARD_SCRIPT. The --mutate case
# no-ops the guard's `exit 1` in a scratch copy: if the absent-cosign test
# could pass against that mutant it would not be testing the exit path.
test_cosign_absent_exits_feature() {
    local out name
    name=$(command basename "$COSIGN_GUARD_SCRIPT")
    out=$(run_feature_cosign_guard "$COSIGN_GUARD_SCRIPT" absent)
    assert_equals "rc=1" "$(_cosign_guard_rc "$out")" \
        "$name exits 1 when cosign is absent"
    assert_contains "$out" "cosign not found on PATH" \
        "the exit comes from the cosign guard, not an earlier failure"
    assert_not_contains "$out" "PAST_GUARD" \
        "$name does not continue past the cosign guard"
}

test_cosign_shadowed_exits_feature() {
    local out name
    name=$(command basename "$COSIGN_GUARD_SCRIPT")
    out=$(run_feature_cosign_guard "$COSIGN_GUARD_SCRIPT" shadowed)
    assert_equals "rc=1" "$(_cosign_guard_rc "$out")" \
        "$name exits 1 when a non-base cosign shadows the base install"
    assert_contains "$out" "not the base install" \
        "the exit comes from the #940 resolved-path check"
    assert_not_contains "$out" "PAST_GUARD" \
        "$name does not continue past the cosign guard"
}

test_cosign_present_passes_guard() {
    local out name
    name=$(command basename "$COSIGN_GUARD_SCRIPT")
    out=$(run_feature_cosign_guard "$COSIGN_GUARD_SCRIPT" present)
    assert_equals "rc=0" "$(_cosign_guard_rc "$out")" \
        "$name runs through the guard when the base cosign is present"
    assert_contains "$out" "PAST_GUARD" \
        "harness reaches the far side of the guard (positive control)"
}

test_cosign_guard_mutant_is_detected() {
    local out name
    name=$(command basename "$COSIGN_GUARD_SCRIPT")
    out=$(run_feature_cosign_guard "$COSIGN_GUARD_SCRIPT" absent --mutate)
    assert_contains "$out" "PAST_GUARD" \
        "with the guard's exit no-op'd, $name continues past it"
    assert_not_equals "rc=1" "$(_cosign_guard_rc "$out")" \
        "the absent-cosign exit status discriminates the mutant"
    out=$(run_feature_cosign_guard "$COSIGN_GUARD_SCRIPT" shadowed --mutate)
    assert_contains "$out" "PAST_GUARD" \
        "with the guard's exit no-op'd, a shadowed cosign also continues past it"
    assert_not_equals "rc=1" "$(_cosign_guard_rc "$out")" \
        "the shadowed-cosign exit status discriminates the mutant"
}

# A guard the truncation cannot find the end of must be refused, not run: the
# copy would otherwise be the whole feature script. Drives the refusal with a
# scratch copy whose guard is collapsed to one line.
test_cosign_guard_untruncatable_is_refused() {
    local out scratch
    scratch=$(command mktemp)
    command awk '
        /^require_cosign \|\|/ { print "require_cosign || exit 1"; skip = 1; next }
        skip && /^}/ { skip = 0; next }
        !skip { print }
    ' "$COSIGN_GUARD_SCRIPT" >"$scratch"
    out=$(run_feature_cosign_guard "$scratch" absent)
    command rm -f "$scratch"
    assert_equals "rc=missing" "$(_cosign_guard_rc "$out")" \
        "a one-line guard is refused rather than run to the end of the script"
    assert_contains "$out" "guard not truncatable" \
        "the refusal names the truncation, not a missing guard"
}

# The guard indented, plus a later column-0 `}` (a function past the guard):
# an unbounded "first column-0 } after the guard" match would stop at that
# later brace and run the post-guard code between them. Must be refused. Run
# in present mode: in absent mode the guard exits before POST_GUARD_RAN
# whether or not the copy was refused, so that assertion could not fail.
test_cosign_guard_far_brace_is_refused() {
    local out scratch
    scratch=$(command mktemp)
    command awk '
        /^require_cosign \|\|/ { g = 1 }
        g && /^}/ {
            print "    }"
            print "echo POST_GUARD_RAN"
            print "post_guard_fn() {"
            print "    :"
            print "}"
            g = 0; next
        }
        { print }
    ' "$COSIGN_GUARD_SCRIPT" >"$scratch"
    out=$(run_feature_cosign_guard "$scratch" present)
    command rm -f "$scratch"
    assert_equals "rc=missing" "$(_cosign_guard_rc "$out")" \
        "a guard closed only by a distant column-0 } is refused"
    assert_contains "$out" "guard not truncatable" \
        "the refusal names the truncation bound"
    assert_not_contains "$out" "POST_GUARD_RAN" \
        "no code past the guard ran"
}

# Code after the closing brace on the same line (`} && x`) runs once the
# guard passes, so a brace with anything after it does not close the copy.
test_cosign_guard_trailing_code_is_refused() {
    local out scratch
    scratch=$(command mktemp)
    command awk '
        /^require_cosign \|\|/ { g = 1 }
        g && /^}/ { print "} && echo POST_GUARD_RAN"; g = 0; next }
        { print }
    ' "$COSIGN_GUARD_SCRIPT" >"$scratch"
    out=$(run_feature_cosign_guard "$scratch" present)
    command rm -f "$scratch"
    assert_equals "rc=missing" "$(_cosign_guard_rc "$out")" \
        "a closing brace followed by code is refused"
    assert_contains "$out" "guard not truncatable" \
        "the refusal names the truncation"
    assert_not_contains "$out" "POST_GUARD_RAN" \
        "the code after the brace did not run"
}

# A second `require_cosign ||` must not restart the 3-line window: the
# indented brace leaves the first guard open, and a restarted window would
# end at the second guard's brace with POST_GUARD_RAN in between.
test_cosign_guard_repeated_guard_is_refused() {
    local out scratch
    scratch=$(command mktemp)
    command awk '
        /^require_cosign \|\|/ { g = 1 }
        g && /^}/ {
            print "    }"
            print "require_cosign || :"
            print "{ echo POST_GUARD_RAN"
            print "}"
            g = 0; next
        }
        { print }
    ' "$COSIGN_GUARD_SCRIPT" >"$scratch"
    out=$(run_feature_cosign_guard "$scratch" present)
    command rm -f "$scratch"
    assert_equals "rc=missing" "$(_cosign_guard_rc "$out")" \
        "a repeated require_cosign line does not widen the window"
    assert_contains "$out" "guard not truncatable" \
        "the refusal names the truncation bound"
    assert_not_contains "$out" "POST_GUARD_RAN" \
        "no code past the first guard ran"
}

# uid 0 is refused before anything runs. A stub `id` first on PATH reports 0;
# the harness resolves `command id` through PATH, so this drives the real check.
test_cosign_guard_refuses_root() {
    local out stubdir
    stubdir=$(command mktemp -d)
    command printf '#!/bin/sh\necho 0\n' >"$stubdir/id"
    command chmod +x "$stubdir/id"
    out=$(PATH="$stubdir:$PATH" run_feature_cosign_guard "$COSIGN_GUARD_SCRIPT" present)
    command rm -rf "$stubdir"
    assert_equals "rc=missing" "$(_cosign_guard_rc "$out")" \
        "running as uid 0 is refused"
    assert_contains "$out" "refusing to run as root" \
        "the refusal names the uid check"
    assert_not_contains "$out" "PAST_GUARD" \
        "the feature script never ran"
}

# The inner shell starts under `env -i`, so an exported function cannot stand
# in for a stub. log_feature_end is called by every absent-mode guard; an
# inherited export would print LEAKED instead of falling through to the no-op.
test_cosign_guard_env_is_cleared() {
    local out
    out=$(
        # shellcheck disable=SC2317 # invoked only if env -i stops clearing it
        log_feature_end() { echo LEAKED; }
        export -f log_feature_end
        run_feature_cosign_guard "$COSIGN_GUARD_SCRIPT" absent
    )
    assert_equals "rc=1" "$(_cosign_guard_rc "$out")" \
        "the guard still exits 1"
    assert_not_contains "$out" "LEAKED" \
        "an exported caller function does not reach the feature script"
}

# bash opens a redirection target before command lookup, so a write to a real
# path in pre-guard code would land even with every tool a no-op. Inject one
# into a scratch copy, pointed at a path inside a fresh temp dir so a failure
# of the scan is observable (the file appears) rather than destructive.
test_cosign_guard_unsafe_redirect_is_refused() {
    local out scratch probe
    scratch=$(command mktemp)
    probe="$(command mktemp -d)/written-by-feature-script"
    command awk -v probe="$probe" '
        /^require_cosign \|\|/ && !done { print "command tee >" probe " </dev/null"; done = 1 }
        { print }
    ' "$COSIGN_GUARD_SCRIPT" >"$scratch"
    out=$(run_feature_cosign_guard "$scratch" absent)
    command rm -f "$scratch"
    assert_equals "rc=missing" "$(_cosign_guard_rc "$out")" \
        "a pre-guard write redirection to a real path is refused"
    assert_contains "$out" "unsafe construct" \
        "the refusal names the scan"
    if [ -e "$probe" ]; then
        assert_equals "absent" "present" "the redirection target was never created"
    else
        assert_equals "absent" "absent" "the redirection target was never created"
    fi
    command rm -rf "$(command dirname "$probe")"
}

# The scan itself: benign forms pass, every refused form trips it. Cases are
# whole files (lines joined by `|`) so multi-line ones carry their state.
test_cosign_guard_scan() {
    local f case
    f=$(command mktemp)
    # The shapes the real feature scripts use, which must stay allowed.
    # shellcheck disable=SC1003 # trailing backslashes are literal scan input
    command printf '%s\n' 'cmd 2>/dev/null' 'cmd >/dev/null 2>&1' \
        'cmd >&2' '(cmd 2>/dev/null)' 'cmd >&-' \
        '# echo x >/etc/comment-only' '#   - dive <image>: Analyze' \
        'add_key "K" \' '    "/usr/share/keyrings/k.gpg" \' '    x' \
        'cmd --keyring /etc/apt/x' '[ -f "/tmp/x" ]' \
        'v=$(. /etc/os-release && echo "$V")' 'echo "a # b"' >"$f"
    _cosign_guard_scan_safe "$f" 2>/dev/null
    assert_equals "0" "$?" "/dev/null, fd duplication, comments and arguments are allowed"
    # shellcheck disable=SC2016 # literal shell text, scanned not run
    for case in 'cmd >/etc/x' 'cmd >>/etc/x' 'cmd 2>/tmp/x' 'cmd >"$VAR"' \
        'cmd &>/etc/x' 'cmd >/dev/null >/etc/x' \
        'x="|#"; echo d >/etc/x' 'echo a\|#b >/etc/x' 'x=$(echo "|#" >/etc/x)' \
        'cmd >&2foo' 'cmd >/dev/nullX' \
        "eval \"x \$(printf '\\076') /cache/x\"" \
        '/usr/bin/sudo id' 'x && /usr/bin/mv a b' 'if "/usr/bin/x"; then :; fi' \
        'command -p mv a b' 'hash -p /usr/bin/mv mv' 'exec /bin/sh' \
        'enable -f x y'; do
        command printf '%s\n' "$case" | command tr '|' '\n' >"$f"
        _cosign_guard_scan_safe "$f" 2>/dev/null
        assert_equals "1" "$?" "refused: $case"
    done
    command rm -f "$f"
}

# register_cosign_guard_tests <feature-script>
#
# Runs the tests above against <feature-script> in the calling suite.
register_cosign_guard_tests() {
    COSIGN_GUARD_SCRIPT="$1"
    run_test test_cosign_absent_exits_feature "Cosign absent: feature exits 1"
    run_test test_cosign_shadowed_exits_feature "Cosign shadowed: feature exits 1"
    run_test test_cosign_present_passes_guard "Cosign present: feature passes guard"
    run_test test_cosign_guard_mutant_is_detected "Cosign guard mutant detected"
    run_test test_cosign_guard_untruncatable_is_refused "Cosign guard: untruncatable copy refused"
    run_test test_cosign_guard_far_brace_is_refused "Cosign guard: distant closing brace refused"
    run_test test_cosign_guard_trailing_code_is_refused "Cosign guard: code after closing brace refused"
    run_test test_cosign_guard_repeated_guard_is_refused "Cosign guard: repeated guard line refused"
    run_test test_cosign_guard_refuses_root "Cosign guard: uid 0 refused"
    run_test test_cosign_guard_env_is_cleared "Cosign guard: caller environment cleared"
    run_test test_cosign_guard_unsafe_redirect_is_refused "Cosign guard: unsafe redirection refused"
    run_test test_cosign_guard_scan "Cosign guard: construct scan"
}
