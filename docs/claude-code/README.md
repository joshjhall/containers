# Claude Code Integration

Detailed reference documentation for Claude Code features in the container
build system. These docs complement the summary in
[CLAUDE.md](../../CLAUDE.md#claude-code-integrations).

## Contents

- **[Plugins & MCP Servers](plugins-and-mcps.md)** — Plugin registry, MCP
  server configuration, entry formats, HTTP auth, release channels, model
  selection
- **[Skills & Agents](skills-and-agents.md)** — Pre-installed skills/agents
  tables, codebase audit system, scanner details, inline suppression
- **[Secrets & Setup](secrets-and-setup.md)** — 1Password `OP_*_REF` /
  `OP_*_FILE_REF` conventions, container setup commands, authentication methods

## Quick Links

| Topic                        | Location                                                                             |
| ---------------------------- | ------------------------------------------------------------------------------------ |
| LSP server table             | [CLAUDE.md](../../CLAUDE.md#lsp-servers-installed-with-_dev-features)                |
| Available MCP short names    | [plugins-and-mcps.md](plugins-and-mcps.md#available-mcp-servers)                     |
| Codebase audit invocation    | [skills-and-agents.md](skills-and-agents.md#codebase-audit-system)                   |
| 1Password secret conventions | [secrets-and-setup.md](secrets-and-setup.md#automatic-secret-loading-from-1password) |
