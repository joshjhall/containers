# Getting Started with Igor

Step-by-step guide for using igor to set up a devcontainer in a new or existing
project.

## Prerequisites

- **Go 1.23+** — required to build igor from source
- **containers submodule** — the project must have the containers repo as a git
  submodule (typically at `containers/`)
- **Docker** — needed to build and run the generated container

## Step 1: Add the Containers Submodule

Skip this if your project already has the submodule.

```bash
git submodule add https://github.com/joshjhall/containers.git containers
git submodule update --init --recursive
```

## Step 2: Build Igor

```bash
cd containers/cmd/igor
go build -o igor .
cd ../../..
```

You now have the binary at `containers/cmd/igor/igor`.

## Step 3: Run the Wizard

From your project root:

```bash
./containers/cmd/igor/igor init
```

Igor auto-detects:

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

Igor creates five files:

```text
.devcontainer/
  docker-compose.yml    # Build definition with selected features
  devcontainer.json     # VS Code configuration
  .env                  # Runtime environment variables
.env.example            # Documented env template (commit this)
.igor.yml               # Igor state file (commit this)
```

Review each file. Content between `=== IGOR:BEGIN ===` and `=== IGOR:END ===`
markers is managed by igor. You can add custom content outside the markers.

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

### Before igor: Manual setup

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

### After igor: One command

```bash
./containers/cmd/igor/igor init
# Select Python, Python Dev, Node.js, Node.js Dev, Dev Tools, Docker, PostgreSQL Client
# → All 5 files generated with correct build args, volumes, extensions, env vars
```

## Next Steps

- [Feature Reference](feature-reference.md) — all available features and
  their dependencies
- [Templates](templates.md) — how the template system works and how to
  customize output
- [cmd/igor/README.md](../../cmd/igor/README.md) — full CLI reference and
  `.igor.yml` schema
