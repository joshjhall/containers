#!/usr/bin/env bash
# Evidence matrix for push-triggered evidence runs (#1111).
#
# Emits the GitHub Actions matrix (`{"include":[...]}`) of every evidence cell
# a luggage-managed tool should have, computed from the vendored catalog
# rather than hard-coded:
#
#   versions = the NEWEST PATCH of each minor, from the catalog's
#              `minimum_recommended` floor up. That is what `RUST_VERSION=X.Y`
#              installs, so it is what evidence has to cover; exact pins to
#              superseded patches stay installable but are not re-tested.
#   tuples   = the version's support_matrix `supported` cells ∩ tuples with a
#              base-images/<os>/<os_version>/<arch>/Dockerfile. A claim with no
#              base image cannot run; a base image nothing claims is not tested.
#
# Same claimed ∩ available rule as bin/dispatch-evidence.sh, applied to the
# whole catalog instead of one bumped version.
#
# Only PENDING cells are emitted: those with no passing `tested[]` row for that
# tuple and no failing row newer than EVIDENCE_FAIL_COOLDOWN_DAYS (default 7).
# A cell that failed before the cooldown is retried, but after every
# never-tested cell, so a persistent failure cannot take cap budget from
# untested work (#1326). Evidence comes from EVIDENCE_TESTED_SOURCE when set (see
# _em_published_evidence): the vendored snapshot never receives `tested[]`
# rows, so judging against it re-ran the same oldest cells forever (#1319).
# Re-running a covered cell is a no-op at ingest (the dedup key matches),
# so it would only burn runners — and the full product (18 versions x 18
# tuples = 324) exceeds GitHub's 256-job matrix cap outright. A base-image
# rebuild re-evidences its tuple separately (dispatch-evidence-for-tuple.sh).
# `max_cells` caps one run; the backlog drains over successive pushes, oldest
# versions first so the floor gets covered before the newest release (within
# each group: never-tested cells, then stale-failure retries).
#
# evidence_matrix covers one tool; evidence_matrix_all (what the workflow runs)
# merges every luggage tool in the catalog under one cap (#1341).
#
# Sourced by .github/workflows/evidence-run.yml and tests/unit/evidence-matrix.sh.
# Requires jq.

# _em_arch_plumbing <arch> — "<runner> <runtime> <rust_target>" for an arch.
# Mirrors evidence-run.yml's arch_plumbing (dispatch path).
_em_arch_plumbing() {
    case "$1" in
        amd64) echo "ubuntu-latest native x86_64-unknown-linux-musl" ;;
        arm64) echo "ubuntu-24.04-arm native aarch64-unknown-linux-musl" ;;
        *) return 1 ;;
    esac
}

# _em_available_tuples <project_root> — every base-image tuple slug whose
# Dockerfile exists AND, when EVIDENCE_PUBLISHED_CHECK names a command, whose
# image that command reports published (it gets the slug, exit 0 = published).
#
# A Dockerfile is not an image: on the merge that adds a tuple, this matrix
# and the base-image publish start together, so without the check the first
# run queued cells for images that did not exist yet and failed pulling them
# (#1113: 12 new tuples, ~130 doomed cells). Unpublished tuples stay pending
# and run on a later push, or via dispatch-evidence-for-tuple.sh once
# published. Unset in unit tests (hermetic); evidence-run.yml sets it.
_em_available_tuples() {
    local f rel slug
    for f in "$1"/base-images/*/*/*/Dockerfile; do
        [ -e "$f" ] || continue
        rel="${f#"$1"/base-images/}"
        rel="${rel%/Dockerfile}"
        slug="${rel//\//-}"
        if [ -n "${EVIDENCE_PUBLISHED_CHECK:-}" ] && ! "$EVIDENCE_PUBLISHED_CHECK" "$slug"; then
            command echo "evidence_matrix: base-$slug not published yet; its cells stay pending" >&2
            continue
        fi
        command echo "$slug"
    done
}

# _em_available_tuples_json <project_root> — the same tuples as a JSON array.
_em_available_tuples_json() {
    _em_available_tuples "$1" | command jq -R . | command jq -cs .
}

# _EM_EVIDENCE_JQ — jq defs shared by the published and vendored paths, so the
# fail policy is computed in one place. `em_evidence` reduces an array of
# tested[] rows to {pass: ["os-osv-arch", ...], fail: {"os-osv-arch": <newest
# fail epoch>}}. A fail row whose tested_at is missing or unparsable gets epoch
# 0: it reads as a stale failure (retried last), never a recent one, so an
# unreadable age cannot hide a cell forever. Accepted tested_at forms (#1349):
# a calendar-valid YYYY-MM-DDTHH:MM:SS with optional fractional seconds, then
# `Z` or a `+HH:MM`/`-HH:MM` offset within -12:00..+14:00. fromdateiso8601
# takes only whole-second `Z`, so the fraction is dropped, the base parsed as
# UTC, and the offset subtracted. libc normalizes a date like Feb 30 into
# March, so the base must also round-trip through todate unchanged.
_EM_EVIDENCE_JQ='
def em_cell: "\(.os)-\(.os_version // "")-\(.arch)";
def em_epoch: ((.tested_at // "" | capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2}))$")
    | select(.z == "Z" or ((.m | tonumber) < 60 and (.h | tonumber) * 60 + (.m | tonumber) <= (if .s == "+" then 840 else 720 end)))
    | ((.b + "Z") as $u | $u | fromdateiso8601 | select(todate == $u))
      - (if .z == "Z" then 0 else (if .s == "-" then -1 else 1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60) end))? // 0);
def em_evidence:
    { pass: ([ .[] | select(.result == "pass") | em_cell ] | unique),
      fail: (reduce (.[] | select(.result == "fail")) as $r ({};
                ($r | em_cell) as $c | .[$c] = ([.[$c] // 0, ($r | em_epoch)] | max))) };
'

# _em_published_evidence <tool> <out_file> — writes the evidence per version
# from EVIDENCE_TESTED_SOURCE to out_file, as {"<version>": <em_evidence>}.
# The source is a colon-separated list of
# directories laid out like containers-db (tools/<tool>/versions/*.json); rows
# from all of them are unioned. evidence-run.yml passes containers-db main plus
# the head of each still-open evidence/batch/* PR, so cells a previous run
# evidenced count as covered while its auto-merge is pending.
#
# Writes `null` when the variable is unset (unit tests, local runs): the
# vendored `tested[]` decides, as before. When a listed directory holds no
# version files or unparsable JSON, it fails: an unreadable source must not
# turn into "every cell pending", which is the silent re-test loop #1319 fixed.
# A file, not a jq argument: the map grows with containers-db and one argv
# string is capped at 128 KiB.
_em_published_evidence() {
    local tool="$1" out="$2"
    if [ -z "${EVIDENCE_TESTED_SOURCE:-}" ]; then
        command echo null >"$out"
        return 0
    fi
    local src dir files=() found srcs
    IFS=: read -r -a srcs <<<"$EVIDENCE_TESTED_SOURCE"
    for src in "${srcs[@]}"; do
        dir="$src/tools/$tool/versions"
        found=("$dir"/*.json)
        if [ ! -e "${found[0]}" ]; then
            command echo "evidence_matrix: no published evidence for $tool at $dir (EVIDENCE_TESTED_SOURCE)" >&2
            return 1
        fi
        files+=("${found[@]}")
    done
    command jq -cs "$_EM_EVIDENCE_JQ"'
        group_by(.version)
        | map({key: .[0].version, value: ([ .[].tested[]? ] | em_evidence)})
        | from_entries
    ' "${files[@]}" >"$out" || {
        command echo "evidence_matrix: unreadable published evidence for $tool in $EVIDENCE_TESTED_SOURCE" >&2
        return 1
    }
}

# evidence_open_prs <now_epoch> [owner] [max_age_hours] — reads
# `gh pr list --json number,headRefName,isCrossRepository,author,createdAt` on
# stdin and prints the numbers of the open ingest PRs whose rows count as
# evidence, one per line. Only same-repo evidence/batch/* branches authored by
# owner (default joshjhall, the CONTAINERS_DB_PAT identity ingest pushes as):
# a branch name alone can come from any fork. A PR older than max_age_hours
# (default 24) is skipped with a warning; an ingest PR that has not merged by
# then is stuck, and must not hide its cells indefinitely.
evidence_open_prs() {
    local now="$1" owner="${2:-joshjhall}" max_age="${3:-24}" rows
    # Captured, not piped into the loop: a pipeline's status is its last
    # command's, so a jq failure would read as "no open PRs" without pipefail.
    rows="$(command jq -r --argjson now "$now" --arg owner "$owner" --argjson max "$max_age" '
        .[]
        | select((.headRefName | startswith("evidence/batch/"))
                 and (.isCrossRepository | not)
                 and .author.login == $owner)
        | if ($now - (.createdAt | fromdateiso8601)) > ($max * 3600)
          then "stale \(.number)" else "ok \(.number)" end
    ')" || {
        command echo "evidence_open_prs: unparsable PR listing" >&2
        return 1
    }
    local state n
    while read -r state n; do
        if [ -z "$state" ]; then
            continue
        elif [ "$state" = stale ]; then
            command echo "evidence_open_prs: containers-db#$n open over ${max_age}h; its rows do not count" >&2
        else
            command echo "$n"
        fi
    done <<<"$rows"
}

# _em_tool_cells <catalog_dir> <tool> <project_root> <image_tag> [available]
# — every pending cell for one tool as a JSON array, uncapped, in run order
# (untested before failure retries, oldest version first), each still carrying
# its `retry` flag for the caller to order and strip. Exit 1 on error.
# available is the JSON array of usable tuples; computed when omitted.
_em_tool_cells() {
    local catalog="$1" tool="$2" root="$3" image_tag="$4" available="${5:-}"
    local index="$catalog/tools/$tool/index.json"
    [ -f "$index" ] || {
        command echo "evidence_matrix: no index for $tool at $index" >&2
        return 1
    }
    # A versions/ dir with no version files is a half-vendored tool: fail with
    # a message that says so, not jq choking on the unmatched glob.
    local versions=("$catalog/tools/$tool/versions/"*.json)
    [ -e "${versions[0]}" ] || {
        command echo "evidence_matrix: no version files for $tool in $catalog/tools/$tool/versions" >&2
        return 1
    }

    local cooldown_days="${EVIDENCE_FAIL_COOLDOWN_DAYS:-7}" now="${EVIDENCE_NOW:-}"
    [ -n "$now" ] || now="$(command date +%s)"
    # Digit caps keep the bash arithmetic below in range: an unbounded value
    # would wrap the signed 64-bit product negative and silently disable the
    # cooldown. 6 digits is ~2700 years of cooldown; 12 is epochs to year 33658.
    [[ "$cooldown_days" =~ ^[0-9]{1,6}$ && "$now" =~ ^[0-9]{1,12}$ ]] || {
        command echo "evidence_matrix: EVIDENCE_FAIL_COOLDOWN_DAYS (1-6 digits) and EVIDENCE_NOW (1-12 digits) must be non-negative integers" >&2
        return 1
    }

    [ -n "$available" ] || available="$(_em_available_tuples_json "$root")"

    local evidence
    evidence="$(command mktemp)" || return 1
    _em_published_evidence "$tool" "$evidence" || {
        command rm -f "$evidence"
        return 1
    }

    local plumbing
    plumbing="$(command jq -cn \
        --arg a "$(_em_arch_plumbing amd64)" \
        --arg b "$(_em_arch_plumbing arm64)" \
        '{amd64: ($a | split(" ")), arm64: ($b | split(" "))}')"

    local out rc=0
    out="$(command jq -cs \
        --arg tool "$tool" \
        --arg tag "$image_tag" \
        --argjson available "$available" \
        --argjson plumbing "$plumbing" \
        --argjson now "$((10#$now))" \
        --argjson cooldown "$((10#$cooldown_days * 86400))" \
        --slurpfile evidence "$evidence" \
        --slurpfile index "$index" "$_EM_EVIDENCE_JQ"'
        def vkey: split(".") | map(tonumber? // 0);
        $evidence[0] as $evidence
        | ($index[0].minimum_recommended // "0") as $floor
        | map(select((.version | vkey) >= ($floor | vkey)))
        # newest patch per X.Y minor
        | group_by(.version | vkey | .[0:2])
        | map(max_by(.version | vkey))
        | sort_by(.version | vkey)
        | [ .[] as $v
            # evidence for this version — from the published source when
            # given, else the vendored tested[]
            | (if $evidence == null then [ $v.tested[]? ] | em_evidence
               else ($evidence[$v.version] // {pass: [], fail: {}}) end) as $ev
            | $v.support_matrix[]?
            | select(.status == "supported" and (.os_version // null) != null)
            | "\(.os)-\(.os_version)-\(.arch)" as $tuple
            | select($available | index($tuple))
            | select($plumbing[.arch])
            # pending: no passing row for this exact tuple, and no failing
            # row inside the cooldown (#1326)
            | select($ev.pass | index($tuple) | not)
            | $ev.fail[$tuple] as $failed_at
            | select($failed_at == null or $failed_at <= $now - $cooldown)
            | {tool: $tool, version: $v.version, tuple: $tuple, image_tag: $tag,
               arch: .arch, runner: $plumbing[.arch][0], runtime: $plumbing[.arch][1],
               rust_target: $plumbing[.arch][2], retry: ($failed_at != null)} ]
        | unique_by([.version, .tuple])
        # never-tested cells first, stale-failure retries last; oldest
        # version first within each
        | sort_by([.retry, (.version | vkey), .tuple])
    ' "${versions[@]}")" || rc=1
    command rm -f "$evidence"
    [ "$rc" -eq 0 ] || return 1
    command echo "$out"
}

# _em_cap <label> <max_cells> — reads an ordered cell array on stdin and prints
# the first max_cells as the matrix, or returns 3 when the array is empty.
_em_cap() {
    local label="$1" max_cells="$2" cells total
    cells="$(command cat)"
    total="$(command jq 'length' <<<"$cells")" || return 1
    if [ "$total" -eq 0 ]; then
        command echo "evidence_matrix: $label has no pending evidence cells" >&2
        return 3
    fi
    if [ "$total" -gt "$max_cells" ]; then
        command echo "evidence_matrix: $total pending cells for $label; running the first $max_cells this time (untested before failure retries, oldest first)" >&2
    fi
    command jq -c --argjson max "$max_cells" '{include: (map(del(.retry)) | .[0:$max])}' <<<"$cells"
}

# evidence_matrix <catalog_dir> <tool> <project_root> [image_tag] [max_cells]
#
# Prints the matrix JSON on stdout (max_cells defaults to 200, under GitHub's
# 256 cap). Exit status:
#   0  a non-empty matrix was printed
#   1  error (no index, bad catalog, unreadable EVIDENCE_TESTED_SOURCE, or a
#      non-integer EVIDENCE_FAIL_COOLDOWN_DAYS / EVIDENCE_NOW) — nothing printed
#   3  nothing pending — every cell has passing or recently failed evidence;
#      nothing printed. Callers skip the evidence job rather than run an empty
#      matrix.
#
# EVIDENCE_FAIL_COOLDOWN_DAYS (default 7) is how long a failing row keeps its
# cell out of the matrix; 0 retries every failure on the next push.
# EVIDENCE_NOW (epoch seconds, default the current time) pins the clock for tests.
evidence_matrix() {
    local catalog="$1" tool="$2" root="$3" image_tag="${4:-latest}" max_cells="${5:-200}"
    local cells
    cells="$(_em_tool_cells "$catalog" "$tool" "$root" "$image_tag")" || return 1
    _em_cap "$tool" "$max_cells" <<<"$cells"
}

# evidence_matrix_all <catalog_dir> <project_root> [image_tag] [max_cells]
#
# evidence_matrix for every luggage-managed tool in the catalog — each
# tools/<tool>/ with a versions/ directory (system_package entries have none) —
# merged into one matrix under one max_cells cap (#1341). Same exit statuses:
# 1 if ANY tool errors (a tool must not silently drop out of evidence), 3 only
# when no tool has a pending cell.
#
# Never-tested cells still precede failure retries across the whole set; within
# each group tools are interleaved round-robin (each tool's 1st cell, then each
# 2nd, ...) so one tool's backlog cannot take the whole cap from the others.
# Each tool keeps its own oldest-first order.
evidence_matrix_all() {
    local catalog="$1" root="$2" image_tag="${3:-latest}" max_cells="${4:-200}"
    local dir tool cells ranked="" tools=() available
    # Probe base-image publication once for the whole run, so every tool
    # judges a tuple against the same answer (and the registry is asked once).
    available="$(_em_available_tuples_json "$root")" || return 1
    for dir in "$catalog"/tools/*/versions; do
        [ -d "$dir" ] || continue
        tool="${dir%/versions}"
        tool="${tool##*/}"
        cells="$(_em_tool_cells "$catalog" "$tool" "$root" "$image_tag" "$available")" || return 1
        # rank = position within (tool, retry group), for the interleave.
        # Streamed through stdin, not --argjson: one argv string caps at 128 KiB.
        cells="$(command jq -c '
            group_by(.retry) | map(to_entries | map(.value + {rank: .key})) | add // []
        ' <<<"$cells")" || return 1
        ranked="$ranked$cells"$'\n'
        tools+=("$tool")
    done
    if [ "${#tools[@]}" -eq 0 ]; then
        command echo "evidence_matrix: no tools with a versions/ directory in $catalog" >&2
        return 1
    fi
    # Captured, not piped: without pipefail a jq failure would reach _em_cap
    # as empty input.
    cells="$(command jq -cs 'add | sort_by([.retry, .rank, .tool]) | map(del(.rank))' <<<"$ranked")" || return 1
    _em_cap "${tools[*]}" "$max_cells" <<<"$cells"
}
