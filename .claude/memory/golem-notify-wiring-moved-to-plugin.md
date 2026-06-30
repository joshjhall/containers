---
name: golem-notify-wiring-moved-to-plugin
description: "golem-notify Notification hook is auto-wired by the librarian workflow plugin's hooks.json; the build no longer wires it"
metadata:
  node_type: memory
  type: project
  originSessionId: 6693106f-000b-4ebc-869b-50f81428e63c
---

# 611 removed the build-bound `golem-notify.sh` (and its manual settings.json

wiring in `claude-code-setup.sh`). The orchestrate golem "BLOCKED — needs a
human" Notification hook now ships *inside* the librarian **workflow** plugin:
`plugins/workflow/hooks/hooks.json` declares the `Notification` event →
`bash "${CLAUDE_PLUGIN_ROOT}/hooks/golem-notify.sh"`. Claude Code auto-wires it
on plugin install — no settings.json edit needed.

**Why:** keeping the manual `~/.claude/hooks/golem-notify.sh` wiring after the
template was deleted would leave a dangling hook path nothing populates. The
plugin (installed offline+unconditionally by claude-setup, default set
`dev-core,review-audit,workflow`) is the single source.

**How to apply:** if golem BLOCKED notifications stop working in-container,
check the workflow plugin is installed (`claude plugin list`), NOT
settings.json. The host runtime copy at `.claude/hooks/golem-notify.sh` (synced
from origin/main by sync-host.sh) still exists for bare-host use and is
unrelated to the container plugin path. See [[librarian-plugin-extraction]],
[[librarian-container-install]], [[golem-feed-event-classification]].
