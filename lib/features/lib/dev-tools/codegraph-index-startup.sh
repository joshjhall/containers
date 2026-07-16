#!/bin/bash
# Keep codegraph's per-project knowledge-graph index built and current, on
# every container start.
#
# codegraph serves an MCP server (registered default-on via mcp-registry.sh)
# that answers from a per-project index living at <project>/.codegraph. The
# index is useless until built, and goes stale as the tree changes, so this
# hook builds it once and then cheaply syncs it on every subsequent boot —
# ensuring a fresh graph is ready before the next round of work.
#
# Index location — why a symlink:
#   codegraph's CODEGRAPH_DIR override only accepts a plain directory NAME that
#   it joins to the project root; absolute paths are rejected. So we can't point
#   it at /cache directly. Instead we symlink <project>/.codegraph ->
#   /cache/codegraph, which the devcontainer backs with a named volume. That
#   keeps the (potentially large) index off the git working tree, lets it
#   survive image rebuilds, and makes it independently droppable to force a
#   clean re-index (docker volume rm <project>-codegraph).
#
# Why every-boot (startup/) and not first-startup/:
#   The index lives on the droppable /cache/codegraph volume, so it can be
#   absent even when the first-run marker is set (fresh volume, image rebuild,
#   manual `docker volume rm`). A first-startup hook would never rebuild it. An
#   every-boot hook self-heals: init when there's no db, sync when there is.
#
# Why setsid-detached:
#   Under VS Code the image entrypoint runs as PID 1 and outlives this script,
#   so a bare `&` background job survives. Under Zed the entrypoint is replayed
#   by `recover-entrypoint` as a transient process that exits immediately; its
#   process group (and any bare-`&` children) gets reaped, killing an in-flight
#   index build. `setsid` detaches the build into its own session so it survives
#   the replay and never blocks startup. See docs/troubleshooting/zed-devcontainer.md.
#
# Runs as the container user. Non-fatal. No-op when codegraph isn't installed or
# no workspace is resolvable. VS Code / JetBrains / Zed all benefit equally.

set -euo pipefail

CODEGRAPH_CACHE_DIR="/cache/codegraph"

# Resolve the project root. WORKING_DIR is baked into the image env (Dockerfile
# `ENV WORKING_DIR`); fall back to $PWD for standalone/manual invocations.
PROJECT_DIR="${WORKING_DIR:-${PWD:-}}"

# No codegraph binary (e.g. dev-tools not installed) → nothing to do.
if ! command -v codegraph >/dev/null 2>&1; then
    exit 0
fi

# No resolvable workspace → nothing to index.
if [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ]; then
    echo "[codegraph-index] no workspace dir (WORKING_DIR/PWD unset or missing); skipping"
    exit 0
fi

CODEGRAPH_LINK="${PROJECT_DIR}/.codegraph"

# Ensure the cache target exists (the named volume mounts here; fix-cache-
# permissions reconciles ownership on startup).
command mkdir -p "$CODEGRAPH_CACHE_DIR"

# Point .codegraph at the cache volume, unless something is already there.
if [ -L "$CODEGRAPH_LINK" ]; then
    : # already a symlink (ours) — leave it
elif [ -e "$CODEGRAPH_LINK" ]; then
    # A real dir/file already exists (e.g. an index built before this hook, or a
    # user-created one). Don't clobber it; just note that it's not on the volume.
    echo "[codegraph-index] ${CODEGRAPH_LINK} already exists and is not a symlink;"
    echo "  leaving it in place (index will NOT use the ${CODEGRAPH_CACHE_DIR} volume)."
else
    command ln -s "$CODEGRAPH_CACHE_DIR" "$CODEGRAPH_LINK"
    echo "[codegraph-index] linked ${CODEGRAPH_LINK} -> ${CODEGRAPH_CACHE_DIR}"
fi

# Choose the operation: full init when there's no index yet, cheap incremental
# sync when there is. Both run detached so startup is never blocked. Non-fatal.
if [ -f "${CODEGRAPH_CACHE_DIR}/codegraph.db" ]; then
    CODEGRAPH_OP="sync"
    echo "[codegraph-index] existing index found; syncing changes in background..."
else
    CODEGRAPH_OP="init"
    echo "[codegraph-index] no index found; building initial index in background..."
fi

# Detach with setsid so the build survives a transient parent (the Zed
# recover-entrypoint replay), and redirect all fds so it never holds the
# startup pipe open.
setsid bash -c '
    cd "'"$PROJECT_DIR"'" || exit 0
    if /usr/local/bin/codegraph "'"$CODEGRAPH_OP"'" . >/tmp/codegraph-index.log 2>&1; then
        echo "[codegraph-index] '"$CODEGRAPH_OP"' complete" >>/tmp/codegraph-index.log
    else
        echo "[codegraph-index] '"$CODEGRAPH_OP"' failed (see above); MCP will index on demand" \
            >>/tmp/codegraph-index.log
    fi
' </dev/null >/dev/null 2>&1 &

exit 0
