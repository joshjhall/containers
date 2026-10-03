# Build Artifacts on /cache Volumes

This page recommends keeping **disposable build artifacts** (virtualenvs,
Rust `target/` dirs, CMake build trees, `node_modules`) on named volumes under
`/cache/<kind>/<checkout>` instead of inside the bind-mounted workspace. This
is the default guidance for projects built on this image. It matters most when
you use git worktrees for parallel agents.

## Why Not the Workspace

- **Correctness on macOS hosts.** `/workspace` is case-insensitive (APFS →
  virtiofs → bindfs), and Compose has no setting to change that. Artifact
  trees contain case-colliding names and symlinks: a uv venv's `lib` and
  `lib64 -> lib`, for example. Deleting such a tree on the workspace mount can
  leave **undeletable phantom entries** (#1004). On a volume the tree never
  touches that mount.
- **Speed.** Artifact trees hold the most small files of anything in a project,
  and virtiofs plus FUSE add overhead to every metadata call. A named volume is
  native ext4 inside the VM.
- **Lifecycle.** A named volume survives image rebuilds. You can still drop one
  kind on its own (`docker volume rm <project>-target`) to force a clean build
  without touching source or any other cache. This is the same pattern
  `/cache/codegraph` already uses.
- **Worktrees.** Each checkout needs its **own** artifact dir. Parallel golems
  building into one shared `target/` or `.venv` corrupt each other's builds.

## Per-Checkout Naming

| Checkout        | `<checkout>`                | Example                          |
| --------------- | --------------------------- | -------------------------------- |
| Main checkout   | `<project>`                 | `/cache/venvs/myproj`            |
| Linked worktree | `<project>--<worktree-dir>` | `/cache/venvs/myproj--issue-569` |

`<project>` is the main checkout's directory name. A linked worktree is
detected by `git rev-parse --git-dir` differing from `--git-common-dir`, so the
scheme works wherever the worktree lives.

The image ships the `artifact-dir` command so projects don't re-implement this:

```bash
artifact-dir venvs              # mkdir -p + print /cache/venvs/<checkout>
artifact-dir --no-create target # print only
artifact-dir --name             # print <checkout> only
artifact-dir --project          # print <project> (the main checkout's name)
artifact-dir -C path/to/repo venvs
```

`fix_cache_permissions` re-owns `/cache` at container startup, so new volumes
mounted under it need no extra privilege wiring.

## Shared vs Per-Checkout

Split artifacts by whether they are content-addressed:

- **Shared:** one dir for all checkouts. Content-addressed download caches are
  safe to share: the uv/pip caches, the cargo registry, the Go module and build
  caches, the npm cache, and the pnpm store. The image already points these at
  `/cache/*`. See [Language Caches](language-caches.md).
- **Per-checkout:** build **outputs** that depend on one checkout's sources.
  These need their own subdirectory each: venvs, `target/`, CMake trees,
  `node_modules`.

## Docker Compose

Mount one named volume per artifact kind. Every checkout then gets its own
subdirectory inside it:

```yaml
services:
  dev:
    init: true
    volumes:
      - ..:/workspace/myproj
      - myproj-cache:/cache                 # shared package caches
      - myproj-venvs:/cache/venvs           # Python
      - myproj-target:/cache/target         # Rust
      - myproj-build:/cache/build           # C/C++ (CMake/Ninja)
      - myproj-node:/cache/node_modules     # Node

volumes:
  myproj-cache:
  myproj-venvs:
  myproj-target:
  myproj-build:
  myproj-node:
```

Separate volumes per kind let you drop one kind (`docker volume rm
myproj-target`) without losing the others. If you don't need that, you can
leave these off and the dirs simply live on the `/cache` volume.

## Per-Ecosystem Recipes

### Python (uv)

Symlink `.venv` to the artifact dir. uv installs into the symlink's target, and
anything that expects `.venv` keeps working: tools that call `uv run` directly
(lefthook hooks), pyright, and editors.

```just
# Point .venv at this checkout's /cache venv (idempotent).
venv-link:
    #!/usr/bin/env bash
    set -euo pipefail
    target="$(artifact-dir venvs)"
    if [ -d .venv ] && [ ! -L .venv ]; then
        echo "moving aside real .venv"; mv .venv ".venv.old.$$"
    fi
    ln -sfn "$target" .venv
    uv sync
```

Add `.venv` to `.gitignore`. It is a symlink now, but still not source.
Alternatively, set `UV_PROJECT_ENVIRONMENT="$(artifact-dir venvs)"`. That works
for `uv` but not for tools that look for `.venv` on disk.

### Python (poetry / pip)

```bash
# poetry: one venv per checkout under the volume
export POETRY_VIRTUALENVS_PATH="$(artifact-dir venvs)"

# plain venv
python -m venv "$(artifact-dir venvs)"
ln -sfn "$(artifact-dir --no-create venvs)" .venv
```

### Rust

```bash
export CARGO_TARGET_DIR="$(artifact-dir target)"
```

rust-analyzer honors `CARGO_TARGET_DIR`. A target dir per checkout also avoids
cargo's build-directory lock contention between worktrees. Keep the cargo
registry (`CARGO_HOME=/cache/cargo`) shared.

### C / C++ (CMake)

Build out-of-source into the artifact dir, then symlink the compilation
database back for clangd:

```bash
build="$(artifact-dir build)"
cmake -S . -B "$build" -G Ninja -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
cmake --build "$build"
ln -sfn "$build/compile_commands.json" compile_commands.json
```

### Node

```bash
ln -sfn "$(artifact-dir node_modules)" node_modules
npm ci
```

Caveats: some tools resolve `node_modules` with `realpath` and then fail to
find the project root, or watch the wrong tree. Bundlers with symlink options
(Vite `resolve.preserveSymlinks`, webpack `resolve.symlinks`) may need them
set. If a tool breaks, consider pnpm instead. Its content-addressed store can
live on `/cache` (`pnpm config set store-dir /cache/pnpm-store`) and be
shared. `node_modules` then holds only links, so leaving it in the workspace is
cheap.

### Go

Go's module and build caches are content-addressed, so share them:

```bash
export GOMODCACHE=/cache/go/pkg/mod
export GOCACHE=/cache/go-build
```

Go has no per-checkout build tree to relocate. `go build -o` outputs are
usually small.

## Cleaning Up After a Worktree

A worktree's artifact dirs live off the worktree, so removing the worktree
orphans them. To remove them:

```bash
artifact-dir prune myproj--issue-569 --dry-run   # list
artifact-dir prune myproj--issue-569             # remove /cache/*/myproj--issue-569
```

`prune` only accepts linked-worktree names (ones containing `--`), and only
removes `/cache/<kind>/<name>` leaves, never a shared cache. Run it from inside
the project: it then also refuses the main checkout's own name, which matters
if your project directory name itself contains `--`.

`just worktree-rm N` runs this check after removing the worktree. If it finds
dirs for `<project>--issue-N`, it lists them. On a TTY it asks before removing
them; otherwise it only prints the `prune` command.

The bundled librarian teardown (`worktree-rm.sh`, also used by
`/workflow:golem` and `/workflow:orchestrate`) does not run this step yet
(tracked in joshjhall/librarian#1092). After those teardowns, run
`artifact-dir prune` yourself.

## Related Documentation

- [Runtime Volumes](runtime-volumes.md) - mounting `/cache` itself
- [Language Caches](language-caches.md) - shared per-language cache paths
- [Case-sensitive filesystems](../../troubleshooting/case-sensitive-filesystems.md)
  - why the workspace mount misbehaves on macOS
