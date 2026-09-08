# ============================================================================
# Worktree & orchestration (golems)
# ============================================================================
#
# These recipes are THIN WRAPPERS over the canonical scripts bundled in the
# `librarian` marketplace's `workflow` plugin (#609). The scripts — not these
# recipes — are the source of truth, so the golem/worktree flow runs identically
# on a host Mac, a bare Linux box, or inside a devcontainer WITHOUT `just`
# (skills invoke them via `${CLAUDE_PLUGIN_ROOT}`; `just` is muscle-memory sugar
# on top). `bin/workflow-scripts-dir.sh` locates the bundled `scripts/` dir
# (the just-side analogue of `${CLAUDE_PLUGIN_ROOT}`, which is unset outside
# Claude Code).
#
# Per-environment config is env-overridable (defaults live in the plugin's
# `config.sh`); export any of these before `just` to relocate worktrees, rename
# branches, or point at a different librarian checkout:
#   GOLEM_WORKTREE_DIR          per-issue worktree dir   (default .worktrees)
#   GOLEM_STATUS_DIR            status cache + feed dir   (default <wt>/.status)
#   GOLEM_BRANCH_PREFIX         branch is <prefix><N>     (default feature/issue-)
#   GOLEM_BASE_REF              ref new branches fork from (default origin/main)
#   GOLEM_WORKTREE_LOCAL_FILES  gitignored files copied into a fresh worktree
#                               (default ".env .claude/settings.local.json")
#   WORKFLOW_SCRIPTS_DIR        override the bundled-scripts location entirely

# Create a push-ready Mode-2 worktree for issue N (idempotent; copies .env etc.).
worktree-new N:
    #!/usr/bin/env bash
    set -euo pipefail
    # Guard N at the just layer before it reaches the shell. just interpolates
    # `{{ N }}` TEXTUALLY before bash parses the line, so a raw `[[ "{{ N }}" ]]`
    # would eagerly run `$(...)` / break quotes (injection) even though the regex
    # later rejects it. `quote()` emits a properly shell-escaped literal, so the
    # value is captured verbatim and only THEN validated. The bundled script
    # re-validates too; this is defense-in-depth at the wrapper.
    _n={{ quote(N) }}
    [[ "$_n" =~ ^[0-9]+$ ]] || { command echo "worktree-new: N must be an issue number, got '$_n'" >&2; exit 2; }
    scripts="$("{{ justfile_directory() }}/bin/workflow-scripts-dir.sh")"
    exec bash "$scripts/worktree-new.sh" "$_n"

# Post-merge cleanup: remove the issue-N worktree and its feature/issue-N branch (clean no-op if absent).
worktree-rm N:
    #!/usr/bin/env bash
    set -euo pipefail
    # See worktree-new for why N is quoted before validation (just interpolates
    # textually; quote() prevents eager $(...)/quote-break injection).
    _n={{ quote(N) }}
    [[ "$_n" =~ ^[0-9]+$ ]] || { command echo "worktree-rm: N must be an issue number, got '$_n'" >&2; exit 2; }
    scripts="$("{{ justfile_directory() }}/bin/workflow-scripts-dir.sh")"
    bash "$scripts/worktree-rm.sh" "$_n"
    # The bundled script is intentionally portable and does NOT carry the
    # containers-specific tail below: a golem PR usually merges into origin/main
    # right before its worktree is torn down, and on a BARE host the on-disk
    # runtime copies (.claude/hooks, justfile, bin) don't update on their own
    # (no work tree to check out into), so the next golem would fire the
    # just-superseded hook/justfile (#606). Refresh them here. Best-effort and
    # bare-host-only: a normal checkout uses git checkout/pull and is left
    # untouched; any failure never aborts the teardown.
    if [ "$(git rev-parse --is-bare-repository 2>/dev/null)" = "true" ]; then
        bash "{{ justfile_directory() }}/bin/sync-host.sh" || \
            echo "  (sync-host refresh skipped — run 'just sync-host' manually)" >&2
    fi

# Show the central golem status table + which golems are BLOCKED (TTY-free).
golems:
    #!/usr/bin/env bash
    set -euo pipefail
    scripts="$("{{ justfile_directory() }}/bin/workflow-scripts-dir.sh")"
    exec bash "$scripts/golem-status.sh"

# Attach to issue N's golem session (worktree or container).
golem-attach N:
    #!/usr/bin/env bash
    set -euo pipefail
    # See worktree-new for why N is quoted before validation.
    _n={{ quote(N) }}
    [[ "$_n" =~ ^[0-9]+$ ]] || { command echo "golem-attach: N must be an issue number, got '$_n'" >&2; exit 2; }
    scripts="$("{{ justfile_directory() }}/bin/workflow-scripts-dir.sh")"
    exec bash "$scripts/golem-attach.sh" "$_n"

# Proactively watch for blocked golems (streams feed + pane gate channels; Ctrl-C to stop).
golem-watch:
    #!/usr/bin/env bash
    set -euo pipefail
    scripts="$("{{ justfile_directory() }}/bin/workflow-scripts-dir.sh")"
    exec bash "$scripts/golem-watch.sh"

# A bare repo never checks files out, so the host's on-disk .claude/hooks,
# justfile, and bin/ drift behind origin/main after a merge and it runs stale
# hooks/justfile (#606). Pass path prefixes to narrow the set.
# Refresh a bare host's on-disk runtime copies (.claude/hooks, justfile, bin) from origin/main.
sync-host *PREFIXES:
    bash "{{ justfile_directory() }}/bin/sync-host.sh" {{ PREFIXES }}

# Drift guard for #606: report any on-disk runtime copy that differs from origin/main, exit non-zero if so (writes nothing).
sync-host-check *PREFIXES:
    bash "{{ justfile_directory() }}/bin/sync-host.sh" --check {{ PREFIXES }}
