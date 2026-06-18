#!/bin/bash
# Bootstrap ~/.config/zed/settings.json with LSP overrides that point Zed
# extensions at the system binaries this container already ships.
#
# Why: several Zed extensions bundle or npm-install their own copy of a
# language server on first connect — racing the postinstall and surfacing
# sticky "failed to start language server" toasts. We already ship the
# matching binaries via dev-tools (dprint, taplo), so pointing the
# extensions at /usr/local/bin/* avoids the race entirely.
#
# Runs in first-startup so we never clobber a user who has written their
# own settings.json (keymaps, themes, AI provider configs, etc.). Users
# with pre-existing settings can paste the printed override block into
# their settings.json manually.
#
# VS Code / JetBrains envs ignore ~/.config/zed/, so this is a no-op
# outside Zed.
#
# The written file is intentionally COMMENT-FREE (strict JSON), not JSONC:
# sibling first-startup scripts (e.g. 41-zed-agent-config) jq-merge into this
# same file, and jq cannot parse // comments. Keeping it strict JSON makes it a
# clean merge base. (Follow-up: add a JSONC-aware CLI so we can ship commented
# defaults again — see the tracking issue.)
#
# What the block does: LSP binary overrides for Zed extensions whose own binary
# fetch races their postinstall (toast: "failed to start language server
# <name>"). The matching binaries ship in this container; redirecting at
# /usr/local/bin/* skips the per-extension npm install / download entirely.

set -euo pipefail

ZED_SETTINGS_DIR="${HOME}/.config/zed"
ZED_SETTINGS_FILE="${ZED_SETTINGS_DIR}/settings.json"

read -r -d '' ZED_LSP_OVERRIDES <<'JSON' || true
{
  "lsp": {
    "dprint": {
      "binary": {
        "path": "/usr/local/bin/dprint",
        "arguments": ["lsp"]
      }
    },
    "taplo": {
      "binary": {
        "path": "/usr/local/bin/taplo",
        "arguments": ["lsp", "stdio"]
      }
    }
  }
}
JSON

if [ -f "$ZED_SETTINGS_FILE" ]; then
    echo "[zed-lsp-config] $ZED_SETTINGS_FILE already exists; leaving it alone."
    echo "  To skip the per-extension LSP install race, merge this into your settings.json:"
    echo "$ZED_LSP_OVERRIDES" | command sed 's/^/    /'
    exit 0
fi

mkdir -p "$ZED_SETTINGS_DIR"
printf '%s\n' "$ZED_LSP_OVERRIDES" >"$ZED_SETTINGS_FILE"

echo "[zed-lsp-config] wrote default $ZED_SETTINGS_FILE with dprint + taplo overrides"
