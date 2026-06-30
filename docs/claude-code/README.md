# Claude Code Integration

Detailed reference documentation for Claude Code features in the container
build system. These docs complement the summary in
[CLAUDE.md](../../CLAUDE.md#claude-code-integrations).

> The general-purpose skills and agents live in the sibling
> [`librarian`](https://github.com/joshjhall/librarian) plugin marketplace, not
> in this repo. See
> [Skills & Agents](skills-and-agents.md#source-of-truth-the-librarian-marketplace)
> for install paths (host and pinned-container) and
> [epic #607](https://github.com/joshjhall/containers/issues/607) for the
> migration.

## Contents

- **[Plugins & MCP Servers](plugins-and-mcps.md)** — Third-party plugin registry
  (upstream Anthropic + LSP plugins), MCP server configuration, entry formats,
  HTTP auth, release channels, model selection
- **[Skills & Agents](skills-and-agents.md)** — `librarian` marketplace as
  source of truth, host + pinned-container install paths, build-bound skills,
  codebase audit system, scanner details, inline suppression
- **[Secrets & Setup](secrets-and-setup.md)** — 1Password `OP_*_REF` /
  `OP_*_FILE_REF` conventions, container setup commands, authentication methods

## Quick Links

| Topic                        | Location                                                                             |
| ---------------------------- | ------------------------------------------------------------------------------------ |
| Librarian marketplace        | [skills-and-agents.md](skills-and-agents.md#source-of-truth-the-librarian-marketplace) |
| LSP server table             | [CLAUDE.md](../../CLAUDE.md#lsp-servers-installed-with-_dev-features)                |
| Available MCP short names    | [plugins-and-mcps.md](plugins-and-mcps.md#available-mcp-servers)                     |
| Codebase audit invocation    | [skills-and-agents.md](skills-and-agents.md#codebase-audit-system)                   |
| 1Password secret conventions | [secrets-and-setup.md](secrets-and-setup.md#automatic-secret-loading-from-1password-op__ref-convention) |
