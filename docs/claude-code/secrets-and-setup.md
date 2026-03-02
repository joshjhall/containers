# Secrets & Setup

Detailed reference for 1Password secret loading, container setup commands, and
Claude Code authentication. For a quick overview, see
[CLAUDE.md](../../CLAUDE.md#claude-code-integrations).

## Automatic Secret Loading from 1Password (`OP_*_REF` convention)

When `INCLUDE_OP=true`, any environment variable matching `OP_<NAME>_REF` is
automatically resolved from 1Password and exported as `<NAME>`. This is generic
-- projects can add their own refs with zero changes to the container build system.

| Variable                     | Exports               | Example                                  |
| ---------------------------- | --------------------- | ---------------------------------------- |
| `OP_SERVICE_ACCOUNT_TOKEN`   | *(required)*          | `ops_xxx...`                             |
| `OP_GITHUB_TOKEN_REF`        | `GITHUB_TOKEN`        | `op://Vault/GitHub-PAT/credential`       |
| `OP_GITLAB_TOKEN_REF`        | `GITLAB_TOKEN`        | `op://Vault/GitLab-PAT/credential`       |
| `OP_KAGI_API_KEY_REF`        | `KAGI_API_KEY`        | `op://Vault/Kagi-API-Key/credential`     |
| `OP_GIT_USER_NAME_REF`       | `GIT_USER_NAME`       | `op://Vault/Identity/full name`          |
| `OP_GIT_USER_EMAIL_REF`      | `GIT_USER_EMAIL`      | `op://Vault/Identity/email`              |
| `OP_GIT_AUTH_SSH_KEY_REF`    | `GIT_AUTH_SSH_KEY`    | `op://Vault/Git-Auth-Key/private key`    |
| `OP_GIT_SIGNING_SSH_KEY_REF` | `GIT_SIGNING_SSH_KEY` | `op://Vault/Git-Signing-Key/private key` |
| `OP_MY_SECRET_REF`           | `MY_SECRET`           | `op://Vault/Item/field`                  |

**Field names** depend on your 1Password item type: API_CREDENTIAL items use
`credential`, LOGIN items use `password`, SSH_KEY items use `private key`, etc.
Check your item in 1Password to find the correct field name.

## File-Based Secrets (`OP_*_FILE_REF` convention)

Some credentials must be **file paths** rather than string values (e.g.,
`GOOGLE_APPLICATION_CREDENTIALS` must point to a JSON file on disk). The
`_FILE_REF` convention fetches content from 1Password, writes it to a secure
RAM-backed path, and exports the **file path** as the environment variable.

| Variable                                     | Exports                                      | Example                             |
| -------------------------------------------- | -------------------------------------------- | ----------------------------------- |
| `OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF` | `GOOGLE_APPLICATION_CREDENTIALS` (file path) | `op://Vault/GCP-SA-Key/sa-key.json` |
| `OP_MY_CERT_FILE_REF`                        | `MY_CERT` (file path)                        | `op://Vault/TLS-Cert/cert.pem`      |

**How it works**:

- Content is fetched via `op read` (same as `_REF`, works with both Document
  items and file attachments on regular items)
- Written to `/dev/shm/` (RAM-backed tmpfs, never touches disk)
- File permissions set to `0600` (owner read/write only)
- Filename derived from the variable name (lowercase, underscores become
  dashes), e.g., `GOOGLE_APPLICATION_CREDENTIALS` -> `google-application-credentials`
- Extension derived from the URI's last path segment (e.g., `sa-key.json` ->
  `.json`; `credential` -> no extension)
- Same precedence rules: direct env var always wins

**URI format**: Point the URI at the **filename** (for Document items) or
**file attachment name** (for regular items), not a text field:

```bash
# Document item -- use the filename
OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF=op://Development/GCP Service Account/sa-key.json

# File attachment on API_CREDENTIAL item -- use the attachment name
OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF=op://Development/GCP Credentials/sa-key.json
```

**Git identity fallback**: If `OP_GIT_USER_NAME_REF` points to a 1Password
Identity item (which has separate `first name`/`last name` fields instead of
`full name`), the system automatically combines them. If nothing resolves,
defaults to `Devcontainer` / `devcontainer@localhost`.

### Example docker-compose.yml

```yaml
services:
  dev:
    environment:
      - OP_SERVICE_ACCOUNT_TOKEN=${OP_SERVICE_ACCOUNT_TOKEN}
      - OP_GITHUB_TOKEN_REF=op://Development/GitHub-PAT/credential
      - OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF=op://Development/GCP Service Account/sa-key.json
      - OP_GIT_USER_NAME_REF=op://Development/Git-Config/full name
      - OP_GIT_USER_EMAIL_REF=op://Development/Git-Config/email
      - OP_GIT_AUTH_SSH_KEY_REF=op://Development/Git-Auth-Key/private key
      - OP_GIT_SIGNING_SSH_KEY_REF=op://Development/Git-Signing-Key/private key
```

Secrets are loaded automatically on shell initialization and container startup.
Direct env vars always win (if `<NAME>` is already set, the OP ref is skipped).

### Caching

Resolved secrets are cached to `/dev/shm/op-secrets-cache` after the first
resolution (whether during container startup or the first interactive shell).
Subsequent shells source the cache file instead of making `op read` API calls,
making shell startup instant.

- **Container restart** clears the cache automatically (`/dev/shm/` is tmpfs)
- **Manual invalidation**: `rm /dev/shm/op-secrets-cache` — the next shell will
  re-resolve all secrets from 1Password
- The cache file is `chmod 600` and ownership-checked before sourcing

## Runtime `.env.secrets` Loading

`OP_SERVICE_ACCOUNT_TOKEN` (and any other sensitive values) can be kept out of
docker-compose `env_file` blocks to prevent `docker compose config` from
exposing them in plaintext. Instead, place them in a `.env.secrets` file that
is sourced at runtime by the container's shell initialization.

### How it works

The container sources the **first** `.env.secrets` file it finds, in this order:

| Priority | Location             | Use case                                   |
| -------- | -------------------- | ------------------------------------------ |
| 1        | `$ENV_SECRETS_FILE`  | Explicit path override                     |
| 2        | `$HOME/.env.secrets` | User-level secrets, shared across projects |
| 3        | `$PWD/.env.secrets`  | Project-level secrets (container WORKDIR)  |

Only the first match is sourced (no stacking). All variables in the file are
auto-exported (`set -a`), so you don't need `export` in the file itself.

### Loading paths

- **Interactive shells**: `65-env-secrets.sh` runs in `/etc/bashrc.d/` before
  `70-1password.sh`, so `OP_SERVICE_ACCOUNT_TOKEN` is available when the
  1Password integration initializes.
- **Container startup**: `45-op-secrets.sh` sources `.env.secrets` before
  checking for `OP_SERVICE_ACCOUNT_TOKEN`, ensuring background processes and
  non-interactive shells also have access.

### Security

- `xtrace` is disabled during sourcing to prevent tokens from appearing in
  debug output (`set -x` logs).
- An idempotency guard (`_ENV_SECRETS_LOADED`) prevents double-sourcing in
  nested shells.

### Example usage

```bash
# .env.secrets (gitignored, never committed)
OP_SERVICE_ACCOUNT_TOKEN=ops_your_token_here
MY_OTHER_SECRET=supersecret
```

```yaml
# docker-compose.yml — no OP_SERVICE_ACCOUNT_TOKEN here
services:
  dev:
    environment:
      - OP_GITHUB_TOKEN_REF=op://Development/GitHub-PAT/credential
    # The token is loaded from .env.secrets at container startup
```

To use a custom path, set `ENV_SECRETS_FILE` in your docker-compose environment:

```yaml
services:
  dev:
    environment:
      - ENV_SECRETS_FILE=/run/secrets/env-secrets
```

## Container Setup Commands

Three setup commands are installed to `/usr/local/bin/` and available in PATH:

| Command      | Purpose                                        |
| ------------ | ---------------------------------------------- |
| `setup-git`  | Git identity, SSH agent, auth key, signing key |
| `setup-gh`   | Authenticate GitHub CLI (`gh`)                 |
| `setup-glab` | Authenticate GitLab CLI (`glab`)               |

All commands are idempotent (safe to run multiple times), OP-agnostic (they
only read direct env vars -- OP ref resolution happens before they run), and
graceful (missing tools or tokens result in a skip, not an error).

### Direct Environment Variables (for non-OP users)

| Variable              | Purpose                                 |
| --------------------- | --------------------------------------- |
| `GIT_USER_NAME`       | Git user.name                           |
| `GIT_USER_EMAIL`      | Git user.email                          |
| `GIT_AUTH_SSH_KEY`    | SSH auth private key (PEM)              |
| `GIT_SIGNING_SSH_KEY` | SSH signing private key (PEM)           |
| `GITHUB_TOKEN`        | GitHub PAT                              |
| `GITLAB_TOKEN`        | GitLab PAT                              |
| `GITLAB_HOST`         | GitLab hostname (default: `gitlab.com`) |

Source: `lib/runtime/commands/setup-git`, `lib/runtime/commands/setup-gh`,
`lib/runtime/commands/setup-glab`.

## Claude Code Authentication

Plugin installation requires interactive authentication.

**Automatic setup (recommended)**: After running `claude` and authenticating,
plugins and MCP servers are configured automatically within 30-60 seconds by
the background `claude-auth-watcher` process. A marker file
(`~/.claude/.container-setup-complete`) prevents repeated setup runs.

**Manual workflow** (if auto-setup doesn't run):

```bash
# 1. Inside container, run Claude and authenticate when prompted
claude

# 2. Close the Claude client (Ctrl+C or exit)

# 3. Run setup to install plugins
claude-setup

# 4. Restart Claude if needed
```

**Note**: Claude Code CLI supports two authentication methods:

- **Interactive OAuth**: Run `claude` and authenticate via browser
- **Token-based**: Set `ANTHROPIC_AUTH_TOKEN` environment variable (for proxy
  setups like LiteLLM)

Both methods work with plugin installation and MCP server configuration.

Verify configuration with:

- `claude plugin list` - See installed plugins
- `claude mcp list` - See configured MCP servers
- `pgrep -f claude-auth-watcher` - Check if watcher is running
