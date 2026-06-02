#!/usr/bin/env bash
# Dispatch luggage evidence-run.yml for luggage-managed tools whose Dockerfile
# pin changed in a merged range (#506 Phase 2).
#
# Invoked by the auto-patch post-merge job after a version bump lands on main.
# For each luggage-managed tool whose `ARG <TOOL>_VERSION=` changed between
# --base and --head, it dispatches the evidence workflow for that tool@version.
#
# Cross-repo ordering: evidence-run.yml clones the sibling containers-db and
# hard-fails if `tools/<slug>/versions/<version>.json` is missing there. So this
# script first checks the sibling catalog; if the version isn't published yet it
# logs a clean deferral (the hourly containers-db scanner adds it independently)
# and moves on. Best-effort by design — never blocks the release.
#
# Usage:
#   bin/dispatch-evidence.sh --base <sha> --head <sha> [--dry-run]
#
# Env overrides:
#   EVIDENCE_TUPLE       base-image tuple slug   (default: debian-12-amd64)
#   EVIDENCE_IMAGE_TAG   base-image tag          (default: latest)
#   EVIDENCE_REPO        workflow repo           (default: joshjhall/containers)
#   CONTAINERS_DB_REPO   sibling catalog repo    (default: joshjhall/containers-db)
#   DISPATCH_PROJECT_ROOT  repo root override    (default: this script's ../)
set -euo pipefail

# Luggage-managed tools as `catalog_slug:DOCKERFILE_ARG`. Add a row when a
# feature script (lib/features/<tool>.sh) starts delegating installation to
# `luggage install <tool>@<version>`. Today: Rust only.
LUGGAGE_TOOLS=(
    "rust:RUST_VERSION"
)

EVIDENCE_REPO="${EVIDENCE_REPO:-joshjhall/containers}"
CONTAINERS_DB_REPO="${CONTAINERS_DB_REPO:-joshjhall/containers-db}"
EVIDENCE_TUPLE="${EVIDENCE_TUPLE:-debian-12-amd64}"
EVIDENCE_IMAGE_TAG="${EVIDENCE_IMAGE_TAG:-latest}"
WORKFLOW="evidence-run.yml"
# GitHub CLI, overridable for tests (a fake `gh` injected by absolute path).
GH="${GH:-gh}"

PROJECT_ROOT="${DISPATCH_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

BASE=""
HEAD=""
DRY_RUN=false

usage() {
    command sed -n '2,27p' "${BASH_SOURCE[0]}"
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

# Does the sibling catalog publish tools/<slug>/versions/<version>.json?
sibling_has_version() {
    local slug="$1" version="$2"
    "$GH" api "repos/${CONTAINERS_DB_REPO}/contents/tools/${slug}/versions/${version}.json" \
        >/dev/null 2>&1
}

dispatch_evidence() {
    local slug="$1" version="$2"
    "$GH" workflow run "$WORKFLOW" --repo "$EVIDENCE_REPO" \
        -f tool="$slug" \
        -f tool_version="$version" \
        -f tuple="$EVIDENCE_TUPLE" \
        -f image_tag="$EVIDENCE_IMAGE_TAG" \
        -f dry_run=false
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

    if sibling_has_version "$slug" "$version"; then
        if [ "$DRY_RUN" = true ]; then
            echo "PLAN dispatch ${slug} ${version} (tuple=${EVIDENCE_TUPLE} tag=${EVIDENCE_IMAGE_TAG})"
        else
            echo "dispatching evidence run for ${slug}@${version}"
            dispatch_evidence "$slug" "$version"
        fi
        dispatched=$((dispatched + 1))
    else
        echo "PLAN defer ${slug} ${version}"
        echo "evidence deferred: containers-db lacks ${slug}@${version} (sibling scanner will add it)"
    fi
done

echo "evidence dispatch complete (${dispatched} dispatched)"
