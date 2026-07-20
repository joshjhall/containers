# Getting Started with stibbons

Step-by-step guide for using stibbons to set up a devcontainer in a new or
existing project.

> **Note:** stibbons is the Rust CLI that replaces the legacy Go `igor` binary.
> The generated files, `.igor.yml` state file, and `IGOR:BEGIN`/`IGOR:END`
> markers keep their names for backward compatibility.

## Prerequisites

- **stibbons** — the CLI itself. Install a release binary with
  `./bin/install-stibbons.sh`, or build from source (needs a Rust toolchain;
  see [Step 2](#step-2-install-stibbons)).
- **containers submodule** — the project must have the containers repo as a git
  submodule (typically at `containers/`)
- **Docker** — needed to build and run the generated container

## Step 1: Add the Containers Submodule

Skip this if your project already has the submodule.

```bash
git submodule add https://github.com/joshjhall/containers.git containers
git submodule update --init --recursive
```

## Step 2: Install stibbons

### Option A: Release binary (recommended)

```bash
./containers/bin/install-stibbons.sh
```

This downloads the prebuilt binary for your host platform and installs it on
your `PATH`.

### Option B: Build from source

Requires a Rust toolchain (`rustup`):

```bash
cargo build --release -p stibbons --manifest-path containers/Cargo.toml
```

The binary is written to `containers/target/release/stibbons`; add it to your
`PATH` or invoke it by that path.

## Step 3: Run the Wizard

From your project root:

```bash
stibbons init
```

stibbons auto-detects:

- **Project name** from the current directory name
- **Containers path** by looking for `containers/Dockerfile`,
  `docker/containers/Dockerfile`, or `.containers/Dockerfile`
- **Username** defaults to `developer`
- **Base image** defaults to `debian:trixie-slim`

Walk through each wizard step:

1. Confirm or edit project configuration
1. Select languages (Python, Node.js, Rust, Go, etc.)
1. Select dev tool bundles (LSP, linters, formatters)
1. Select cloud tools (Kubernetes, Terraform, AWS, etc.)
1. Select utilities (Docker CLI, 1Password, database clients, Ollama)
1. Review selections and auto-resolved dependencies
1. Confirm to generate files

## Step 4: Review Generated Files

stibbons creates five files:

```text
.devcontainer/
  docker-compose.yml    # Build definition with selected features
  devcontainer.json     # VS Code configuration
  .env                  # Runtime environment variables
.env.example            # Documented env template (commit this)
.igor.yml               # stibbons state file (commit this)
```

Review each file. Content between `=== IGOR:BEGIN ===` and `=== IGOR:END ===`
markers is managed by stibbons. You can add custom content outside the markers.

## Step 5: Build and Open the Container

### Option A: VS Code Dev Containers

1. Install the
   [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
1. Open the project in VS Code
1. Press `Ctrl+Shift+P` → "Dev Containers: Reopen in Container"

### Option B: Docker Compose

```bash
docker compose -f .devcontainer/docker-compose.yml up -d
docker compose -f .devcontainer/docker-compose.yml exec devcontainer bash
```

## Before and After

### Before stibbons: Manual setup

Setting up a Python + Node.js dev container manually requires:

```bash
# 20+ build arguments to remember
docker build -t myproject:dev \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myproject \
  --build-arg USERNAME=developer \
  --build-arg BASE_IMAGE=debian:trixie-slim \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_PYTHON_DEV=true \
  --build-arg PYTHON_VERSION=3.14.0 \
  --build-arg INCLUDE_NODE=true \
  --build-arg INCLUDE_NODE_DEV=true \
  --build-arg NODE_VERSION=22.12.0 \
  --build-arg INCLUDE_DEV_TOOLS=true \
  --build-arg INCLUDE_DOCKER=true \
  --build-arg INCLUDE_POSTGRES_CLIENT=true \
  .

# Then manually create:
#   .devcontainer/docker-compose.yml (with correct volumes, networks, args)
#   .devcontainer/devcontainer.json (with correct extensions, settings)
#   .devcontainer/.env (with language-specific env vars)
```

### After stibbons: One command

```bash
stibbons init
# Select Python, Python Dev, Node.js, Node.js Dev, Dev Tools, Docker, PostgreSQL Client
# → All 5 files generated with correct build args, volumes, extensions, env vars
```

## Next Steps

- [Feature Reference](feature-reference.md) — all available features and
  their dependencies
- [Templates](templates.md) — how the template system works and how to
  customize output
- [`bin/install-stibbons.sh`](../../bin/install-stibbons.sh) — install the
  stibbons CLI from release binaries. Run `stibbons --help` for the full CLI
  reference.
