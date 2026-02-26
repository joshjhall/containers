# Plugins & MCP Servers

Detailed reference for Claude Code plugin and MCP server configuration in the
container build system. For a quick overview, see
[CLAUDE.md](../../CLAUDE.md#claude-code-integrations).

## Claude Code Plugins and LSP Integration

When `INCLUDE_DEV_TOOLS=true`, Claude Code plugins and LSP support are
automatically configured on first container startup via
`/etc/container/first-startup/30-claude-code-setup.sh`.

### Core Plugins (always installed)

- `commit-commands` - Git commit helpers
- `frontend-design` - Interface design assistance
- `code-simplifier` - Code simplification
- `context7` - Documentation lookup
- `security-guidance` - Security best practices
- `claude-md-management` - CLAUDE.md file management
- `pr-review-toolkit` - Comprehensive PR review tools
- `code-review` - Code review assistance
- `hookify` - Hook creation helpers
- `claude-code-setup` - Project setup assistance
- `feature-dev` - Feature development workflow

### Language-specific LSP Plugins (based on build flags)

| Build Flag           | Claude Code Plugin                          |
| -------------------- | ------------------------------------------- |
| `INCLUDE_RUST_DEV`   | `rust-analyzer-lsp@claude-plugins-official` |
| `INCLUDE_PYTHON_DEV` | `pyright-lsp@claude-plugins-official`       |
| `INCLUDE_NODE_DEV`   | `typescript-lsp@claude-plugins-official`    |
| `INCLUDE_KOTLIN_DEV` | `kotlin-lsp@claude-plugins-official`        |

### Extra Plugins

Use `CLAUDE_EXTRA_PLUGINS` to install additional plugins:

```bash
# At build time
docker build --build-arg CLAUDE_EXTRA_PLUGINS="stripe,posthog,vercel" ...

# At runtime (overrides build-time value)
docker run -e CLAUDE_EXTRA_PLUGINS="stripe,posthog" ...
```

## MCP Server Configuration

### Extra MCP Servers

Use `CLAUDE_EXTRA_MCPS` to install additional MCP servers:

```bash
# At build time
docker build --build-arg CLAUDE_EXTRA_MCPS="brave-search,memory,fetch" ...

# At runtime (overrides build-time value)
docker run -e CLAUDE_EXTRA_MCPS="brave-search,sentry" -e BRAVE_API_KEY=xxx ...
```

### Available MCP Servers

Registered short names:

| Short Name            | Package                                            | Required Env Vars                       |
| --------------------- | -------------------------------------------------- | --------------------------------------- |
| `github`              | `@modelcontextprotocol/server-github`              | `GITHUB_TOKEN`                          |
| `gitlab`              | `@modelcontextprotocol/server-gitlab`              | `GITLAB_TOKEN`, `GITLAB_API_URL` (opt.) |
| `brave-search`        | `@modelcontextprotocol/server-brave-search`        | `BRAVE_API_KEY`                         |
| `fetch`               | `@modelcontextprotocol/server-fetch`               | (none)                                  |
| `memory`              | `@modelcontextprotocol/server-memory`              | `MEMORY_FILE_PATH` (optional)           |
| `sequential-thinking` | `@modelcontextprotocol/server-sequential-thinking` | (none)                                  |
| `git`                 | `@modelcontextprotocol/server-git`                 | (none)                                  |
| `sentry`              | `@sentry/mcp-server`                               | `SENTRY_ACCESS_TOKEN`                   |
| `perplexity`          | `@perplexity-ai/mcp-server`                        | `PERPLEXITY_API_KEY`                    |
| `kagi`                | `kagimcp` (Python/uvx)                             | `KAGI_API_KEY`                          |

### Entry Formats

Both `CLAUDE_EXTRA_MCPS` and `CLAUDE_USER_MCPS` support four entry formats:

| Format                   | Example                                            | Behavior                             |
| ------------------------ | -------------------------------------------------- | ------------------------------------ |
| Registered short name    | `memory`, `fetch`                                  | Resolved via MCP registry            |
| npm package              | `@myorg/mcp-internal`                              | Passed through as `npx -y <package>` |
| `name=url`               | `my-api=http://localhost:8080/mcp`                 | Added as HTTP MCP server             |
| `name=url\|Header:Value` | `api=http://host/mcp\|Authorization:Bearer ${TOK}` | HTTP MCP with custom headers         |

### Personal MCP Servers

Use `CLAUDE_USER_MCPS` for personal MCP additions without modifying shared team
config. Runtime-only (no build-time default):

```bash
# In your personal .env file
CLAUDE_USER_MCPS=@myorg/mcp-internal,my-api=http://localhost:8080/mcp
```

### GitHub/GitLab Auto-detection

At first startup, git remotes under `/workspace/` are inspected. If
`github.com` or `gitlab` patterns are found and the corresponding token
(`GITHUB_TOKEN` / `GITLAB_TOKEN`) is set, the platform MCP is automatically
added. Opt-out:

```bash
CLAUDE_AUTO_DETECT_MCPS=false
```

### HTTP MCP Authentication

When `ANTHROPIC_AUTH_TOKEN` is set, HTTP MCP servers from `CLAUDE_EXTRA_MCPS` /
`CLAUDE_USER_MCPS` automatically receive an
`Authorization: Bearer ${ANTHROPIC_AUTH_TOKEN}` header (env var reference, not a
literal value). This enables LiteLLM proxy setups where the same token
authenticates both the API and MCP endpoints.

- The token is stored in `/dev/shm/anthropic-auth-token` (RAM-backed, mode
  0600, never touches disk) and removed from the shell environment on login
- A `claude()` shell wrapper injects the token into only the `claude` CLI
  process, so it never appears in `env`, `/proc/PID/environ`, or `ps e` output
- Auto-injection only applies to user-specified HTTP MCPs, never hardcoded ones
  (e.g., `figma-desktop`)
- Only the `${ANTHROPIC_AUTH_TOKEN}` reference is written to `~/.claude.json` —
  the wrapper ensures the env var exists for the CLI process that reads the config
- Explicit headers in the pipe-delimited syntax override auto-injection for
  that MCP
- Opt out entirely: `CLAUDE_MCP_AUTO_AUTH=false`

```bash
# Auto-inject auth (default when ANTHROPIC_AUTH_TOKEN is set)
CLAUDE_EXTRA_MCPS=olympus=http://litellm:8080/mcp

# Explicit headers via pipe-delimited syntax
CLAUDE_EXTRA_MCPS=olympus=http://litellm:8080/mcp|Authorization:Bearer ${ANTHROPIC_AUTH_TOKEN}|X-Custom:value

# Disable auto-injection
CLAUDE_MCP_AUTO_AUTH=false
```

## Core MCP Servers (installed by claude-code-setup.sh)

Core MCP servers are automatically installed when Node.js is available
(`INCLUDE_NODE=true` or `INCLUDE_NODE_DEV=true`):

- **Filesystem**: `@modelcontextprotocol/server-filesystem` - Enhanced file ops
- **Bash LSP**: `bash-language-server` - Shell script language server

MCP configuration is created on first container startup via
`/etc/container/first-startup/30-claude-code-setup.sh`:

- **Always** configures filesystem MCP server for `/workspace`
- **Always** configures Figma desktop MCP (`http://host.docker.internal:3845/mcp`)
- **Auth-conditional** — plugin installation requires prior authentication
  (gracefully skips with instructions if unauthenticated)
- **Is idempotent** - checks existing config before adding

**GitHub/GitLab MCPs** are auto-detected from git remotes when the corresponding
token is set (`GITHUB_TOKEN` / `GITLAB_TOKEN`). They can also be added
explicitly via `CLAUDE_EXTRA_MCPS="github,gitlab"`.

Set the appropriate token at runtime:

- `GITHUB_TOKEN`: GitHub personal access token (when using GitHub MCP)
- `GITLAB_TOKEN`: GitLab personal access token (when using GitLab MCP)

To disable auto-detection: `CLAUDE_AUTO_DETECT_MCPS=false`

## Release Channel

Use `CLAUDE_CHANNEL` to select the Claude Code release channel:

```bash
# Use latest channel (default, recommended for new features)
docker build --build-arg CLAUDE_CHANNEL=latest ...

# Use stable channel (1-week delay, skips regressions)
docker build --build-arg CLAUDE_CHANNEL=stable ...

# Runtime override (requires rebuild to take effect)
docker run -e CLAUDE_CHANNEL=stable ...
```

**Default**: `latest` (get new features immediately)
**Stable**: Delays ~1 week, skips releases with known issues

## Model Selection

Use `ANTHROPIC_MODEL` to set the default model:

```bash
# Set default model at runtime (docker-compose.yml or .env)
ANTHROPIC_MODEL=claude-opus-4-6              # Claude Opus 4.6 (most capable)
ANTHROPIC_MODEL=claude-sonnet-4-6            # Claude Sonnet 4.6 (balanced)
ANTHROPIC_MODEL=claude-sonnet-4-5-20250929   # Claude Sonnet 4.5 (specific version)
ANTHROPIC_MODEL=claude-haiku-4-5-20251001    # Claude Haiku 4.5 (fastest)
```

**Note**: Use full model IDs (e.g., `claude-opus-4-6`), not aliases like `opus`
or `sonnet`.

## Auth Watcher Configuration

| Variable                       | Purpose                     | Default |
| ------------------------------ | --------------------------- | ------- |
| `CLAUDE_AUTH_WATCHER_TIMEOUT`  | Watcher timeout in seconds  | 14400   |
| `CLAUDE_AUTH_WATCHER_INTERVAL` | Polling interval in seconds | 30      |

The watcher uses `inotifywait` for efficient event-driven detection when
available, falling back to polling otherwise.

The startup script is idempotent and will skip plugins that are already
installed. To verify installed plugins, run: `claude plugin list`
