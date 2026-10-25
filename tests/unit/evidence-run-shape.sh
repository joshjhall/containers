#!/usr/bin/env bash
# Unit tests: evidence-run.yml keeps the batched-ingest shape.
#
# Before batching, each evidence cell opened its own containers-db PR and its
# own tracking issue, so one push produced up to 200 PRs (conflicting on
# shared version files) and dozens of duplicate issues, and cells read
# containers-db main, which raced DB changes that needed a matching luggage
# change. These checks fail if any of that comes back.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "evidence-run.yml batched-ingest shape"

WF="$PROJECT_ROOT/.github/workflows/evidence-run.yml"

# _job_block <job> — the YAML of one top-level job (from its key to the next).
_job_block() {
    /usr/bin/awk -v job="$1" '
        $0 ~ "^  " job ":$" { on = 1; print; next }
        on && /^  [a-z_-]+:$/ { exit }
        on { print }
    ' "$WF"
}

test_cells_install_as_the_container_user() {
    # Evidence must take the run-as-user path real containers take
    # (lib/features/rust.sh passes --user): installing as root hid an Alpine
    # post-install PATH bug while every Alpine cell passed (#1165).
    local cell
    cell="$(_job_block evidence | /usr/bin/grep -vE '^[[:space:]]*#')"
    if /usr/bin/grep -qE 'luggage install .*--user runner' <<<"$cell"; then
        assert_true true "luggage install runs with --user runner"
    else
        assert_true false "evidence luggage install must pass --user runner"
    fi
}

test_cells_open_no_prs_or_issues() {
    local cell
    # Comment lines excluded: prose may mention the scripts it no longer runs.
    cell="$(_job_block evidence | /usr/bin/grep -vE '^[[:space:]]*#')"
    if /usr/bin/grep -qE 'ingest-evidence(-batch)?\.sh|gh pr create|open_or_update_tracking_issue|open_run_tracking_issue' <<<"$cell"; then
        assert_true false "the evidence (cell) job must not ingest or file issues; that is the collect job's"
    else
        assert_true true "cells only record and upload"
    fi
}

test_collect_job_batches_into_one_pr() {
    local collect
    collect="$(_job_block collect)"
    assert_contains "$collect" "ingest-evidence-batch.sh" "collect ingests the whole run in one batch"
    assert_contains "$collect" "open_run_tracking_issue" "collect files one issue per run"
    assert_contains "$collect" "always()" "collect runs even when some cells failed"
}

test_artifact_name_is_per_cell() {
    # Per-tuple names collided once a tuple had many versions.
    assert_file_contains "$WF" 'name: evidence-row-${{ matrix.tool }}-${{ matrix.version }}-${{ matrix.tuple }}' \
        "artifact name includes tool, version, and tuple"
}

# _db_sources_run — the executable lines of the "Collect open evidence PRs"
# step's run: block (comments dropped, so prose cannot satisfy a pin).
_db_sources_run() {
    /usr/bin/awk '
        /- name: Collect open evidence PRs/ { on = 1; next }
        on && /- name: / { exit }
        on { print }
    ' "$WF" | /usr/bin/grep -vE '^[[:space:]]*#'
}

# _db_sources_fn — the executable lines of evidence_db_sources, which holds
# the step's logic since #1328 (its behavior is unit-tested in
# tests/unit/bin/lib/evidence-sources.sh; these pins keep its shape).
_db_sources_fn() {
    /usr/bin/awk '/^evidence_db_sources\(\) \{/ { on = 1 } on { print } on && /^\}$/ { exit }' \
        "$PROJECT_ROOT/bin/lib/evidence-sources.sh" | /usr/bin/grep -vE '^[[:space:]]*#'
}

test_open_pr_sources_step_calls_the_lib() {
    # The step is a call, so the fail-closed guards stay where tests reach them.
    local run
    run="$(_db_sources_run)"
    assert_contains "$run" 'source bin/lib/evidence-sources.sh' "the step sources the lib"
    assert_contains "$run" 'SOURCES=$(evidence_db_sources "$PWD/_db" "$PWD" "$(date -u +%s)")' \
        "and resolves its sources through evidence_db_sources"
    assert_not_contains "$run" 'gh pr list' "no inline listing is left in the step"
}

test_open_pr_sources_count_only_added_rows() {
    # #1327: an open PR's whole head tree re-asserted rows main had since
    # revoked; only the rows it adds over its merge-base may count.
    local fn
    fn="$(_db_sources_fn)"
    assert_contains "$fn" 'evidence_pr_rows "$work/_db_pr/$n/base" "$work/_db_pr/$n/head" "$work/_db_pr/$n/rows"' \
        "each PR is reduced to its added rows, base before head"
    assert_contains "$fn" 'sources="$sources:$work/_db_pr/$n/rows"' "the rows tree joins the sources"
    assert_not_contains "$fn" 'sources="$sources:$work/_db_pr/$n/head"' "the head tree itself never joins them"
}

test_open_pr_sources_pin_the_main_read() {
    # Merge-bases and the merged check use the fetched main SHA, not the
    # moving ref, or a PR that merges mid-step lands in neither source.
    local fn
    fn="$(_db_sources_fn)"
    assert_contains "$fn" 'main_sha="$(command git -C "$db" rev-parse HEAD)"' "the main read's SHA is captured"
    assert_contains "$fn" 'compare/$main_sha...$head_sha' "the merge-base is taken against it"
    assert_contains "$fn" 'compare/$merge...$main_sha' "the merged check is too"
    assert_not_contains "$fn" 'compare/main...' "never against live main"
}

test_open_pr_sources_skip_via_the_decision() {
    # The skip rules themselves are evidence_pr_skip's, behavior-tested in
    # tests/unit/bin/lib/evidence-matrix.sh (#1446). Here: the loop asks it,
    # after the head fetch, with the re-read state.
    local fn fetch_line state_line skip_line
    fn="$(_db_sources_fn)"
    assert_contains "$fn" '--json state,mergeCommit' "each PR's state is re-read"
    assert_contains "$fn" 'verdict="$(evidence_pr_skip "$state" "$merge" "$in_main")" || return 1' \
        "the skip decision is evidence_pr_skip's, and its failure is fatal"
    fetch_line="$(/usr/bin/grep -n 'refs/pull/$n/head' <<<"$fn" | /usr/bin/cut -d: -f1)"
    state_line="$(/usr/bin/grep -n 'json state,mergeCommit' <<<"$fn" | /usr/bin/cut -d: -f1)"
    skip_line="$(/usr/bin/grep -n 'evidence_pr_skip "' <<<"$fn" | /usr/bin/cut -d: -f1)"
    assert_true "[ ${fetch_line:-0} -gt 0 ] && [ ${state_line:-0} -gt ${fetch_line:-0} ] && [ ${skip_line:-0} -gt ${state_line:-0} ]" \
        "the state is read after the head fetch, and decided on after that"
}

test_cells_install_from_the_vendored_catalog() {
    local cell
    cell="$(_job_block evidence)"
    assert_contains "$cell" 'crates/luggage/testdata/catalog:/catalog:ro' \
        "cells install against the catalog luggage was built with"
    if /usr/bin/grep -q 'clone.*containers-db' <<<"$cell"; then
        assert_true false "cells must not clone containers-db (races DB changes against luggage)"
    else
        assert_true true "cells do not read containers-db main"
    fi
}

# _trigger_paths <event> [workflow] — the `paths:` entries of one `on:` trigger
# (in $WF by default), unquoted. The trigger key is matched only inside the
# column-0 `on:` block, so a same-named job id is never read as one. The
# trigger ends at its next sibling trigger or at any column-0 key, so the last
# trigger never reads on into `permissions:`/`env:`/`jobs:`. Comment and blank
# lines inside the list are skipped; any other line before the list dedents
# prints `UNPARSED: <line>`, which the caller fails on, so an entry (in
# particular a `!` exclusion) can never be dropped silently. The `on:`,
# trigger, and `paths:` keys may carry trailing blanks or a comment. Any other
# text after the trigger or `paths:` key (flow style) is UNPARSED too, as is a
# compact `    - ` entry. Shapes outside that (an inline `on:` value, another
# indent width) yield no entries, which the caller also fails on.
_trigger_paths() {
    /usr/bin/awk -v ev="$1" '
        /^on:[[:space:]]*(#.*)?$/ { inon = 1; next }
        !on && /^[^[:space:]#]/ { inon = 0 }
        inon && !on && $0 ~ ("^  " ev ":[[:space:]]*(#.*)?$") { on = 1; next }
        inon && !on && $0 ~ ("^  " ev ":") { print "UNPARSED: " $0; exit }
        on && /^[^[:space:]#]/ { exit }
        on && /^  [A-Za-z0-9_-]+:/ { exit }
        on && /^    paths:[[:space:]]*(#.*)?$/ { inpaths = 1; next }
        on && /^    paths:/ { print "UNPARSED: " $0; next }
        on && inpaths && /^[[:space:]]*(#.*)?$/ { next }
        on && inpaths && /^      - "[^"]*"$/ { sub(/^      - "/, ""); sub(/"$/, ""); print; next }
        on && inpaths && /^      / { print "UNPARSED: " $0; next }
        on && inpaths && /^    -( |$)/ { print "UNPARSED: " $0; next }
        on && inpaths { inpaths = 0 }
    ' "${2:-$WF}"
}

# _filter_glob_ere <glob> — a GitHub paths: glob as an anchored ERE. Unlike a
# bash glob, a single `*` does not cross `/` there (only `**` does), so a bash
# `[[ == ]]` match would accept `bin/*.sh` for bin/lib/evidence-x.sh even
# though GitHub would not trigger on it. Other metacharacters are taken
# literally: an unsupported pattern then fails to match, never over-matches.
_filter_glob_ere() {
    local g="$1" out="" c i
    for ((i = 0; i < ${#g}; i++)); do
        c="${g:i:1}"
        case "$c" in
            '*')
                if [ "${g:i+1:1}" = '*' ]; then
                    out+='.*'
                    i=$((i + 1))
                else
                    out+='[^/]*'
                fi
                ;;
            '.' | '?' | '+' | '^' | '$' | '(' | ')' | '|' | '{' | '}' | '[' | ']' | '\') out+="\\$c" ;;
            *) out+="$c" ;;
        esac
    done
    printf '^%s$' "$out"
}

# _covered <file> <pattern>... — whether GitHub's paths: filter matches <file>.
# Entries apply in order and the last match wins, so a `!` entry excludes
# what an earlier entry included.
_covered() {
    local f="$1" p hit=1
    shift
    for p in "$@"; do
        if [ "${p:0:1}" = '!' ]; then
            [[ "$f" =~ $(_filter_glob_ere "${p:1}") ]] && hit=1
        else
            [[ "$f" =~ $(_filter_glob_ere "$p") ]] && hit=0
        fi
    done
    return "$hit"
}

test_trigger_paths_cover_evidence_scripts() {
    # Every bin/lib/evidence-*.sh lib and bin/ingest-evidence*.sh script must
    # re-trigger the workflow, or a change confined to it first runs on some
    # unrelated push to main (#1388). The set comes from disk, so a new file
    # under those names is checked without editing this test; a helper the
    # jobs source under some OTHER name is not.
    local ev f p unparsed
    local -a scripts=() patterns
    # An unmatched glob stays literal and would match its own trigger entry,
    # so keep only real files and fail on an empty set.
    for f in "$PROJECT_ROOT"/bin/lib/evidence-*.sh "$PROJECT_ROOT"/bin/ingest-evidence*.sh; do
        [ -f "$f" ] && scripts+=("${f#"$PROJECT_ROOT"/}")
    done
    if [ "${#scripts[@]}" -eq 0 ]; then
        assert_true false "no evidence libs or ingest scripts found to check"
        return
    fi
    for ev in pull_request push; do
        mapfile -t patterns < <(_trigger_paths "$ev")
        if [ "${#patterns[@]}" -eq 0 ]; then
            assert_true false "$ev has no paths: entries to check"
            continue
        fi
        unparsed=""
        for p in "${patterns[@]}"; do
            [ "${p#UNPARSED: }" != "$p" ] && unparsed="$p"
        done
        if [ -n "$unparsed" ]; then
            assert_true false "$ev paths: entry not of the form - \"glob\": ${unparsed#UNPARSED: }"
            continue
        fi
        for f in "${scripts[@]}"; do
            if _covered "$f" "${patterns[@]}"; then
                assert_true true "$ev paths: cover $f"
            else
                assert_true false "$ev paths: cover $f"
            fi
        done
    done
}

test_trigger_paths_parser_fixtures() {
    # The real workflow is well-formed, so none of _trigger_paths' fail-closed
    # branches fire against it (#1392). Each fixture pins one branch by the
    # parser's full output, so dropping a rule changes what it prints.
    local dir
    if ! dir=$(command mktemp -d "${TMPDIR:-/tmp}/evidence-run-shape.XXXXXX"); then
        assert_true false "mktemp failed under ${TMPDIR:-/tmp}"
        return
    fi

    printf '%s\n' 'on:' '# column-0 note' '  push:' '    paths:' '      - "a"' \
        '      # note' '' '# column-0 note' '      - "b"' 'jobs:' >"$dir/comments.yml"
    _expect_trigger_paths "comment and blank lines are skipped, neighbours kept" \
        push "$dir/comments.yml" 'a' 'b'

    printf '%s\n' 'on:' '  push:' '    paths:' '      - "a"' '      # exclude:' \
        '      - "!b"' 'jobs:' >"$dir/bang.yml"
    _expect_trigger_paths "a ! entry after a comment is read" \
        push "$dir/bang.yml" 'a' '!b'

    printf '%s\n' 'on:' '  push:' '    paths:' "      - 'single'" \
        '      - "trailing" # why' '      - unquoted' '      - "z"' 'jobs:' >"$dir/unparsed.yml"
    _expect_trigger_paths "single-quoted, trailing-comment, unquoted entries are UNPARSED" \
        push "$dir/unparsed.yml" \
        "UNPARSED:       - 'single'" \
        'UNPARSED:       - "trailing" # why' \
        'UNPARSED:       - unquoted' \
        'z'

    printf '%s\n' 'on:' '  push:' '    branches: [main]' 'jobs:' >"$dir/nopaths.yml"
    _expect_trigger_paths "a trigger with no paths: yields nothing" \
        push "$dir/nopaths.yml"

    # push is the last trigger: before the column-0 exit its scan ran on into
    # the top-level keys, and an indented paths: there was read as its own.
    printf '%s\n' 'on:' '  pull_request:' '    paths:' '      - "pr"' '  push:' \
        '    paths:' '      - "p"' 'permissions:' '    paths:' '      - "leak"' \
        >"$dir/col0.yml"
    _expect_trigger_paths "the last trigger stops at the first column-0 key" \
        push "$dir/col0.yml" 'p'

    printf '%s\n' 'on:' '  push:' '    paths:' '      - "p"' '  merge-group2:' \
        '    paths:' '      - "leak"' 'jobs:' >"$dir/sibling.yml"
    _expect_trigger_paths "a sibling trigger with - and digits ends the block" \
        push "$dir/sibling.yml" 'p'

    printf '%s\n' 'on:' '  push:' '    paths:' '      - "p"' '  workflow_run: # note' \
        '    paths:' '      - "leak"' 'jobs:' >"$dir/sibling-tail.yml"
    _expect_trigger_paths "a sibling trigger with text after its colon ends the block" \
        push "$dir/sibling-tail.yml" 'p'

    printf '%s\n' 'on:' '  push:' '    paths:' '      - "a"' '    branches:' \
        '      - "main"' 'jobs:' >"$dir/dedent.yml"
    _expect_trigger_paths "the paths list ends at the next key under the trigger" \
        push "$dir/dedent.yml" 'a'

    printf '%s\n' 'on: [workflow_dispatch]' 'jobs:' '  push:' '    paths:' \
        '      - "leak"' >"$dir/job-named-push.yml"
    _expect_trigger_paths "a job named like the trigger outside on: is not read" \
        push "$dir/job-named-push.yml"

    printf '%s\n' 'on:' '  pull_request:' '    paths:' '      - "pr"' 'jobs:' '  push:' \
        '    paths:' '      - "leak"' >"$dir/job-after-on.yml"
    _expect_trigger_paths "the on: block ends at the next column-0 key" \
        push "$dir/job-after-on.yml"

    printf '%s\n' 'on: # c' '  push: # note' '    paths: # why' '      - "a"' 'jobs:' \
        >"$dir/key-comments.yml"
    _expect_trigger_paths "start keys may carry a trailing comment" \
        push "$dir/key-comments.yml" 'a'

    printf '%s\n' 'on:  ' '  push:   ' '    paths: ' '      - "a"' 'jobs:' >"$dir/key-blanks.yml"
    _expect_trigger_paths "start keys may carry trailing blanks" \
        push "$dir/key-blanks.yml" 'a'

    printf '%s\n' 'on:' '  push: {paths: ["a"]}' 'jobs:' >"$dir/flow-trigger.yml"
    _expect_trigger_paths "a flow-style trigger is UNPARSED" \
        push "$dir/flow-trigger.yml" 'UNPARSED:   push: {paths: ["a"]}'

    printf '%s\n' 'on:' '  push:' '    paths: ["a"]' 'jobs:' >"$dir/flow-paths.yml"
    _expect_trigger_paths "a flow-style paths: list is UNPARSED" \
        push "$dir/flow-paths.yml" 'UNPARSED:     paths: ["a"]'

    printf '%s\n' 'on:' '  push:' '    paths:' '    - "a"' '    - "b"' 'jobs:' >"$dir/compact.yml"
    _expect_trigger_paths "compact same-indent entries are UNPARSED" \
        push "$dir/compact.yml" 'UNPARSED:     - "a"' 'UNPARSED:     - "b"'

    printf '%s\n' 'on:' '  push:' '    paths:' '    -' '    - "b"' 'jobs:' >"$dir/compact-bare.yml"
    _expect_trigger_paths "a bare compact dash is UNPARSED" \
        push "$dir/compact-bare.yml" 'UNPARSED:     -' 'UNPARSED:     - "b"'

    printf '%s\n' 'on:' '  push:' '    paths:' '      - "a"' '  push:' '    paths:' \
        '      - "leak"' 'jobs:' >"$dir/dup-trigger.yml"
    _expect_trigger_paths "a repeated trigger key ends the block, not re-opens it" \
        push "$dir/dup-trigger.yml" 'a'

    printf '%s\n' 'on:' '  push:' '    paths:' '      - "a"' '      - ""' 'jobs:' >"$dir/empty-entry.yml"
    _expect_trigger_paths "a trailing empty entry is kept" \
        push "$dir/empty-entry.yml" 'a' ''

    command rm -rf "$dir"
}

# _expect_trigger_paths <message> <event> <workflow> <entry>... — the parser
# prints exactly <entry>... (nothing, if none are given), in order. A parser
# that fails (e.g. an unwritten fixture) is a failure, never an empty match.
# Both sides end in a sentinel, since $(...) would strip a trailing empty
# entry and make its presence invisible to the comparison.
_expect_trigger_paths() {
    local msg="$1" ev="$2" wf="$3" got want=x
    shift 3
    [ "$#" -gt 0 ] && want="$(printf '%s\n' "$@" && printf x)"
    if ! got="$(_trigger_paths "$ev" "$wf" && printf x)"; then
        assert_true false "$msg (parser failed on $wf)"
        return
    fi
    assert_equals "$want" "$got" "$msg"
}

test_filter_glob_semantics() {
    # Pins the two GitHub rules the coverage test depends on, so a translator
    # regression (e.g. `*` -> `.*`) cannot pass silently through the real
    # workflow's patterns.
    _expect_covered no "single * stays within a path segment" bin/lib/evidence-x.sh 'bin/*.sh'
    _expect_covered yes "** crosses directories" bin/lib/evidence-x.sh 'bin/**'
    _expect_covered no ". is literal" bin/ingest-evidenceXsh 'bin/ingest-evidence.sh'
    _expect_covered no "a later ! entry excludes" \
        bin/lib/evidence-x.sh 'bin/lib/evidence-*.sh' '!bin/lib/evidence-x.sh'
    _expect_covered yes "a later positive entry re-includes" \
        bin/lib/evidence-x.sh '!bin/lib/evidence-x.sh' 'bin/lib/*'
}

# _expect_covered <yes|no> <message> <file> <pattern>...
_expect_covered() {
    local want="$1" msg="$2" got=no
    shift 2
    _covered "$@" && got=yes
    if [ "$got" = "$want" ]; then
        assert_true true "$msg"
    else
        assert_true false "$msg (expected covered=$want, got $got)"
    fi
}

run_test test_cells_install_as_the_container_user "cells install as the container user (--user runner)"
run_test test_cells_open_no_prs_or_issues "cells open no PRs or issues"
run_test test_collect_job_batches_into_one_pr "collect job batches into one PR and one issue"
run_test test_artifact_name_is_per_cell "artifact name is per cell"
run_test test_open_pr_sources_step_calls_the_lib "open-PR sources step calls evidence_db_sources (#1328)"
run_test test_open_pr_sources_count_only_added_rows "open-PR sources count only the rows each PR adds (#1327)"
run_test test_open_pr_sources_pin_the_main_read "open-PR sources take merge-bases against the fetched main"
run_test test_open_pr_sources_skip_via_the_decision "open-PR sources skip through evidence_pr_skip (#1446)"
run_test test_cells_install_from_the_vendored_catalog "cells install from the vendored catalog"
run_test test_trigger_paths_cover_evidence_scripts "trigger paths cover every evidence lib and script"
run_test test_trigger_paths_parser_fixtures "paths: parser fails closed on fixture workflows"
run_test test_filter_glob_semantics "paths: glob matching follows GitHub semantics"

generate_report
