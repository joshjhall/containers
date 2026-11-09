#!/bin/sh
# evidence-ccache-entry — run an evidence `luggage install` through ccache.
#
# Mounted into a source-build evidence cell's container and used as its
# command wrapper (#1594):
#
#   docker run ... -v "$CCACHE_HOST_DIR:/ccache" -e CCACHE_DIR=/ccache \
#     -v "$CCACHE_BIN:/opt/evidence-ccache/ccache:ro" ... \
#     "$IMAGE" /usr/local/bin/evidence-ccache-entry luggage install ...
#
# 1. Use the static ccache binary the runner fetched, verified, and mounted
#    at $EVIDENCE_CCACHE_BIN (default /opt/evidence-ccache/ccache). Nothing is
#    installed into the image: a ccache *package* would pull in runtime libs
#    (libstdc++, zstd, xxhash) that could mask a dependency the catalog
#    forgot, so a cell could pass that a clean install would fail.
# 2. If that binary runs, zero its stats, put its directory on PATH, and
#    export LUGGAGE_COMPILER_LAUNCHER=ccache, which luggage's source-build
#    method turns into CC="ccache cc" / CXX="ccache c++". luggage itself never
#    installs or assumes ccache, so production installs are unaffected.
# 3. Run the wrapped command, then write `ccache -s` to $CCACHE_STATS_OUT
#    (default /out/ccache-stats.txt) for the job summary.
# 4. Exit with the wrapped command's status, unchanged.
#
# Cache plumbing must never decide an evidence verdict: if the binary is
# missing or will not run, the command runs uncached, with a warning, rather
# than failing.
#
# POSIX sh, not bash: alpine base images do not ship bash.

set -u

if [ "$#" -eq 0 ]; then
    printf 'usage: evidence-ccache-entry <command> [args...]\n' >&2
    exit 64
fi

stats_out="${CCACHE_STATS_OUT:-/out/ccache-stats.txt}"
ccache_bin="${EVIDENCE_CCACHE_BIN:-/opt/evidence-ccache/ccache}"

cached=false
if [ -x "$ccache_bin" ] && "$ccache_bin" --version >/dev/null 2>&1; then
    "$ccache_bin" -z >/dev/null 2>&1 || true
    # luggage spawns the launcher by name, so its directory goes on PATH.
    PATH="${ccache_bin%/*}:$PATH"
    LUGGAGE_COMPILER_LAUNCHER=ccache
    export PATH LUGGAGE_COMPILER_LAUNCHER
    cached=true
    printf 'evidence-ccache-entry: ccache enabled (%s, CCACHE_DIR=%s)\n' \
        "$ccache_bin" "${CCACHE_DIR:-unset}" >&2
else
    unset LUGGAGE_COMPILER_LAUNCHER
    printf '::warning::evidence-ccache-entry: no runnable ccache at %s; building uncached\n' \
        "$ccache_bin" >&2
fi

"$@"
rc=$?

if [ "$cached" = true ]; then
    if ! "$ccache_bin" -s >"$stats_out" 2>&1; then
        printf 'evidence-ccache-entry: could not write ccache stats to %s\n' "$stats_out" >&2
    fi
fi

exit "$rc"
