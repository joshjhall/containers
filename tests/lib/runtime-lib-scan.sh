#!/usr/bin/env bash
# Resolve every /opt/container-runtime/lib fragment reference in the installed
# scripts (#1095, extracted for fixture coverage in #1262).
#
# Every installed consumer loads its fragment behind a bare [ -f ], so a path
# typo skips it at boot without failing. This scans the installed scripts for
# fragment references and resolves each the way its consumer does:
#
#   - a literal path is tested as written, so a typo in the directory counts,
#     not just the basename
#   - a $VAR/<name>.sh reference (entrypoint's $_RUNTIME_LIB) is expanded
#     through that file's own assignment -- or, where it is computed
#     (healthcheck's RUNTIME_LIB), through every lib-dir literal in the file --
#     so a typo'd assignment or use-site variable fails too
#
# The known consumers must be among those scanned, so a regex that matches
# nothing cannot print the sentinel; a grep error fails rather than silently
# shrinking the scan.
#
# Prints "consumers-ok", or "missing:<refs> unseen:<files> errors: <stderr>"
# where each ref is "<file>:<ref>" (or "<file>:<ref>@<dir>" for a $VAR ref).
#
# The integration test runs this file's bytes in the image via `bash -c`, so
# it takes no arguments there. The unit test
# (tests/unit/runtime/runtime-lib-scan.sh) drives it against a fixture tree:
#
#   --root DIR     prefix for the scanned dirs and for resolving refs; output
#                  paths stay relative to it (default: empty, the real root)
#   --expect PATH  a consumer that must be scanned (repeatable; replaces the
#                  default list)
#
# Shapes this does NOT recognize, so a typo in them is never seen: a lib-dir
# variable whose name lacks RUNTIME (LIB_DIR=...; "$LIB_DIR/x.sh"), and a
# runtime-built basename (.../lib/${name}.sh). For a computed variable it
# trusts every lib-dir literal in the file, not the variable's own value. A
# bare lib-dir literal it cannot pair with a fragment is not reported: comments
# and healthcheck's own `echo "/opt/container-runtime/lib"` are that shape. No
# installed consumer is written in an unrecognized shape today.

root=""
expect=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --root)
            root="${2%/}"
            shift 2
            ;;
        --expect)
            expect+=("$2")
            shift 2
            ;;
        *)
            command echo "runtime-lib-scan: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done
if [ "${#expect[@]}" -eq 0 ]; then
    expect=(/usr/local/bin/entrypoint /usr/local/bin/workspace-fs-health-cron
        /usr/local/bin/healthcheck /etc/container/startup/42-workspace-fs-health.sh)
fi

libdir='/opt/container-[A-Za-z0-9_.-]+/lib[A-Za-z0-9_.-]*'
lit="$libdir/[A-Za-z0-9_./-]+\\.sh"
var='\$\{?_?[A-Z_]*RUNTIME[A-Z_]*\}?/[A-Za-z0-9_./-]+\.sh'
dirs=()
for d in /usr/local/bin /usr/local/sbin /etc/container/startup /opt/container-runtime; do
    [ -d "$root$d" ] && dirs+=("$root$d")
done
errfile=$(command mktemp)
consumers=""
if [ "${#dirs[@]}" -gt 0 ]; then
    consumers=$(command grep -rlIE "$lit|$var" "${dirs[@]}" </dev/null 2>"$errfile")
fi
missing=""
seen=""
# Newline-delimited, so a consumer path with a space is one entry.
while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel=${f#"$root"}
    seen="$seen$rel"$'\n'
    for ref in $(command grep -ohE "$lit" "$f" 2>>"$errfile" | command sort -u); do
        [ -f "$root$ref" ] || missing="$missing $rel:$ref"
    done
    for ref in $(command grep -ohE "$var" "$f" 2>>"$errfile" | command sort -u); do
        name=${ref%%/*}
        name=${name#\$}
        name=${name#\{}
        name=${name%\}}
        dir=$(command sed -nE "s/^[[:space:]]*${name}=\"?(\\/[^\"\$]*)\"?[[:space:]]*\$/\\1/p" "$f" 2>>"$errfile")
        if [ -z "$dir" ] && command grep -qE "^[[:space:]]*${name}=" "$f" 2>>"$errfile"; then
            dir=$(command grep -ohE "${libdir}\\}?\"" "$f" 2>>"$errfile" | command sed -E 's/\}?"$//' | command sort -u)
        fi
        [ -n "$dir" ] || missing="$missing $rel:$ref"
        for d in $dir; do
            [ -f "$root$d/${ref#*/}" ] || missing="$missing $rel:$ref@$d"
        done
    done
done <<<"$consumers"
errs=$(<"$errfile")
command rm -f "$errfile"
unseen=""
for want in "${expect[@]}"; do
    command grep -qxF "$want" <<<"$seen" || unseen="$unseen $want"
done
if [ -z "$missing$unseen$errs" ]; then command echo consumers-ok; else command echo "missing:$missing unseen:$unseen errors: $errs"; fi
