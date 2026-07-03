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
# Trust boundary (#667): the justfile `exec bash`es the scripts in the resolved
# dir, so a resolved dir is accepted only when it is TRUSTED — owned by the
# invoking user AND not group/world-writable. That closes the theme surfaced by
# #609's review: a cache "version" dir, an env-override, or a shared dev mount
# that an attacker can write into would otherwise be exec'd. A distrusted source
# does not hard-fail; it is skipped so a trusted source further down the list
# still wins (a trusted lower-priority dir beats an untrusted higher-priority
# one).
#
# Usage: workflow-scripts-dir.sh        # prints the dir, or fails with guidance
#        scripts="$(workflow-scripts-dir.sh)"
set -euo pipefail

# A candidate is valid only if it holds the bundled scripts. config.sh is sourced
# by every other script, so its presence is the cheapest reliable marker.
is_scripts_dir() {
    [ -n "${1:-}" ] && [ -f "$1/config.sh" ]
}

# A candidate is trusted only if it is owned by the invoking user and is not
# group- or world-writable — otherwise another principal could plant/replace the
# scripts the justfile is about to exec. `find -user`/`find -perm -MODE` are used
# deliberately: the resolver runs on macOS BSD + Alpine busybox too, where
# `stat`'s formatting flags differ (`-c` GNU vs `-f` BSD), while these `find`
# primitives are common to GNU/BSD/busybox. `-perm -0020`/`-perm -0002` match
# when the group-/other-write bit is set; a match means "writable" ⇒ distrusted.
is_trusted_dir() {
    local dir="${1:-}" owner
    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    owner="$(/usr/bin/id -un)"
    # Owned by us?
    [ -n "$(/usr/bin/find "$dir" -maxdepth 0 -user "$owner" 2>/dev/null)" ] || return 1
    # Group- or world-writable? (any match ⇒ not trusted)
    [ -z "$(/usr/bin/find "$dir" -maxdepth 0 \( -perm -0020 -o -perm -0002 \) 2>/dev/null)" ]
}

# Accept a candidate only when it both holds the bundled scripts AND is trusted.
# On a valid-but-distrusted dir, warn once and return non-zero so the caller
# falls through to the next resolution source.
accept() {
    local dir="${1:-}"
    is_scripts_dir "$dir" || return 1
    if ! is_trusted_dir "$dir"; then
        command echo "workflow-scripts-dir: refusing $dir — not owned by $(/usr/bin/id -un) or is group/world-writable; skipping (#667)." >&2
        return 1
    fi
    return 0
}

# 1. Explicit override.
if [ -n "${WORKFLOW_SCRIPTS_DIR:-}" ] && accept "$WORKFLOW_SCRIPTS_DIR"; then
    /usr/bin/printf '%s\n' "$WORKFLOW_SCRIPTS_DIR"
    exit 0
fi

# 2. Inside Claude Code: the plugin root is injected.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && accept "$CLAUDE_PLUGIN_ROOT/scripts"; then
    /usr/bin/printf '%s\n' "$CLAUDE_PLUGIN_ROOT/scripts"
    exit 0
fi

# 3. Newest installed marketplace cache. Versions are sortable dirs (e.g.
#    0.1.0); pick the highest so an upgraded install wins. `sort -V` is the
#    natural fit but is a GNU coreutils extension absent from macOS BSD sort and
#    busybox (Alpine) — and this resolver's whole point is to run on a host Mac
#    and bare Linux. Probe once for `-V` and fall back to a field-based numeric
#    sort on the dotted components, which busybox/BSD/GNU all support. (Detect
#    the capability up front rather than `sort -Vr || sort ...` in the pipe: the
#    first sort would drain stdin before the fallback could re-read it.)
cache_base="${HOME:-/home/$(/usr/bin/id -un)}/.claude/plugins/cache/librarian/workflow"
if [ -d "$cache_base" ]; then
    if /usr/bin/printf '1\n' | /usr/bin/sort -V >/dev/null 2>&1; then
        version_sort=(/usr/bin/sort -Vr)
    else
        version_sort=(/usr/bin/sort "-t." "-k1,1rn" "-k2,2rn" "-k3,3rn")
    fi
    while IFS= read -r ver; do
        [ -z "$ver" ] && continue
        if accept "$cache_base/$ver/scripts"; then
            /usr/bin/printf '%s\n' "$cache_base/$ver/scripts"
            exit 0
        fi
    done < <(/usr/bin/ls -1 "$cache_base" 2>/dev/null | "${version_sort[@]}")
fi

# 4. Temporary dev mount (until librarian ships its own devcontainer — #607).
#    Path overridable via WORKFLOW_DEV_MOUNT (mainly so tests can point the
#    last-resort probe at a controlled location); defaults to the compose mount.
dev_mount="${WORKFLOW_DEV_MOUNT:-/workspace/librarian/plugins/workflow/scripts}"
if accept "$dev_mount"; then
    /usr/bin/printf '%s\n' "$dev_mount"
    exit 0
fi

command echo "workflow-scripts-dir: could not locate a trusted librarian 'workflow' plugin scripts dir." >&2
command echo "  Looked in: \$WORKFLOW_SCRIPTS_DIR, \$CLAUDE_PLUGIN_ROOT/scripts," >&2
command echo "  $cache_base/*/scripts, and $dev_mount." >&2
command echo "  A candidate must contain config.sh AND be owned by $(/usr/bin/id -un) and not group/world-writable (#667)." >&2
command echo "  Install the librarian marketplace (see docs/claude-code/) or set WORKFLOW_SCRIPTS_DIR." >&2
exit 1
