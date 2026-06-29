#!/usr/bin/env bash
# Dispatch luggage evidence-run.yml for luggage-managed tools whose Dockerfile
# pin changed in a merged range (#506 Phase 2, #645 full-matrix enumeration).
#
# Invoked by the auto-patch post-merge job after a version bump lands on main.
# For each luggage-managed tool whose `ARG <TOOL>_VERSION=` changed between
# --base and --head, it dispatches the evidence workflow once per tuple the new
# version actually claims AND that has a published base image — not one
# hardcoded tuple. A bump that previously evidenced a single cell now evidences
# every cell it declares `supported`, so a version never silently ships
# unverified support claims.
#
# Tuple set = support_matrix `supported` cells ∩ available base tuples. The
# available set is the local `base-images/<os>/<os_version>/<arch>/Dockerfile`
# tree (canonical per base-images/README.md, mirrored by build-base-images.yml),
# overridable for tests via DISPATCH_PROJECT_ROOT / PROJECT_ROOT. The
# intersection naturally tracks the "arm64 wired but inactive" reality: today
# only debian-12-amd64 is published, so even a version claiming arm64/debian-13
# fires only the cell that can actually run.
#
# Cross-repo ordering: evidence-run.yml clones the sibling containers-db and
# hard-fails if `tools/<slug>/versions/<version>.json` is missing there. So this
# script first fetches the sibling catalog entry; if the version isn't published
# yet it logs a clean deferral (the hourly containers-db scanner adds it
# independently) and moves on. Best-effort by design — never blocks the release.
#
# Usage:
#   bin/dispatch-evidence.sh --base <sha> --head <sha> [--dry-run]
#
# Env overrides:
#   EVIDENCE_TUPLE       single-tuple manual override (unset => enumerate matrix)
#   EVIDENCE_IMAGE_TAG   base-image tag          (default: latest)
#   EVIDENCE_REPO        workflow repo           (default: joshjhall/containers)
#   CONTAINERS_DB_REPO   sibling catalog repo    (default: joshjhall/containers-db)
#   DISPATCH_PROJECT_ROOT  repo root override    (default: this script's ../)
set -euo pipefail

# Luggage-managed tools as `catalog_slug:DOCKERFILE_ARG`. Add a row when a
# feature script (lib/features/<tool>.sh) starts delegating installation to
# `luggage install <tool>@<version>`. Today: Rust only. Mirrors
# bin/dispatch-evidence-for-tuple.sh — keep the two tables in sync until a third
# consumer justifies factoring them out.
LUGGAGE_TOOLS=(
    "rust:RUST_VERSION"
)

EVIDENCE_REPO="${EVIDENCE_REPO:-joshjhall/containers}"
CONTAINERS_DB_REPO="${CONTAINERS_DB_REPO:-joshjhall/containers-db}"
EVIDENCE_IMAGE_TAG="${EVIDENCE_IMAGE_TAG:-latest}"
WORKFLOW="evidence-run.yml"
# GitHub CLI, overridable for tests (a fake `gh` injected by absolute path).
GH="${GH:-gh}"

PROJECT_ROOT="${DISPATCH_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

BASE=""
HEAD=""
DRY_RUN=false

usage() {
    command sed -n '2,35p' "${BASH_SOURCE[0]}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --base)
            BASE="$2"
            shift 2
            ;;
        --head)
            HEAD="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -z "$BASE" ] || [ -z "$HEAD" ]; then
    echo "error: --base and --head are required" >&2
    exit 2
fi

# Current value of a Dockerfile ARG on the checked-out tree.
arg_value() {
    local arg="$1"
    command grep -E "^ARG ${arg}=" "$PROJECT_ROOT/Dockerfile" |
        command head -1 | command cut -d= -f2 | command tr -d '"'
}

# Did the `ARG <arg>=` line change between BASE and HEAD?
arg_changed() {
    local arg="$1"
    command git -C "$PROJECT_ROOT" diff "${BASE}..${HEAD}" -- Dockerfile |
        command grep -qE "^[+-]ARG ${arg}="
}

# Available base tuples = every base-images/<os>/<os_version>/<arch>/Dockerfile
# in the tree, emitted one `<os>-<os_version>-<arch>` slug per line. The
# base-images tree is the canonical source of "which tuples can actually run"
# (build-base-images.yml mirrors it). Guard the no-match case so an empty tree
# yields zero tuples rather than the literal glob.
available_base_tuples() {
    local dockerfile slug
    for dockerfile in "$PROJECT_ROOT"/base-images/*/*/*/Dockerfile; do
        [ -e "$dockerfile" ] || continue
        # .../base-images/<os>/<osv>/<arch>/Dockerfile -> os-osv-arch
        local arch_dir os_dir osv_dir
        arch_dir="$(command dirname "$dockerfile")" # .../<os>/<osv>/<arch>
        osv_dir="$(command dirname "$arch_dir")"    # .../<os>/<osv>
        os_dir="$(command dirname "$osv_dir")"      # .../<os>
        slug="$(command basename "$os_dir")-$(command basename "$osv_dir")-$(command basename "$arch_dir")"
        echo "$slug"
    done
}

# Fetch tools/<slug>/versions/<version>.json from the sibling catalog and decode
# it to raw JSON on stdout. `gh api .../contents/...` returns the file base64 in
# `.content`; decode so jq sees real JSON. Non-zero (empty stdout) on 404.
fetch_version_json() {
    local slug="$1" version="$2"
    "$GH" api "repos/${CONTAINERS_DB_REPO}/contents/tools/${slug}/versions/${version}.json" \
        --jq '.content' 2>/dev/null | command base64 -d 2>/dev/null
}

# Every `<os>-<os_version>-<arch>` slug the version's support_matrix claims
# `supported`, one per line. Apply the reconciler's wildcard rule: a row with no
# `os_version` matches any version of that os — but the slug still needs a
# concrete version token, so wildcard rows are skipped here (the available-tuple
# intersection supplies concrete versions; a wildcard claim is realized through
# whichever concrete available tuples it covers). Reads JSON on stdin.
supported_tuples_for_version() {
    command jq -r '
        .support_matrix[]?
        | select(.status == "supported" and (.os_version // null) != null)
        | "\(.os)-\(.os_version)-\(.arch)"
    '
}

dispatch_evidence() {
    local slug="$1" version="$2" tuple="$3"
    "$GH" workflow run "$WORKFLOW" --repo "$EVIDENCE_REPO" \
        -f tool="$slug" \
        -f tool_version="$version" \
        -f tuple="$tuple" \
        -f image_tag="$EVIDENCE_IMAGE_TAG" \
        -f dry_run=false
}

# Dispatch (or, in dry-run, plan) one evidence run for slug@version on tuple.
dispatch_one() {
    local slug="$1" version="$2" tuple="$3"
    if [ "$DRY_RUN" = true ]; then
        echo "PLAN dispatch ${slug} ${version} (tuple=${tuple} tag=${EVIDENCE_IMAGE_TAG})"
    else
        echo "dispatching evidence run for ${slug}@${version} on ${tuple}"
        dispatch_evidence "$slug" "$version" "$tuple"
    fi
}

dispatched=0
for entry in "${LUGGAGE_TOOLS[@]}"; do
    slug="${entry%%:*}"
    arg="${entry##*:}"

    if ! arg_changed "$arg"; then
        echo "no change: ${slug} (${arg}) — skipping"
        continue
    fi

    version="$(arg_value "$arg")"
    if [ -z "$version" ]; then
        echo "warning: ${arg} changed but no value found in Dockerfile; skipping ${slug}" >&2
        continue
    fi

    version_json="$(fetch_version_json "$slug" "$version" || true)"
    if [ -z "$version_json" ]; then
        echo "PLAN defer ${slug} ${version}"
        echo "evidence deferred: containers-db lacks ${slug}@${version} (sibling scanner will add it)"
        continue
    fi

    # EVIDENCE_TUPLE set => single-tuple manual override; dispatch only it,
    # bypassing the support_matrix ∩ available intersection (operator's call).
    if [ -n "${EVIDENCE_TUPLE:-}" ]; then
        dispatch_one "$slug" "$version" "$EVIDENCE_TUPLE"
        dispatched=$((dispatched + 1))
        continue
    fi

    # Enumerate: tuples the version claims `supported` ∩ tuples with a published
    # base image. The intersection is why only debian-12-amd64 fires today even
    # for a version that claims arm64/debian-13 (those base images aren't built).
    claimed="$(printf '%s' "$version_json" | supported_tuples_for_version)"
    available="$(available_base_tuples)"

    resolved=""
    if [ -n "$claimed" ] && [ -n "$available" ]; then
        # comm needs sorted input; both lists are small and unique per source.
        resolved="$(command comm -12 \
            <(printf '%s\n' "$claimed" | command sort -u) \
            <(printf '%s\n' "$available" | command sort -u))"
    fi

    if [ -z "$resolved" ]; then
        echo "no supported tuples available for ${slug}@${version}"
        continue
    fi

    while IFS= read -r tuple; do
        [ -n "$tuple" ] || continue
        dispatch_one "$slug" "$version" "$tuple"
        dispatched=$((dispatched + 1))
    done <<<"$resolved"
done

echo "evidence dispatch complete (${dispatched} dispatched)"
