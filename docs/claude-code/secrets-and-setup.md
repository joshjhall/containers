# Secrets & Setup

Detailed reference for 1Password secret loading, container setup commands, and
Claude Code authentication. For a quick overview, see
[CLAUDE.md](../../CLAUDE.md#claude-code-integrations).

## How Secrets Flow Into the Container

There are two independent resolution phases. Both use the same `OP_*_REF`
naming convention but run at different times:

| Phase                    | When                                         | Script                                                                         | What it does                                                                                                                      |
| ------------------------ | -------------------------------------------- | ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| **Host-side** (optional) | `initializeCommand`, before container starts | `host/init-env.sh`                                                             | Reads `.env.init`, resolves `OP_*_REF` via host `op` CLI, writes `.devcontainer/.env` for Docker Compose `env_file`               |
| **Container startup**    | Every container create/start (entrypoint)    | `lib/features/lib/op-cli/45-op-secrets.sh`                                     | Scans env for `OP_*_REF` / `OP_*_FILE_REF`, calls `op read`, exports resolved values, writes cache to `/dev/shm/op-secrets-cache` |
| **Interactive shell**    | Every new bash session                       | `lib/features/lib/bashrc/65-env-secrets.sh` then `70-1password.sh` (op-cli.sh) | Sources `.env.secrets`, then loads secrets from cache (or re-fetches on cache miss)                                               |

After startup, `05-cleanup-init-env.sh` shreds `.devcontainer/.env` so
resolved secrets don't persist on disk. From that point on, secrets exist only
in process environment and `/dev/shm/` (RAM-backed tmpfs).

## Automatic Secret Loading from 1Password (`OP_*_REF` convention)

When `INCLUDE_OP=true`, any environment variable matching `OP_<NAME>_REF` is
automatically resolved from 1Password and exported as `<NAME>`. This is generic
-- projects can add their own refs with zero changes to the container build system.

| Variable                     | Exports               | Example                                  |
| ---------------------------- | --------------------- | ---------------------------------------- |
| `OP_SERVICE_ACCOUNT_TOKEN`   | _(required)_          | `ops_xxx...`                             |
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

**Precedence**: Direct env vars always win — if `<NAME>` is already set, the
`OP_*_REF` is skipped. If an `op read` call fails, that variable is silently
skipped and remaining refs continue to resolve.

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

**Note**: `OP_*_FILE_REF` is only supported inside the container (container-side
resolution). It is **not** supported in `.env.init` (host-side resolution) —
`init-env.sh` will warn and skip any `FILE_REF` entries.

**Git identity fallback**: If `OP_GIT_USER_NAME_REF` points to a 1Password
Identity item (which has separate `first name`/`last name` fields instead of
`full name`), the system automatically combines them. If nothing resolves,
defaults to `Devcontainer` / `devcontainer@localhost`.

### Example docker-compose.yml

```yaml
services:
  dev:
    environment:
      - OP_GITHUB_TOKEN_REF=op://Development/GitHub-PAT/credential
      - OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF=op://Development/GCP Service Account/sa-key.json
      - OP_GIT_USER_NAME_REF=op://Development/Git-Config/full name
      - OP_GIT_USER_EMAIL_REF=op://Development/Git-Config/email
      - OP_GIT_AUTH_SSH_KEY_REF=op://Development/Git-Auth-Key/private key
      - OP_GIT_SIGNING_SSH_KEY_REF=op://Development/Git-Signing-Key/private key
    # OP_SERVICE_ACCOUNT_TOKEN loaded from .env.secrets at runtime (see below)
```

### Caching

Two caches work together. Both keep resolved secrets in tmpfs — secrets
resolved from 1Password are **never written to persistent disk**.

**Interactive-shell cache** (`/dev/shm/op-secrets-cache`)

A single file containing all resolved exports, sourced by interactive shells
and setup commands so they don't need to re-run `op read`. Cleared on container
restart (tmpfs). `chmod 600`, ownership-checked before sourcing. Manual
invalidation: `rm /dev/shm/op-secrets-cache`.

**Per-ref persistent cache** (`/cache/1password/secrets/`, tmpfs-backed volume)

Upstream `op read` calls for `OP_*_REF` / `OP_*_FILE_REF` vars short-circuit
through a TTL-gated cache at `/cache/1password/secrets/<sha256-of-ref>`. This
is what prevents 1Password service-account rate-throttling across container
restarts, parallel agents, and frequent worktree recreation.

**The cache must be tmpfs-backed.** Resolved secrets should never land on
persistent storage. Mount a tmpfs-backed docker volume at the cache path:

```yaml
volumes:
  op-secret-cache:
    driver_opts:
      type: tmpfs
      device: tmpfs
      o: "size=16m,mode=700"

services:
  dev:
    volumes:
      - op-secret-cache:/cache/1password/secrets
```

This gives you: secrets live in host kernel memory only, survive `docker restart` and `docker-compose down && up` (the named volume persists across
container recreate), and are wiped on host reboot. 16 MiB is plenty for
hundreds of cached refs; `mode=700` matches the script's permissioning.

On container startup `45-op-secrets.sh` verifies the cache directory is
tmpfs-backed (`stat -f -c %T`). If it isn't, the script **falls back to
`/dev/shm/op-secrets-persistent/`** (still tmpfs, still off disk) and emits a
one-shot warning on stderr explaining the downgrade. In degraded mode the cache
is cleared on container restart, so the rate-throttle benefit is lost but no
secrets are written to disk.

**Tunables** (all optional):

| Variable                         | Default                          | Purpose                                           |
| -------------------------------- | -------------------------------- | ------------------------------------------------- |
| `OP_SECRET_CACHE_DIR`            | `/cache/1password/secrets`       | Primary cache path (must be tmpfs-backed)         |
| `OP_SECRET_CACHE_FALLBACK_DIR`   | `/dev/shm/op-secrets-persistent` | Fallback when primary isn't tmpfs                 |
| `OP_SECRET_CACHE_TTL`            | `1800` (30 min)                  | Cache freshness in seconds; `0` disables caching  |
| `OP_SECRET_CACHE_MAX_CONCURRENT` | `4`                              | Concurrent `op read` cap (protects against burst) |
| `OP_READ_MAX_ATTEMPTS`           | `3`                              | Retries per ref on detected throttle              |
| `OP_READ_RETRY_DELAY`            | `1`                              | Initial backoff in seconds (doubles per retry)    |

**Invalidation**

- **Per-ref**: `rm /cache/1password/secrets/<hash>` — next fetch re-reads from
  1Password. The hash is `sha256` of the exact ref URL.
- **Whole cache**: `rm -rf /cache/1password/secrets/*` — same effect, all refs.
- **Disable**: `OP_SECRET_CACHE_TTL=0` in the container env.
- **Automatic**: TTL expiry (mtime-based) re-fetches on next startup.

**Trust model**

The cache is a container-local tmpfs volume — not shared across developer
machines, not backed up, not written to disk. A threat actor who already has
code-execution inside the container can read the cache, process environment,
and anything else the user has access to; the cache doesn't change that. A
threat actor with disk/backup access cannot read the cache because it never
touches disk.

### 1Password CLI Configuration

The interactive shell loader sets these environment variables for the `op` CLI:

| Variable                      | Value                     | Purpose                 |
| ----------------------------- | ------------------------- | ----------------------- |
| `OP_CACHE_DIR`                | `/cache/1password`        | CLI cache directory     |
| `OP_CONFIG_DIR`               | `/cache/1password/config` | CLI config directory    |
| `OP_BIOMETRIC_UNLOCK_ENABLED` | `true`                    | Enable biometric unlock |

## Host-Side Resolution (`.env.init`)

For values needed by Docker Compose _before_ the container starts (e.g.,
`POSTGRES_PASSWORD` for the postgres service), use `.env.init` with
`host/init-env.sh`:

1. Copy `.env.init.example` to `.env.init` at the project root
1. `init-env.sh` runs during `initializeCommand` (before container starts)
1. It resolves `OP_*_REF` entries using the host's `op` CLI and writes the
   result to `.devcontainer/.env` (chmod 600)
1. Docker Compose picks up `.devcontainer/.env` via `env_file`
1. On container boot, `05-cleanup-init-env.sh` shreds `.devcontainer/.env`

```bash
# .env.init — host-side resolution only
OP_POSTGRES_PASSWORD_REF=op://Vault/Postgres/password  # → POSTGRES_PASSWORD in .devcontainer/.env
POSTGRES_DB=assembli_dev                                # → passed through as-is
```

**Limitations**: `OP_*_FILE_REF` is not supported in `.env.init` (no `/dev/shm`
on the host). `OP_SERVICE_ACCOUNT_TOKEN` must be in `.env.secrets` or the
host environment — not in `.env.init` itself.

## Runtime `.env.secrets` Loading

`OP_SERVICE_ACCOUNT_TOKEN` (and any other sensitive values) can be kept out of
docker-compose `env_file` blocks to prevent `docker compose config` from
exposing them in plaintext. Instead, place them in a `.env.secrets` file that
is sourced at runtime by the container's shell initialization.

### How it works

The container sources the **first** `.env.secrets` file it finds, in this order:

| Priority | Location                    | Use case                                                |
| -------- | --------------------------- | ------------------------------------------------------- |
| 1        | `$ENV_SECRETS_FILE`         | Explicit path override                                  |
| 2        | `$HOME/.env.secrets`        | User-level secrets, shared across projects              |
| 3        | `$PWD/.env.secrets`         | Project-level secrets (container WORKDIR)               |
| 4        | `/workspace/*/.env.secrets` | Workspace mount fallback (first match under /workspace) |

Only the first match is sourced (no stacking). All variables in the file are
auto-exported (`set -a`), so you don't need `export` in the file itself.

### Loading paths

Both the container startup script and the interactive shell loader source
`.env.secrets` before checking for `OP_SERVICE_ACCOUNT_TOKEN`:

- **Container startup** (`45-op-secrets.sh`): ensures background processes and
  non-interactive shells have access
- **Interactive shell** (`65-env-secrets.sh`): runs in `/etc/bashrc.d/` before
  `70-1password.sh` (the OP secret loader), with an idempotency guard
  (`_ENV_SECRETS_LOADED`) to prevent double-sourcing in nested shells

### Security

- `xtrace` is disabled during sourcing to prevent tokens from appearing in
  debug output (`set -x` logs).
- An idempotency guard (`_ENV_SECRETS_LOADED`) prevents double-sourcing in
  nested shells.

### Example usage

```bash
# .env.secrets (gitignored, never committed)
OP_SERVICE_ACCOUNT_TOKEN=ops_your_token_here
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

| Command      | Purpose                                                        |
| ------------ | -------------------------------------------------------------- |
| `setup-git`  | Git identity, SSH agent, SSH keep-alive, auth key, signing key |
| `setup-gh`   | Authenticate GitHub CLI (`gh`) and persist token               |
| `setup-glab` | Authenticate GitLab CLI (`glab`) and persist token             |

All commands are idempotent (safe to run multiple times), OP-aware (they
auto-source `/dev/shm/op-secrets-cache` if present, so OP-resolved secrets are
available even when `BASH_ENV` is not honored), and graceful (missing tools or
tokens result in a skip, not an error).

This means `postStartCommand` in devcontainers needs no manual cache sourcing:

```json
"postStartCommand": "setup-git && setup-gh"
```

### `setup-git` Details

Runs five steps in order:

1. **Git identity**: Sets `user.name` and `user.email` from `GIT_USER_NAME` /
   `GIT_USER_EMAIL` (falls back to `Devcontainer` / `devcontainer@localhost`)
1. **SSH agent**: Starts `ssh-agent` if not running, persists socket info to
   `~/.ssh/agent.env` for future shells
1. **SSH keep-alive**: Adds `ServerAliveInterval 60` / `ServerAliveCountMax 10`
   to `~/.ssh/config` for `github.com` and `gitlab.com` (prevents timeout on
   long pushes)
1. **Auth SSH key**: Writes `GIT_AUTH_SSH_KEY` to `~/.ssh/git_auth_key` and
   adds it to the agent
1. **Signing SSH key**: Writes `GIT_SIGNING_SSH_KEY` to
   `~/.ssh/git_signing_key`, derives the public key, configures
   `gpg.format=ssh` / `commit.gpgsign=true` / `tag.gpgsign=true`, and creates
   `~/.ssh/allowed_signers`

### `setup-gh` / `setup-glab` Details

- Authenticate via `gh auth login --with-token` / `glab auth login --stdin`
  (token piped via stdin to avoid process listing exposure)
- Persist a bashrc snippet that re-derives `GITHUB_TOKEN` / `GITLAB_TOKEN`
  from the CLI's auth store on subsequent shells (so the env var is always
  available even without OP refs)
- `setup-glab` supports `GITLAB_HOST` for self-hosted GitLab instances
  (default: `gitlab.com`)

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

## Interactive 1Password Helper Functions

Available in interactive shells when `INCLUDE_OP=true`:

### `op-env-safe` (recommended)

Load all concealed/notes fields from a 1Password item as environment variables:

```bash
op-env-safe Development/API-Keys
echo "$API_KEY"  # now available
```

Exports variables directly without `eval`. Disables xtrace during execution.

### `op-exec`

Execute a command with secrets loaded from a 1Password item:

```bash
op-exec Development/API-Keys npm run deploy
```

Uses `op-env-safe` internally.

### `op-env` (use with caution)

```bash
eval $(op-env Development/API-Keys)
```

Uses `eval` — secrets may appear in command history and process listings.
Prefer `op-env-safe` instead.

### Shell Aliases

| Alias | Expands to      |
| ----- | --------------- |
| `ops` | `op signin`     |
| `opl` | `op vault list` |
| `opg` | `op item get`   |
| `opi` | `op inject`     |

## Security Summary

- **Secrets never touch disk** — stored in `/dev/shm/` (tmpfs) and process
  environment only
- **Re-fetched on every container start** — values stay current with the vault
- **`.devcontainer/.env` shredded on boot** — host-side resolved file removed
  by `05-cleanup-init-env.sh` after Docker Compose injects it
- **xtrace disabled** during all secret operations to prevent exposure in
  `set -x` debug output
- **Cache file ownership-checked** — `/dev/shm/op-secrets-cache` is skipped if
  not owned by the current user
- **Token piped via stdin** — `setup-gh` / `setup-glab` avoid exposing tokens
  in process listings

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
