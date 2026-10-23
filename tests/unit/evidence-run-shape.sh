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
# particular a `!` exclusion) can never be dropped silently.
_trigger_paths() {
    /usr/bin/awk -v ev="$1" '
        /^on:$/ { inon = 1; next }
        !on && /^[^[:space:]#]/ { inon = 0 }
        inon && $0 ~ "^  " ev ":$" { on = 1; next }
        on && /^[^[:space:]#]/ { exit }
        on && /^  [A-Za-z0-9_-]+:/ { exit }
        on && /^    paths:$/ { inpaths = 1; next }
        on && inpaths && /^[[:space:]]*(#.*)?$/ { next }
        on && inpaths && /^      - "[^"]*"$/ { sub(/^      - "/, ""); sub(/"$/, ""); print; next }
        on && inpaths && /^      / { print "UNPARSED: " $0; next }
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

    command rm -rf "$dir"
}

# _expect_trigger_paths <message> <event> <workflow> <entry>... — the parser
# prints exactly <entry>... (nothing, if none are given), in order. A parser
# that fails (e.g. an unwritten fixture) is a failure, never an empty match.
_expect_trigger_paths() {
    local msg="$1" ev="$2" wf="$3" got want=""
    shift 3
    [ "$#" -gt 0 ] && want="$(printf '%s\n' "$@")"
    if ! got="$(_trigger_paths "$ev" "$wf")"; then
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
run_test test_cells_install_from_the_vendored_catalog "cells install from the vendored catalog"
run_test test_trigger_paths_cover_evidence_scripts "trigger paths cover every evidence lib and script"
run_test test_trigger_paths_parser_fixtures "paths: parser fails closed on fixture workflows"
run_test test_filter_glob_semantics "paths: glob matching follows GitHub semantics"

generate_report
