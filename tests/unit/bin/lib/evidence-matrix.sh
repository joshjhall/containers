#!/usr/bin/env bash
# Unit tests: bin/lib/evidence-matrix.sh builds the push-triggered evidence
# matrix from the catalog (#1111) — newest patch per minor from the floor up,
# claimed ∩ base-image tuples, pending cells only, capped under GitHub's 256.
#
# Hermetic: a synthetic catalog + base-images tree per test, with exact
# expected cells (not substring checks), so a wrong-but-plausible matrix fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../framework.sh"

init_test_framework

test_suite "Evidence matrix (catalog-derived)"

# shellcheck source=bin/lib/evidence-matrix.sh
source "$PROJECT_ROOT/bin/lib/evidence-matrix.sh"
# Tests that rely on the vendored tested[] path must not inherit a source.
unset EVIDENCE_TESTED_SOURCE EVIDENCE_PUBLISHED_CHECK
# shellcheck source=tests/lib/evidence-matrix-fixtures.sh
source "$PROJECT_ROOT/tests/lib/evidence-matrix-fixtures.sh"

test_newest_patch_per_minor_from_floor() {
    local r out
    r="$(_fixture 1.85.0)"
    _version "$r/catalog" 1.84.1 debian-13-amd64  # below floor
    _version "$r/catalog" 1.85.0 debian-13-amd64  # superseded patch
    _version "$r/catalog" 1.85.2 debian-13-amd64  # newest 1.85
    _version "$r/catalog" 1.85.10 debian-13-amd64 # numerically newer than .2
    _version "$r/catalog" 1.86.0 debian-13-amd64
    out="$(evidence_matrix "$r/catalog" rust "$r")"
    assert_equals $'1.85.10 debian-13-amd64\n1.86.0 debian-13-amd64' "$(_cells "$out")" \
        "newest patch of each minor at/above the floor, compared numerically"
}

test_claims_intersect_base_images() {
    local r out
    r="$(_fixture 1.0.0)"
    # rhel-10-amd64 is claimed but has no base image; alpine-3.24-arm64 likewise.
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64,rhel-10-amd64,alpine-3.24-arm64
    out="$(evidence_matrix "$r/catalog" rust "$r")"
    assert_equals $'1.90.0 debian-13-amd64\n1.90.0 debian-13-arm64' "$(_cells "$out")" \
        "only claimed tuples that have a base image"
}

test_covered_cells_are_not_pending() {
    local r out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64 debian-13-amd64
    out="$(evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "1.90.0 debian-13-arm64" "$(_cells "$out")" \
        "a cell with a passing row is not re-run"
}

test_nothing_pending_exits_3_with_no_output() {
    local r out rc=0
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64 debian-13-amd64
    out="$(evidence_matrix "$r/catalog" rust "$r" 2>/dev/null)" || rc=$?
    assert_equals "3" "$rc" "nothing pending is exit 3, so the workflow can skip the job"
    assert_equals "" "$out" "and prints no (empty) matrix"
}

test_cap_takes_oldest_first() {
    local r out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.80.0 debian-13-amd64,debian-13-arm64
    _version "$r/catalog" 1.81.0 debian-13-amd64,debian-13-arm64
    out="$(evidence_matrix "$r/catalog" rust "$r" latest 3 2>/dev/null)"
    assert_equals $'1.80.0 debian-13-amd64\n1.80.0 debian-13-arm64\n1.81.0 debian-13-amd64' "$(_cells "$out")" \
        "max_cells keeps the oldest pending cells"
}

test_cells_carry_arch_plumbing() {
    local r out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-arm64
    out="$(evidence_matrix "$r/catalog" rust "$r" v9)"
    assert_equals \
        '{"tool":"rust","version":"1.90.0","tuple":"debian-13-arm64","image_tag":"v9","arch":"arm64","runner":"ubuntu-24.04-arm","runtime":"native","rust_target":"aarch64-unknown-linux-musl"}' \
        "$(command jq -c '.include[0]' <<<"$out")" \
        "each cell carries the same fields the dispatch path builds"
}

test_unpublished_tuples_are_not_available() {
    # evidence-run.yml computes a PR's matrix against the BASE branch's
    # base-images tree: a tuple the PR adds has no published image to pull
    # yet. Pointing the root at a tree without that tuple must drop it.
    local r base out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,alpine-3.24-amd64
    base="$(command mktemp -d "$TEST_TEMP_DIR/base.XXXXXX")"
    command mkdir -p "$base/base-images/debian/13/amd64"
    command touch "$base/base-images/debian/13/amd64/Dockerfile"
    out="$(evidence_matrix "$r/catalog" rust "$base")"
    assert_equals "1.90.0 debian-13-amd64" "$(_cells "$out")" \
        "a tuple absent from the root's base-images tree is not offered"
}

test_unpublished_images_are_skipped() {
    # EVIDENCE_PUBLISHED_CHECK gates each tuple on its image being published:
    # on the merge that adds a tuple, the matrix runs before the image exists.
    local r out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,alpine-3.24-amd64
    _published_debian_only() { [ "$1" = debian-13-amd64 ]; }
    out="$(EVIDENCE_PUBLISHED_CHECK=_published_debian_only evidence_matrix "$r/catalog" rust "$r" 2>/dev/null)"
    assert_equals "1.90.0 debian-13-amd64" "$(_cells "$out")" \
        "a tuple whose image is not published is skipped"

    # Unset (unit tests, local runs): Dockerfiles alone decide, as before.
    out="$(evidence_matrix "$r/catalog" rust "$r")"
    assert_equals $'1.90.0 alpine-3.24-amd64\n1.90.0 debian-13-amd64' "$(_cells "$out")" \
        "with no check configured, every tuple with a Dockerfile is offered"
}
test_published_evidence_decides_pending() {
    # #1319: the vendored snapshot never receives tested[] rows, so pending-ness
    # comes from the published source. Same catalog, two sources: a passing
    # published row excludes the cell; without one the cell is included.
    local r db out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.90.0 debian-13-amd64
    out="$(EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "1.90.0 debian-13-arm64" "$(_cells "$out")" \
        "a cell with a passing published row is excluded"

    _db_version "$db" 1.90.0 ""
    out="$(EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals $'1.90.0 debian-13-amd64\n1.90.0 debian-13-arm64' "$(_cells "$out")" \
        "the same cell without a published row is included"
}

test_published_source_overrides_vendored_tested() {
    # A vendored pass row does not count once a source is set, and only
    # passing published rows count; a failing one with no tested_at is a
    # stale failure, so the cell stays pending (#1326 cooldown tests below).
    local r db out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64,alpine-3.24-amd64 debian-13-amd64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.90.0 alpine-3.24-amd64 debian-13-arm64
    out="$(EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals $'1.90.0 debian-13-amd64\n1.90.0 debian-13-arm64' "$(_cells "$out")" \
        "vendored pass ignored, published fail pending, published pass excluded"
}

test_version_missing_from_published_is_pending() {
    # A version vendored but not yet in containers-db has no evidence at all.
    local r db out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64
    _version "$r/catalog" 1.91.0 debian-13-amd64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.90.0 debian-13-amd64
    out="$(EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "1.91.0 debian-13-amd64" "$(_cells "$out")" \
        "a version with no published file is fully pending"
}

test_open_ingest_pr_rows_count_as_covered() {
    # A previous run's evidence PR may still be awaiting auto-merge when the
    # next push resolves its matrix. evidence-run.yml lists that PR's head next
    # to main; rows from every listed source are unioned.
    local r main pr out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64,alpine-3.24-amd64
    main="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    pr="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$main" 1.90.0 debian-13-amd64
    _db_version "$pr" 1.90.0 debian-13-arm64
    out="$(EVIDENCE_TESTED_SOURCE="$main:$pr" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "1.90.0 alpine-3.24-amd64" "$(_cells "$out")" \
        "a cell covered by any listed source is excluded"

    local rc=0
    out="$(EVIDENCE_TESTED_SOURCE="$main:$TEST_TEMP_DIR/no-such-pr" evidence_matrix "$r/catalog" rust "$r" 2>/dev/null)" || rc=$?
    assert_equals "1" "$rc" "any unreadable listed source is exit 1"
    assert_equals "" "$out" "and prints no matrix"
}

test_pr_rows_drop_inherited_rows() {
    # A PR head carries main's rows from its branch point. A pass row revoked
    # on main since must not be re-asserted by the PR's stale copy (#1327).
    local r main base head rows out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64,alpine-3.24-amd64
    base="$(command mktemp -d "$TEST_TEMP_DIR/base.XXXXXX")"
    head="$(command mktemp -d "$TEST_TEMP_DIR/head.XXXXXX")"
    main="$(command mktemp -d "$TEST_TEMP_DIR/main.XXXXXX")"
    rows="$TEST_TEMP_DIR/rows.$$.$RANDOM"
    _db_version "$base" 1.90.0 debian-13-amd64
    _db_version "$head" 1.90.0 debian-13-amd64,debian-13-arm64
    _db_version "$main" 1.90.0 ""
    evidence_pr_rows "$base" "$head" "$rows"
    assert_equals '[{"os":"debian","os_version":"13","arch":"arm64","result":"pass"}]' \
        "$(command jq -c .tested "$rows/tools/rust/versions/1.90.0.json")" \
        "only the row the PR added survives"

    out="$(EVIDENCE_TESTED_SOURCE="$main:$rows" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals $'1.90.0 alpine-3.24-amd64\n1.90.0 debian-13-amd64' "$(_cells "$out")" \
        "the revoked amd64 pass is pending again; the PR's own arm64 row still covers"

    # Mutation guard: unioning the head tree whole re-asserts the revoked row.
    out="$(EVIDENCE_TESTED_SOURCE="$main:$head" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "1.90.0 alpine-3.24-amd64" "$(_cells "$out")" \
        "the fixture does distinguish: the whole head tree hides the amd64 cell"
}

test_pr_rows_new_file_and_untouched_tool() {
    # A version file the PR adds counts whole; a file (or tool) whose rows are
    # all inherited is not written, and reads as "no rows from this source".
    local base head rows
    base="$(command mktemp -d "$TEST_TEMP_DIR/base.XXXXXX")"
    head="$(command mktemp -d "$TEST_TEMP_DIR/head.XXXXXX")"
    rows="$TEST_TEMP_DIR/rows.$$.$RANDOM"
    _db_version "$base" 1.90.0 debian-13-amd64
    _db_version "$head" 1.90.0 debian-13-amd64
    _db_version "$base" 1.22.0 debian-13-amd64 "" "" go
    _db_version "$head" 1.22.0 debian-13-amd64 "" "" go
    _db_version "$head" 1.91.0 debian-13-amd64,alpine-3.24-amd64
    evidence_pr_rows "$base" "$head" "$rows"
    assert_equals "tools/rust/versions/1.91.0.json" \
        "$(cd "$rows" && command find tools -type f | command sort)" \
        "only the new version file is written; unchanged rust 1.90.0 and go are not"
    assert_equals "2" "$(command jq '.tested | length' "$rows/tools/rust/versions/1.91.0.json")" \
        "a new file's rows all count"
    assert_dir_exists "$rows/tools" "out keeps a readable tools/ tree"
    assert_dir_not_exists "$rows/tools/go" "with no tools/go for the untouched tool"

    # The real reader takes that shape as "no go rows here", not exit 1.
    local r main out rc=0
    r="$(_fixture 1.0.0)"
    _tool "$r/catalog" go 1.22.0
    _version "$r/catalog" 1.22.0 debian-13-amd64 "" go
    main="$(command mktemp -d "$TEST_TEMP_DIR/main.XXXXXX")"
    _db_version "$main" 1.22.0 "" "" "" go
    out="$(EVIDENCE_TESTED_SOURCE="$main:$rows" evidence_matrix "$r/catalog" go "$r" 2>/dev/null)" || rc=$?
    assert_equals "0" "$rc" "a rows tree without the tool is not an error"
    assert_equals "1.22.0 debian-13-amd64" "$(_cells "$out")" "and adds no go evidence"
}

test_pr_rows_changed_row_counts() {
    # A row the PR rewrites (a fail superseded by a pass) is the PR's
    # assertion, so it counts; the base's old copy is not carried over.
    local base head rows
    base="$(command mktemp -d "$TEST_TEMP_DIR/base.XXXXXX")"
    head="$(command mktemp -d "$TEST_TEMP_DIR/head.XXXXXX")"
    rows="$TEST_TEMP_DIR/rows.$$.$RANDOM"
    _db_version "$base" 1.90.0 "" debian-13-amd64
    _db_version "$head" 1.90.0 debian-13-amd64
    evidence_pr_rows "$base" "$head" "$rows"
    assert_equals '[{"os":"debian","os_version":"13","arch":"amd64","result":"pass"}]' \
        "$(command jq -c .tested "$rows/tools/rust/versions/1.90.0.json")" \
        "the rewritten row is kept as the PR's own"
}

test_pr_rows_unreadable_is_an_error() {
    # Each failure is pinned by its message, so a case cannot pass because a
    # different guard happened to return 1.
    local base head err rel=tools/rust/versions/1.90.0.json
    base="$(command mktemp -d "$TEST_TEMP_DIR/base.XXXXXX")"
    head="$(command mktemp -d "$TEST_TEMP_DIR/head.XXXXXX")"
    err="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
    _pr_rows_fails() {
        local rc=0
        evidence_pr_rows "$1" "$2" "$TEST_TEMP_DIR/rows.$$.$RANDOM" 2>"$err" || rc=$?
        assert_equals "1" "$rc" "$4 is exit 1"
        # Last line: jq's own diagnostic may precede ours, and is kept.
        assert_equals "$3" "$(command tail -n 1 "$err")" "$4 names its guard"
    }

    _db_version "$base" 1.90.0 ""
    command mkdir -p "$head/tools/rust/versions"
    command echo '{not json' >"$head/$rel"
    _pr_rows_fails "$base" "$head" "evidence_pr_rows: unreadable $rel in $head or $base" "an unparsable head file"

    _db_version "$head" 1.90.0 ""
    command echo '{not json' >"$base/$rel"
    _pr_rows_fails "$base" "$head" "evidence_pr_rows: unreadable $rel in $head or $base" "an unparsable base file"

    # Zero-byte files are no jq input, not "no rows": an empty base would
    # re-assert every inherited row, an empty head would drop silently.
    : >"$base/$rel"
    _db_version "$head" 1.90.0 debian-13-amd64
    _pr_rows_fails "$base" "$head" "evidence_pr_rows: empty $rel in $head or $base" "a zero-byte base file"

    _db_version "$base" 1.90.0 ""
    : >"$head/$rel"
    _pr_rows_fails "$base" "$head" "evidence_pr_rows: empty $rel in $head or $base" "a zero-byte head file"

    _pr_rows_fails "$TEST_TEMP_DIR/no-such-base" "$head" \
        "evidence_pr_rows: $TEST_TEMP_DIR/no-such-base and $head must both hold a tools/ tree" "a base with no tools/ tree"

    # A head with no tools/ must not yield an empty-but-readable rows tree,
    # which _em_published_evidence would read as "no rows" (#1319).
    local rows="$TEST_TEMP_DIR/rows.$$.$RANDOM" rc=0
    evidence_pr_rows "$base" "$TEST_TEMP_DIR/no-such-head" "$rows" 2>"$err" || rc=$?
    assert_equals "1" "$rc" "a head with no tools/ tree is exit 1"
    assert_equals "evidence_pr_rows: $base and $TEST_TEMP_DIR/no-such-head must both hold a tools/ tree" \
        "$(command cat "$err")" "and names its guard"
    assert_dir_not_exists "$rows" "and writes no rows tree"
}

test_pr_rows_head_without_rows_writes_nothing() {
    # A head version file with no tested key, or tested: [], adds no rows, so
    # no file is written for it (#1446).
    local base head rows f
    base="$(command mktemp -d "$TEST_TEMP_DIR/base.XXXXXX")"
    head="$(command mktemp -d "$TEST_TEMP_DIR/head.XXXXXX")"
    rows="$TEST_TEMP_DIR/rows.$$.$RANDOM"
    _db_version "$base" 1.90.0 debian-13-amd64
    _db_version "$head" 1.90.0 debian-13-amd64
    command mkdir -p "$head/tools/rust/versions"
    command printf '{"schemaVersion":1,"tool":"rust","version":"1.91.0"}\n' \
        >"$head/tools/rust/versions/1.91.0.json"
    command printf '{"schemaVersion":1,"tool":"rust","version":"1.92.0","tested":[]}\n' \
        >"$head/tools/rust/versions/1.92.0.json"
    evidence_pr_rows "$base" "$head" "$rows"
    f="$(cd "$rows" && command find tools -type f | command sort)"
    assert_equals "" "$f" "no tested key and tested: [] each write nothing"
    assert_dir_exists "$rows/tools" "and out is still a readable tools/ tree"
}

test_pr_rows_head_dropping_a_row_writes_nothing() {
    # A head that is a subset of its base (the PR removed a row) asserts
    # nothing new: no file is written, and the removed row is not re-asserted.
    local base head rows
    base="$(command mktemp -d "$TEST_TEMP_DIR/base.XXXXXX")"
    head="$(command mktemp -d "$TEST_TEMP_DIR/head.XXXXXX")"
    rows="$TEST_TEMP_DIR/rows.$$.$RANDOM"
    _db_version "$base" 1.90.0 debian-13-amd64,debian-13-arm64
    _db_version "$head" 1.90.0 debian-13-amd64
    evidence_pr_rows "$base" "$head" "$rows"
    assert_file_not_exists "$rows/tools/rust/versions/1.90.0.json" "a head that only drops a row writes no file"
    assert_equals "" "$(cd "$rows" && command find tools -type f)" "nor any other"
}

test_pr_skip_decision() {
    # Every state/status the per-PR re-read can produce (#1446). A merge
    # commit counts as landed only when main as read contains it.
    local cases case_ state merge in_main want rc_want out rc
    cases=(
        "OPEN|-|-|count|0"
        "CLOSED|-|-|skip closed|0"
        "MERGED|abc|ahead|skip landed|0"
        "MERGED|abc|identical|skip landed|0"
        "MERGED|abc|behind|count|0"
        "MERGED|abc|diverged|count|0"
        "MERGED|-|-|evidence_pr_skip: MERGED with no merge commit|1"
        "MERGED||ahead|evidence_pr_skip: MERGED with no merge commit|1"
        "MERGED|abc||evidence_pr_skip: unknown compare status '' for abc|1"
        "DRAFT|-|-|evidence_pr_skip: unknown PR state 'DRAFT'|1"
    )
    for case_ in "${cases[@]}"; do
        IFS='|' read -r state merge in_main want rc_want <<<"$case_"
        rc=0
        out="$(evidence_pr_skip "$state" "$merge" "$in_main" 2>&1)" || rc=$?
        assert_equals "$rc_want $want" "$rc $out" "state=$state merge=$merge compare=$in_main"
    done
}

test_open_prs_filters_trust_and_age() {
    # Only same-repo ingest branches by the ingest identity, under the age
    # bound, count. A fork can name a branch evidence/batch/* too.
    local now prs out
    now="$(command date -u -d 2026-10-18T12:00:00Z +%s)"
    prs='[
      {"number":1,"headRefName":"evidence/batch/111","isCrossRepository":false,"author":{"login":"joshjhall"},"createdAt":"2026-10-18T11:00:00Z"},
      {"number":2,"headRefName":"evidence/batch/222","isCrossRepository":true,"author":{"login":"joshjhall"},"createdAt":"2026-10-18T11:00:00Z"},
      {"number":3,"headRefName":"evidence/batch/333","isCrossRepository":false,"author":{"login":"someone"},"createdAt":"2026-10-18T11:00:00Z"},
      {"number":4,"headRefName":"scan/rust-1.99","isCrossRepository":false,"author":{"login":"joshjhall"},"createdAt":"2026-10-18T11:00:00Z"},
      {"number":5,"headRefName":"evidence/batch/555","isCrossRepository":false,"author":{"login":"joshjhall"},"createdAt":"2026-10-16T11:00:00Z"},
      {"number":6,"headRefName":"evidence/batch/666","isCrossRepository":false,"author":{"login":"joshjhall"},"createdAt":"2026-10-18T00:30:00Z"}
    ]'
    out="$(evidence_open_prs "$now" <<<"$prs" 2>/dev/null)"
    assert_equals $'1\n6' "$out" "same-repo, ingest-authored, under 24h only"
    out="$(evidence_open_prs "$now" <<<"$prs" 2>&1 >/dev/null)"
    assert_equals "evidence_open_prs: containers-db#5 open over 24h; its rows do not count" "$out" \
        "a stale ingest PR is skipped with a warning"
}

test_open_prs_unparsable_listing_is_an_error() {
    # Without pipefail too: a jq failure must not read as "no open PRs",
    # which would re-queue every cell those PRs cover (#1319).
    local out rc=0
    out="$(
        set +o pipefail
        evidence_open_prs 0 <<<'{not json' 2>/dev/null
    )" || rc=$?
    assert_equals "1" "$rc" "an unparsable listing is exit 1"
    assert_equals "" "$out" "and prints no PR numbers"

    # Failing mid-stream: jq has already emitted "ok 1" when the null
    # createdAt aborts it. Captured output means no PR number escapes.
    rc=0
    out="$(
        set +o pipefail
        evidence_open_prs 0 2>/dev/null <<<'[
          {"number":1,"headRefName":"evidence/batch/1","isCrossRepository":false,"author":{"login":"joshjhall"},"createdAt":"1970-01-01T00:00:00Z"},
          {"number":2,"headRefName":"evidence/batch/2","isCrossRepository":false,"author":{"login":"joshjhall"},"createdAt":null}
        ]'
    )" || rc=$?
    assert_equals "1" "$rc" "a listing jq fails on partway is exit 1"
    assert_equals "" "$out" "and prints no PR numbers, not even ones before the failure"

    # An empty listing is exit 0 with no output at all (the x sentinel keeps
    # $(...) from stripping a stray blank line).
    rc=0
    out="$(
        evidence_open_prs 0 <<<'[]' || exit
        printf x
    )" || rc=$?
    assert_equals "0" "$rc" "an empty listing is exit 0"
    assert_equals "x" "$out" "and prints nothing, not even a blank line"
}

test_fully_published_coverage_exits_3() {
    # The end state #1319 is for: the backlog drains, nothing is pending.
    local r db out rc=0
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.90.0 debian-13-amd64,debian-13-arm64
    out="$(EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r" 2>/dev/null)" || rc=$?
    assert_equals "3" "$rc" "every cell published is exit 3"
    assert_equals "" "$out" "and prints no matrix"
}

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

test_recent_fail_is_not_pending() {
    # #1326: a cell that failed inside the cooldown is evidenced (failed), not
    # re-queued on every push. One day ago, against the default 7 days. The
    # timestamp carries nanoseconds, as real ingest rows do.
    local r db out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64,alpine-3.24-amd64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.90.0 "" debian-13-arm64 2026-10-20T00:00:00.123456789Z
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals $'1.90.0 alpine-3.24-amd64\n1.90.0 debian-13-amd64' "$(_cells "$out")" \
        "a recently failed cell is not pending"
}

test_only_recent_failures_exits_3() {
    # A version whose every cell recently failed has nothing pending.
    local r db out rc=0
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.90.0 "" debian-13-amd64 2026-10-20T00:00:00Z
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r" 2>/dev/null)" || rc=$?
    assert_equals "3" "$rc" "only recent failures is exit 3"
    assert_equals "" "$out" "and prints no matrix"
}

test_stale_fail_sorts_after_untested() {
    # A failure older than the cooldown is retried, but after every
    # never-tested cell, even ones at newer versions, so it cannot take cap
    # budget from untested work.
    local r db out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.80.0 debian-13-amd64
    _version "$r/catalog" 1.81.0 debian-13-amd64,debian-13-arm64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.80.0 "" debian-13-amd64 2026-10-01T00:00:00Z
    _db_version "$db" 1.81.0 "" debian-13-arm64 2026-09-01T00:00:00Z
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals $'1.81.0 debian-13-amd64\n1.80.0 debian-13-amd64\n1.81.0 debian-13-arm64' \
        "$(command jq -r '.include[] | "\(.version) \(.tuple)"' <<<"$out")" \
        "untested first, then stale-failure retries, oldest version first in each"
    assert_equals "0" "$(command jq '[.include[] | select(has("retry"))] | length' <<<"$out")" \
        "the sort key is not emitted into the matrix"

    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r" latest 1 2>/dev/null)"
    assert_equals "1.81.0 debian-13-amd64" "$(_cells "$out")" \
        "under the cap the untested newer cell beats the older failure"
}

test_newest_fail_row_decides_cooldown() {
    # Several fail rows for one cell: the newest one sets the cooldown, not
    # the last one listed. An unparsable tested_at reads as stale, never as
    # recent.
    local r db out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    command mkdir -p "$db/tools/rust/versions"
    command jq -n '{schemaVersion: 1, tool: "rust", version: "1.90.0", tested: [
        {os: "debian", os_version: "13", arch: "amd64", result: "fail", tested_at: "2026-10-19T00:00:00Z"},
        {os: "debian", os_version: "13", arch: "amd64", result: "fail", tested_at: "2026-01-01T00:00:00Z"},
        {os: "debian", os_version: "13", arch: "arm64", result: "fail", tested_at: "yesterday"}]}' \
        >"$db/tools/rust/versions/1.90.0.json"
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "1.90.0 debian-13-arm64" "$(_cells "$out")" \
        "newest fail row is recent so amd64 waits; unparsable age is retried"
}

test_offset_tested_at_decides_cooldown() {
    # #1349: a numeric-offset tested_at is converted to UTC, not read as epoch
    # 0. The cooldown edge is 2026-10-14T00:00:00Z (seven days before _NOW).
    # arm64's wall clock is inside the window but its UTC instant is outside;
    # alpine's is the reverse. Ignoring the offset, or applying it with the
    # wrong sign, flips both.
    local r db out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64,alpine-3.24-amd64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    command mkdir -p "$db/tools/rust/versions"
    command jq -n '{schemaVersion: 1, tool: "rust", version: "1.90.0", tested: [
        {os: "debian", os_version: "13", arch: "amd64", result: "fail", tested_at: "2026-10-20T00:00:00.123456789+00:00"},
        {os: "debian", os_version: "13", arch: "arm64", result: "fail", tested_at: "2026-10-14T01:00:00+02:00"},
        {os: "alpine", os_version: "3.24", arch: "amd64", result: "fail", tested_at: "2026-10-13T20:00:00-05:00"}]}' \
        >"$db/tools/rust/versions/1.90.0.json"
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "1.90.0 debian-13-arm64" "$(_cells "$out")" \
        "+00:00 and -05:00 failures inside the window wait; +02:00 one outside it is retried"
}

test_near_miss_tested_at_is_stale() {
    # #1349: forms the parse rejects read as epoch 0 (stale, retried), never
    # as a recent failure. Each wall clock is one day before _NOW, so a parser
    # that loosened to accept it would hide the cell. -99:59 would otherwise
    # land four days in the future and hold the cooldown past its window.
    local r db out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64,alpine-3.24-amd64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    command mkdir -p "$db/tools/rust/versions"
    command jq -n '{schemaVersion: 1, tool: "rust", version: "1.90.0", tested: [
        {os: "debian", os_version: "13", arch: "amd64", result: "fail", tested_at: "2026-10-20T00:00:00+0200"},
        {os: "debian", os_version: "13", arch: "arm64", result: "fail", tested_at: "2026-10-20T00:00:00z"},
        {os: "alpine", os_version: "3.24", arch: "amd64", result: "fail", tested_at: "2026-10-20T00:00:00-99:59"}]}' \
        >"$db/tools/rust/versions/1.90.0.json"
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals $'1.90.0 alpine-3.24-amd64\n1.90.0 debian-13-amd64\n1.90.0 debian-13-arm64' "$(_cells "$out")" \
        "+HHMM, lowercase z, and an out-of-range offset are stale, so all three retry"
}

test_offset_range_boundaries() {
    # #1349: real offsets span -12:00..+14:00. Each row's UTC instant is one
    # day before _NOW, so a parsed row waits out the cooldown and an
    # unparsable one (epoch 0) retries. The minute clause is driven alone by
    # +05:60, whose hour is in range.
    local r db out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64,alpine-3.24-amd64
    _version "$r/catalog" 1.91.0 debian-13-amd64,debian-13-arm64,alpine-3.24-amd64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    command mkdir -p "$db/tools/rust/versions"
    command jq -n '{schemaVersion: 1, tool: "rust", version: "1.90.0", tested: [
        {os: "debian", os_version: "13", arch: "amd64", result: "fail", tested_at: "2026-10-20T14:00:00+14:00"},
        {os: "debian", os_version: "13", arch: "arm64", result: "fail", tested_at: "2026-10-19T12:00:00-12:00"},
        {os: "alpine", os_version: "3.24", arch: "amd64", result: "fail", tested_at: "2026-10-20T14:01:00+14:01"}]}' \
        >"$db/tools/rust/versions/1.90.0.json"
    command jq -n '{schemaVersion: 1, tool: "rust", version: "1.91.0", tested: [
        {os: "debian", os_version: "13", arch: "amd64", result: "fail", tested_at: "2026-10-19T11:59:00-12:01"},
        {os: "debian", os_version: "13", arch: "arm64", result: "fail", tested_at: "2026-10-20T06:00:00+05:60"},
        {os: "alpine", os_version: "3.24", arch: "amd64", result: "fail", tested_at: "2026-10-20T15:00:00+15:00"}]}' \
        >"$db/tools/rust/versions/1.91.0.json"
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals $'1.90.0 alpine-3.24-amd64\n1.91.0 alpine-3.24-amd64\n1.91.0 debian-13-amd64\n1.91.0 debian-13-arm64' "$(_cells "$out")" \
        "+14:00 and -12:00 parse; +14:01, -12:01, +05:60 and +15:00 are stale"
}

test_offset_minutes_and_calendar_validity() {
    # #1349: an in-range non-zero-minute offset is applied to the minute. Each
    # row sits just past the cooldown edge (2026-10-14T00:00:00Z) only when
    # its minutes count: +05:30 is 2026-10-13T23:50Z, -09:30 is
    # 2026-10-13T23:45Z. Dropping the minute term moves both inside the
    # window. A calendar-impossible base reads as stale, not as the date libc
    # normalizes it to: 23:59:60 would roll into a recent 2026-10-20.
    local r db out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64,alpine-3.24-amd64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    command mkdir -p "$db/tools/rust/versions"
    command jq -n '{schemaVersion: 1, tool: "rust", version: "1.90.0", tested: [
        {os: "debian", os_version: "13", arch: "amd64", result: "fail", tested_at: "2026-10-14T05:20:00+05:30"},
        {os: "debian", os_version: "13", arch: "arm64", result: "fail", tested_at: "2026-10-13T14:15:00-09:30"},
        {os: "alpine", os_version: "3.24", arch: "amd64", result: "fail", tested_at: "2026-10-19T23:59:60Z"}]}' \
        >"$db/tools/rust/versions/1.90.0.json"
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals $'1.90.0 alpine-3.24-amd64\n1.90.0 debian-13-amd64\n1.90.0 debian-13-arm64' "$(_cells "$out")" \
        "minute offsets land just outside the window; an impossible date is stale"

    command jq -n '{schemaVersion: 1, tool: "rust", version: "1.90.0", tested: [
        {os: "debian", os_version: "13", arch: "amd64", result: "fail", tested_at: "2026-10-14T05:40:00+05:30"},
        {os: "alpine", os_version: "3.24", arch: "amd64", result: "fail", tested_at: "2026-10-19T00:00:00Z"}]}' \
        >"$db/tools/rust/versions/1.90.0.json"
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "1.90.0 debian-13-arm64" "$(_cells "$out")" \
        "ten minutes later +05:30 is inside the window, and a real date still waits"
}

test_future_fail_is_retried() {
    # #1356: a fail stamped past now + 300 s skew reads as stale, so it is
    # retried (last), not held until the date arrives. Two minutes ahead is
    # skew, and still inside the cooldown.
    local r db out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64,alpine-3.24-amd64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    command mkdir -p "$db/tools/rust/versions"
    command jq -n '{schemaVersion: 1, tool: "rust", version: "1.90.0", tested: [
        {os: "debian", os_version: "13", arch: "amd64", result: "fail", tested_at: "2030-01-01T00:00:00Z"},
        {os: "debian", os_version: "13", arch: "arm64", result: "fail", tested_at: "2026-10-21T00:02:00Z"}]}' \
        >"$db/tools/rust/versions/1.90.0.json"
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "alpine-3.24-amd64|debian-13-amd64" "$(command jq -r '[.include[].tuple] | join("|")' <<<"$out")" \
        "the future fail is retried after the untested cell; the skewed one waits"
}

test_pass_beats_recent_fail() {
    local r db out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.90.0 debian-13-amd64 debian-13-amd64 2026-10-20T00:00:00Z
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_FAIL_COOLDOWN_DAYS=0 EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "1.90.0 debian-13-arm64" "$(_cells "$out")" \
        "a passing row excludes the cell whatever its fail rows say"
}

test_fail_cooldown_override() {
    local r db out rc=0
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.90.0 "" debian-13-amd64 2026-10-18T00:00:00Z
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_FAIL_COOLDOWN_DAYS=2 EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "1.90.0 debian-13-amd64" "$(_cells "$out")" \
        "a three-day-old failure is retried under a two-day cooldown"
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_FAIL_COOLDOWN_DAYS=4 EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r" 2>/dev/null)" || rc=$?
    assert_equals "3" "$rc" "and waits under a four-day one"
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_FAIL_COOLDOWN_DAYS=3 EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "1.90.0 debian-13-amd64" "$(_cells "$out")" \
        "a failure exactly one cooldown old is retried"
    rc=0
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_FAIL_COOLDOWN_DAYS=08 EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r" 2>/dev/null)" || rc=$?
    assert_equals "3" "$rc" "a leading-zero cooldown (08) is decimal, not an octal error"

    rc=0
    out="$(EVIDENCE_FAIL_COOLDOWN_DAYS=7d EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r" 2>/dev/null)" || rc=$?
    assert_equals "1" "$rc" "a non-integer cooldown is an error"
    assert_equals "" "$out" "and prints no matrix"
    rc=0
    out="$(EVIDENCE_NOW=abc EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r" 2>/dev/null)" || rc=$?
    assert_equals "1" "$rc" "a non-integer EVIDENCE_NOW is an error"
    assert_equals "" "$out" "and prints no matrix"

    # A value that would overflow the 64-bit product (and wrap the cooldown
    # negative, re-queuing every failure) is refused, not silently disabled.
    rc=0
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_FAIL_COOLDOWN_DAYS=999999999999999 EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r" 2>/dev/null)" || rc=$?
    assert_equals "1" "$rc" "an overflowing cooldown is an error"
    assert_equals "" "$out" "and prints no matrix"
    rc=0
    out="$(EVIDENCE_NOW=99999999999999999999 EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r" 2>/dev/null)" || rc=$?
    assert_equals "1" "$rc" "an overflowing EVIDENCE_NOW is an error"
    # #1403: the 12-digit cap is the boundary, not just a guard on huge values.
    rc=0
    out="$(EVIDENCE_NOW=1792540800000 EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r" 2>/dev/null)" || rc=$?
    assert_equals "1" "$rc" "a 13-digit EVIDENCE_NOW is an error"
    assert_equals "" "$out" "and prints no matrix"
    rc=0
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_FAIL_COOLDOWN_DAYS=999999 EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r" 2>/dev/null)" || rc=$?
    assert_equals "3" "$rc" "the largest accepted cooldown still keeps the failure out"
}

test_vendored_recent_fail_is_not_pending() {
    # The policy applies to the vendored tested[] too (no source set).
    local r out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64
    command jq '.tested = [{os: "debian", os_version: "13", arch: "arm64", result: "fail",
                            tested_at: "2026-10-20T00:00:00Z"}]' \
        "$r/catalog/tools/rust/versions/1.90.0.json" >"$r/v.json"
    command mv "$r/v.json" "$r/catalog/tools/rust/versions/1.90.0.json"
    out="$(EVIDENCE_NOW="$_NOW" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "1.90.0 debian-13-amd64" "$(_cells "$out")" \
        "a recent vendored fail row keeps its cell out"
}

test_vendored_future_fail_is_retried() {
    # #1391: the #1356 future-dated fail retry, read from the vendored tested[]
    # (no source set) rather than published evidence — same expected order.
    local r out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64,alpine-3.24-amd64
    command jq '.tested = [
        {os: "debian", os_version: "13", arch: "amd64", result: "fail", tested_at: "2030-01-01T00:00:00Z"},
        {os: "debian", os_version: "13", arch: "arm64", result: "fail", tested_at: "2026-10-21T00:02:00Z"}]' \
        "$r/catalog/tools/rust/versions/1.90.0.json" >"$r/v.json"
    command mv "$r/v.json" "$r/catalog/tools/rust/versions/1.90.0.json"
    out="$(EVIDENCE_NOW="$_NOW" evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "alpine-3.24-amd64|debian-13-amd64" "$(command jq -r '[.include[].tuple] | join("|")' <<<"$out")" \
        "a future vendored fail is retried after the untested cell; the skewed one waits"
    # #1403: a zero-padded EVIDENCE_NOW is decimal (10#), not an octal error.
    out="$(EVIDENCE_NOW=001792540800 evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "alpine-3.24-amd64|debian-13-amd64" "$(command jq -r '[.include[].tuple] | join("|")' <<<"$out")" \
        "a zero-padded EVIDENCE_NOW yields the same matrix as the unpadded one"
}

test_missing_index_is_an_error() {
    local rc=0
    evidence_matrix "$TEST_TEMP_DIR/nope" rust "$TEST_TEMP_DIR" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "a missing index is exit 1, not an empty matrix"
}

run_test test_newest_patch_per_minor_from_floor "newest patch per minor from the floor (numeric)"
run_test test_claims_intersect_base_images "claims intersect available base images"
run_test test_covered_cells_are_not_pending "covered cells are not re-run"
run_test test_nothing_pending_exits_3_with_no_output "nothing pending exits 3 with no output"
run_test test_cap_takes_oldest_first "cap keeps the oldest pending cells"
run_test test_cells_carry_arch_plumbing "cells carry arch plumbing"
run_test test_unpublished_tuples_are_not_available "tuples absent from the root tree are not offered"
run_test test_unpublished_images_are_skipped "unpublished images are skipped when a check is set"
run_test test_published_evidence_decides_pending "published evidence decides pending-ness"
run_test test_published_source_overrides_vendored_tested "published source overrides vendored tested[]"
run_test test_version_missing_from_published_is_pending "a version absent from published evidence is pending"
run_test test_open_ingest_pr_rows_count_as_covered "open ingest PR rows count as covered"
run_test test_pr_rows_drop_inherited_rows "an open PR counts only the rows it adds, not main's stale ones"
run_test test_pr_rows_new_file_and_untouched_tool "PR rows: new files count whole, untouched tools are absent"
run_test test_pr_rows_changed_row_counts "PR rows: a rewritten row counts as the PR's"
run_test test_pr_rows_unreadable_is_an_error "PR rows: an unreadable side is an error"
run_test test_pr_rows_head_without_rows_writes_nothing "PR rows: a head file with no or empty tested[] writes nothing"
run_test test_pr_rows_head_dropping_a_row_writes_nothing "PR rows: a head that drops a base row writes nothing"
run_test test_pr_skip_decision "open evidence PRs: skip decision per state and compare status"
run_test test_open_prs_filters_trust_and_age "open evidence PRs: trust and age filter"
run_test test_open_prs_unparsable_listing_is_an_error "open evidence PRs: unparsable listing is an error"
run_test test_fully_published_coverage_exits_3 "full published coverage exits 3"
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
run_test test_recent_fail_is_not_pending "a recently failed cell is not pending"
run_test test_only_recent_failures_exits_3 "only recent failures exits 3"
run_test test_stale_fail_sorts_after_untested "stale failures retry after never-tested cells"
run_test test_newest_fail_row_decides_cooldown "the newest fail row decides the cooldown"
run_test test_future_fail_is_retried "a future-dated fail is retried, not held"
run_test test_offset_tested_at_decides_cooldown "a numeric-offset tested_at is converted to UTC for the cooldown"
run_test test_near_miss_tested_at_is_stale "near-miss tested_at forms read as stale failures"
run_test test_offset_range_boundaries "offsets parse only within -12:00..+14:00"
run_test test_offset_minutes_and_calendar_validity "minute offsets apply exactly; impossible dates are stale"
run_test test_pass_beats_recent_fail "a pass row beats a recent fail row"
run_test test_fail_cooldown_override "EVIDENCE_FAIL_COOLDOWN_DAYS overrides the cooldown"
run_test test_vendored_recent_fail_is_not_pending "the cooldown applies to vendored tested[]"
run_test test_vendored_future_fail_is_retried "a future-dated vendored fail is retried, not held"
run_test test_missing_index_is_an_error "missing index is an error"

generate_report
