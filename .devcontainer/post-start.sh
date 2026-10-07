#!/usr/bin/env bash
# post-start.sh — Runs on EVERY devcontainer start (devcontainer.json
# `postStartCommand`). One-time setup lives in post-create.sh.
#
# Order matters and is preserved from the old inline chain
# (`recover-entrypoint && … && setup-git && setup-gh`):
#
#   1. recover-entrypoint — no-op under VS Code (the image ENTRYPOINT already
#      ran as PID 1); under Zed, which replaces the ENTRYPOINT despite
#      `"overrideCommand": false`, it replays it so OP_*_REF secrets resolve
#      before the steps below need them.
#   2. setup-git — git identity + SSH auth/signing keys.
#   3. setup-gh  — gh auth from GITHUB_TOKEN.
#
# `set -e` keeps the old `&&` abort semantics: a failing step skips the rest.
# See docs/troubleshooting/zed-devcontainer.md#lifecycle-hook-behavior.
set -euo pipefail

echo "==> Replaying image entrypoint if needed..."
recover-entrypoint

echo "==> Configuring git..."
setup-git

echo "==> Configuring gh..."
setup-gh

echo "==> Post-start setup complete."
