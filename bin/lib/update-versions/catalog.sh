#!/bin/bash
# Vendored luggage catalog updates for update-versions.sh
#
# Description:
#   Sourced by updaters.sh. Relies on PROJECT_ROOT, DRY_RUN and the color
#   variables, all resolved at call time.

# Add a bumped luggage-installed tool's new version to the vendored catalog
# snapshot (crates/luggage/testdata/catalog), which the image build COPYs to
# /opt/containers-db and resolves `luggage install <tool>@<version>` against.
# Without this, a Dockerfile pin can outrun the catalog and the build fails
# with "no version of <tool> matches spec <version>" (see issue #506).
#
# The `luggage catalog add-version` subcommand is additive and idempotent, so a
# re-run for an already-present version is a no-op. A missing luggage binary is
# a hard error rather than a silent skip: skipping would let the pin and the
# catalog drift, breaking the build the change is meant to keep green.
# add-version keeps index.json consistent; the version file itself is then
# replaced by containers-db's copy when one exists (mirror_upstream_catalog_entry).
# Usage: update_luggage_catalog <tool> <version>
update_luggage_catalog() {
    local tool="$1"
    local version="$2"
    local catalog="$PROJECT_ROOT/crates/luggage/testdata/catalog"

    # Short-circuit ahead of the binary probe so a dry run does not require a
    # built luggage, and cannot report a spurious RC_UPDATE_FAILED for its absence.
    if [ "${DRY_RUN:-false}" = true ]; then
        return 0
    fi

    local luggage_bin="${LUGGAGE_BIN:-}"
    if [ -z "$luggage_bin" ]; then
        if [ -x "$PROJECT_ROOT/target/release/luggage" ]; then
            luggage_bin="$PROJECT_ROOT/target/release/luggage"
        elif [ -x "$PROJECT_ROOT/target/debug/luggage" ]; then
            luggage_bin="$PROJECT_ROOT/target/debug/luggage"
        else
            luggage_bin="$(command -v luggage 2>/dev/null || true)"
        fi
    fi

    if [ -z "$luggage_bin" ]; then
        echo -e "${RED}    ERROR: luggage binary not found; cannot update vendored catalog for ${tool}@${version}${NC}" >&2
        echo -e "${YELLOW}    Build it first (cargo build --release -p luggage) or set LUGGAGE_BIN.${NC}" >&2
        return 1
    fi

    echo -e "${BLUE}    Updating vendored luggage catalog: ${tool}@${version}${NC}"
    "$luggage_bin" catalog add-version "${tool}@${version}" --catalog "$catalog" || return 1
    mirror_upstream_catalog_entry "$tool" "$version" "$catalog"
}

# mirror_upstream_catalog_entry - Replace a freshly added vendored catalog
# version file with containers-db's copy, when containers-db has one.
#
# Arguments:
#   $1 - tool slug (e.g. rust)
#   $2 - version (e.g. 1.99.0)
#   $3 - vendored catalog root (crates/luggage/testdata/catalog)
#
# Description:
#   `luggage catalog add-version` builds the entry by cloning the newest
#   vendored version, so it carries today's timestamps, today as `released`,
#   and no `tested[]` rows. tests/unit/vendored-catalog.sh fails any version
#   present in both catalogs that disagrees, and since the containers-db
#   scanner publishes new versions within a day, upstream normally already
#   has the version by the time auto-patch bumps the pin. Without this, every
#   such bump red-lit its own auto-patch branch.
#
#   Source: $CONTAINERS_DB_SRC when it is a checkout (CI and local runs),
#   else containers-db main over HTTPS (the repo is public). Not
#   ${CONTAINERS_DB:-}: inside these containers that is /opt/containers-db,
#   the image's copy of this same vendored snapshot.
#
#   No upstream entry (or no way to reach it) keeps the generated file: the
#   pin still needs a catalog entry to install, and the drift gate reports a
#   vendored-only version as skipped, not as drift. The fallback is announced
#   on stderr so it is never mistaken for a mirrored entry.
mirror_upstream_catalog_entry() {
    local tool="$1" version="$2" catalog="$3"
    local rel="tools/$tool/versions/$version.json"
    local dest="$catalog/$rel"
    local tmp
    tmp="$(command mktemp)" || return 1

    if [ -n "${CONTAINERS_DB_SRC:-}" ] && [ -d "$CONTAINERS_DB_SRC/tools" ]; then
        if [ -f "$CONTAINERS_DB_SRC/$rel" ]; then
            command cp "$CONTAINERS_DB_SRC/$rel" "$tmp"
        else
            : >"$tmp"
        fi
    elif ! command curl -fsSL --retry 3 \
        "https://raw.githubusercontent.com/joshjhall/containers-db/main/$rel" \
        -o "$tmp" 2>/dev/null; then
        : >"$tmp"
    fi

    # Only a well-formed entry for exactly this tool@version replaces the
    # generated one; a 404 page, an empty fetch, or a mismatched file does not.
    if [ -s "$tmp" ] && command jq -e \
        --arg t "$tool" --arg v "$version" \
        '.tool == $t and .version == $v' "$tmp" >/dev/null 2>&1; then
        command cp "$tmp" "$dest"
        command rm -f "$tmp"
        echo -e "${BLUE}    Mirrored containers-db entry for ${tool}@${version}${NC}"
        return 0
    fi

    command rm -f "$tmp"
    echo -e "${YELLOW}    containers-db has no ${tool}@${version} entry yet; keeping the generated one${NC}" >&2
    return 0
}
