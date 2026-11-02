#!/usr/bin/env bash
# A fake `gh` for suites that drive bin/lib/github-api-commit.sh (#1573):
# tests/unit/bin/lib/github-api-commit.sh and tests/unit/ingest-evidence-batch.sh.
# Sourced only — it lives outside tests/unit/ so the unit runner does not
# execute it as a suite. Callers source tests/framework.sh first.
#
# gh_stub_install sets STUB_DIR (prepend it to PATH) and exports:
#   GH_LOG       every argv, one line per call
#   GH_PAYLOADS  directory; each `api graphql --input F` copies F to N.json
# Behavior knobs (env, read at call time):
#   GH_STUB_REF_EXISTS=1  `api repos/.../git/ref/heads/...` succeeds (else 404)
#   GH_STUB_REF_EXISTS_ONLY  with REF_EXISTS=1, only refs whose path contains
#                         this string exist
#   GH_STUB_FAIL_MATCH    any `api` call whose argv contains this string exits 1
#   GH_STUB_TREE_TRUNCATED=1  the tree response reports truncated:true
#   GH_STUB_BRANCH_HEAD   object.sha an existing ref reports (default empty)
#   GH_STUB_PARENT        parents[0].sha of any `git/commits/<sha>` lookup
#   GH_STUB_MESSAGE       message of that commit (default "chore: headline")
#   GH_STUB_GRAPHQL_FAIL_FIRST=N  the first N graphql calls exit 1
#   GH_STUB_GRAPHQL_LANDED=1  graphql records the payload, then exits 1 (the
#                         commit landed but the response was lost)
#   GH_STUB_VERIFIED      the commit's verification.verified (default true)
#   GH_STUB_TREE_MODE     mode every path reports in the tree (default: the
#                         mode the payload implies, 100644)
#   GH_STUB_GRAPHQL_FAIL=1  graphql exits 1
# The tree response lists every addition path from the last payload.

gh_stub_install() {
    STUB_DIR="$(command mktemp -d "$TEST_TEMP_DIR/gh.XXXXXX")"
    GH_LOG="$STUB_DIR/gh.log"
    GH_PAYLOADS="$STUB_DIR/payloads"
    command mkdir -p "$GH_PAYLOADS"
    : >"$GH_LOG"
    export GH_LOG GH_PAYLOADS
    command cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
last() { command ls "$GH_PAYLOADS" | command sort -n | command tail -1; }
case "$1 $2" in
    "pr create") printf 'https://github.com/joshjhall/containers-db/pull/9\n' ;;
    "api graphql")
        [ "${GH_STUB_GRAPHQL_FAIL:-}" = 1 ] && exit 1
        if [ -n "${GH_STUB_GRAPHQL_FAIL_FIRST:-}" ]; then
            tries=$(( $(command cat "$GH_PAYLOADS/.tries" 2>/dev/null || echo 0) + 1 ))
            echo "$tries" >"$GH_PAYLOADS/.tries"
            [ "$tries" -le "$GH_STUB_GRAPHQL_FAIL_FIRST" ] && exit 1
        fi
        n=$(( $(command ls "$GH_PAYLOADS" | command wc -l) + 1 ))
        command cp "$4" "$GH_PAYLOADS/$n.json"
        [ "${GH_STUB_GRAPHQL_LANDED:-}" = 1 ] && exit 1
        printf '{"data":{"createCommitOnBranch":{"commit":{"oid":"c0ffee%04d","url":"u"}}}}\n' "$n"
        ;;
    "api "*)
        if [ -n "${GH_STUB_FAIL_MATCH:-}" ]; then
            case "$*" in *"$GH_STUB_FAIL_MATCH"*) exit 1 ;; esac
        fi
        for a in "$@"; do path="$a"; case "$a" in repos/*) break ;; esac; done
        case "$path" in
            */git/ref/heads/*)
                [ "${GH_STUB_REF_EXISTS:-}" = 1 ] || exit 1
                case "$path" in *"${GH_STUB_REF_EXISTS_ONLY:-}"*) ;; *) exit 1 ;; esac
                printf '{"object":{"sha":"%s"}}\n' "${GH_STUB_BRANCH_HEAD:-}"
                ;;
            */git/trees/*)
                command jq -c --arg m "${GH_STUB_TREE_MODE:-100644}" \
                    --argjson t "$([ "${GH_STUB_TREE_TRUNCATED:-}" = 1 ] && echo true || echo false)" \
                    '{truncated:$t, tree: [.variables.input.fileChanges.additions[] | {path, mode:$m}]}' \
                    "$GH_PAYLOADS/$(last)"
                ;;
            */git/commits/*)
                command jq -cn --arg p "${GH_STUB_PARENT:-}" --arg m "${GH_STUB_MESSAGE-chore: headline}" \
                    '{parents: [{sha: $p}], message: $m}' ;;
            */commits/*)
                printf '{"commit":{"verification":{"verified":%s}}}\n' "${GH_STUB_VERIFIED:-true}" ;;
            *) echo '{}' ;;
        esac
        ;;
esac
exit 0
STUB
    command chmod +x "$STUB_DIR/gh"
}

# gh_stub_payload [n] — the n-th (default last) graphql payload's path.
gh_stub_payload() {
    local n="${1:-}"
    if [ -z "$n" ]; then
        n="$(command ls "$GH_PAYLOADS" | command sort -n | command tail -1)"
        n="${n%.json}"
    fi
    command echo "$GH_PAYLOADS/$n.json"
}

# gh_stub_file <payload> <path> — the decoded contents of <path>'s addition.
gh_stub_file() {
    command jq -r --arg p "$2" '.variables.input.fileChanges.additions[] | select(.path == $p) | .contents' "$1" |
        command base64 -d
}
