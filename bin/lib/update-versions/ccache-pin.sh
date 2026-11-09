#!/bin/bash
# Static ccache pin bump for update-versions.sh (#1611)
#
# Description:
#   Sourced by updaters.sh. Relies on its sed_inplace() (dry-run aware),
#   RC_INVALID_VERSION, RC_PIN_UNREWRITABLE and RC_UPDATE_FAILED, all
#   resolved at call time.
#
#   evidence-run.yml's "Fetch static ccache" step pins CCACHE_VERSION plus a
#   per-arch sha256 of the musl-static release tarball. Upstream publishes
#   only minisign signatures (no sha256 files), so the bump downloads both
#   tarballs and hashes them itself. The version and both digests must move
#   together: a version without matching digests makes every source-build
#   cell fall back to an uncached build (the fetch step only warns).
#
#   Trust model: the digest is trust-on-first-use — it pins the bytes seen at
#   bump time (over HTTPS) against later tampering, and the bump lands as a
#   reviewed auto-patch PR. It does not verify upstream's minisign signature.

# The arches the workflow pins, as `<CCACHE_SHA256_ suffix>:<asset arch>`.
CCACHE_PIN_ARCHES=("X86_64:x86_64" "AARCH64:aarch64")

# ccache_asset_sha256 - Print the sha256 of one musl-static release tarball.
#
# Arguments:
#   $1 - ccache version (X.Y.Z)
#   $2 - asset arch (x86_64 | aarch64)
#
# Returns:
#   0 and the 64-hex digest on stdout, or 1 (nothing on stdout) on failure.
#   A separate function so the unit tests can stub the network away.
ccache_asset_sha256() {
    local version="$1" carch="$2"
    local name="ccache-${version}-linux-${carch}-musl-static"
    local url="https://github.com/ccache/ccache/releases/download/v${version}/${name}.tar.xz"
    local tmp sum rc=0
    tmp=$(command mktemp) || return 1
    # https only, redirects included: the digest is trust-on-first-use, so a
    # downgraded redirect must not get to choose the bytes we pin. The size cap
    # (the tarball is ~1 MB) bounds a runaway response.
    if command curl -fsSL --retry 3 --proto '=https' --proto-redir '=https' \
        --max-filesize 67108864 -o "$tmp" "$url"; then
        # No pipe: sha256sum's own status must decide rc (a `| cut` would
        # report cut's 0 over a failed hash).
        sum=$(command sha256sum "$tmp") || rc=1
        sum=${sum%% *}
    else
        echo -e "${RED:-}    ERROR: could not download $url${NC:-}" >&2
        rc=1
    fi
    command rm -f "$tmp"
    [ "$rc" -eq 0 ] || return 1
    printf '%s\n' "$sum"
}

# bump_ccache_pin - Rewrite CCACHE_VERSION and both per-arch digests.
#
# Arguments:
#   $1 - path to .github/workflows/evidence-run.yml
#   $2 - new ccache version (X.Y.Z)
#
# Description:
#   Every digest is fetched and validated BEFORE any write, and the three
#   lines are rewritten by one sed_inplace call, so a failed download leaves
#   the workflow byte-identical rather than half-bumped.
#
# Returns:
#   0 on success; RC_INVALID_VERSION when the version is refused, or
#   RC_PIN_UNREWRITABLE when a pin line's shape is refused (both before any
#   write); RC_UPDATE_FAILED when a digest can't be computed or the write fails.
bump_ccache_pin() {
    local workflow_path="$1" latest="$2"

    # The version is spliced into the download URL, so only plain X.Y.Z.
    [[ $latest =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo -e "${RED}    ERROR: refusing non-X.Y.Z ccache version '$latest'${NC}" >&2
        return "$RC_INVALID_VERSION"
    }

    # sed exits 0 on no match, so a reformatted pin would otherwise report a
    # bump that wrote nothing. Require each line in the shape the seds expect.
    local entry suffix
    for entry in "VERSION:" "${CCACHE_PIN_ARCHES[@]}"; do
        suffix=${entry%%:*}
        if [ "$suffix" = VERSION ]; then
            command grep -qE '^ +CCACHE_VERSION: [0-9][^[:space:]]*$' "$workflow_path"
        else
            command grep -qE "^ +CCACHE_SHA256_${suffix}: [0-9a-f]{64}\$" "$workflow_path"
        fi || {
            echo -e "${RED}    ERROR: no CCACHE_${suffix} pin line found in $workflow_path — leaving it unchanged${NC}" >&2
            return "$RC_PIN_UNREWRITABLE"
        }
    done

    # Short-circuit ahead of the downloads so a dry run needs no network.
    if [ "${DRY_RUN:-false}" = true ]; then
        return 0
    fi

    local script="s/^\( *CCACHE_VERSION: \)[0-9][^[:space:]]*\$/\1${latest}/"
    local carch sum
    for entry in "${CCACHE_PIN_ARCHES[@]}"; do
        suffix=${entry%%:*} carch=${entry#*:}
        sum=$(ccache_asset_sha256 "$latest" "$carch") || sum=""
        [[ $sum =~ ^[0-9a-f]{64}$ ]] || {
            echo -e "${RED}    ERROR: no sha256 for ccache $latest ($carch) — leaving the pin unchanged${NC}" >&2
            return "$RC_UPDATE_FAILED"
        }
        script+=";s/^\( *CCACHE_SHA256_${suffix}: \)[0-9a-f]\{64\}\$/\1${sum}/"
    done

    # One sed script, one write: all three lines change together.
    sed_inplace "$script" "$workflow_path" || return "$RC_UPDATE_FAILED"
    echo -e "${BLUE}    Pinned ccache → ${latest} (x86_64 + aarch64 digests)${NC}"
}
