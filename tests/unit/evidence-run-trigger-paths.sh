#!/usr/bin/env bash
# Unit tests: evidence-run.yml's trigger paths cover every script it runs.
#
# A change confined to a script the workflow runs or sources must re-trigger
# the workflow, or the evidence it produces goes stale without a run. These
# checks derive that script set from the workflow and its sources (#1393) and
# fail if a push/pull_request `paths:` filter misses any of it. Split out of
# evidence-run-shape.sh (#1467).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "evidence-run.yml trigger paths"

WF="$PROJECT_ROOT/.github/workflows/evidence-run.yml"

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

# _normalize_path <path> — collapse `./` and `seg/..` segments of a relative
# path, so a `../` hop resolves to the same repo-relative name as a direct one.
# A `..` that climbs out of the repo prints `UNRESOLVED: ...` instead.
_normalize_path() {
    local seg
    local -a out=()
    local IFS=/
    for seg in $1; do
        case "$seg" in
            '' | .) ;;
            ..)
                if [ "${#out[@]}" -eq 0 ]; then
                    printf 'UNRESOLVED: escapes the repo: %s\n' "$1"
                    return
                fi
                unset 'out[${#out[@]}-1]'
                ;;
            *) out+=("$seg") ;;
        esac
    done
    printf '%s\n' "${out[*]}"
}

# _source_target <line> — the target of the `source` on <line>, quotes
# dropped, or nothing. `source` or `.` may open the line; `source` may also
# follow `;`, `&`, `|`, or then/do/else, as in `[ -f x ] && source x`. A
# mid-line `.` is not read: jq filters in these files are full of `then . else`
# and `(. as $r`. The target runs to the end of the line, so anything chained
# after it fails to resolve rather than being dropped.
_source_target() {
    local re_start='^[[:space:]]*(source|\.)[[:space:]]+(.*[^[:space:]])'
    local re_mid='(^|[;&|]|[[:space:]](then|do|else))[[:space:]]*source[[:space:]]+(.*[^[:space:]])'
    if [[ "$1" =~ $re_start ]]; then
        printf '%s\n' "${BASH_REMATCH[2]//\"/}"
    elif [[ "$1" =~ $re_mid ]]; then
        printf '%s\n' "${BASH_REMATCH[3]//\"/}"
    fi
}

# _workflow_entry_scripts [workflow] — the repo-relative scripts the workflow's
# run: lines source or execute. Two sweeps over the non-comment lines, both
# printed. First, every literal repo-root `bin/....sh` path mentioned in any
# form: bare, quoted, after `bash`, `./`, or $GITHUB_WORKSPACE/ (but not
# /usr/bin/x.sh). That deliberately over-reads: the paths: and sparse-checkout
# lists name scripts too, which only widens the checked set, and a stale entry
# there then fails as `missing`. Second, every source target per
# _source_target. A target that is not a literal path once $GITHUB_WORKSPACE/
# is dropped prints `UNRESOLVED: <line>`, which the caller fails on. So a form
# this cannot read never drops a file silently.
_workflow_entry_scripts() {
    local line target
    # No literal path is a grep exit 1, not an error: never let it end the
    # function under errexit before the source sweep runs.
    {
        /usr/bin/grep -vE '^[[:space:]]*#' "${1:-$WF}" |
            /usr/bin/grep -oE '(^|[[:space:]"'"'"'=(;&|]|\./|WORKSPACE\}?/)bin/[A-Za-z0-9_./-]+\.sh' |
            /usr/bin/sed -E 's#^[^b]*##' |
            while IFS= read -r line; do _normalize_path "$line"; done
    } || true
    while IFS= read -r line; do
        target="$(_source_target "$line")"
        [ -n "$target" ] || continue
        target="${target#\$GITHUB_WORKSPACE/}"
        target="${target#\$\{GITHUB_WORKSPACE\}/}"
        if [[ "$target" =~ ^[A-Za-z0-9_./-]+$ ]]; then
            _normalize_path "$target"
        else
            printf 'UNRESOLVED: %s\n' "$line"
        fi
    done < <(/usr/bin/grep -vE '^[[:space:]]*#' "${1:-$WF}")
}

# _sourced_by <file> [root] — the repo-relative files <file> (repo-relative,
# under [root]) sources directly, read by _source_target. Two forms resolve
# against <file>'s own directory: `$(dirname "${BASH_SOURCE[0]}")/x` (with or
# without `command`), and `$SCRIPT_DIR/x` when the file sets SCRIPT_DIR from
# BASH_SOURCE[0]'s dirname. Any other target prints
# `UNRESOLVED: <file>: <line>`. Libs that execute (not source) another script
# are not followed; none of the evidence libs do.
_sourced_by() {
    local file="$1" root="${2:-$PROJECT_ROOT}" dir line target rest
    dir="$(/usr/bin/dirname "$file")"
    while IFS= read -r line; do
        target="$(_source_target "$line")"
        [ -n "$target" ] || continue
        case "$target" in
            '$(dirname ${BASH_SOURCE[0]})/'* | '$(command dirname ${BASH_SOURCE[0]})/'*)
                rest="${target#*\)/}"
                ;;
            '$SCRIPT_DIR/'* | '${SCRIPT_DIR}/'*)
                if /usr/bin/grep -qE '^SCRIPT_DIR=.*dirname.*BASH_SOURCE\[0\]' "$root/$file"; then
                    rest="${target#*/}"
                else
                    printf 'UNRESOLVED: %s: %s\n' "$file" "$line"
                    continue
                fi
                ;;
            *)
                printf 'UNRESOLVED: %s: %s\n' "$file" "$line"
                continue
                ;;
        esac
        _normalize_path "$dir/$rest"
    done < <(/usr/bin/grep -vE '^[[:space:]]*#' "$root/$file")
}

# _derived_scripts [workflow] [root] — every file the workflow runs, closed
# over the files each of those sources, each printed once. An UNRESOLVED form
# is passed through, and a reached path missing under [root] is UNRESOLVED too.
_derived_scripts() {
    local wf="${1:-$WF}" root="${2:-$PROJECT_ROOT}" f next
    local -a queue
    local -A seen=()
    mapfile -t queue < <(_workflow_entry_scripts "$wf")
    while [ "${#queue[@]}" -gt 0 ]; do
        f="${queue[0]}"
        queue=("${queue[@]:1}")
        if [ "${f#UNRESOLVED: }" != "$f" ]; then
            printf '%s\n' "$f"
            continue
        fi
        [ -n "${seen[$f]:-}" ] && continue
        seen[$f]=1
        if [ ! -f "$root/$f" ]; then
            printf 'UNRESOLVED: missing %s\n' "$f"
            continue
        fi
        printf '%s\n' "$f"
        while IFS= read -r next; do
            queue+=("$next")
        done < <(_sourced_by "$f" "$root")
    done
}

# _uncovered <event> <workflow> <file>... — each <file> the event's paths:
# filter would not trigger on. A trigger with no entries prints `NOPATHS`, and
# an unreadable entry its `UNPARSED: ` line, so the caller fails on either.
_uncovered() {
    local ev="$1" wf="$2" f p
    local -a patterns
    shift 2
    mapfile -t patterns < <(_trigger_paths "$ev" "$wf")
    if [ "${#patterns[@]}" -eq 0 ]; then
        printf 'NOPATHS\n'
        return
    fi
    for p in "${patterns[@]}"; do
        if [ "${p#UNPARSED: }" != "$p" ]; then
            printf '%s\n' "$p"
            return
        fi
    done
    for f in "$@"; do
        _covered "$f" "${patterns[@]}" || printf '%s\n' "$f"
    done
}

test_trigger_paths_cover_evidence_scripts() {
    # Every file the workflow runs must re-trigger it, or a change confined to
    # that file first runs on some unrelated push to main (#1388). The checked
    # set is the union of two views, so neither can shrink coverage: the files
    # the run: blocks source or execute, closed over what those source (#1393),
    # and every bin/lib/evidence-*.sh / bin/ingest-evidence*.sh on disk.
    local ev f line
    local -a derived=() named=() unresolved=() scripts missing
    while IFS= read -r line; do
        if [ "${line#UNRESOLVED: }" != "$line" ]; then
            unresolved+=("${line#UNRESOLVED: }")
        else
            derived+=("$line")
        fi
    done < <(_derived_scripts)
    for line in "${unresolved[@]}"; do
        assert_true false "unresolvable source in the workflow's scripts: $line"
    done
    if [ "${#derived[@]}" -eq 0 ]; then
        assert_true false "no scripts derived from the workflow's run: blocks"
        return
    fi
    # evidence-matrix.sh and evidence-epoch.sh are reached only through other
    # libs, so their presence shows the closure follows source lines.
    for f in bin/lib/evidence-sources.sh bin/lib/evidence-matrix.sh bin/lib/evidence-epoch.sh; do
        # Exact line match: a substring would accept evidence-epoch.sh.bak.
        if /usr/bin/grep -qxF "$f" <<<"$(printf '%s\n' "${derived[@]}")"; then
            assert_true true "the derived set includes $f"
        else
            assert_true false "the derived set includes $f"
        fi
    done
    # An unmatched glob stays literal and would match its own trigger entry,
    # so keep only real files.
    for f in "$PROJECT_ROOT"/bin/lib/evidence-*.sh "$PROJECT_ROOT"/bin/ingest-evidence*.sh; do
        [ -f "$f" ] && named+=("${f#"$PROJECT_ROOT"/}")
    done
    mapfile -t scripts < <(printf '%s\n' "${derived[@]}" "${named[@]}" | /usr/bin/sort -u)
    for ev in pull_request push; do
        mapfile -t missing < <(_uncovered "$ev" "$WF" "${scripts[@]}")
        if [ "${#missing[@]}" -eq 0 ]; then
            assert_true true "$ev paths: cover all ${#scripts[@]} scripts"
            continue
        fi
        for f in "${missing[@]}"; do
            case "$f" in
                NOPATHS) assert_true false "$ev has no paths: entries to check" ;;
                UNPARSED:*) assert_true false "$ev paths: entry not of the form - \"glob\": ${f#UNPARSED: }" ;;
                *) assert_true false "$ev paths: cover $f" ;;
            esac
        done
    done
}

test_derived_set_catches_off_convention_helper() {
    # The name-glob view cannot see a helper sourced under another name; the
    # derived view must, and must report it uncovered until paths: lists it.
    local dir got
    if ! dir=$(command mktemp -d "${TMPDIR:-/tmp}/evidence-run-trigger-paths.XXXXXX"); then
        assert_true false "mktemp failed under ${TMPDIR:-/tmp}"
        return
    fi
    command mkdir -p "$dir/bin/lib"
    # Single quotes are deliberate: the fixture scripts hold literal source lines.
    # shellcheck disable=SC2016
    {
        printf '%s\n' '#!/usr/bin/env bash' \
            'source "$(dirname "${BASH_SOURCE[0]}")/epoch-util.sh"' >"$dir/bin/lib/evidence-a.sh"
        printf '%s\n' '#!/usr/bin/env bash' >"$dir/bin/lib/epoch-util.sh"
        printf '%s\n' '#!/usr/bin/env bash' \
            'SCRIPT_DIR="$(command cd "$(command dirname "${BASH_SOURCE[0]}")" && command pwd)"' \
            '# source "$SCRIPT_DIR/lib/commented.sh"' \
            'source "$SCRIPT_DIR/lib/merge-util.sh"' 'source "${SCRIPT_DIR}/lib/braced-util.sh"' \
            >"$dir/bin/ingest-x.sh"
        printf '%s\n' '#!/usr/bin/env bash' >"$dir/bin/lib/merge-util.sh"
        printf '%s\n' '#!/usr/bin/env bash' >"$dir/bin/lib/braced-util.sh"
        printf '%s\n' 'on:' '  push:' '    paths:' '      - "bin/lib/evidence-*.sh"' 'jobs:' \
            '  j:' '    steps:' '      - run: |' '          source bin/lib/evidence-a.sh' \
            >"$dir/narrow.yml"
        printf '%s\n' 'on:' '  push:' '    paths:' '      - "bin/lib/evidence-*.sh"' \
            '      - "bin/lib/epoch-util.sh"' 'jobs:' '  j:' '    steps:' '      - run: |' \
            '          source "$GITHUB_WORKSPACE/bin/lib/evidence-a.sh"' >"$dir/wide.yml"
        printf '%s\n' 'jobs:' '  j:' '    steps:' '      - run: |' \
            '          ./bin/ingest-x.sh --flag' >"$dir/exec.yml"
        printf '%s\n' '#!/usr/bin/env bash' 'source "$X/y.sh"' >"$dir/bin/lib/evidence-b.sh"
        printf '%s\n' 'jobs:' '  j:' '    steps:' '      - run: |' \
            '          source bin/lib/evidence-b.sh' '          source "$HOME/z.sh"' >"$dir/odd.yml"
    }

    mapfile -t got < <(_derived_scripts "$dir/narrow.yml" "$dir")
    assert_equals "bin/lib/evidence-a.sh bin/lib/epoch-util.sh" "${got[*]}" \
        "a helper sourced via dirname BASH_SOURCE is derived transitively"
    assert_equals "bin/lib/epoch-util.sh" "$(_uncovered push "$dir/narrow.yml" "${got[@]}")" \
        "the off-convention helper is reported uncovered"

    mapfile -t got < <(_derived_scripts "$dir/wide.yml" "$dir")
    assert_equals "" "$(_uncovered push "$dir/wide.yml" "${got[@]}")" \
        "listing it in paths: covers it (\$GITHUB_WORKSPACE/ prefix read)"

    assert_equals "bin/ingest-x.sh bin/lib/merge-util.sh bin/lib/braced-util.sh" \
        "$(_derived_scripts "$dir/exec.yml" "$dir" | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')" \
        "an executed ./bin script and its \$SCRIPT_DIR source are derived; comments are not"

    # shellcheck disable=SC2016
    assert_equals \
        "$(printf '%s\n' 'bin/lib/evidence-b.sh' 'UNRESOLVED:           source "$HOME/z.sh"' \
            'UNRESOLVED: bin/lib/evidence-b.sh: source "$X/y.sh"')" \
        "$(_derived_scripts "$dir/odd.yml" "$dir")" \
        "unreadable source forms are UNRESOLVED, not dropped"

    command rm -rf "$dir"
}

test_derivation_edge_forms() {
    # Each branch of the derivation helpers, pinned by full output (#1393
    # review): a regression in any of them would drop a file or hang the
    # closure, and the real workflow exercises only the common forms.
    local dir
    if ! dir=$(command mktemp -d "${TMPDIR:-/tmp}/evidence-run-trigger-paths.XXXXXX"); then
        assert_true false "mktemp failed under ${TMPDIR:-/tmp}"
        return
    fi
    command mkdir -p "$dir/bin/lib"
    # shellcheck disable=SC2016
    {
        printf '%s\n' '#!/usr/bin/env bash' 'source "$(command dirname "${BASH_SOURCE[0]}")/../lib/b.sh"' \
            >"$dir/bin/lib/a.sh"
        printf '%s\n' '#!/usr/bin/env bash' '[ -n "$x" ] && source "$(dirname "${BASH_SOURCE[0]}")/a.sh"' \
            '  jq '"'"'if .done then . else (. as $r | $r) end'"'"'' >"$dir/bin/lib/b.sh"
        printf '%s\n' '#!/usr/bin/env bash' 'source "$SCRIPT_DIR/lib/a.sh"' >"$dir/bin/lib/noscriptdir.sh"
        printf '%s\n' '#!/usr/bin/env bash' 'source "$(dirname "${BASH_SOURCE[0]}")/gone.sh"' \
            >"$dir/bin/lib/dangling.sh"
        printf '%s\n' 'jobs:' '  j:' '    steps:' '      - run: |' \
            '          . "${GITHUB_WORKSPACE}/bin/lib/a.sh"' '          bash bin/lib/noscriptdir.sh' \
            '          x=1; source "bin/lib/dangling.sh"' '          ./bin/lib/../../../out.sh' >"$dir/forms.yml"
        printf '%s\n' 'jobs:' '  j:' '    steps:' '      - run: |' \
            '          run "./bin/q1.sh"' "          bash 'bin/q2.sh'" '          x="$GITHUB_WORKSPACE/bin/q3.sh"' \
            '          /usr/bin/ignored.sh' '          true | source bin/s1.sh' \
            '          if true; then source bin/s2.sh' '          for i in 1; do source bin/s3.sh; done' \
            '          else source bin/s4.sh' '          v=$(bin/c1.sh);bin/c2.sh&&bin/c3.sh|bin/c4.sh' \
            '          tools/bin/ignored.sh' >"$dir/seps.yml"
        printf '%s\n' 'jobs:' '  j:' '    steps:' '      - run: |' '          source "$HOME/x.sh"' \
            >"$dir/noliteral.yml"
        printf '%s\n' 'on:' '  push:' '    branches: [main]' 'jobs:' >"$dir/nopaths.yml"
        printf '%s\n' 'on:' '  push:' '    paths: ["a"]' 'jobs:' >"$dir/flow.yml"
    }

    assert_equals "bin/lib/a.sh" "$(_normalize_path ./bin/x/../lib//a.sh)" "_normalize_path collapses . .. and //"
    assert_equals "UNRESOLVED: escapes the repo: bin/../../x.sh" "$(_normalize_path bin/../../x.sh)" \
        "a .. above the root is UNRESOLVED"
    # The workflow sweep first (literal paths, then source targets), then
    # breadth-first by queue order: a.sh's b.sh (whose a.sh is already seen,
    # so the cycle ends), noscriptdir.sh's refusal, dangling.sh's gone.sh.
    # shellcheck disable=SC2016
    assert_equals "$(printf '%s\n' \
        'bin/lib/a.sh' \
        'bin/lib/noscriptdir.sh' \
        'bin/lib/dangling.sh' \
        'UNRESOLVED: escapes the repo: bin/lib/../../../out.sh' \
        'bin/lib/b.sh' \
        'UNRESOLVED: bin/lib/noscriptdir.sh: source "$SCRIPT_DIR/lib/a.sh"' \
        'UNRESOLVED: missing bin/lib/gone.sh')" \
        "$(_derived_scripts "$dir/forms.yml" "$dir")" \
        "braced \$GITHUB_WORKSPACE, '. ', bash, chained source, cycles, missing files, and unset SCRIPT_DIR"
    # Literal sweep: double- and single-quoted, unbraced $GITHUB_WORKSPACE/,
    # after $( ; && |, never a nested .../bin/. Source sweep: after |, then,
    # do, and else. The s3 target swallows `; done`, so it fails to resolve
    # rather than misread. The literal sweep has already caught s3, so
    # nothing is dropped.
    assert_equals "$(printf '%s\n' bin/q1.sh bin/q2.sh bin/q3.sh bin/s1.sh bin/s2.sh bin/s3.sh bin/s4.sh \
        bin/c1.sh bin/c2.sh bin/c3.sh bin/c4.sh \
        bin/s1.sh bin/s2.sh 'UNRESOLVED:           for i in 1; do source bin/s3.sh; done' bin/s4.sh)" \
        "$(_workflow_entry_scripts "$dir/seps.yml")" \
        "quoted and workspace-prefixed paths, and source after | then do else, are all read"
    # shellcheck disable=SC2016
    assert_equals 'UNRESOLVED:           source "$HOME/x.sh"' \
        "$(set -euo pipefail && _workflow_entry_scripts "$dir/noliteral.yml")" \
        "with no literal bin path, the source sweep still runs under errexit"
    assert_equals "NOPATHS" "$(_uncovered push "$dir/nopaths.yml" bin/lib/a.sh)" "a trigger without paths: is NOPATHS"
    assert_equals 'UNPARSED:     paths: ["a"]' "$(_uncovered push "$dir/flow.yml" bin/lib/a.sh)" \
        "an unreadable paths: entry is passed through"

    command rm -rf "$dir"
}

test_trigger_paths_parser_fixtures() {
    # The real workflow is well-formed, so none of _trigger_paths' fail-closed
    # branches fire against it (#1392). Each fixture pins one branch by the
    # parser's full output, so dropping a rule changes what it prints.
    local dir
    if ! dir=$(command mktemp -d "${TMPDIR:-/tmp}/evidence-run-trigger-paths.XXXXXX"); then
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

run_test test_trigger_paths_cover_evidence_scripts "trigger paths cover every script the workflow runs or sources"
run_test test_derived_set_catches_off_convention_helper "derived coverage catches a helper outside the evidence-* names (#1393)"
run_test test_derivation_edge_forms "derivation resolves or fails closed on every source form"
run_test test_trigger_paths_parser_fixtures "paths: parser fails closed on fixture workflows"
run_test test_filter_glob_semantics "paths: glob matching follows GitHub semantics"

generate_report
