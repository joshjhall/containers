# `pre-secrets.d/` — credential-provider hooks

`*.sh` files here run at container start **before** 1Password secrets load,
Claude auth, and `setup-git` (startup script `30-credential-setup.sh`, on both
VS Code and Zed). Use them to wire in an external credential provider —
something that makes `op`, `gh`, `glab` or git's ssh/signing work without a
token in the environment.

Hooks are **opt-in**: they run only when the container has
`CREDENTIAL_SETUP_HOOKS=true` (set it in your gitignored override, below).
Without it, any `*.sh` here is skipped with a log line, so cloning a repo can
never make your container run its code at boot.

Each hook is its own process, so export env for later steps by appending to
the hand-off file:

```bash
#!/bin/bash
echo 'export PATH="/opt/provider/shims:$PATH"' >>"$CONTAINER_CREDENTIAL_ENV_FILE"
```

Provider hooks are usually machine-specific. Keep them out of git with a
`.git/info/exclude` entry (for example `.devcontainer/pre-secrets.d/*.sh`)
unless every contributor uses the same provider.

Mounts the provider needs (its socket, its shims) and the opt-in flag go in
`.devcontainer/docker-compose.override.yml`. `devcontainer.json` already
layers it after `docker-compose.yml`; the committed copy is an empty
placeholder, so a clean checkout still opens. Edit it locally:

```yaml
services:
  devcontainer:
    environment:
      CREDENTIAL_SETUP_HOOKS: "true"
```

Then keep your edits out of git:

```bash
git update-index --skip-worktree .devcontainer/docker-compose.override.yml
```

Full reference: `docs/claude-code/external-credential-providers.md`.
