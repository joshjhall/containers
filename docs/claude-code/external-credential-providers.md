# External Credential Providers

Companion to [Secrets & Setup](secrets-and-setup.md), which covers the
default `OP_*_REF` / `OP_*_FILE_REF` flow and the container setup commands.

An external credential provider makes `op` (and often `gh`, `glab`, and git's
ssh/signing) work **without a token in the container's environment** — for
example a host-side process that holds a 1Password service-account token and
exposes it to the container through a read-only socket plus small shims on
`PATH`. Nothing here requires one: with only `OP_SERVICE_ACCOUNT_TOKEN` set,
behaviour is unchanged. When one is present, the image uses it instead of
overriding it.

## How `op` is detected

Every secret consumer (`45-op-secrets.sh`, `claude-setup`,
`claude-auth-watcher`, the bashrc helpers, and the `setup-*` commands) asks one
shared helper, `op_is_usable` (`/opt/container-runtime/lib/op-usable.sh`).
`op` must be on `PATH`, then the first match wins:

1. `OP_SERVICE_ACCOUNT_TOKEN` is set — no subprocess (today's behaviour)
1. `OP_CONNECT_HOST` **and** `OP_CONNECT_TOKEN` are set
1. `op whoami` succeeds — run with stdin closed and a hard timeout, so it can
   never prompt for a sign-in or hang

With none of these, every consumer skips cleanly with the same messages as
before.

| Variable                 | Default    | Purpose                                                  |
| ------------------------ | ---------- | -------------------------------------------------------- |
| `OP_WHOAMI_TIMEOUT`      | `5`        | Seconds before `op whoami` is killed                     |
| `OP_NO_WHOAMI_PROBE`     | `false`    | `true` = token/Connect only, never probe                 |
| `OP_USABLE_NEGATIVE_TTL` | `30`       | Seconds a "not usable" verdict is reused before re-probe |
| `OP_WHOAMI_CACHE_DIR`    | `/dev/shm` | Where the shared verdict cache lives                     |

A successful probe is cached for 60s, so shells do not each pay for one. The
cache is keyed on the resolved `op` path, so a "no" from the real binary never
hides a provider shim that reaches `PATH` later.

## Pre-secrets hook

Providers usually need to put shims on `PATH` or set env **before** secrets
load. `/etc/container/startup/30-credential-setup.sh` runs, in order:

1. `CONTAINER_CREDENTIAL_SETUP_CMD`, if set (run via `bash -c`)
1. `/workspace/<project>/.devcontainer/pre-secrets.d/*.sh`, sorted —
   **only when `CREDENTIAL_SETUP_HOOKS=true`**

Workspace hooks are **opt-in** because they are a trust boundary: they come
from whatever repos are mounted under `/workspace` and run at boot, before
secrets load, where a hook could put a fake `op` or `gh` on `PATH`. Without the
flag, any hook files present are skipped with one log line saying how to enable
them. `CONTAINER_CREDENTIAL_SETUP_CMD` needs no opt-in: it comes from your own
environment or compose file, not from a repository.

With the flag on, a hook is still refused, with a `WARN: ignoring hook …` line
naming the reason, unless it is a regular file (not a symlink), owned by the
current user or root, and not group- or world-writable. Set the flag only for
workspaces whose `pre-secrets.d/` you have reviewed.

Startup scripts run in filename order — 30 comes before
`35-claude-auth-watcher`, `45-op-secrets` and `60-setup-git` — on both the
image entrypoint (VS Code) and `recover-entrypoint` (Zed), so no other wiring
is needed. Each hook is bounded by `CREDENTIAL_SETUP_TIMEOUT` (default 30s);
a failing or hung hook is logged and the next one still runs. With no command
and no hook files the script does nothing at all.

**Handing env forward.** Each startup script is a separate process, so a hook
that just runs `export PATH=...` affects only itself. Append shell assignments
to `$CONTAINER_CREDENTIAL_ENV_FILE` instead (exported to hooks; default
`/dev/shm/container-credential-env.<uid>`, mode 0600, recreated each boot):

```bash
#!/bin/bash
# .devcontainer/pre-secrets.d/10-provider.sh
echo 'export PATH="/opt/provider/shims:$PATH"' >>"$CONTAINER_CREDENTIAL_ENV_FILE"
echo 'export GIT_SSH_COMMAND="/opt/provider/shims/ssh"' >>"$CONTAINER_CREDENTIAL_ENV_FILE"
```

Every later consumer — startup scripts, `setup-*`, interactive shells — loads
that file. It is executed as shell, so it is ignored unless it is a regular
file owned by the current user and not group- or world-writable. Write
configuration there, not secret values.

## git and forge CLIs

`setup-git` leaves externally provided ssh and signing alone, skipping only the
conflicting part and logging one `skip:` line with the reason:

| Provided externally when…                                                         | Skipped                                                    |
| --------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| `SKIP_GIT_SSH_SETUP=true`, `GIT_SSH_COMMAND` set, or `core.sshCommand` in `GIT_CONFIG_*` | its own `ssh-agent`, auth key, `core.sshCommand`          |
| `SKIP_GIT_SIGNING_SETUP=true`, or `gpg.format` / `gpg.ssh.program` / `user.signingkey` in `GIT_CONFIG_*` | all signing writes **and** the stale-signing cleanup |

Identity (`GIT_USER_NAME` / `GIT_USER_EMAIL`) and the SSH keep-alive always
run.

`setup-gh` / `setup-glab` do not copy a token into shells when the CLI is
authenticated without a stored token of its own (see
[`setup-gh` / `setup-glab` Details](secrets-and-setup.md#setup-gh--setup-glab-details)). A tool
that genuinely needs `GITHUB_TOKEN` in its env can still get it from
`OP_GITHUB_TOKEN_REF`.

## `BASH_ENV`

A provider may point `BASH_ENV` at a file that only exists after
`postStartCommand`. bash silently ignores a missing `BASH_ENV` file, and
nothing in the startup path depends on it.

## This repo's devcontainer

Wire a provider in locally without committing it:

- Put mounts in `.devcontainer/docker-compose.override.yml` (gitignored) and
  add it to your local `dockerComposeFile` list. Compose cannot optionally
  include a missing file, so the checked-in `devcontainer.json` keeps the
  single file and a clean checkout still opens.
- Drop hook scripts in `.devcontainer/pre-secrets.d/` and set
  `CREDENTIAL_SETUP_HOOKS: "true"` in that override's `environment` — see the
  README there.
