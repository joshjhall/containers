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
# tuple. Re-running a covered cell is a no-op at ingest (the dedup key matches),
# so it would only burn runners — and the full product (18 versions x 18
# tuples = 324) exceeds GitHub's 256-job matrix cap outright. A base-image
# rebuild re-evidences its tuple separately (dispatch-evidence-for-tuple.sh).
# `max_cells` caps one run; the backlog drains over successive pushes, oldest
# versions first so the floor gets covered before the newest release.
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

# evidence_matrix <catalog_dir> <tool> <project_root> [image_tag] [max_cells]
#
# Prints the matrix JSON on stdout (max_cells defaults to 200, under GitHub's
# 256 cap). Exit status:
#   0  a non-empty matrix was printed
#   1  error (no index, bad catalog) — nothing printed
#   3  nothing pending — every cell already has passing evidence; nothing
#      printed. Callers skip the evidence job rather than run an empty matrix.
evidence_matrix() {
    local catalog="$1" tool="$2" root="$3" image_tag="${4:-latest}" max_cells="${5:-200}"
    local index="$catalog/tools/$tool/index.json"
    [ -f "$index" ] || {
        command echo "evidence_matrix: no index for $tool at $index" >&2
        return 1
    }

    local available
    available="$(_em_available_tuples "$root" | command jq -R . | command jq -cs .)"

    local plumbing
    plumbing="$(command jq -cn \
        --arg a "$(_em_arch_plumbing amd64)" \
        --arg b "$(_em_arch_plumbing arm64)" \
        '{amd64: ($a | split(" ")), arm64: ($b | split(" "))}')"

    local out
    out="$(command jq -cs \
        --arg tool "$tool" \
        --arg tag "$image_tag" \
        --argjson available "$available" \
        --argjson plumbing "$plumbing" \
        --slurpfile index "$index" '
        def vkey: split(".") | map(tonumber? // 0);
        ($index[0].minimum_recommended // "0") as $floor
        | map(select((.version | vkey) >= ($floor | vkey)))
        # newest patch per X.Y minor
        | group_by(.version | vkey | .[0:2])
        | map(max_by(.version | vkey))
        | sort_by(.version | vkey)
        | [ .[] as $v
            | $v.support_matrix[]?
            | select(.status == "supported" and (.os_version // null) != null)
            | "\(.os)-\(.os_version)-\(.arch)" as $tuple
            | select($available | index($tuple))
            | select($plumbing[.arch])
            | . as $cell
            # pending: no passing evidence row for this exact tuple
            | select([ $v.tested[]?
                       | select(.result == "pass" and .os == $cell.os
                                and (.os_version // "") == $cell.os_version
                                and .arch == $cell.arch) ] | length == 0)
            | {tool: $tool, version: $v.version, tuple: $tuple, image_tag: $tag,
               arch: .arch, runner: $plumbing[.arch][0], runtime: $plumbing[.arch][1],
               rust_target: $plumbing[.arch][2]} ]
        | unique_by([.version, .tuple])
        | sort_by([(.version | vkey), .tuple])
        | {include: .[0:'"$max_cells"'], pending_total: length}
    ' "$catalog/tools/$tool/versions/"*.json)" || return 1

    local total
    total="$(command jq '.pending_total' <<<"$out")"
    if [ "$total" -eq 0 ]; then
        command echo "evidence_matrix: $tool has no pending evidence cells" >&2
        return 3
    fi
    if [ "$total" -gt "$max_cells" ]; then
        command echo "evidence_matrix: $total pending cells for $tool; running the oldest $max_cells this time" >&2
    fi
    command jq -c 'del(.pending_total)' <<<"$out"
}
