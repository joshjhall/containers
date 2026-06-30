#!/usr/bin/env bash
# workflow-scripts-dir.sh — resolve the librarian `workflow` plugin's bundled
# `scripts/` directory for the justfile's golem/worktree recipes (#609).
#
# The golem/worktree flow's canonical scripts (worktree-new.sh, worktree-rm.sh,
# golem-status.sh, golem-attach.sh, golem-watch.sh, …) live in the `workflow`
# plugin of the `librarian` marketplace, so they run on host / bare Linux /
# inside a devcontainer WITHOUT `just`. Skills invoke them via the
# `${CLAUDE_PLUGIN_ROOT}` env var that Claude Code injects at runtime.
#
# `just` recipes run OUTSIDE Claude Code, where `${CLAUDE_PLUGIN_ROOT}` is unset,
# so the thin-wrapper recipes need their own way to find that same directory.
# This helper is that just-side analogue: it prints the absolute path to the
# bundled `scripts/` dir on stdout (exit 0), or prints guidance to stderr and
# exits 1 when the plugin can't be located.
#
# Resolution order (first hit wins):
#   1. $WORKFLOW_SCRIPTS_DIR        explicit override (testing / unusual layouts)
#   2. $CLAUDE_PLUGIN_ROOT/scripts  when a recipe is run from within Claude Code
#   3. newest installed cache       ~/.claude/plugins/cache/librarian/workflow/*/scripts
#                                   (highest version dir wins; this is where the
#                                   pinned local-marketplace install lands — #608)
#   4. dev mount                    /workspace/librarian/plugins/workflow/scripts
#                                   (the temporary ../../librarian compose mount
#                                   used until librarian has its own devcontainer)
#
# A directory only counts as a hit when it actually contains the bundled scripts
# (config.sh is the source-of-truth sibling every script sources), so a stale
# empty dir never shadows a real one further down the list.
#
# Usage: workflow-scripts-dir.sh        # prints the dir, or fails with guidance
#        scripts="$(workflow-scripts-dir.sh)"
set -euo pipefail

# A candidate is valid only if it holds the bundled scripts. config.sh is sourced
# by every other script, so its presence is the cheapest reliable marker.
is_scripts_dir() {
    [ -n "${1:-}" ] && [ -f "$1/config.sh" ]
}

# 1. Explicit override.
if [ -n "${WORKFLOW_SCRIPTS_DIR:-}" ] && is_scripts_dir "$WORKFLOW_SCRIPTS_DIR"; then
    /usr/bin/printf '%s\n' "$WORKFLOW_SCRIPTS_DIR"
    exit 0
fi

# 2. Inside Claude Code: the plugin root is injected.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && is_scripts_dir "$CLAUDE_PLUGIN_ROOT/scripts"; then
    /usr/bin/printf '%s\n' "$CLAUDE_PLUGIN_ROOT/scripts"
    exit 0
fi

# 3. Newest installed marketplace cache. Versions are sortable dirs
#    (e.g. 0.1.0); pick the highest with `sort -V` so an upgraded install wins.
cache_base="${HOME:-/home/$(/usr/bin/id -un)}/.claude/plugins/cache/librarian/workflow"
if [ -d "$cache_base" ]; then
    while IFS= read -r ver; do
        [ -z "$ver" ] && continue
        if is_scripts_dir "$cache_base/$ver/scripts"; then
            /usr/bin/printf '%s\n' "$cache_base/$ver/scripts"
            exit 0
        fi
    done < <(/usr/bin/ls -1 "$cache_base" 2>/dev/null | /usr/bin/sort -Vr)
fi

# 4. Temporary dev mount (until librarian ships its own devcontainer — #607).
#    Path overridable via WORKFLOW_DEV_MOUNT (mainly so tests can point the
#    last-resort probe at a controlled location); defaults to the compose mount.
dev_mount="${WORKFLOW_DEV_MOUNT:-/workspace/librarian/plugins/workflow/scripts}"
if is_scripts_dir "$dev_mount"; then
    /usr/bin/printf '%s\n' "$dev_mount"
    exit 0
fi

command echo "workflow-scripts-dir: could not locate the librarian 'workflow' plugin scripts." >&2
command echo "  Looked in: \$WORKFLOW_SCRIPTS_DIR, \$CLAUDE_PLUGIN_ROOT/scripts," >&2
command echo "  $cache_base/*/scripts, and $dev_mount." >&2
command echo "  Install the librarian marketplace (see docs/claude-code/) or set WORKFLOW_SCRIPTS_DIR." >&2
exit 1
