# Zed Devcontainer Notes

This document covers editor-specific behavior when opening this repo (or any
project that uses this container build system) in [Zed](https://zed.dev/) 0.231.1+
via its native devcontainer implementation.

> **Stub notice**: this file currently covers only **Lifecycle hook behavior**
> (issue #443). Sections for Requirements / Open in Zed / Known limitations /
> Parity matrix vs VS Code are added by issue #445, and the `forwardPorts`
> workaround is added by issue #444.

## Lifecycle hook behavior

Zed 0.231.1 replaced the Node-based `devcontainer up` CLI with a native,
spec-compliant implementation. The standard devcontainer lifecycle hooks
(`initializeCommand`, `onCreateCommand`, `updateContentCommand`,
`postCreateCommand`, `postStartCommand`, `postAttachCommand`) are advertised as
supported. This section records how those hooks behave in practice for this
repo's `.devcontainer/devcontainer.json`.

### Hooks in use

This repo currently wires only one lifecycle hook:

- **`postStartCommand`** — `bash -c './.devcontainer/bin/setup-dev-environment.sh && setup-git && setup-gh'`
  - Installs lefthook git hooks (`.git/hooks/pre-commit`, `pre-push`, `commit-msg`).
  - Verifies `.env` posture and reports recommended-tool availability.
  - Configures git user identity from secrets via `setup-git`.
  - Authenticates `gh` if `OP_GITHUB_TOKEN_REF` is configured via `setup-gh`.

Other hooks (`initializeCommand`, `postCreateCommand`, `postAttachCommand`,
`updateContentCommand`, `onCreateCommand`) are **not used** in this repo today.
The `host/init-env.sh` script could be wired as `initializeCommand` later, but
isn't currently. Anyone adding a new lifecycle hook must re-run the
verification procedure below in both editors.

### VS Code baseline

For comparison, here's how `postStartCommand` behaves under VS Code (the
reference implementation):

| Aspect          | Behavior                                                       |
| --------------- | -------------------------------------------------------------- |
| When it fires   | Every container start (initial create _and_ subsequent starts) |
| Working dir     | `workspaceFolder` (`/workspace/containers` for this repo)      |
| Shell           | `/bin/bash` invoked via `bash -c …`                            |
| Output location | "Dev Containers" output panel                                  |
| Failure mode    | Logged to output panel; container still attaches               |

### Verification procedure (Zed)

Run these steps after opening the repo in Zed 0.231.1+ to confirm
`postStartCommand` fires and produces the same observable artifacts as VS Code.

1. Open the repo in Zed; accept the "Open in Container" prompt and let the
   container build.

1. After build completes, open a terminal inside Zed and run the four
   one-liners below. Each maps to a specific stage of the chained hook
   command — if any returns a failure, that stage didn't run.

   ```bash
   # Stage 0 — entrypoint ran (not a lifecycle hook, but a useful sanity check).
   [ -f ~/.container-initialized ] && echo "OK: entrypoint" || echo "FAIL: entrypoint"

   # Stage 1 — postStartCommand → setup-dev-environment.sh → lefthook install.
   ls .git/hooks/pre-commit .git/hooks/pre-push .git/hooks/commit-msg

   # Stage 2 — postStartCommand → setup-git.
   git config user.email && echo "OK: setup-git" || echo "FAIL: setup-git"

   # Stage 3 — postStartCommand → setup-gh (only if OP_GITHUB_TOKEN_REF is set).
   gh auth status
   ```

1. Capture the post-hook terminal environment and compare with the same
   commands run in a VS Code terminal:

   ```bash
   echo "PATH=$PATH"
   echo "SHELL=$SHELL"
   pwd
   ```

   Note: this captures the _terminal_ environment, not the environment
   `postStartCommand` itself ran in. Hook-time env can only be captured with
   instrumentation, which we have not added. If a delta below points to an
   ambiguity here, file a follow-up to add an opt-in trace.

1. **Restart the container.** Zed has no in-editor "Rebuild Container" action
   (its docs explicitly note that `.devcontainer/devcontainer.json` changes do
   not auto-rebuild). Force a fresh-state rebuild from a host terminal,
   outside any editor:

   ```bash
   cd /path/to/containers   # host path to this repo

   # Stop + remove the container and the locally-built image. Cache volumes
   # are kept by default — add `--volumes` to drop them too (slower rebuild).
   docker compose -f .devcontainer/docker-compose.yml down --rmi local

   # Optional — pre-build with no cache so the next open uses a fresh image:
   docker compose -f .devcontainer/docker-compose.yml build --no-cache
   ```

   Then reopen the project in Zed via `Cmd/Ctrl+Shift+P` → **`project: open
   remote`** (or the `Ctrl+Cmd+Shift+O` / `Alt+Ctrl+Shift+O` shortcut). Wait
   for `[ -f ~/.container-initialized ]` to be true before re-running the
   verification commands — that's the cheapest "container is fully started"
   gate. Re-check that `.git/hooks/pre-commit` is present and that
   `setup-dev-environment.sh` output appears in Zed's container log on this
   fresh start. VS Code re-runs `postStartCommand` on every start — Zed
   should match.

### Findings

Captured 2026-05-10 against this repo's `.devcontainer/devcontainer.json`.
VS Code baseline: VS Code Dev Containers extension, image built by VS Code.
Zed: editor 0.231.1+, remote-server `1.1.7+stable.268`, fresh
`docker compose down --rmi local` rebuild.

| Hook / aspect                                  | VS Code baseline                                                                                              | Zed observed                                                                                                                              | Notes                                                                                                                                                                |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Image `ENTRYPOINT` (`/usr/local/bin/entrypoint`) | Runs (`~/.container-initialized` written; `OP_*_REF` resolved to env vars: `GITHUB_TOKEN`, `GIT_USER_EMAIL`, …) | **Does not run.** PID 1 is `docker-init -- /bin/sh -c 'echo Container started; trap "exit 0" 15; exec "$@"; while sleep 1 …' - sleep infinity` — image entrypoint replaced despite `"overrideCommand": false` | Root cause of all OP-dependent failures below; see [Root cause](#root-cause-zed-replaces-image-entrypoint). Recovered by [`recover-entrypoint`](#fix-recover-entrypoint) in this PR.                                                                                                                                                |
| `postStartCommand` (first, lefthook stage)     | Fires; `.git/hooks/{pre-commit,pre-push,commit-msg}` installed                                                | **Fires** — same three hooks installed with fresh mtimes                                                                                  | `postStartCommand` plumbing itself works under Zed; only the OP-dependent stages fail without recovery.                                                              |
| `postStartCommand` (first, `setup-git` stage)  | Sets `user.email` / `user.name` from resolved `OP_GIT_USER_*_REF` (e.g. `josh@yaplabs.com`)                   | Without fix: falls back to `Devcontainer <devcontainer@localhost>`. With `recover-entrypoint` prepended: sets the real identity.          | `setup-git` reads `GIT_USER_EMAIL` / `GIT_USER_NAME`; entrypoint replay populates them via `/dev/shm/op-secrets-cache` (sourced by `_wait-for-op-cache`).             |
| `postStartCommand` (first, `setup-gh` stage)   | `gh auth status` shows logged-in account                                                                      | Without fix: "You are not logged into any GitHub hosts." With `recover-entrypoint` prepended: authenticated as expected.                  | `setup-gh` needs resolved `GITHUB_TOKEN`; same recovery path as `setup-git`.                                                                                         |
| `postStartCommand` (restart)                   | Re-fires; lefthook re-installed                                                                               | Not separately tested in this run — first-start lefthook install confirms the hook execution path. Restart re-test deferred to bug repro. |                                                                                                                                                                      |
| Working dir at hook time                       | `/workspace/containers`                                                                                       | Same (`pwd` in post-hook terminal = `/workspace/containers`)                                                                              |                                                                                                                                                                      |
| `$SHELL` at hook time                          | `/bin/bash`                                                                                                   | `/bin/bash`                                                                                                                               |                                                                                                                                                                      |
| `PATH` includes container PATH                 | yes (includes `/cache/cargo/bin`, `/cache/npm-global/bin`, `/opt/fzf/bin`, `~/.local/bin`)                    | Yes — same entries present                                                                                                                |                                                                                                                                                                      |

### Root cause: Zed replaces image ENTRYPOINT

PID 1 inside the Zed-launched container is `docker-init` wrapping `/bin/sh -c
'echo Container started; trap "exit 0" 15; exec "$@"; while sleep 1 …' -
sleep infinity` — Zed's stub command, not the image's
`tini -- /usr/local/bin/entrypoint`. This happens even with
`"overrideCommand": false` in `devcontainer.json`.

`/usr/local/bin/entrypoint` is the only place that:

1. Runs `op read` on every `OP_*_REF` env var and exports the resolved values
   under the bare names (`OP_GITHUB_TOKEN_REF` → `GITHUB_TOKEN`,
   `OP_GIT_USER_EMAIL_REF` → `GIT_USER_EMAIL`, etc.).
2. Writes the `~/.container-initialized` marker.

When Zed skips it, the cascade is deterministic:

- Stage 0 (`~/.container-initialized`) — file is never written → **FAIL**.
- Stage 2 (`setup-git`) — `GIT_USER_EMAIL` / `GIT_USER_NAME` are unset, so
  `setup-git:82-83` applies the fallback `Devcontainer
  <devcontainer@localhost>`. The script exits 0, but the identity is
  effectively wrong → **FAIL (silent)**.
- Stage 3 (`setup-gh`) — no `GITHUB_TOKEN` to authenticate with → **FAIL**.

Stage 1 (lefthook) passes because `setup-dev-environment.sh` is invoked
directly by `postStartCommand` and doesn't depend on any OP-resolved secret.

The `OP_*_REF` env vars themselves are present in the Zed container (set via
`containerEnv` / `.env` and inherited through Compose), and
`OP_SERVICE_ACCOUNT_TOKEN` is also set — so the issue is strictly that the
resolution step (the entrypoint) was never executed, not that the inputs are
missing.

### Fix: `recover-entrypoint`

The in-tree fix is a small image-side helper, `recover-entrypoint`, that
replays the image ENTRYPOINT when its marker (`~/.container-initialized`)
is missing. It's wired into every devcontainer this build system produces:

- Script: `lib/runtime/commands/recover-entrypoint` → installed to
  `/usr/local/bin/recover-entrypoint` by the Dockerfile (alongside
  `setup-git`, `setup-gh`, etc.).
- Generated `devcontainer.json` template
  (`crates/containers-common/src/template/sources/devcontainer.json.j2`)
  prepends it to the default `postStartCommand`, so any project scaffolded
  by `stibbons` gets the recovery automatically.
- This repo's own `.devcontainer/devcontainer.json` chains it ahead of
  `setup-dev-environment.sh && setup-git && setup-gh`.

The script is idempotent: when the marker exists (VS Code's normal path) it
short-circuits in well under a millisecond; when missing (Zed's path) it
invokes the entrypoint as the current user, which sudos internally for
privileged setup (cache chown, etc.), runs `/etc/container/startup/*.sh`,
writes the marker, and exits 0. Downstream `setup-git` and `setup-gh` then
see resolved `GITHUB_TOKEN` / `GIT_USER_EMAIL` via `_wait-for-op-cache`'s
existing source of `/dev/shm/op-secrets-cache`.

For projects writing a custom `postStartCommand`, the convention is to keep
`recover-entrypoint &&` as the first link:

```jsonc
"postStartCommand": "recover-entrypoint && <your setup chain>"
```

### Upstream Zed bug

The systemic fix above papers over the divergence locally — the underlying
issue is upstream in Zed, tracked at
[zed-industries/zed#56357](https://github.com/zed-industries/zed/issues/56357).
If new symptoms
appear that aren't covered by `recover-entrypoint` (other ENTRYPOINT
behaviors beyond setup-script execution — signal forwarding, zombie reaping
semantics, etc.), they should be added to that bug, or filed as a fresh
bug if categorically different.

### Action on new failures

If a stage fails or differs from the VS Code baseline in a way
`recover-entrypoint` doesn't address:

- The full output of the four verification one-liners above
- The PATH/SHELL/PWD capture from step 3
- Zed editor version + remote-server version
- A minimal reproducer (ideally pointing at this repo's
  `.devcontainer/devcontainer.json` directly)
- `cat /proc/1/cmdline | tr '\0' ' '; echo` — what's actually running as PID 1

Either append to the upstream Zed bug, or — if the symptom is a new failure
mode in the recovery path itself — file an in-repo issue and update
`recover-entrypoint` accordingly.

### Hooks not yet in use

If a future change wires `initializeCommand`, `postCreateCommand`,
`postAttachCommand`, `updateContentCommand`, or `onCreateCommand`, re-run the
verification above for that hook and append a row to the findings table. The
`postCreateCommand` and `postAttachCommand` semantics differ subtly across
implementations (one-time vs every-attach), so don't assume parity.
