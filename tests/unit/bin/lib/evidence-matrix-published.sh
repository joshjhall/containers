#!/usr/bin/env bash
# Unit tests: bin/lib/evidence-matrix.sh fails closed on a published evidence
# source it cannot read (#1319) and names the culprit — an unopenable file as
# unreadable (#1463), a misshapen one by its shape (#1329), the first in glob
# order whatever its kind (#1495) — and removes its scratch on every exit path.
# Split out of evidence-matrix.sh (#1464); fixtures shared via
# tests/lib/evidence-matrix-fixtures.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../framework.sh"

init_test_framework

test_suite "Evidence matrix (published-evidence failures)"

# shellcheck source=bin/lib/evidence-matrix.sh
source "$PROJECT_ROOT/bin/lib/evidence-matrix.sh"
# Each test sets its own source; none may inherit one from the caller.
unset EVIDENCE_TESTED_SOURCE EVIDENCE_PUBLISHED_CHECK
# shellcheck source=tests/lib/evidence-matrix-fixtures.sh
source "$PROJECT_ROOT/tests/lib/evidence-matrix-fixtures.sh"

test_unreadable_published_source_is_an_error() {
    # An unreachable source must not become "everything pending" (#1319).
    local r db out err rc=0
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64
    err="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
    out="$(EVIDENCE_TESTED_SOURCE="$TEST_TEMP_DIR/no-such-db" evidence_matrix "$r/catalog" rust "$r" 2>"$err")" || rc=$?
    assert_equals "1" "$rc" "a missing source is exit 1"
    assert_equals "" "$out" "and prints no matrix"
    # A wrong path is not a tool vendored ahead of containers-db (#1365).
    assert_equals "evidence_matrix: no published evidence for rust at $TEST_TEMP_DIR/no-such-db/tools/rust/versions (EVIDENCE_TESTED_SOURCE)" \
        "$(command cat "$err")" "a tools/-less first source gets the generic message"

    # Main has tools/rust/ but no version files: half-published, not vendored
    # ahead, so the generic message too.
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    command mkdir -p "$db/tools/rust/versions"
    rc=0
    out="$(EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r" 2>"$err")" || rc=$?
    assert_equals "1" "$rc" "a first source with an empty tools/rust/versions is exit 1"
    assert_equals "evidence_matrix: no published evidence for rust at $db/tools/rust/versions (EVIDENCE_TESTED_SOURCE)" \
        "$(command cat "$err")" "and gets the generic message, not the vendored-ahead one"

    command echo '{not json' >"$db/tools/rust/versions/1.90.0.json"
    rc=0
    out="$(EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r" 2>"$err")" || rc=$?
    assert_equals "1" "$rc" "an unparsable source is exit 1"
    assert_equals "" "$out" "and prints no matrix"
    assert_equals "$(_malformed_msg "$db/tools/rust/versions/1.90.0.json")" \
        "$(command sed -n 1p "$err")" "and names the unparsable file (#1329)"
    # jq's parse error follows, so the operator sees where the file broke
    # (#1463). Its wording belongs to the jq release; only the location is pinned.
    assert_contains "$(command sed -n '2,$p' "$err")" "line 1, column" "and jq's parse location follows it"
}

# _unopenable_fails <source> <bad_file> <what> [restore] — evidence_matrix
# exits 1, prints no matrix, and says bad_file cannot be read, without the
# shape hint. With restore, bad_file is made readable again before any
# assertion can fail, so a mode-000 fixture never outlives the test.
_unopenable_fails() {
    local src="$1" bad="$2" what="$3" restore="${4:-}" r out err rc=0
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64
    err="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
    out="$(EVIDENCE_TESTED_SOURCE="$src" evidence_matrix "$r/catalog" rust "$r" 2>"$err")" || rc=$?
    [ -z "$restore" ] || command chmod 644 "$bad"
    assert_equals "1" "$rc" "$what is exit 1"
    assert_equals "" "$out" "$what prints no matrix"
    assert_equals "evidence_matrix: cannot read published evidence for rust: $bad" \
        "$(command cat "$err")" "$what is named as unreadable, not misshapen"
}

test_unopenable_published_file_is_named() {
    # #1463: a file the glob matched but jq cannot open is an access problem;
    # the shape hint would send the operator to its content. Still fatal
    # (#1319). 1.80.0 and 1.90.0 are valid, so the culprit is not just
    # "the only file there is".
    local db f
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.80.0 debian-13-amd64
    _db_version "$db" 1.90.0 debian-13-amd64

    f="$db/tools/rust/versions/1.95.0.json"
    command ln -s nowhere.json "$f"
    _unopenable_fails "$db" "$f" "a broken symlink"
    command rm -f "$f"

    # Sorting first, the dangling link is found[0], which the empty-directory
    # probe must not read as "no version files".
    f="$db/tools/rust/versions/1.10.0.json"
    command ln -s nowhere.json "$f"
    _unopenable_fails "$db" "$f" "a broken symlink that sorts first"
    command rm -f "$f"

    # A directory the glob matched is not a regular file either.
    f="$db/tools/rust/versions/1.95.0.json"
    command mkdir "$f"
    _unopenable_fails "$db" "$f" "a directory named like a version file"
    command rmdir "$f"

    # A later source takes the i>0 branch of the empty-directory probe, so
    # its dangling first match is pinned there too.
    local db2
    db2="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    command mkdir -p "$db2/tools/rust/versions"
    f="$db2/tools/rust/versions/1.10.0.json"
    command ln -s nowhere.json "$f"
    _unopenable_fails "$db:$db2" "$f" "a broken symlink first in a second source"
}

test_unreadable_mode_published_file_is_named() {
    # Root, a DAC-override capability, or a FUSE permission overlay can all
    # read a mode-000 file anyway, so probe the denial itself rather than the
    # uid. Its own test, so the skip covers only it (skips render as passes,
    # and skip_test relabels everything that already ran in the same test).
    local db f
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.80.0 debian-13-amd64
    _db_version "$db" 1.90.0 debian-13-amd64
    f="$db/tools/rust/versions/1.90.0.json"
    command chmod 000 "$f"
    if [ -r "$f" ]; then
        command chmod 644 "$f"
        skip_test "mode 000 does not deny reads here"
        return 0
    fi
    _unopenable_fails "$db" "$f" "a file without read permission" restore
}

test_unopenable_only_file_is_named() {
    # The source's only match is a dangling link: still a named file, not
    # the "no published evidence ... at <dir>" message (#1463).
    local db f
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    command mkdir -p "$db/tools/rust/versions"
    f="$db/tools/rust/versions/1.90.0.json"
    command ln -s nowhere.json "$f"
    _unopenable_fails "$db" "$f" "a lone broken symlink"
}

test_evidence_scratch_failure_is_an_error() {
    # The batch's stderr sidecar is a mktemp (#1463); when that cannot be
    # created the source is unread, so exit 1 (#1319) with a message that
    # names the step, never a matrix.
    local r db out err rc=0
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.90.0 ""
    out="$(command mktemp "$TEST_TEMP_DIR/out.XXXXXX")"
    err="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
    # Portable: BSD mktemp with no template is `-t tmp` under $TMPDIR too (#1495).
    TMPDIR="$TEST_TEMP_DIR/no-such-tmp" EVIDENCE_TESTED_SOURCE="$db" \
        _em_published_evidence rust "$out" 0 2>"$err" || rc=$?
    assert_equals "1" "$rc" "a failed scratch mktemp is exit 1"
    # mktemp's own diagnostic comes first and its wording is the platform's,
    # so the step's message is pinned as the last line, alone.
    assert_equals "evidence_matrix: cannot create a scratch file for rust evidence" \
        "$(command tail -n 1 "$err")" "and says which step failed"
    assert_not_contains "$(command cat "$err")" "unreadable published evidence" \
        "and no later path ran"
    assert_equals "" "$(command cat "$out")" "and writes no matrix"
}

test_preexisting_out_err_is_not_a_failure() {
    # The sidecar is its own mktemp (#1463): a directory at "$out.err" made
    # the old 2>"$out.err" redirect fail and read as an evidence failure.
    local db out err rc=0
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.90.0 debian-13-amd64
    out="$(command mktemp "$TEST_TEMP_DIR/out.XXXXXX")"
    err="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
    command mkdir "$out.err"
    EVIDENCE_TESTED_SOURCE="$db" _em_published_evidence rust "$out" 0 2>"$err" || rc=$?
    assert_equals "0" "$rc" "a directory at \$out.err is not a failure"
    assert_equals "" "$(command cat "$err")" "and prints nothing"
    assert_equals "true" "$(command jq '. != null and has("1.90.0")' "$out")" "and writes the matrix"
}

test_first_culprit_wins_across_kinds() {
    # The culprit loop checks access then shape per file, in glob order, so
    # the first bad file is named whatever its kind (#1495). An access pass
    # over every file before a shape pass would flip case "shape".
    local db v out err rc first ver want
    for first in shape access; do
        db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
        for ver in 1.10.0 1.80.0 1.95.0; do
            _db_version "$db" "$ver" debian-13-amd64
        done
        v="$db/tools/rust/versions"
        if [ "$first" = shape ]; then
            _mutate "$v/1.10.0.json" 'del(.version)'
            command ln -sf nowhere.json "$v/1.95.0.json"
            want="$(_malformed_msg "$v/1.10.0.json")"
        else
            command ln -sf nowhere.json "$v/1.10.0.json"
            _mutate "$v/1.95.0.json" 'del(.version)'
            want="evidence_matrix: cannot read published evidence for rust: $v/1.10.0.json"
        fi
        out="$(command mktemp "$TEST_TEMP_DIR/out.XXXXXX")"
        err="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
        rc=0
        EVIDENCE_TESTED_SOURCE="$db" _em_published_evidence rust "$out" 0 2>"$err" || rc=$?
        assert_equals "1" "$rc" "a $first culprit first is exit 1"
        assert_equals "$want" "$(command sed -n 1p "$err")" "the first file, a $first culprit, is named"
    done
}

test_open_refused_after_access_check_is_named() {
    # #1463: test -r asks access(2), which a FUSE overlay or a root-squashed
    # mount can answer yes while the open still fails. A jq stub stands in
    # for that open, failing every read with jq 1.7's wording (the code keys
    # only on its "Could not open" stem), so the culprit loop must name the
    # file as unreadable, not misshapen, and still remove its scratch.
    local r db bin tmp f out err rc=0
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.90.0 debian-13-amd64
    f="$db/tools/rust/versions/1.90.0.json"
    bin="$(command mktemp -d "$TEST_TEMP_DIR/bin.XXXXXX")"
    command printf '#!/bin/sh\nfor a; do f=$a; done\nprintf "jq: error: Could not open file %%s: Permission denied\\n" "$f" >&2\nexit 2\n' >"$bin/jq"
    command chmod +x "$bin/jq"
    err="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
    out="$(command mktemp "$TEST_TEMP_DIR/out.XXXXXX")"
    tmp="$(command mktemp -d "$TEST_TEMP_DIR/tmp.XXXXXX")"
    PATH="$bin:$PATH" TMPDIR="$tmp" EVIDENCE_TESTED_SOURCE="$db" \
        _em_published_evidence rust "$out" 0 2>"$err" || rc=$?
    assert_equals "1" "$rc" "an open refused past access(2) is exit 1"
    assert_equals "" "$(command ls -A "$tmp")" "and leaves no scratch behind"
    assert_equals "evidence_matrix: cannot read published evidence for rust: $f" \
        "$(command sed -n 1p "$err")" "and is named as unreadable, not misshapen"
    assert_equals "jq: error: Could not open file $f: Permission denied" \
        "$(command sed -n '2,$p' "$err")" "and jq's open error follows it"
}

_malformed_msg() {
    command echo "evidence_matrix: unreadable published evidence for rust: $1 (must be one JSON object with a string .version and, if present, an array .tested)"
}

# _malformed_fails <source> <bad_file> <what> — evidence_matrix over a
# 1.90.0 catalog exits 1, prints no matrix, and names exactly bad_file.
_malformed_fails() {
    local src="$1" bad="$2" what="$3" r out err rc=0
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64
    err="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
    out="$(EVIDENCE_TESTED_SOURCE="$src" evidence_matrix "$r/catalog" rust "$r" 2>"$err")" || rc=$?
    assert_equals "1" "$rc" "$what is exit 1"
    assert_equals "" "$out" "$what prints no matrix"
    assert_equals "$(_malformed_msg "$bad")" "$(command cat "$err")" "$what is named in the error"
}

# _mutate <file> <jq filter> — rewrites a version file in place. A failed
# rewrite fails the test: chained cases would otherwise pass on the previous
# case's malformed content.
_mutate() {
    local tmp
    tmp="$(command mktemp "$TEST_TEMP_DIR/mut.XXXXXX")"
    if command jq "$2" "$1" >"$tmp"; then
        command mv "$tmp" "$1"
    else
        fail_test "_mutate: jq '$2' failed on $1"
    fi
}

test_malformed_published_file_is_named() {
    # #1329: a version file with a bad shape stays fatal (skipping it would
    # make its cells pending again, #1319), and the message names the file
    # rather than only the source list. 1.80.0 is valid, so the culprit is
    # not just "the only file there is".
    local db pr f
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.80.0 debian-13-amd64
    _db_version "$db" 1.90.0 debian-13-amd64
    f="$db/tools/rust/versions/1.90.0.json"

    _mutate "$f" 'del(.version)'
    _malformed_fails "$db" "$f" "a file with no version key"

    _mutate "$f" '.version = null'
    _malformed_fails "$db" "$f" "a null version"

    _mutate "$f" '.version = "1.90.0" | .tested = "x"'
    _malformed_fails "$db" "$f" "a non-array tested"

    # Without the explicit check jq iterates an object's values as rows and
    # exits 0, so this is the case only the shape check catches.
    _mutate "$f" '.tested = {a: {os: "debian", os_version: "13", arch: "amd64", result: "pass"}}'
    _malformed_fails "$db" "$f" "an object tested"

    _mutate "$f" '.tested = null'
    _malformed_fails "$db" "$f" "a null tested"

    _mutate "$f" '[.]'
    _malformed_fails "$db" "$f" "a top-level array"

    # Slurping drops an empty file and splits a two-document one, so only
    # the value-count check sees these.
    : >"$f"
    _malformed_fails "$db" "$f" "an empty file"
    _db_version "$db" 1.90.0 debian-13-amd64
    command cat "$f" "$f" >"$f.two" && command mv "$f.two" "$f"
    _malformed_fails "$db" "$f" "a file with two documents"

    # Together they keep the total value count equal to the file count, so
    # only a per-file count stops the batch passing. Both files are bad; the
    # culprit loop names the first in glob order, the empty 1.80.0.
    : >"$db/tools/rust/versions/1.80.0.json"
    _malformed_fails "$db" "$db/tools/rust/versions/1.80.0.json" "an empty file beside a two-document one"
    _db_version "$db" 1.80.0 debian-13-amd64
    _db_version "$db" 1.90.0 debian-13-amd64

    # The culprit sits in a later source (an open PR's rows): main is fine.
    _mutate "$f" '.tested = []'
    pr="$(command mktemp -d "$TEST_TEMP_DIR/pr.XXXXXX")"
    _db_version "$pr" 1.90.0 debian-13-amd64
    _mutate "$pr/tools/rust/versions/1.90.0.json" 'del(.version)'
    _malformed_fails "$db:$pr" "$pr/tools/rust/versions/1.90.0.json" "a bad file in a PR-rows source"
}

test_unnamed_evidence_failure_names_the_sources() {
    # Every file has the right shape but a row is not an object, so the
    # evidence step fails where no per-file check can point: the message
    # falls back to the source list, still exit 1 (#1329).
    local r db out err rc=0
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.90.0 ""
    _mutate "$db/tools/rust/versions/1.90.0.json" '.tested = [1]'
    err="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
    out="$(EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r" 2>"$err")" || rc=$?
    assert_equals "1" "$rc" "a bad row in a well-shaped file is exit 1"
    assert_equals "" "$out" "and prints no matrix"
    assert_equals "evidence_matrix: unreadable published evidence for rust in $db" \
        "$(command sed -n 1p "$err")" "and names the source list"
    # jq's own cause follows, so the fallback still says what broke. Its
    # wording belongs to the jq release, so only its presence is pinned.
    assert_not_equals "" "$(command sed -n 2p "$err")" "and jq's error follows it"
    # The batch's own shape error is our string, not jq's: it must not be the
    # cause here, or the shape gate rejected a file the culprit check passed.
    assert_not_contains "$(command cat "$err")" "malformed version file" "and the shape gate did not fire"
}

test_evidence_scratch_is_removed() {
    # The batch jq's stderr sidecar is its own mktemp (#1463), like
    # evidence_matrix's output file; every exit path (success, an unopenable
    # file, a named file, the fallback) removes both, so a scratch TMPDIR is
    # empty afterwards. Each case pins its exit code and first stderr line,
    # so the four cases cannot quietly collapse onto one path.
    local r db tmp f link err case rc want_rc want_err
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    f="$db/tools/rust/versions/1.90.0.json"
    link="$db/tools/rust/versions/1.95.0.json"
    err="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
    for case in ok unopenable named fallback; do
        _db_version "$db" 1.90.0 ""
        command rm -f "$link"
        case "$case" in
            ok) want_rc=0 want_err="" ;;
            unopenable)
                command ln -s nowhere.json "$link"
                want_rc=1 want_err="evidence_matrix: cannot read published evidence for rust: $link"
                ;;
            named)
                _mutate "$f" 'del(.version)'
                want_rc=1 want_err="$(_malformed_msg "$f")"
                ;;
            fallback)
                _mutate "$f" '.tested = [1]'
                want_rc=1 want_err="evidence_matrix: unreadable published evidence for rust in $db"
                ;;
        esac
        tmp="$(command mktemp -d "$TEST_TEMP_DIR/tmp.XXXXXX")"
        rc=0
        TMPDIR="$tmp" EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r" >/dev/null 2>"$err" || rc=$?
        assert_equals "$want_rc" "$rc" "the $case path exits $want_rc"
        assert_equals "$want_err" "$(command sed -n 1p "$err")" "the $case path is the one taken"
        assert_equals "" "$(command ls -A "$tmp")" "no scratch left after the $case path"
    done
}

test_repeated_source_is_not_two_documents() {
    # The per-file count must not read a source listed twice as one file
    # holding two documents: the repeat adds the same rows, nothing more.
    local r db out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.90.0 debian-13-amd64
    out="$(EVIDENCE_TESTED_SOURCE="$db:$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "1.90.0 debian-13-arm64" "$(_cells "$out")" "a repeated source counts once"
}

test_published_file_without_tested_is_valid() {
    # A version file with no tested key has no rows: its cells are pending,
    # not an error (the #1329 shape check must not reject it).
    local r db out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.90.0 ""
    _mutate "$db/tools/rust/versions/1.90.0.json" 'del(.tested)'
    out="$(EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "1.90.0 debian-13-amd64" "$(_cells "$out")" "no tested key means pending"
}

run_test test_unreadable_published_source_is_an_error "an unreadable evidence source is an error, not a full matrix"
run_test test_malformed_published_file_is_named "a malformed published version file is fatal and named"
run_test test_unopenable_published_file_is_named "an unopenable published version file is fatal and named as unreadable"
run_test test_unreadable_mode_published_file_is_named "a version file without read permission is named as unreadable"
run_test test_unopenable_only_file_is_named "a lone dangling version file is named, not read as an empty source"
run_test test_evidence_scratch_failure_is_an_error "a failed published-evidence scratch file is an error"
run_test test_preexisting_out_err_is_not_a_failure "a pre-existing \$out.err does not fake an evidence failure"
run_test test_first_culprit_wins_across_kinds "the first culprit in glob order is named, unopenable or misshapen"
run_test test_open_refused_after_access_check_is_named "an open refused past the access check is named as unreadable"
run_test test_unnamed_evidence_failure_names_the_sources "a failure no file check explains falls back to the source list"
run_test test_evidence_scratch_is_removed "published-evidence scratch is removed on every exit path"
run_test test_repeated_source_is_not_two_documents "a source listed twice is not a two-document file"
run_test test_published_file_without_tested_is_valid "a published version file without tested is pending, not an error"

generate_report
