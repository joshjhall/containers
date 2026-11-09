#!/usr/bin/env bash
# fetch-release-asset.sh — download one release asset, surviving brief outages.
#
# Usage: bin/fetch-release-asset.sh URL DEST
#
# CI installs its pinned toolchain (lint tools, yq, gitleaks, osv-scanner) from
# GitHub release assets. A bare `curl -fsSL` turned a few hours of upstream
# `releases/download` 504s into three failed release attempts in a row, while
# the very same assets were served fine by the API asset path (#1607). So:
#
#   1. Cache. When TOOLCHAIN_CACHE_DIR is set and already holds the URL, copy
#      it and log `cache hit: <asset>` — a warm run downloads nothing.
#   2. curl with retries on every transient error (5xx included).
#   3. Fallback: for a github.com/<owner>/<repo>/releases/download/<tag>/<asset>
#      URL, `gh release download`, which goes through api.github.com.
#   4. A successful download is stored in TOOLCHAIN_CACHE_DIR (when set).
#
# This script only FETCHES. Integrity is the caller's job: every caller
# verifies DEST against its pinned checksum after this returns — including on
# a cache hit, so a poisoned cache entry fails exactly like a bad download.
#
# Cache entries are keyed by the whole URL, not the asset's file name: several
# pinned assets carry no version in their name (yq_linux_amd64,
# conform-linux-amd64), so a name-keyed entry would hand an old version to a
# bumped pin.
#
# Exits 0 with DEST written, or prints a `::error::` line and exits 1.
set -euo pipefail

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
    printf '::error::usage: %s URL DEST\n' "${0##*/}" >&2
    exit 1
fi

url="$1"
dest="$2"
asset="${url##*/}"
cache_dir="${TOOLCHAIN_CACHE_DIR:-}"

# Retry knobs are overridable only so the unit test can keep its stubbed
# failure path fast; CI uses the defaults.
retries="${FETCH_RETRIES:-5}"
retry_delay="${FETCH_RETRY_DELAY:-5}"

if [ -z "$asset" ]; then
    printf '::error::cannot derive an asset name from %s\n' "$url" >&2
    exit 1
fi

# https://github.com/o/r/releases/download/v1/x.tgz -> github.com_o_r_releases_download_v1_x.tgz
cache_key="${url#*://}"
cache_key="${cache_key//[^A-Za-z0-9._-]/_}"

if [ -n "$cache_dir" ] && [ -s "$cache_dir/$cache_key" ]; then
    command cp -- "$cache_dir/$cache_key" "$dest"
    printf 'cache hit: %s\n' "$asset"
    exit 0
fi

# Download into a temp file beside DEST and move it into place only on
# success, so a failed attempt never leaves a truncated DEST for the caller.
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

command mv -f -- "$tmp" "$dest"
trap - EXIT

if [ -n "$cache_dir" ]; then
    command mkdir -p -- "$cache_dir"
    command cp -- "$dest" "$cache_dir/$cache_key"
fi
printf 'downloaded: %s\n' "$asset"
