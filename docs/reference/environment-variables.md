# Environment Variables Reference

This document lists all environment variables used in the container build
system, organized by category.

## Table of Contents

- [Build Arguments](#build-arguments)
- [User Configuration](#user-configuration)
- [Language Versions](#language-versions)
- [Cache Directories](#cache-directories)
- [Feature-Specific Variables](#feature-specific-variables)
- [Runtime Configuration](#runtime-configuration)

---

## Build Arguments

Build arguments are passed during `docker build` and control what gets
installed. They are converted to environment variables during the build process.

### Base Configuration

| Variable       | Default                      | Description                                           |
| -------------- | ---------------------------- | ----------------------------------------------------- |
| `BASE_IMAGE`   | `debian:trixie-slim`         | Base Docker image to use                              |
| `PROJECT_PATH` | `..`                         | Path to project root relative to containers directory |
| `PROJECT_NAME` | `project`                    | Name of the project (used in paths)                   |
| `WORKING_DIR`  | `/workspace/${PROJECT_NAME}` | Working directory inside container                    |

### User Configuration

| Variable                   | Default     | Description                                    |
| -------------------------- | ----------- | ---------------------------------------------- |
| `USERNAME`                 | `developer` | Non-root username to create                    |
| `USER_UID`                 | `1000`      | User ID for the non-root user                  |
| `USER_GID`                 | `1000`      | Group ID for the non-root user                 |
| `ENABLE_PASSWORDLESS_SUDO` | `false`     | Sudo policy (three-valued) — see below         |

`ENABLE_PASSWORDLESS_SUDO` accepts three values:

- `scoped` — **recommended for development.** Grants passwordless sudo for
  only the fixed set of privileged startup-reconciliation commands the
  entrypoint runs (`bindfs`; the Docker-socket `chown`/`chmod`/`groupadd`/
  `usermod`; and the `/cache`//`/run` ownership fixes) via a `Cmnd_Alias`
  allowlist. The two variable ownership fixes run through fixed-purpose,
  path-hardcoded wrapper commands (`reconcile-cache-owner`,
  `reconcile-run-owner`) rather than a bare `chown`, so a process running as
  the non-root user cannot coerce the grant into chowning an arbitrary path —
  it cannot escalate to arbitrary root.
- `true` — **legacy.** Full `NOPASSWD:ALL`; any process running as the user
  can become root without a password. Kept for backward compatibility;
  prefer `scoped`.
- `false` — **production/secure (default).** The user is in the `sudo` group
  but every `sudo` invocation requires a password. Note that startup
  reconciliation (bindfs overlay, `/cache`//`/run` chowns) is skipped when the
  entrypoint runs unprivileged, so use `scoped` if you need those.

### Build Output Configuration

| Variable    | Default | Description                                    |
| ----------- | ------- | ---------------------------------------------- |
| `LOG_LEVEL` | `INFO`  | Build log verbosity (ERROR, WARN, INFO, DEBUG) |

**Log Levels:**

- `ERROR` (0): Only errors - minimal output for CI/CD
- `WARN` (1): Errors and warnings
- `INFO` (2): Normal verbosity (default)
- `DEBUG` (3): Full verbosity for troubleshooting

**Example - Quiet build for CI:**

```bash
docker build --build-arg LOG_LEVEL=ERROR -t myimage .
```

**Example - Verbose build for debugging:**

```bash
docker build --build-arg LOG_LEVEL=DEBUG -t myimage .
```

### Feature Flags

All features are disabled by default. Set to `true` to enable:

**Languages:**

| Variable          | Description                              |
| ----------------- | ---------------------------------------- |
| `INCLUDE_PYTHON`  | Install Python runtime                   |
| `INCLUDE_NODE`    | Install Node.js runtime                  |
| `INCLUDE_RUST`    | Install Rust runtime                     |
| `INCLUDE_RUBY`    | Install Ruby runtime                     |
| `INCLUDE_R`       | Install R statistical environment        |
| `INCLUDE_GOLANG`  | Install Go runtime                       |
| `INCLUDE_JAVA`    | Install Java JDK                         |
| `INCLUDE_MOJO`    | Install Mojo language                    |
| `INCLUDE_KOTLIN`  | Install Kotlin (auto-triggers Java)      |
| `INCLUDE_ANDROID` | Install Android SDK (auto-triggers Java) |

**Development Tools:**

| Variable              | Description                                          |
| --------------------- | ---------------------------------------------------- |
| `INCLUDE_PYTHON_DEV`  | Install Python dev tools (pytest, black, mypy, etc.) |
| `INCLUDE_NODE_DEV`    | Install Node.js dev tools (TypeScript, Jest, etc.)   |
| `INCLUDE_RUST_DEV`    | Install Rust dev tools (rust-analyzer, clippy, etc.) |
| `INCLUDE_RUBY_DEV`    | Install Ruby dev tools (rubocop, pry, etc.)          |
| `INCLUDE_R_DEV`       | Install R dev tools (devtools, tidyverse, etc.)      |
| `INCLUDE_GOLANG_DEV`  | Install Go dev tools (gopls, delve, etc.)            |
| `INCLUDE_JAVA_DEV`    | Install Java dev tools (Spring, JBang, etc.)         |
| `INCLUDE_MOJO_DEV`    | Install Mojo dev tools                               |
| `INCLUDE_KOTLIN_DEV`  | Install Kotlin dev tools (kotlin-language-server)    |
| `INCLUDE_ANDROID_DEV` | Install Android dev tools (emulator, NDK)            |
| `INCLUDE_DEV_TOOLS`   | Install general dev tools (gh, lazygit, fzf, etc.)   |
| `SKIP_LSP_INSTALL`    | Skip LSP server installation (for headless agents)   |
| `INCLUDE_HOST_EVENTS` | Forward Claude→host agent events to a host monitor (opt-in; requires dev tools) |

**Cloud & Infrastructure:**

| Variable             | Description                         |
| -------------------- | ----------------------------------- |
| `INCLUDE_AWS`        | Install AWS CLI and tools           |
| `INCLUDE_GCLOUD`     | Install Google Cloud SDK            |
| `INCLUDE_CLOUDFLARE` | Install Cloudflare tools (wrangler) |
| `INCLUDE_KUBERNETES` | Install kubectl, k9s, helm          |
| `INCLUDE_TERRAFORM`  | Install Terraform and related tools |

**Database Clients:**

| Variable                  | Description                      |
| ------------------------- | -------------------------------- |
| `INCLUDE_POSTGRES_CLIENT` | Install PostgreSQL client (psql) |
| `INCLUDE_REDIS_CLIENT`    | Install Redis client (redis-cli) |
| `INCLUDE_SQLITE_CLIENT`   | Install SQLite client (sqlite3)  |

**Other Tools:**

| Variable         | Description                                               |
| ---------------- | --------------------------------------------------------- |
| `INCLUDE_DOCKER` | Install Docker CLI tools                                  |
| `INCLUDE_OP`     | Install 1Password CLI                                     |
| `INCLUDE_MISE`   | Install Mise polyglot runtime version manager             |
| `INCLUDE_OLLAMA` | Install Ollama for local LLMs                             |
| `INCLUDE_BINDFS` | Install bindfs FUSE overlay for VirtioFS permission fixes |
| `INCLUDE_CRON`   | Install cron daemon (auto-triggered by some features)     |

---

## Language Versions

Control which version of each language to install:

| Variable         | Default  | Description                             |
| ---------------- | -------- | --------------------------------------- |
| `PYTHON_VERSION` | `3.14.3` | Python version to install from source   |
| `NODE_VERSION`   | `22`     | Node.js major version (from NodeSource) |
| `RUST_VERSION`   | `1.94.0` | Rust toolchain version                  |
| `RUBY_VERSION`   | `4.0.1`  | Ruby version to install from source     |
| `R_VERSION`      | `4.5.2`  | R version from CRAN repositories        |
| `GO_VERSION`     | `1.26.1` | Go version to install                   |
| `JAVA_VERSION`   | `21`     | Java JDK version (Temurin)              |
| `KOTLIN_VERSION` | `2.3.10` | Kotlin compiler version                 |
| `MOJO_VERSION`   | `25.4`   | Mojo version via pixi                   |

### Android Versions

| Variable                        | Default         | Description                              |
| ------------------------------- | --------------- | ---------------------------------------- |
| `ANDROID_CMDLINE_TOOLS_VERSION` | `14742923`      | Android command-line tools package build |
| `ANDROID_API_LEVELS`            | `34,35`         | Comma-separated Android API levels       |
| `ANDROID_NDK_VERSION`           | `29.0.14206865` | Android NDK version                      |

### Tool Versions

| Variable             | Default   | Description                                         |
| -------------------- | --------- | --------------------------------------------------- |
| `PIXI_VERSION`       | `0.65.0`  | Pixi package manager version (for Mojo)             |
| `MISE_VERSION`       | `2026.4.20` | Mise polyglot runtime version manager version     |
| `KUBECTL_VERSION`    | `1.33.9`  | kubectl CLI version                                 |
| `K9S_VERSION`        | `0.50.18` | k9s terminal UI version                             |
| `KREW_VERSION`       | `0.5.0`   | Krew kubectl plugin manager version                 |
| `HELM_VERSION`       | `4.1.1`   | Helm package manager version                        |
| `TERRAGRUNT_VERSION` | `0.99.4`  | Terragrunt version                                  |
| `TFDOCS_VERSION`     | `0.21.0`  | terraform-docs version                              |
| `TFLINT_VERSION`     | `0.61.0`  | TFLint version                                      |
| `CLAUDE_CHANNEL`     | `latest`  | Claude Code release channel                         |
| `LIBRARIAN_REF`      | `v0.6.1`  | Pinned **signed release tag** (v0.4.0+) of the librarian plugin marketplace; the build fetches the signed release tarball and verifies it with cosign before installing to `/opt/librarian` (fail-closed, #671) |
| `LIBRARIAN_SIGNER_IDENTITY` | `<repo>/.github/workflows/release.yml@refs/tags/<ref>` | cosign `--certificate-identity` trust anchor for librarian verification (the signing workflow at the release tag; derived from `LIBRARIAN_REPO_URL` + `LIBRARIAN_REF`). Override for a fork or test signer |
| `LIBRARIAN_SIGNER_ISSUER` | `https://token.actions.githubusercontent.com` | cosign `--certificate-oidc-issuer` for librarian verification (GitHub Actions OIDC). Override for a fork or test signer |
| `KEYBINDING_PROFILE` | `iterm`   | Terminal keybinding profile (iterm, xterm, minimal) |

### Security & Logging Flags

| Variable                     | Default | Description                                                         |
| ---------------------------- | ------- | ------------------------------------------------------------------- |
| `PRODUCTION_MODE`            | `false` | Enable production hardening (nologin for service users)             |
| `RESTRICT_SHELLS`            | `true`  | Limit `/etc/shells` to bash only                                    |
| `REQUIRE_VERIFIED_DOWNLOADS` | `false` | Block Tier 4 TOFU checksum fallback (defaults to `PRODUCTION_MODE`) |
| `ENABLE_JSON_LOGGING`        | `false` | Emit structured JSON log output                                     |
| `ENABLE_AUDIT_LOGGING`       | `false` | Enable audit logging for security events                            |

> **Note**: The Dockerfile is the authoritative source for default versions.
> These values drift with automated patch releases — check the `ARG` declarations
> in the [Dockerfile](../../Dockerfile) for current defaults.

---

## Cache Directories

All cache directories are located under `/cache` for persistence across builds:

### Python

| Variable             | Default              | Description                     |
| -------------------- | -------------------- | ------------------------------- |
| `PIP_CACHE_DIR`      | `/cache/pip`         | pip package cache               |
| `POETRY_CACHE_DIR`   | `/cache/poetry`      | Poetry package cache            |
| `PIPX_HOME`          | `/opt/pipx`          | pipx installation directory     |
| `PIPX_BIN_DIR`       | `/opt/pipx/bin`      | pipx binary directory           |
| `IPYTHONDIR`         | `$HOME/.ipython`     | IPython configuration directory |
| `JUPYTER_CONFIG_DIR` | `$HOME/.jupyter`     | Jupyter configuration directory |
| `BLACK_CACHE_DIR`    | `$HOME/.cache/black` | Black formatter cache           |

### Node.js

| Variable         | Default             | Description         |
| ---------------- | ------------------- | ------------------- |
| `NPM_CACHE_DIR`  | `/cache/npm`        | npm package cache   |
| `YARN_CACHE_DIR` | `/cache/yarn`       | Yarn package cache  |
| `PNPM_STORE_DIR` | `/cache/pnpm`       | pnpm package store  |
| `NPM_GLOBAL_DIR` | `/cache/npm-global` | Global npm packages |

### Rust

| Variable      | Default         | Description                 |
| ------------- | --------------- | --------------------------- |
| `CARGO_HOME`  | `/cache/cargo`  | Cargo packages and registry |
| `RUSTUP_HOME` | `/cache/rustup` | Rustup installation         |

### Go

| Variable     | Default           | Description               |
| ------------ | ----------------- | ------------------------- |
| `GOPATH`     | `/cache/go`       | Go workspace              |
| `GOMODCACHE` | `/cache/go-mod`   | Go module cache           |
| `GOCACHE`    | `/cache/go-build` | Go build cache            |
| `GOROOT`     | `/usr/local/go`   | Go installation directory |

### Ruby

| Variable      | Default              | Description               |
| ------------- | -------------------- | ------------------------- |
| `GEM_HOME`    | `/cache/ruby/gems`   | Ruby gems installation    |
| `GEM_PATH`    | `/cache/ruby/gems`   | Ruby gems search path     |
| `BUNDLE_PATH` | `/cache/ruby/bundle` | Bundler installation path |

### Java

| Variable           | Default                           | Description               |
| ------------------ | --------------------------------- | ------------------------- |
| `JAVA_HOME`        | `/usr/lib/jvm/default-java`       | Java JDK installation     |
| `GRADLE_USER_HOME` | `/cache/gradle`                   | Gradle cache and config   |
| `MAVEN_OPTS`       | `-Dmaven.repo.local=/cache/maven` | Maven repository location |

### R

| Variable      | Default            | Description       |
| ------------- | ------------------ | ----------------- |
| `R_LIBS_USER` | `/cache/r/library` | R package library |

### Docker

| Variable                  | Default                     | Description              |
| ------------------------- | --------------------------- | ------------------------ |
| `DOCKER_CONFIG`           | `/cache/docker`             | Docker CLI configuration |
| `DOCKER_CLI_PLUGINS_PATH` | `/cache/docker/cli-plugins` | Docker CLI plugins       |

### Development Tools

| Variable           | Default                         | Description                |
| ------------------ | ------------------------------- | -------------------------- |
| `DEV_TOOLS_CACHE`  | `/cache/dev-tools`              | General dev tools cache    |
| `CAROOT`           | `/cache/dev-tools/mkcert-ca`    | mkcert CA certificates     |
| `DIRENV_ALLOW_DIR` | `/cache/dev-tools/direnv-allow` | direnv allowed directories |

#### codegraph index

The `codegraph` MCP stores its per-project knowledge-graph index at
`<project>/.codegraph`. codegraph's `CODEGRAPH_DIR` override only accepts a
plain directory name (no absolute paths), so the index cannot be pointed at
`/cache` directly. Instead the dev-tools first-startup hook symlinks
`<project>/.codegraph` → `/cache/codegraph`, which the devcontainer backs with
the `containers-codegraph` named volume. Drop that volume
(`docker volume rm containers-codegraph`) to force a clean re-index.

### Mojo / Pixi

| Variable         | Default               | Description            |
| ---------------- | --------------------- | ---------------------- |
| `PIXI_CACHE_DIR` | `/cache/pixi`         | Pixi package cache     |
| `MOJO_PROJECT`   | `/cache/mojo/project` | Mojo project workspace |

### Kotlin / Android

| Variable                | Default              | Description                      |
| ----------------------- | -------------------- | -------------------------------- |
| `JDTLS_DATA_DIR`        | `/cache/jdtls`       | Eclipse JDT Language Server data |
| `ANDROID_AVD_HOME`      | `/cache/android-avd` | Android Virtual Device home      |
| `ANDROID_EMULATOR_HOME` | `/cache/android-avd` | Android emulator home            |

### Terraform

| Variable              | Default            | Description            |
| --------------------- | ------------------ | ---------------------- |
| `TF_PLUGIN_CACHE_DIR` | `/cache/terraform` | Terraform plugin cache |

---

## Feature-Specific Variables

### Go Configuration

| Variable      | Default                           | Description          |
| ------------- | --------------------------------- | -------------------- |
| `GO111MODULE` | `on`                              | Enable Go modules    |
| `GOPROXY`     | `https://proxy.golang.org,direct` | Go module proxy      |
| `GOSUMDB`     | `sum.golang.org`                  | Go checksum database |

### Java Configuration

| Variable      | Default                               | Description                   |
| ------------- | ------------------------------------- | ----------------------------- |
| `GRADLE_HOME` | `/usr/share/gradle`                   | Gradle installation directory |
| `GRADLE_OPTS` | `-Xmx1024m -XX:MaxMetaspaceSize=512m` | Gradle JVM options            |

### Python Configuration

| Variable                | Default | Description                                   |
| ----------------------- | ------- | --------------------------------------------- |
| `JUPYTER_PLATFORM_DIRS` | `1`     | Use platform-specific directories for Jupyter |

### Ruby Configuration

| Variable                         | Default | Description                        |
| -------------------------------- | ------- | ---------------------------------- |
| `BUNDLE_AUDIT_UPDATE_ON_INSTALL` | `true`  | Update vulnerability DB on install |

### Rust Configuration

The `cargo-sweep` cron job (installed with `INCLUDE_RUST_DEV=true`) runs every
6 hours to reclaim old Rust build artifacts.

| Variable                | Default      | Description                                                                                    |
| ----------------------- | ------------ | ---------------------------------------------------------------------------------------------- |
| `CARGO_SWEEP_ROOTS`     | `/workspace` | Colon-separated discovery roots. Decoupled from `WORKING_DIR` so sibling checkouts are swept   |
| `CARGO_SWEEP_DAYS`      | `14`         | Age threshold — remove artifacts older than N days                                             |
| `CARGO_SWEEP_MAXSIZE`   | `10GB`       | Per-project size ceiling backstop (empty disables). Unit defaults to MB                        |
| `CARGO_SWEEP_INSTALLED` | `true`       | Also drop artifacts from toolchains no longer installed via rustup                             |
| `CARGO_SWEEP_DISABLE`   | `false`      | Set to `true` to disable the automatic sweep entirely                                          |

`CARGO_SWEEP_ROOTS` is deliberately independent of `WORKING_DIR`: deployments
narrow `WORKING_DIR` to a single project directory (e.g. `/workspace/containers`),
which would hide sibling checkouts under `/workspace` (e.g. `/workspace/octarine`)
from the sweep. The cron scans `/workspace` broadly by design.

### Bindfs Configuration

| Variable            | Default | Description                                                         |
| ------------------- | ------- | ------------------------------------------------------------------- |
| `BINDFS_ENABLED`    | `auto`  | `auto`: probe + apply if broken; `true`: always apply; `false`: off |
| `BINDFS_SKIP_PATHS` | (empty) | Comma-separated paths to exclude (e.g., `/workspace/.git`)          |

Bindfs requires `--cap-add SYS_ADMIN` and `--device /dev/fuse` at runtime.
In `auto` mode (default), the entrypoint probes permissions on bind mounts
under `/workspace` and only applies overlays when permissions are broken
(common on macOS VirtioFS). On Linux hosts, this is a safe no-op.

---

## Runtime Configuration

These variables can be set when running containers (via `docker run -e`):

### GitHub Integration

| Variable       | Description                                              |
| -------------- | -------------------------------------------------------- |
| `GITHUB_TOKEN` | GitHub personal access token for API rate limit increase |

### 1Password Integration

| Variable                         | Default                          | Description                                                         |
| -------------------------------- | -------------------------------- | ------------------------------------------------------------------- |
| `OP_SERVICE_ACCOUNT_TOKEN`       | —                                | 1Password service account token for automated access                |
| `ENV_SECRETS_FILE`               | —                                | Custom path to `.env.secrets` file (overrides default search order) |
| `OP_SECRET_CACHE_DIR`            | `/cache/1password/secrets`       | Per-ref cache dir (must be tmpfs-backed; see secrets-and-setup.md)  |
| `OP_SECRET_CACHE_FALLBACK_DIR`   | `/dev/shm/op-secrets-persistent` | Degraded fallback when primary isn't tmpfs                          |
| `OP_SECRET_CACHE_TTL`            | `1800`                           | Cache TTL in seconds (30 min); `0` disables caching                 |
| `OP_SECRET_CACHE_MAX_CONCURRENT` | `4`                              | Cap on concurrent `op read` calls                                   |
| `OP_READ_MAX_ATTEMPTS`           | `3`                              | Retries per ref on detected 1Password throttle                      |
| `OP_READ_RETRY_DELAY`            | `1`                              | Initial retry backoff in seconds (doubles per attempt)              |

### Resource Limits

| Variable                | Default | Description                                    |
| ----------------------- | ------- | ---------------------------------------------- |
| `FILE_DESCRIPTOR_LIMIT` | `4096`  | Maximum open file descriptors (ulimit -n)      |
| `MAX_USER_PROCESSES`    | `2048`  | Maximum user processes (ulimit -u)             |
| `CORE_DUMP_SIZE`        | `0`     | Core dump size limit (ulimit -c, 0 = disabled) |

### Container Identity

| Variable        | Default                  | Description                                      |
| --------------- | ------------------------ | ------------------------------------------------ |
| `CONTAINER_UID` | `1000`                   | UID to look up for the container user at runtime |
| `METRICS_DIR`   | `/tmp/container-metrics` | Directory for startup metrics                    |

### Filesystem & Platform

| Variable               | Default | Description                                        |
| ---------------------- | ------- | -------------------------------------------------- |
| `SKIP_CASE_CHECK`      | `false` | Skip case-insensitive filesystem detection warning |
| `FUSE_CLEANUP_DISABLE` | `false` | Disable periodic `.fuse_hidden*` file cleanup      |

### Host Event Forwarding

Build an image with `INCLUDE_HOST_EVENTS=true` (a build-time feature, like
`INCLUDE_OP` / `INCLUDE_DOCKER`). The flag is persisted to
`enabled-features.conf`; on every container start `claude-setup` reads it and
wires the forwarder hook into `~/.claude/settings.json` so Claude Code agent
state is POSTed to a host monitor's local HTTP bridge (e.g. Bartender Top Shelf).
Toggle by rebuilding — there is no runtime override. The `NOTCHBAR_AGENTS_*` vars
below are runtime tuning knobs for where to reach the bridge. See
`examples/env/host-events.env`.

| Variable               | Default                              | Description                                             |
| ---------------------- | ------------------------------------ | ------------------------------------------------------- |
| `INCLUDE_HOST_EVENTS`  | `false`                              | Build-time: stage + wire the forwarder (rebuild to toggle) |
| `NOTCHBAR_AGENTS_HOST` | `host.docker.internal` / `127.0.0.1` | Runtime: host running the monitor bridge (topology-auto-default) |
| `NOTCHBAR_AGENTS_PORT` | `7823`                               | Runtime: port of the monitor bridge                     |
| `CLAUDE_SESSION_ROLE`  | _(unset)_                            | Runtime: `orchestrator` marks a non-golem session driving a fleet via `/orchestrate`, so it surfaces on the host monitor / `just golems` feed as `orchestrator` instead of a plain `primary` (human) session. Emitted by the librarian `/orchestrate` skill; consumed by both identity hooks (`claude-host-event.sh`, `golem-notify.sh`). Unset/unknown → `primary`. |

#### Worktree golems (host-side wiring)

The `claude-setup` merge above only runs **inside containers**, so it wires the
forwarder into a _container's_ `~/.claude/settings.json`. Worktree golems run in
host tmux under the **host's** Claude Code — their hooks fire on the host (where
the forwarder's topology-aware default correctly picks `127.0.0.1`), but nothing
wires the hook into the **host** `~/.claude/settings.json`.

`bin/seed-host-events.sh` is the host-side twin of that merge, exposed via
`just`. It is **opt-in** — a host that never runs `install` is never touched:

```bash
just host-events-install   # copy the hook + jq-merge the 8-event block into host ~/.claude
just host-events-check     # read-only: report whether it is fully wired (exit 1 if not)
just host-events-remove    # un-wire only our hooks + delete the copied hook
```

The merge is idempotent and preserves any hooks you already have on those (or
other) events — the same invariants as the container `claude-setup` merge. After
`install`, a worktree golem reports to the host monitor bridge with the same
`<project>-golem-N` identity as a container golem.

#### Golem activity line (pipeline phase)

For a **golem** session the host title's activity portion reflects the golem's
current `/next-issue` → `/ship-issue` phase rather than its launch prompt (which
just re-states the issue number already in the golem name). The forwarder reads
`phase` from the golem's per-issue state file
(`<worktree>/.claude/memory/tmp/next-issue-{N}.json`) and maps it to a verb:
`select` → `Selecting`, `plan` → `Planning`, `implement` → `Building`,
`ship` → `Shipping`. When no phase is available (no state file yet, a
primary/human session, or a malformed/unknown value) it falls back to the
prior prompt-derived title. The read is best-effort and never blocks the
session.

### Golem Feed Transport

A **container** golem records its decision-point events (permission `gate`,
plan-gate, mid-flight `escalation`, `dead-end`) as JSON lines in
`.worktrees/.status/feed.jsonl` that an orchestrator tails (`just golems`).
librarian's Notification hook (`golem-notify.sh`) resolves that feed via the
git common dir — for a golem worktree, the **main repo's** `.worktrees/.status`
(`/workspace/{repo}/.worktrees/.status`). `stibbons agent start` already
bind-mounts each repo's checkout (`{base}/{repo}:{base}/{repo}`), so that feed is
**already visible on the host** — no extra mount is needed.

To keep the golem entrypoint's coarse per-agent status cache
(`<AGENT_ID>.json`) from splitting away into a base-level
`/workspace/.worktrees/.status` that no mount exposes, `agent-entrypoint.sh`
co-locates it in the same repo-level `.worktrees/.status` as the feed (resolved
from `AGENT_REPOS`). `GOLEM_STATUS_DIR` overrides the target when set.

| Variable           | Default                                 | Description                                                                                     |
| ------------------ | --------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `GOLEM_STATUS_DIR` | `/workspace/{repo}/.worktrees/.status`  | Override for the container golem status-cache dir (default co-locates with the librarian feed)   |

> HTTP-sink forwarding (librarian's `GOLEM_EVENT_SINKS`) is a separate,
> filesystem-free transport tracked as a follow-up; the shared-filesystem feed
> above is the ADR-0001 approach (a) baseline.

### Retry Configuration

| Variable              | Default | Description                                        |
| --------------------- | ------- | -------------------------------------------------- |
| `RETRY_MAX_ATTEMPTS`  | `3`     | Maximum retry attempts for network operations      |
| `RETRY_INITIAL_DELAY` | `2`     | Initial delay between retries (seconds)            |
| `RETRY_MAX_DELAY`     | `30`    | Maximum delay between retries (seconds)            |
| `APT_RETRY_DELAY`     | `5`     | Initial delay between apt retry attempts (seconds) |

### Logging

| Variable           | Default                                                                | Description                                 |
| ------------------ | ---------------------------------------------------------------------- | ------------------------------------------- |
| `BUILD_LOG_DIR`    | `/var/log/container-build` (root) or `/tmp/container-build` (non-root) | Build log directory with automatic fallback |
| `CURRENT_FEATURE`  | -                                                                      | Name of currently installing feature        |
| `CURRENT_LOG_FILE` | -                                                                      | Path to current feature's log file          |

**Note on BUILD_LOG_DIR:** The logging system automatically handles permission
issues:

- If explicitly set, that directory is used
- If running as root or with proper permissions, uses `/var/log/container-build`
- If permissions are restricted (e.g., rootless containers, CI), falls back to
  `/tmp/container-build`
- Fails with clear error message if neither location is writable

### Configuration Validation

| Variable                 | Default | Description                                                 |
| ------------------------ | ------- | ----------------------------------------------------------- |
| `VALIDATE_CONFIG`        | `false` | Enable runtime configuration validation (opt-in)            |
| `VALIDATE_CONFIG_STRICT` | `false` | Treat warnings as errors (fails on warnings)                |
| `VALIDATE_CONFIG_RULES`  | -       | Path to custom validation rules file                        |
| `VALIDATE_CONFIG_QUIET`  | `false` | Suppress informational messages (show only errors/warnings) |

**Example Usage**:

```bash
# Enable validation with default rules
docker run -e VALIDATE_CONFIG=true myapp:prod

# Enable strict mode (warnings become errors)
docker run \
  -e VALIDATE_CONFIG=true \
  -e VALIDATE_CONFIG_STRICT=true \
  myapp:prod

# Use custom validation rules
docker run \
  -e VALIDATE_CONFIG=true \
  -e VALIDATE_CONFIG_RULES=/app/config/validation-rules.sh \
  -v ./my-validation.sh:/app/config/validation-rules.sh:ro \
  myapp:prod
```

See [examples/validation/](../examples/validation/) for complete examples
including web apps, API services, and background workers.

---

## Usage Examples

### Build Time

```bash
# Build with specific Python version
docker build \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg PYTHON_VERSION=3.12.0 \
  -t myproject:python312 .

# Build with multiple features
docker build \
  --build-arg INCLUDE_PYTHON_DEV=true \
  --build-arg INCLUDE_NODE_DEV=true \
  --build-arg INCLUDE_DOCKER=true \
  -t myproject:full-dev .

# Build without passwordless sudo (production)
docker build \
  --build-arg ENABLE_PASSWORDLESS_SUDO=false \
  -t myproject:prod .
```

### Runtime

```bash
# Run with GitHub token for higher API limits
docker run -e GITHUB_TOKEN="your_token_here" myproject:dev

# Run with 1Password service account
docker run -e OP_SERVICE_ACCOUNT_TOKEN="your_token_here" myproject:dev

# Run with custom retry configuration
docker run \
  -e RETRY_MAX_ATTEMPTS=5 \
  -e RETRY_INITIAL_DELAY=1 \
  myproject:dev
```

### Persistent Cache Volumes

```bash
# Create named volumes for caches
docker volume create project-pip-cache
docker volume create project-npm-cache
docker volume create project-cargo-cache

# Mount caches
docker run \
  -v project-pip-cache:/cache/pip \
  -v project-npm-cache:/cache/npm \
  -v project-cargo-cache:/cache/cargo \
  myproject:dev
```

---

## Finding Variables in Your Container

### Check What's Set

```bash
# List all exported environment variables
env | grep -E "(CACHE|HOME|PATH)" | sort

# Check specific feature variables
env | grep -i python
env | grep -i node
env | grep -i rust
```

### View Build Configuration

```bash
# Check which features are installed
check-installed-versions.sh

# View build logs for a feature
check-build-logs.sh python
check-build-logs.sh node-dev
```

### Use list-features Script

```bash
# List all available features
list-features.sh

# Get JSON output with build args
list-features.sh --json

# Filter by category
list-features.sh --filter language
list-features.sh --filter dev-tools
```

---

## Claude Code Variables

For Claude Code-specific environment variables (`CLAUDE_EXTRA_PLUGINS`,
`CLAUDE_EXTRA_MCPS`, `CLAUDE_EXTRA_SKILLS`, `CLAUDE_EXTRA_AGENTS`,
`CLAUDE_CHANNEL`, `ANTHROPIC_MODEL`,
`ANTHROPIC_AUTH_TOKEN`, `CLAUDE_AUTO_DETECT_MCPS`, `CLAUDE_MCP_AUTO_AUTH`,
auth watcher config, etc.), see
[Claude Code: Plugins & MCP Servers](../claude-code/plugins-and-mcps.md).

For 1Password `OP_*_REF` / `OP_*_FILE_REF` conventions and setup command
env vars (`GIT_USER_NAME`, `GIT_AUTH_SSH_KEY`, etc.), see
[Claude Code: Secrets & Setup](../claude-code/secrets-and-setup.md).

---

## Related Documentation

- [CLAUDE.md](../../CLAUDE.md) - Build arguments and common commands
- [Dockerfile](../../Dockerfile) - Complete list of build arguments with defaults
- [Troubleshooting](../troubleshooting.md) - Common issues with environment
  variables
- [Testing Framework](../development/testing.md) - Test environment
  configuration

---

## Contributing

When adding new features or environment variables:

1. Update this documentation
1. Add to the feature's `log_feature_summary` call
1. Include in the feature's test verification script
1. Document in the feature script's header comments
