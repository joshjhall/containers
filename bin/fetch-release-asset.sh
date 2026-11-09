#!/usr/bin/env bash
# fetch-release-asset.sh — download one pinned release asset, verified, surviving
# brief upstream outages.
#
# Usage: bin/fetch-release-asset.sh [--sha256 HEX] URL DEST
#
# CI installs its pinned toolchain (lint tools, yq, gitleaks, osv-scanner) from
# GitHub release assets. A bare `curl -fsSL` turned a few hours of upstream
# `releases/download` 504s into three failed release attempts in a row, while
# the very same assets were served fine by the API asset path (#1607). So:
#
#   1. Cache. When TOOLCHAIN_CACHE_DIR is set and holds the URL, use it and log
#      `cache hit: <asset>` — a warm run downloads nothing.
#   2. curl with retries on every transient error (5xx included).
#   3. Fallback: for a github.com/<owner>/<repo>/releases/download/<tag>/<asset>
#      URL, `gh release download`, which goes through api.github.com.
#   4. A verified download is stored in TOOLCHAIN_CACHE_DIR (when set).
#
# Integrity (--sha256). The cache persists across runs, so an unverified entry
# would be reused by every later run until a pin changes. With --sha256 the
# helper verifies BOTH paths itself: a cache entry that does not match is
# evicted and re-downloaded (never handed to the caller), a download that does
# not match fails the run, and only verified bytes are ever cached. Without
# --sha256 nothing is cached — an unverifiable asset must not outlive its run.
#
# Cache entries are keyed by the whole URL, not the asset's file name: several
# pinned assets carry no version in their name (yq_linux_amd64,
# conform-linux-amd64), so a name-keyed entry would hand an old version to a
# bumped pin.
#
# Exits 0 with DEST written, or prints a `::error::` line and exits 1.
set -euo pipefail

usage() {
    printf '::error::usage: %s [--sha256 HEX] URL DEST\n' "${0##*/}" >&2
    exit 1
}

want_sha=""
if [ "${1:-}" = "--sha256" ]; then
    [ "$#" -ge 2 ] || usage
    want_sha="$2"
    shift 2
    if [[ ! "$want_sha" =~ ^[0-9a-f]{64}$ ]]; then
        printf '::error::--sha256 must be 64 lowercase hex characters (got %s)\n' "$want_sha" >&2
        exit 1
    fi
fi
if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
    usage
fi

url="$1"
dest="$2"
asset="${url##*/}"
cache_dir=""
# Only a verifiable asset may be cached (see "Integrity" above).
[ -n "$want_sha" ] && cache_dir="${TOOLCHAIN_CACHE_DIR:-}"

# Retry knobs are overridable only so the unit test can keep its stubbed
# failure path fast; CI uses the defaults.
retries="${FETCH_RETRIES:-5}"
retry_delay="${FETCH_RETRY_DELAY:-5}"

if [ -z "$asset" ]; then
    printf '::error::cannot derive an asset name from %s\n' "$url" >&2
    exit 1
fi

# sha_ok <file> — true when no checksum was pinned, or <file> matches it.
sha_ok() {
    [ -z "$want_sha" ] && return 0
    local got
    got=$(command sha256sum -- "$1" | command cut -d' ' -f1)
    [ "$got" = "$want_sha" ]
}

# https://github.com/o/r/releases/download/v1/x.tgz -> github.com_o_r_releases_download_v1_x.tgz
cache_key="${url#*://}"
cache_key="${cache_key//[^A-Za-z0-9._-]/_}"

if [ -n "$cache_dir" ] && [ -s "$cache_dir/$cache_key" ]; then
    if sha_ok "$cache_dir/$cache_key"; then
        command cp -- "$cache_dir/$cache_key" "$dest"
        printf 'cache hit: %s\n' "$asset"
        exit 0
    fi
    # A bad entry would otherwise fail every run until a pin changed.
    printf '::warning::cached %s does not match its pinned SHA256; evicting and re-downloading\n' "$asset" >&2
    command rm -f -- "$cache_dir/$cache_key"
fi

# Download into a temp file beside DEST and move it into place only once it is
# complete and verified, so a failed attempt never leaves a bad DEST behind.
tmp="$(command mktemp "${dest}.part.XXXXXX")"
trap 'command rm -f -- "$tmp"' EXIT

fetched=no
# Plain --retry covers timeouts and HTTP 408/429/500/502/503/504 only;
# --retry-all-errors extends it to connection resets, TLS failures, partial
# transfers and other 5xx codes — any of which a flaky CDN edge can produce.
if command curl -fsSL \
    --retry "$retries" --retry-all-errors --retry-delay "$retry_delay" \
    --connect-timeout 20 \
    -o "$tmp" "$url"; then
    fetched=yes
else
    printf '::warning::curl could not fetch %s after %s retries\n' "$url" "$retries" >&2
    # owner/repo/tag from https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>
    if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/download/(.+)/([^/]+)$ ]]; then
        repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        tag="${BASH_REMATCH[3]}"
        if command -v gh >/dev/null 2>&1; then
            printf 'falling back to the API asset path: gh release download %s -R %s -p %s\n' \
                "$tag" "$repo" "$asset" >&2
            if command gh release download "$tag" -R "$repo" -p "$asset" \
                -O "$tmp" --clobber; then
                fetched=yes
            fi
        else
            printf '::warning::gh not on PATH; no API fallback for %s\n' "$asset" >&2
        fi
    fi
fi

if [ "$fetched" != yes ] || [ ! -s "$tmp" ]; then
    printf '::error::failed to download %s\n' "$url" >&2
    exit 1
fi

if ! sha_ok "$tmp"; then
    printf '::error::%s does not match its pinned SHA256 %s\n' "$asset" "$want_sha" >&2
    exit 1
fi

command mv -f -- "$tmp" "$dest"
trap - EXIT

if [ -n "$cache_dir" ]; then
    command mkdir -p -- "$cache_dir"
    command cp -- "$dest" "$cache_dir/$cache_key"
fi
if [ -n "$want_sha" ]; then
    printf 'downloaded + verified: %s\n' "$asset"
else
    printf 'downloaded: %s\n' "$asset"
fi
