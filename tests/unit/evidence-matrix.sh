#!/usr/bin/env bash
# Unit tests: bin/lib/evidence-matrix.sh builds the push-triggered evidence
# matrix from the catalog (#1111) — newest patch per minor from the floor up,
# claimed ∩ base-image tuples, pending cells only, capped under GitHub's 256.
#
# Hermetic: a synthetic catalog + base-images tree per test, with exact
# expected cells (not substring checks), so a wrong-but-plausible matrix fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Evidence matrix (catalog-derived)"

# shellcheck source=bin/lib/evidence-matrix.sh
source "$PROJECT_ROOT/bin/lib/evidence-matrix.sh"
# Tests that rely on the vendored tested[] path must not inherit a source.
unset EVIDENCE_TESTED_SOURCE EVIDENCE_PUBLISHED_CHECK

# _version <dir> <version> <tuples-csv> [passing-tuple]
# One version file claiming each `os-osv-arch` in tuples-csv supported, with an
# optional passing evidence row for passing-tuple.
_version() {
    local dir="$1" v="$2" tuples="$3" pass="${4:-}"
    command jq -n --arg v "$v" --arg t "$tuples" --arg p "$pass" '
        def cell: split("-") as $x | {os: $x[0], os_version: $x[1], arch: $x[2]};
        {schemaVersion: 1, tool: "rust", version: $v,
         support_matrix: [ $t | split(",")[] | cell + {status: "supported"} ],
         tested: (if $p == "" then [] else [ ($p | cell) + {tested_at: "2026-10-01T00:00:00Z", result: "pass"} ] end)}
    ' >"$dir/tools/rust/versions/$v.json"
}

# _fixture <floor> — fresh catalog + base-images root; echoes its path.
_fixture() {
    local root
    root="$(command mktemp -d "$TEST_TEMP_DIR/em.XXXXXX")"
    command mkdir -p "$root/catalog/tools/rust/versions"
    command printf '{"id":"rust","minimum_recommended":"%s"}\n' "$1" >"$root/catalog/tools/rust/index.json"
    local t
    for t in debian/13/amd64 debian/13/arm64 alpine/3.24/amd64; do
        command mkdir -p "$root/base-images/$t"
        command touch "$root/base-images/$t/Dockerfile"
    done
    command echo "$root"
}

# _cells <matrix-json> — "version tuple" per cell, sorted.
_cells() {
    command jq -r '.include[] | "\(.version) \(.tuple)"' <<<"$1" | command sort
}

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

# _db_version <db_root> <version> <pass-csv> [fail-csv] [failed-at] — a published
# containers-db version file with a passing row per pass-csv tuple and a
# failing row per fail-csv tuple. failed-at (ISO 8601) stamps the fail rows'
# tested_at; without it they carry none, which reads as a stale failure.
_db_version() {
    local db="$1" v="$2" pass="$3" fail="${4:-}" at="${5:-}"
    command mkdir -p "$db/tools/rust/versions"
    command jq -n --arg v "$v" --arg p "$pass" --arg f "$fail" --arg at "$at" '
        def cell: split("-") as $x | {os: $x[0], os_version: $x[1], arch: $x[2]};
        def rows($csv; $r): $csv | select(. != "") | split(",")[] | cell + {result: $r};
        def stamp: if $at == "" then . else . + {tested_at: $at} end;
        {schemaVersion: 1, tool: "rust", version: $v,
         tested: [ rows($p; "pass"), (rows($f; "fail") | stamp) ]}
    ' >"$db/tools/rust/versions/$v.json"
}

# Fixed clock for the fail-cooldown tests: 2026-10-21T00:00:00Z.
_NOW=1792540800

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
    local r db out rc=0
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64
    out="$(EVIDENCE_TESTED_SOURCE="$TEST_TEMP_DIR/no-such-db" evidence_matrix "$r/catalog" rust "$r" 2>/dev/null)" || rc=$?
    assert_equals "1" "$rc" "a missing source is exit 1"
    assert_equals "" "$out" "and prints no matrix"

    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    command mkdir -p "$db/tools/rust/versions"
    command echo '{not json' >"$db/tools/rust/versions/1.90.0.json"
    rc=0
    out="$(EVIDENCE_TESTED_SOURCE="$db" evidence_matrix "$r/catalog" rust "$r" 2>/dev/null)" || rc=$?
    assert_equals "1" "$rc" "an unparsable source is exit 1"
    assert_equals "" "$out" "and prints no matrix"
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

test_missing_index_is_an_error() {
    local rc=0
    evidence_matrix "$TEST_TEMP_DIR/nope" rust "$TEST_TEMP_DIR" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "a missing index is exit 1, not an empty matrix"
}

test_real_catalog_respects_github_cap() {
    # The shipped catalog against the real base-images tree: whatever is
    # pending, one run never exceeds GitHub's 256-job matrix limit.
    local out rc=0 n=0
    out="$(evidence_matrix "$PROJECT_ROOT/crates/luggage/testdata/catalog" rust "$PROJECT_ROOT" 2>/dev/null)" || rc=$?
    if [ "$rc" -eq 3 ]; then
        assert_true true "nothing pending in the shipped catalog"
        return
    fi
    assert_equals "0" "$rc" "the shipped catalog yields a matrix"
    n="$(command jq '.include | length' <<<"$out")"
    if [ "$n" -gt 0 ] && [ "$n" -le 256 ]; then
        assert_true true "$n cells, within GitHub's 256 cap"
    else
        assert_true false "matrix has $n cells; must be 1..256"
    fi
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
run_test test_open_prs_filters_trust_and_age "open evidence PRs: trust and age filter"
run_test test_open_prs_unparsable_listing_is_an_error "open evidence PRs: unparsable listing is an error"
run_test test_fully_published_coverage_exits_3 "full published coverage exits 3"
run_test test_unreadable_published_source_is_an_error "an unreadable evidence source is an error, not a full matrix"
run_test test_recent_fail_is_not_pending "a recently failed cell is not pending"
run_test test_only_recent_failures_exits_3 "only recent failures exits 3"
run_test test_stale_fail_sorts_after_untested "stale failures retry after never-tested cells"
run_test test_newest_fail_row_decides_cooldown "the newest fail row decides the cooldown"
run_test test_offset_tested_at_decides_cooldown "a numeric-offset tested_at is converted to UTC for the cooldown"
run_test test_near_miss_tested_at_is_stale "near-miss tested_at forms read as stale failures"
run_test test_pass_beats_recent_fail "a pass row beats a recent fail row"
run_test test_fail_cooldown_override "EVIDENCE_FAIL_COOLDOWN_DAYS overrides the cooldown"
run_test test_vendored_recent_fail_is_not_pending "the cooldown applies to vendored tested[]"
run_test test_missing_index_is_an_error "missing index is an error"
run_test test_real_catalog_respects_github_cap "shipped catalog stays within GitHub's 256 cap"

generate_report
