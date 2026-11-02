#!/bin/bash
# Re-vendor stibbons' repo-baseline templates for update-versions.sh
#
# Description:
#   Sourced by updaters.sh. Relies on PROJECT_ROOT, DRY_RUN and the color
#   variables, all resolved at call time.

# The sync script ships beside this module, not under PROJECT_ROOT (which tests
# override to a fixture tree that need not carry it).
REPO_BASELINE_SYNC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/sync-repo-baseline.sh"

# sync_repo_baseline - Re-vendor crates/stibbons/assets/repo-baseline/ from the
# librarian release a LIBRARIAN_REF bump moves to (#1543).
#
# Arguments:
#   $1 - librarian version, without the leading `v` (e.g. 0.19.0)
#
# Description:
#   `stibbons setup standards` embeds librarian's repo-baseline templates. A pin
#   bump that skipped this left the embedded copy silently behind the pinned
#   librarian. bin/sync-repo-baseline.sh does the copy and keeps the local
#   pygments patch until librarian ships it.
#
#   Source: $LIBRARIAN_SRC when set (tests, offline runs), else a shallow clone
#   of joshjhall/librarian at tag v<version>. The source's VERSION must equal
#   <version>: vendoring some other release under the new pin is exactly the
#   drift this exists to prevent. Any failure returns 1 so the caller reports
#   RC_UPDATE_FAILED — a pin bumped without its templates must fail the run,
#   never auto-merge.
sync_repo_baseline() {
    local version="$1" src tmp="" got rc=0

    if [ "${DRY_RUN:-false}" = true ]; then
        return 0
    fi

    if [ -n "${LIBRARIAN_SRC:-}" ]; then
        src="$LIBRARIAN_SRC"
    else
        tmp="$(command mktemp -d)" || return 1
        src="$tmp/librarian"
        echo -e "${BLUE}    Cloning librarian v${version} for repo-baseline templates${NC}"
        if ! command git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v${version}" \
            https://github.com/joshjhall/librarian.git "$src" >&2; then
            echo -e "${RED}    ERROR: could not clone librarian v${version}${NC}" >&2
            command rm -rf "$tmp"
            return 1
        fi
    fi

    got=""
    if [ -f "$src/VERSION" ]; then
        got="$(command tr -d '[:space:]' <"$src/VERSION")"
    fi
    if [ "$got" != "$version" ]; then
        echo -e "${RED}    ERROR: librarian source ${src} is version '${got}', expected ${version}${NC}" >&2
        rc=1
    elif ! REPO_BASELINE_DEST="$PROJECT_ROOT/crates/stibbons/assets/repo-baseline" \
        "$REPO_BASELINE_SYNC" "$src"; then
        echo -e "${RED}    ERROR: re-vendoring repo-baseline templates from librarian ${version} failed${NC}" >&2
        rc=1
    fi

    [ -z "$tmp" ] || command rm -rf "$tmp"
    return "$rc"
}
