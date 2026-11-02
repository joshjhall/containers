#!/bin/sh
# evidence-ccache-entry — run an evidence `luggage install` through ccache.
#
# Mounted into a source-build evidence cell's container and used as its
# command wrapper (#1594):
#
#   docker run ... -v "$CCACHE_HOST_DIR:/ccache" -e CCACHE_DIR=/ccache ... \
#     "$IMAGE" /usr/local/bin/evidence-ccache-entry luggage install ...
#
# 1. Install ccache with whatever package manager the base image has.
# 2. On success, zero its stats and export LUGGAGE_COMPILER_LAUNCHER=ccache,
#    which luggage's source-build method turns into CC="ccache cc" /
#    CXX="ccache c++". luggage itself never installs or assumes ccache, so
#    production installs are unaffected.
# 3. Run the wrapped command, then write `ccache -s` to $CCACHE_STATS_OUT
#    (default /out/ccache-stats.txt) for the job summary.
# 4. Exit with the wrapped command's status, unchanged.
#
# Cache plumbing must never decide an evidence verdict: if ccache cannot be
# installed the command runs uncached, with a warning, rather than failing.
#
# POSIX sh, not bash: alpine base images do not ship bash.

set -u

if [ "$#" -eq 0 ]; then
    printf 'usage: evidence-ccache-entry <command> [args...]\n' >&2
    exit 64
fi

stats_out="${CCACHE_STATS_OUT:-/out/ccache-stats.txt}"

install_ccache() {
    if command -v ccache >/dev/null 2>&1; then
        return 0
    fi
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache ccache
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && DEBIAN_FRONTEND=noninteractive \
            apt-get install -y --no-install-recommends ccache
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ccache
    elif command -v microdnf >/dev/null 2>&1; then
        microdnf install -y ccache
    else
        printf 'evidence-ccache-entry: no known package manager\n' >&2
        return 1
    fi
}

cached=false
if install_ccache >&2 && command -v ccache >/dev/null 2>&1; then
    ccache -z >/dev/null 2>&1 || true
    LUGGAGE_COMPILER_LAUNCHER=ccache
    export LUGGAGE_COMPILER_LAUNCHER
    cached=true
    printf 'evidence-ccache-entry: ccache enabled (CCACHE_DIR=%s)\n' "${CCACHE_DIR:-unset}" >&2
else
    unset LUGGAGE_COMPILER_LAUNCHER
    printf '::warning::evidence-ccache-entry: ccache unavailable; building uncached\n' >&2
fi

"$@"
rc=$?

if [ "$cached" = true ]; then
    if ! ccache -s >"$stats_out" 2>&1; then
        printf 'evidence-ccache-entry: could not write ccache stats to %s\n' "$stats_out" >&2
    fi
fi

exit "$rc"
