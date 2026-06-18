#!/bin/bash
# Bootstrap codegraph's per-project knowledge-graph index on first startup.
#
# codegraph serves an MCP server (registered default-on via mcp-registry.sh)
# that answers from a per-project index living at <project>/.codegraph. The
# index is useless until built, so this hook builds it once after the workspace
# is mounted.
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
# Runs once (first-startup), as the container user, after the workspace mount
# is present. Non-fatal and backgrounded so a slow/large index never blocks
# container startup. No-op when codegraph isn't installed or no workspace is
# mounted. VS Code / JetBrains / Zed all benefit equally — this is editor-
# agnostic.

set -euo pipefail

CODEGRAPH_CACHE_DIR="/cache/codegraph"
PROJECT_DIR="${WORKING_DIR:-}"

# No codegraph binary (e.g. dev-tools not installed) → nothing to do.
if ! command -v codegraph >/dev/null 2>&1; then
    exit 0
fi

# No mounted workspace → nothing to index.
if [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ]; then
    echo "[codegraph-index] no workspace dir (WORKING_DIR unset/missing); skipping"
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

# Skip indexing if an index is already present on the volume.
if [ -f "${CODEGRAPH_CACHE_DIR}/codegraph.db" ]; then
    echo "[codegraph-index] existing index found; skipping initial build"
    exit 0
fi

# Build the index in the background so startup is never blocked. Non-fatal.
echo "[codegraph-index] building initial index in ${PROJECT_DIR} (background)..."
(
    cd "$PROJECT_DIR" || exit 0
    if /usr/local/bin/codegraph init . >/tmp/codegraph-index.log 2>&1; then
        echo "[codegraph-index] index build complete" >>/tmp/codegraph-index.log
    else
        echo "[codegraph-index] index build failed (see above); MCP will index on demand" \
            >>/tmp/codegraph-index.log
    fi
) &

exit 0
