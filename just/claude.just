# ============================================================================
# Claude Code configuration
# ============================================================================
# Idempotent install / remove / read-only check recipes operating on a Claude
# Code CONFIGURATION — the host's ~/.claude, and the container's plugin
# registry. Split out of just/golem.just (#943): these are neither worktree nor
# golem orchestration, and that module's name overstated its scope once the
# librarian-repair pair landed beside the host-event trio.
#
# Every recipe here is safe to re-run. The `-check` variants write nothing and
# exit non-zero when the thing they check is not in place, which is what makes
# them usable as CI or pre-flight guards.
#
# Note the two different targets, and that the distinction is load-bearing:
# `host-events-*` wraps a bin/ script and acts on the HOST ~/.claude, while
# `claude-plugins-*` calls an in-container command and acts on the container's
# plugin registry. See the comment above those recipes.

# Opt-in: wire the INCLUDE_HOST_EVENTS forwarder into the HOST ~/.claude for worktree golems (#738). Idempotent, preserves existing hooks.
host-events-install:
    bash "{{ justfile_directory() }}/bin/seed-host-events.sh" install

# Un-wire the host event forwarder from the HOST ~/.claude (removes only our hooks + the copied script).
host-events-remove:
    bash "{{ justfile_directory() }}/bin/seed-host-events.sh" remove

# Report whether the host event forwarder is wired into the HOST ~/.claude (read-only; exit 1 if not).
host-events-check:
    bash "{{ justfile_directory() }}/bin/seed-host-events.sh" check

# ============================================================================
# Librarian plugin repair (#777)
# ============================================================================
# A Claude Code update inside a running container can silently de-register the
# librarian marketplace and uninstall dev-core/review-audit/workflow. Every
# /workflow:*, /dev-core:* and /review-audit:* skill then vanishes mid-session
# with no error — `claude plugin list` just stops listing them.
#
# These call the in-container command, NOT a bin/ script: the repair must run
# against the image-baked, LIBRARIAN_REF-pinned /opt/librarian cache, which only
# exists inside the container. Re-adding the marketplace from a librarian
# working-tree checkout instead would register the un-pinned tree and silently
# defeat the pin.

# Re-register + reinstall the librarian plugins from the image-baked /opt/librarian cache.
claude-plugins-repair:
    claude-plugins-repair repair

# Report whether the librarian marketplace + all three plugins are registered (read-only; exit 1 if not).
claude-plugins-check:
    claude-plugins-repair check
