#!/usr/bin/env bash
# Dispatch luggage evidence-run.yml for a base-image tuple that was just rebuilt
# to a new digest (#640).
#
# Invoked by build-base-images.yml after a tuple's image is published + signed.
# Evidence freshness rides on `image_digest`: a rebuilt base image is
# content-addressed to a new digest and should yield a new `tested[]` row. But
# evidence-run.yml's triggers are path-scoped to source dirs, so a CVE-patch
# rebuild (new digest, identical Dockerfile) fires nothing on its own. This
# script closes that loop: for each luggage-managed tool that claims the rebuilt
# tuple `supported`, it dispatches an evidence run — unless the newest passing
# evidence already records this exact digest.
#
# Two-layer idempotency:
#   - Dispatch layer (here): skip when the new digest already equals the newest
#     passing `tested[]` digest for the cell, so an identical rebuild fires no
#     workflow at all.
#   - Ingest layer (bin/ingest-evidence.sh): even a redundant dispatch no-ops on
#     the (os, os_version, arch, image_digest) dedup key.
#
# Cross-repo ordering: evidence-run.yml clones the sibling containers-db and
# hard-fails if `tools/<slug>/versions/<version>.json` is missing there. So this
# script first checks the sibling catalog; if the version isn't published yet it
# logs a clean deferral (the sibling scanner adds it independently) and moves on.
# Best-effort by design — never blocks the base-image build.
#
# Usage:
#   bin/dispatch-evidence-for-tuple.sh --tuple <os>-<os_version>-<arch> \
#       --digest <sha256:...> [--image-tag <tag>] [--dry-run]
#
# Env overrides:
#   EVIDENCE_IMAGE_TAG   base-image tag          (default: latest)
#   EVIDENCE_REPO        workflow repo           (default: joshjhall/containers)
#   CONTAINERS_DB_REPO   sibling catalog repo    (default: joshjhall/containers-db)
#   DISPATCH_PROJECT_ROOT  repo root override    (default: this script's ../)
set -euo pipefail

# Luggage-managed tools as `catalog_slug:DOCKERFILE_ARG`. Add a row when a
# feature script (lib/features/<tool>.sh) starts delegating installation to
# `luggage install <tool>@<version>`. Today: Rust only. Mirrors
# bin/dispatch-evidence.sh — keep the two tables in sync until a third consumer
# justifies factoring them out.
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

TUPLE=""
DIGEST=""
DRY_RUN=false

usage() {
    command sed -n '2,33p' "${BASH_SOURCE[0]}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tuple)
            TUPLE="$2"
            shift 2
            ;;
        --digest)
            DIGEST="$2"
            shift 2
            ;;
        --image-tag)
            EVIDENCE_IMAGE_TAG="$2"
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

if [ -z "$TUPLE" ] || [ -z "$DIGEST" ]; then
    echo "error: --tuple and --digest are required" >&2
    exit 2
fi

# Validate the digest shape up front — the same guard evidence-run.yml applies
# before recording a row. A malformed digest means the build emitted something
# unexpected; fail loudly rather than dispatch against garbage.
if [[ ! "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "error: --digest is not a sha256:<64 hex>: $DIGEST" >&2
    exit 2
fi

# Split debian-12-amd64 -> OS=debian OSV=12 ARCH=amd64. Mirror evidence-run.yml's
# "Derive tuple coordinates" guard: exactly three dash-separated parts.
IFS='-' read -ra _tuple_parts <<<"$TUPLE"
if [ "${#_tuple_parts[@]}" -ne 3 ]; then
    echo "error: --tuple has unexpected shape: $TUPLE (want <os>-<os_version>-<arch>)" >&2
    exit 2
fi
OS="${_tuple_parts[0]}"
OSV="${_tuple_parts[1]}"
ARCH="${_tuple_parts[2]}"

# Current value of a Dockerfile ARG on the checked-out tree.
arg_value() {
    local arg="$1"
    command grep -E "^ARG ${arg}=" "$PROJECT_ROOT/Dockerfile" |
        command head -1 | command cut -d= -f2 | command tr -d '"'
}

# Fetch tools/<slug>/versions/<version>.json from the sibling catalog and decode
# it to raw JSON on stdout. `gh api .../contents/...` returns the file base64 in
# `.content`; decode so jq sees real JSON. Non-zero (empty stdout) on 404.
fetch_version_json() {
    local slug="$1" version="$2"
    "$GH" api "repos/${CONTAINERS_DB_REPO}/contents/tools/${slug}/versions/${version}.json" \
        --jq '.content' 2>/dev/null | command base64 -d 2>/dev/null
}

# Does the tool's support_matrix claim this tuple `supported`? Apply the
# reconciler's wildcard rule: a row with no `os_version` matches any version of
# that os. Reads JSON on stdin.
tuple_is_supported() {
    command jq -e --arg os "$OS" --arg osv "$OSV" --arg arch "$ARCH" '
        [ .support_matrix[]?
          | select(.os == $os and .arch == $arch
                   and ((.os_version // null) == null or .os_version == $osv)
                   and .status == "supported") ] | length > 0
    ' >/dev/null
}

# Newest (by tested_at) passing tested[] row's image_digest for this cell, or ""
# if none. A failed row's digest must not suppress a fresh re-test, so restrict
# to result == "pass". Reads JSON on stdin.
newest_tested_digest() {
    command jq -r --arg os "$OS" --arg osv "$OSV" --arg arch "$ARCH" '
        [ .tested[]?
          | select(.os == $os and .arch == $arch
                   and ((.os_version // null) == null or .os_version == $osv)
                   and .result == "pass" and (.image_digest != null)) ]
        | sort_by(.tested_at) | last | (.image_digest // "")
    '
}

dispatch_evidence() {
    local slug="$1" version="$2"
    "$GH" workflow run "$WORKFLOW" --repo "$EVIDENCE_REPO" \
        -f tool="$slug" \
        -f tool_version="$version" \
        -f tuple="$TUPLE" \
        -f image_tag="$EVIDENCE_IMAGE_TAG" \
        -f dry_run=false
}

dispatched=0
for entry in "${LUGGAGE_TOOLS[@]}"; do
    slug="${entry%%:*}"
    arg="${entry##*:}"

    version="$(arg_value "$arg")"
    if [ -z "$version" ]; then
        echo "warning: no value for ${arg} in Dockerfile; skipping ${slug}" >&2
        continue
    fi

    version_json="$(fetch_version_json "$slug" "$version" || true)"
    if [ -z "$version_json" ]; then
        echo "PLAN defer ${slug} ${version}"
        echo "evidence deferred: containers-db lacks ${slug}@${version} (sibling scanner will add it)"
        continue
    fi

    if ! printf '%s' "$version_json" | tuple_is_supported; then
        echo "skip: ${slug}@${version} does not claim ${TUPLE} supported"
        continue
    fi

    newest="$(printf '%s' "$version_json" | newest_tested_digest)"
    if [ "$newest" = "$DIGEST" ]; then
        echo "no-op: ${slug}@${version} newest tested digest already == ${DIGEST}"
        continue
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "PLAN dispatch ${slug} ${version} (tuple=${TUPLE} digest=${DIGEST})"
    else
        echo "dispatching evidence run for ${slug}@${version} on ${TUPLE}"
        dispatch_evidence "$slug" "$version"
    fi
    dispatched=$((dispatched + 1))
done

echo "evidence dispatch complete (${dispatched} dispatched)"
