# Zed Devcontainer Notes

This document covers editor-specific behavior when opening this repo (or any
project that uses this container build system) in [Zed](https://zed.dev/) 0.231.1+
via its native devcontainer implementation.

If you're new to Zed + devcontainers, read [Requirements](#requirements) and
[Open in Zed](#open-in-zed) first, then skim [Known limitations](#known-limitations)
and the [Parity matrix](#parity-matrix). The deeper [Lifecycle hook behavior](#lifecycle-hook-behavior)
and [Port forwarding](#port-forwarding) sections are reference material for
when something behaves differently than VS Code.

## Requirements

- **Zed 0.231.1+** — the April 2026 release replaced the Node-based
  `devcontainer up` CLI with a native, spec-compliant implementation. Earlier
  versions either don't ship devcontainer support or rely on the deprecated
  Node CLI and are not supported here.
- **Docker on `PATH`** — Zed shells out to the `docker` binary directly for
  build, run, and `compose` operations. BuildKit is fine; the modern
  `docker compose ...` form (Compose v2) is required — the legacy hyphenated
  `docker-compose` binary is not invoked.
- **Podman** — supported via a `docker` symlink on `PATH` (`ln -s
  $(command -v podman) ~/.local/bin/docker`). Zed has no first-class Podman
  backend, so anything Podman doesn't faithfully emulate from the Docker CLI
  surface is on you to work around.
- **No additional Zed extensions required on the host.** Container-side
  extensions are installed by Zed from `customizations.zed.extensions` in
  `devcontainer.json` and persisted in the `zed-extensions` named volume so
  they survive container restarts.

## Open in Zed

1. From a host terminal at the repo root, run `zed .` (or pick the repo from
   `File → Open Recent`). Zed detects `.devcontainer/devcontainer.json` and
   prompts **"Open in Container"** in the bottom-right.
1. Accept the prompt. Zed builds or pulls the image, starts the compose
   stack, and re-opens the workspace targeting the container. First-time
   builds take a few minutes; subsequent opens reuse the existing container.
1. Wait for the container log to settle. The cheapest "container is fully
   started" gate is `[ -f ~/.container-initialized ]` returning success in
   a container terminal — see the [Verification procedure](#verification-procedure-zed)
   below.
1. Attach a terminal with `` Ctrl+` `` (Linux/Windows) or `` Cmd+` ``
   (macOS). The terminal runs inside the container with the same `PATH`,
   user, and working directory as VS Code's "Dev Containers" terminal.
1. Extensions declared under `customizations.zed.extensions` install on
   first open and land in the `zed-extensions` named volume. They are not
   reinstalled on every container start.

If you customize `postStartCommand` in `.devcontainer/devcontainer.json`,
keep `recover-entrypoint &&` as the first link in the chain — it is what
makes secrets (`OP_*_REF` → resolved env vars) and git identity work under
Zed. See [Fix: recover-entrypoint](#fix-recover-entrypoint) for the why.

## Known limitations

Zed's native devcontainer support is spec-compliant for the common path but
has well-known gaps versus VS Code. The ones that affect this build system:

- **`forwardPorts` is silently ignored** — only `appPort` is honored.
  Publish service ports via the compose `ports:` block instead.
  See [Port forwarding](#port-forwarding) for the workaround and the
  fields to avoid emitting.
- **No auto-rebuild on `devcontainer.json` change** — Zed does not detect
  changes to `.devcontainer/devcontainer.json` and rebuild. You have to
  stop the container from a host terminal and reopen the project. See the
  rebuild block under [Verification procedure (Zed)](#verification-procedure-zed)
  for the exact `docker compose down --rmi local` invocation.
- **Docker is the only backend** — Podman works only via the `docker`
  symlink workaround above; there is no native Podman driver.
- **Host VS Code extensions are not mirrored** — opening the same repo in
  Zed does not inherit your VS Code extension set. Zed installs whatever is
  declared in `customizations.zed.extensions`, which is a separate list
  emitted from the same per-feature registry that drives
  `customizations.vscode.extensions`. The source of truth lives in the
  feature registry; the generated `devcontainer.json` carries both lists.
- **Image `ENTRYPOINT` is replaced** — Zed runs the container with its own
  `docker-init -- /bin/sh -c '... sleep infinity'` stub as PID 1, even with
  `"overrideCommand": false`. This is why the image's tini + entrypoint
  chain does not run on its own. See
  [Root cause](#root-cause-zed-replaces-image-entrypoint) and
  [Fix: recover-entrypoint](#fix-recover-entrypoint) for the replay
  mechanism that papers over this locally. Upstream bug:
  [zed-industries/zed#56357](https://github.com/zed-industries/zed/issues/56357).

## Parity matrix

How VS Code (Dev Containers extension) and Zed (0.231.1+ native impl)
compare across the surface area this build system exercises:

| Aspect                                       | VS Code                                                                                              | Zed                                                                                                                                | Notes                                                                                                                              |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Lifecycle hooks                              | Full spec — `initializeCommand`, `onCreateCommand`, `updateContentCommand`, `postCreateCommand`, `postStartCommand`, `postAttachCommand` | Spec-compliant, but image `ENTRYPOINT` is replaced. `postStartCommand` plumbing fires; entrypoint-driven setup needs replay.       | See [Lifecycle hook behavior](#lifecycle-hook-behavior) and [Fix: recover-entrypoint](#fix-recover-entrypoint).                    |
| Every-boot startup scripts (`/etc/container/startup/*`) | Run on **every** container start by the image ENTRYPOINT (PID 1) — secrets refresh, auth watcher, project health check, codegraph index sync, etc. | Image ENTRYPOINT never runs, so these are replayed by `recover-entrypoint`: full replay on first start, then a startup-only replay (`ENTRYPOINT_STARTUP_ONLY=true`) on each subsequent start — matching VS Code's every-boot behavior without redoing one-time privileged setup. | See [Fix: recover-entrypoint](#fix-recover-entrypoint). Before this, later Zed starts silently skipped every-boot scripts (e.g. a stale codegraph index). |
| Extensions                                   | `customizations.vscode.extensions` — installed on first attach, cached per-user on the host          | `customizations.zed.extensions` — installed on first open, cached in the `zed-extensions` named volume                             | Same per-feature registry generates both lists; neither editor inherits the other's set.                                           |
| Port forwarding                              | `forwardPorts`, `portsAttributes`, `otherPortsAttributes`, `appPort` all honored                     | Only `appPort` honored; `forwardPorts` and `*Attributes` fields are silently dropped                                               | Cross-editor portable form: declare `ports:` in `docker-compose.yml`. See [Port forwarding](#port-forwarding).                     |
| Multi-service Compose                        | Full — `dockerComposeFile`, `service`, `runServices` all respected                                   | Full — recent fixes for `labels` and multi-stage Dockerfiles landed in 0.231.x                                                     | Sidecar services (Postgres, Redis, etc.) from `examples/contexts/devcontainer/docker-compose.yml` work identically in both editors. |
| Secrets pass-through (`OP_*_REF` → env vars) | Image entrypoint runs `op read` once per `OP_*_REF`; resolved values are exported under bare names   | Without `recover-entrypoint`: not resolved (entrypoint replaced). With `recover-entrypoint`: resolved at first `postStartCommand`. | See [Root cause](#root-cause-zed-replaces-image-entrypoint) for the replacement mechanism and [Fix](#fix-recover-entrypoint).      |

## Lifecycle hook behavior

Zed 0.231.1 replaced the Node-based `devcontainer up` CLI with a native,
spec-compliant implementation. The standard devcontainer lifecycle hooks
(`initializeCommand`, `onCreateCommand`, `updateContentCommand`,
`postCreateCommand`, `postStartCommand`, `postAttachCommand`) are advertised as
supported. This section records how those hooks behave in practice for this
repo's `.devcontainer/devcontainer.json`.

### Hooks in use

This repo currently wires only one lifecycle hook:

- **`postStartCommand`** — the chain below:

  ```bash
  bash -c 'recover-entrypoint && ./.devcontainer/bin/setup-dev-environment.sh && setup-git && setup-gh'
  ```

  - `recover-entrypoint` replays the image ENTRYPOINT setup that Zed skips —
    full one-time setup on first start, then the every-boot startup phase
    (`/etc/container/startup/*`, e.g. codegraph index sync, secret refresh) on
    each subsequent start. See [Fix: recover-entrypoint](#fix-recover-entrypoint).
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
replays the image ENTRYPOINT setup Zed skips. It's wired into every
devcontainer this build system produces:

- Script: `lib/runtime/commands/recover-entrypoint` → installed to
  `/usr/local/bin/recover-entrypoint` by the Dockerfile (alongside
  `setup-git`, `setup-gh`, etc.).
- Generated `devcontainer.json` template
  (`crates/containers-common/src/template/sources/devcontainer.json.j2`)
  prepends it to the default `postStartCommand`, so any project scaffolded
  by `stibbons` gets the recovery automatically.
- This repo's own `.devcontainer/devcontainer.json` chains it ahead of
  `setup-dev-environment.sh && setup-git && setup-gh`.

The script branches on the marker (`~/.container-initialized`), and runs on
every `postStartCommand` (i.e. every container start):

- **Marker missing (first start under Zed).** Full replay: invokes the
  entrypoint as the current user, which sudos internally for one-time
  privileged setup (cache chown, bindfs, cron, OP secret resolution),
  runs `/etc/container/{first-startup,startup}/*.sh`, writes the marker,
  and exits 0.
- **Marker present (every subsequent start).** Startup-only replay: invokes
  the entrypoint with `ENTRYPOINT_STARTUP_ONLY=true`, which **skips** the
  expensive one-time privileged block and re-runs only the every-boot
  `/etc/container/startup/*.sh` phase. This is what keeps parity with VS
  Code, where the PID-1 entrypoint re-runs those scripts on every boot —
  refreshing secrets, the claude-auth watcher, the project health check, and
  the codegraph index (`sync`). Without it, later Zed starts silently ran
  none of them.

Under VS Code the marker is written by the PID-1 entrypoint, so the first
`recover-entrypoint` call already takes the startup-only branch (a cheap
no-op-ish re-run of the same every-boot scripts). Downstream `setup-git` and
`setup-gh` see resolved `GITHUB_TOKEN` / `GIT_USER_EMAIL` via
`_wait-for-op-cache`'s existing source of `/dev/shm/op-secrets-cache`.

The every-boot scripts are individually guarded/idempotent (marker files,
skip gates), so re-running them each boot is safe.

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

## Port forwarding

Zed's native devcontainer implementation (0.231.1+) honors only the
`appPort` field from `devcontainer.json` — `forwardPorts` and other
advanced port-forwarding directives are silently ignored. See
[zed.dev/docs/dev-containers](https://zed.dev/docs/dev-containers):

> Only the `appPort` field is supported. `forwardPorts` and other advanced
> port-forwarding features are not implemented.

There is no error and no breadcrumb in the container log; ports simply do
not appear on the host. Users coming from VS Code (where
`forwardPorts: [8080, 5432]` Just Works) will hit this the moment they
need to expose a service from inside the container.

### Recommended: docker-compose `ports:`

Declare port publishing in `docker-compose.yml` rather than in
`devcontainer.json`. Compose publishes via Docker directly, so both
VS Code and Zed honor it — the editor doesn't have to know.

```yaml
services:
  devcontainer:
    ports:
      - "8080:8080"  # Works in both VS Code and Zed; do not rely on forwardPorts
      - "5432:5432"
```

This is what `examples/contexts/devcontainer/docker-compose.yml` already
does for sidecar services like Postgres and Redis. Any project scaffolded
by `stibbons` can extend the generated compose file the same way without
touching `devcontainer.json`.

### Single-port alternative: `appPort`

If a project really wants to stay inside `devcontainer.json`, Zed does
honor `appPort` for a single port (or a small array):

```jsonc
{
  "appPort": 8080
}
```

This is more restrictive than `forwardPorts` (no `portsAttributes`, no
`onAutoForward`, no auto-detection of newly-bound ports) and is mostly
useful for the appPort/single-service case. For anything beyond one
fixed port, prefer the compose-level form above.

### Fields silently dropped by Zed

Avoid these in `devcontainer.json` unless a project is VS Code-only:

- `forwardPorts`
- `portsAttributes`
- `otherPortsAttributes`

If you find one of these in a generated `devcontainer.json` after a future
`stibbons` change, treat it as a bug — the template should not emit them.
