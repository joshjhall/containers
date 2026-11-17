# `pre-secrets.d/` — credential-provider hooks

`*.sh` files here run at container start **before** 1Password secrets load,
Claude auth, and `setup-git` (startup script `30-credential-setup.sh`, on both
VS Code and Zed). Use them to wire in an external credential provider —
something that makes `op`, `gh`, `glab` or git's ssh/signing work without a
token in the environment. With no `*.sh` files here, nothing runs.

Each hook is its own process, so export env for later steps by appending to
the hand-off file:

```bash
#!/bin/bash
echo 'export PATH="/opt/provider/shims:$PATH"' >>"$CONTAINER_CREDENTIAL_ENV_FILE"
```

Provider hooks are usually machine-specific. Keep them out of git with a
`.git/info/exclude` entry (for example `.devcontainer/pre-secrets.d/*.sh`)
unless every contributor uses the same provider.

Mounts the provider needs (its socket, its shims) go in
`.devcontainer/docker-compose.override.yml`, which is gitignored. Add it to
your local `dockerComposeFile` list:

```jsonc
"dockerComposeFile": ["docker-compose.yml", "docker-compose.override.yml"],
```

Don't commit that `devcontainer.json` change: Compose fails on a missing file,
so a clean checkout without an override would no longer open.

Full reference: `docs/claude-code/secrets-and-setup.md` § External Credential
Providers.
