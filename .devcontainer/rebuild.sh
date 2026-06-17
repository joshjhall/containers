#!/usr/bin/env bash
# rebuild.sh — pre-build the devcontainer image (HOST-side helper for Zed).
#
# Zed has no in-editor "Rebuild Container" action and does NOT detect
# .devcontainer/devcontainer.json changes, so after editing the devcontainer
# config (or when state is wedged) you tear the old container down and rebuild
# the image from a host terminal, then reopen the project. This wraps that.
#
# Why pre-build instead of letting Zed do it on reopen? Zed delegates to the
# devcontainer spec, which builds in two stages: (1) THIS image from
# docker-compose.yml (the slow part — Rust/Node/etc.), then (2) a generated
# Dockerfile.extended that layers devcontainer *features* on top. Zed
# regenerates stage 2 every launch and owns container creation (it injects
# SYS_PTRACE, seccomp=unconfined, and devcontainer labels via a runtime
# overlay), so this script CANNOT create the final container itself. What it
# CAN do is build stage 1 with the cache warm — Zed's build sets
# BUILDKIT_INLINE_CACHE=1, so on reopen it reuses every layer we built here and
# only the cheap features layer runs. Net effect: you control when the slow
# build happens, and the reopen is near-instant.
#
# Run this from a HOST terminal (your laptop), NOT inside the dev container.
#
# Usage:
#   .devcontainer/rebuild.sh [--no-cache] [--rmi] [--volumes] [--help]
#
#   (default)     down (keep image + cache), then `build` warm so reopen is fast
#   --no-cache    build with --no-cache (cold, slow) — use when layers are stale
#   --rmi         also remove the locally-built image on teardown
#   --volumes,-v  also drop named cache volumes (pip/npm/cargo/… — slower rebuild)
#   --help,-h     show this help
#
# After it finishes, reopen the project in Zed:
#   Cmd/Ctrl+Shift+P -> "project: open remote"  (or Ctrl/Alt+Cmd+Shift+O)

set -euo pipefail

# --- resolve paths (script lives in .devcontainer/) -------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

NO_CACHE=false
DROP_VOLUMES=false
REMOVE_IMAGE=false

usage() {
    command sed -n '2,30p' "${BASH_SOURCE[0]}" | command sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-cache) NO_CACHE=true ;;
        --rmi) REMOVE_IMAGE=true ;;
        --volumes | -v) DROP_VOLUMES=true ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            printf 'rebuild.sh: unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

# --- guards -----------------------------------------------------------------
# Must run on the host: you can't tear down the container from inside it.
if [ -f /.dockerenv ] || [ -f "$HOME/.container-initialized" ]; then
    printf 'rebuild.sh: looks like this is running INSIDE the dev container.\n' >&2
    printf '            Run it from a host terminal instead.\n' >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    printf 'rebuild.sh: docker not found on PATH.\n' >&2
    exit 1
fi

# Zed drives Compose v2 (`docker compose`), not the legacy `docker-compose`.
if ! docker compose version >/dev/null 2>&1; then
    printf 'rebuild.sh: `docker compose` (Compose v2) is required but not available.\n' >&2
    exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
    printf 'rebuild.sh: compose file not found: %s\n' "$COMPOSE_FILE" >&2
    exit 1
fi

# --- resolve the Compose project name ---------------------------------------
# Zed (and VS Code) launch the stack under a project name derived from the
# WORKSPACE folder (e.g. "containers_devcontainer"), NOT from this compose
# file's parent dir. If we let `docker compose` derive the name itself it would
# pick "devcontainer" (the .devcontainer/ dirname) and every command would
# target a project that doesn't exist — silently doing nothing and leaving the
# wedged container running. So discover the real name from the running/exited
# container's compose labels, keyed off this script's directory.
PROJECT_NAME="$(
    docker ps -a \
        --filter "label=com.docker.compose.project.working_dir=$SCRIPT_DIR" \
        --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | command head -n1
)"
# Fallback when no container exists yet (e.g. first build, or it was already
# removed): editors name the project "<workspace-folder-basename>_devcontainer".
if [ -z "$PROJECT_NAME" ]; then
    PROJECT_NAME="$(command basename "$(command dirname "$SCRIPT_DIR")")_devcontainer"
    printf '==> No existing container found; assuming project name: %s\n' "$PROJECT_NAME"
else
    printf '==> Targeting Compose project: %s\n' "$PROJECT_NAME"
fi

compose() {
    docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
}

# --- tear down --------------------------------------------------------------
# Default keeps the image and cache so the rebuild below is fast; --rmi/--volumes
# opt into the slow, clean-slate variants.
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

# --- build ------------------------------------------------------------------
# Build stage 1 now so Zed's reopen reuses the warm cache (BUILDKIT_INLINE_CACHE
# is set in Zed's build overlay). We do NOT `up` — Zed must create the runtime
# container itself with its devcontainer overlay (SYS_PTRACE, seccomp, labels).
if [ "$NO_CACHE" = true ]; then
    printf '==> Building image with --no-cache (cold; this takes a while)…\n'
    compose build --no-cache
else
    printf '==> Building image with warm cache…\n'
    compose build
fi

# --- next steps -------------------------------------------------------------
cat <<'EOF'

==> Image built. Reopen the project in Zed to create + start the container:
      Cmd/Ctrl+Shift+P  ->  "project: open remote"
      (shortcut: Ctrl+Cmd+Shift+O on macOS, Alt+Ctrl+Shift+O on Linux)

    Zed adds the devcontainer features layer on top of the image we just built
    (fast, since the slow layers are cached) and creates the container.

    Wait for first start to finish before working — quickest gate:
      [ -f ~/.container-initialized ] && echo ready
EOF
