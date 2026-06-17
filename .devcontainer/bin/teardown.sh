#!/usr/bin/env bash
# teardown.sh — tear down the devcontainer stack (HOST-side helper for Zed).
#
# Zed has no in-editor "Rebuild Container" action and does NOT detect
# .devcontainer/devcontainer.json changes, so after editing the devcontainer
# config (or when state is wedged) you tear the old container down from a host
# terminal, then reopen the project so Zed rebuilds and recreates it.
#
# This script ONLY tears down. It deliberately does NOT pre-build the image:
# Zed drives its own build on reopen (it owns container creation — injecting
# SYS_PTRACE, seccomp=unconfined, and devcontainer labels via a runtime
# overlay, and it layers devcontainer *features* on top via a generated
# Dockerfile.extended). A host-side `compose build` runs on a different builder
# than Zed's, so the layers it produced were NOT reused on reopen — the warm
# cache never materialized. Letting Zed own the whole build is slower to reach
# (you close/reopen the project window) but it actually reuses its own cache.
#
# By default the image and named cache volumes are KEPT, so Zed's reopen build
# is incremental. Use --rmi / --volumes only when you want a clean slate.
#
# Run this from a HOST terminal (your laptop), NOT inside the dev container.
#
# Usage:
#   .devcontainer/bin/teardown.sh [--rmi] [--volumes] [--help]
#
#   (default)     stop + remove the container (image + caches kept)
#   --rmi         also remove the locally-built image on teardown
#   --volumes,-v  also drop named cache volumes (pip/npm/cargo/… — slower rebuild)
#   --help,-h     show this help
#
# After it finishes, reopen the project in Zed to rebuild + start the container:
#   Cmd/Ctrl+Shift+P -> "project: open remote"  (or Ctrl/Alt+Cmd+Shift+O)

set -euo pipefail

# --- resolve paths (script lives in .devcontainer/bin/) ---------------------
# SCRIPT_DIR is this script's dir (bin/); the compose file and the Compose
# working_dir label live one level up, in .devcontainer/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVCONTAINER_DIR="$(command dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$DEVCONTAINER_DIR/docker-compose.yml"

DROP_VOLUMES=false
REMOVE_IMAGE=false

usage() {
    command sed -n '2,30p' "${BASH_SOURCE[0]}" | command sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --rmi) REMOVE_IMAGE=true ;;
        --volumes | -v) DROP_VOLUMES=true ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            printf 'teardown.sh: unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

# --- guards -----------------------------------------------------------------
# Must run on the host: you can't tear down the container from inside it.
if [ -f /.dockerenv ] || [ -f "$HOME/.container-initialized" ]; then
    printf 'teardown.sh: looks like this is running INSIDE the dev container.\n' >&2
    printf '             Run it from a host terminal instead.\n' >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    printf 'teardown.sh: docker not found on PATH.\n' >&2
    exit 1
fi

# Zed drives Compose v2 (`docker compose`), not the legacy `docker-compose`.
if ! docker compose version >/dev/null 2>&1; then
    printf 'teardown.sh: `docker compose` (Compose v2) is required but not available.\n' >&2
    exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
    printf 'teardown.sh: compose file not found: %s\n' "$COMPOSE_FILE" >&2
    exit 1
fi

# --- resolve the Compose project name ---------------------------------------
# Zed (and VS Code) launch the stack under a project name derived from the
# WORKSPACE folder (e.g. "containers_devcontainer"), NOT from the compose
# file's parent dir. If we let `docker compose` derive the name itself it would
# pick "devcontainer" (the .devcontainer/ dirname) and every command would
# target a project that doesn't exist — silently doing nothing and leaving the
# wedged container running. So discover the real name from the running/exited
# container's compose labels, keyed off the .devcontainer/ dir (Compose's
# working_dir is the compose file's dir, not this script's bin/ dir).
PROJECT_NAME="$(
    docker ps -a \
        --filter "label=com.docker.compose.project.working_dir=$DEVCONTAINER_DIR" \
        --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | command head -n1
)"
# Fallback when no container exists yet (e.g. it was already removed): editors
# name the project "<workspace-folder-basename>_devcontainer".
if [ -z "$PROJECT_NAME" ]; then
    PROJECT_NAME="$(command basename "$(command dirname "$DEVCONTAINER_DIR")")_devcontainer"
    printf '==> No existing container found; assuming project name: %s\n' "$PROJECT_NAME"
else
    printf '==> Targeting Compose project: %s\n' "$PROJECT_NAME"
fi

compose() {
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
}

# --- tear down --------------------------------------------------------------
# Default keeps the image and cache so Zed's reopen build is incremental;
# --rmi/--volumes opt into the slow, clean-slate variants.
down_args=(down)
teardown_msg='==> Stopping and removing the container (image + caches kept)…'
if [ "$REMOVE_IMAGE" = true ]; then
    down_args+=(--rmi local)
    teardown_msg='==> Stopping container and removing the locally-built image…'
fi
if [ "$DROP_VOLUMES" = true ]; then
    down_args+=(--volumes)
    teardown_msg='==> Stopping container, removing image AND cache volumes…'
fi
printf '%s\n' "$teardown_msg"
compose "${down_args[@]}"

# --- next steps -------------------------------------------------------------
cat <<'EOF'

==> Torn down. Reopen the project in Zed to rebuild + start the container:
      Cmd/Ctrl+Shift+P  ->  "project: open remote"
      (shortcut: Ctrl+Cmd+Shift+O on macOS, Alt+Ctrl+Shift+O on Linux)

    Zed builds the image and layers the devcontainer features on top, then
    creates the container. The image + caches kept above keep that build
    incremental (use --rmi / --volumes next time for a clean slate).

    Wait for first start to finish before working — quickest gate:
      [ -f ~/.container-initialized ] && echo ready
EOF
