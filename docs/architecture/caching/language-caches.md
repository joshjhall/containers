# Language Cache Directories

All language package managers are configured to use the `/cache` directory. This
page details the cache paths and directory structure for each language.

## Python

**Cache directories**:

- `/cache/pip` - pip package cache
- `/cache/poetry` - Poetry cache
- `/cache/pipx` - pipx virtual environments and binaries

**Environment variables**:

```bash
export PIP_CACHE_DIR="/cache/pip"
export POETRY_CACHE_DIR="/cache/poetry"
export PIPX_HOME="/cache/pipx"
export PIPX_BIN_DIR="/cache/pipx/bin"
```

**How it works**:

- Python feature script creates cache directories
- Sets ownership to `${USER_UID}:${USER_GID}`
- Configures pip, poetry, pipx to use these paths
- Packages installed during build are cached
- Runtime `pip install` reuses cached packages

## Node.js

**Cache directories**:

- `/cache/npm` - npm package cache
- `/cache/npm-global` - global npm packages
- `/cache/pnpm` - pnpm store (if pnpm installed)
- `/cache/yarn` - yarn cache (if yarn installed)

**Environment variables**:

```bash
export NPM_CONFIG_CACHE="/cache/npm"
export NPM_CONFIG_PREFIX="/cache/npm-global"
export PNPM_HOME="/cache/pnpm"
export YARN_CACHE_FOLDER="/cache/yarn"
```

**How it works**:

- npm installs packages to cache during build
- Global packages stored in `/cache/npm-global`
- Binaries accessible via PATH: `/cache/npm-global/bin`

## Rust

**Cache directories**:

- `/cache/cargo/registry` - crate registry index and downloads
- `/cache/cargo/git` - git dependencies
- `/cache/cargo/target` - compiled build artifacts (optional)

**Environment variables**:

```bash
export CARGO_HOME="/cache/cargo"
```

**How it works**:

- Cargo downloads crates to registry cache
- Compiled crates cached in registry
- `cargo build` reuses cached compiled dependencies

## Go

**Cache directories**:

- `/cache/go/mod` - downloaded Go modules
- `/cache/go/build` - compiled build cache

**Environment variables**:

```bash
export GOMODCACHE="/cache/go/mod"
export GOCACHE="/cache/go/build"
```

**How it works**:

- `go get` downloads modules to mod cache
- `go build` caches compilation artifacts
- Subsequent builds reuse compiled packages

## Ruby

**Cache directories**:

- `/cache/ruby/gems` - installed gems
- `/cache/ruby/bundle` - bundler cache

**Environment variables**:

```bash
export GEM_HOME="/cache/ruby/gems"
export GEM_PATH="/cache/ruby/gems"
export BUNDLE_PATH="/cache/ruby/bundle"
```

**How it works**:

- `gem install` stores gems in GEM_HOME
- `bundle install` caches dependencies
- Gem binaries accessible via PATH: `/cache/ruby/gems/bin`

## R

**Cache directories**:

- `/cache/r/library` - installed R packages
- `/cache/r/tmp` - temporary files during package installation

**Environment variables**:

```bash
export R_LIBS_USER="/cache/r/library"
export R_CACHE_DIR="/cache/r"
export TMPDIR="/cache/r/tmp"
```

**Configuration files**:

- `/etc/R/Renviron.site` - system-wide R environment
- `~/.Rprofile` - user R profile with cache configuration

**How it works**:

- `install.packages()` installs to R_LIBS_USER
- Binary packages cached, avoiding recompilation
- Large packages (tidyverse, data.table) only installed once

## Java

**Cache directories**:

- `/cache/maven` - Maven local repository
- `/cache/gradle` - Gradle cache

**Environment variables**:

```bash
export MAVEN_OPTS="-Dmaven.repo.local=/cache/maven"
export GRADLE_USER_HOME="/cache/gradle"
```

**How it works**:

- Maven downloads artifacts to local repository
- Gradle caches dependencies and build outputs
- Multi-project builds share cached dependencies

## Additional Tools

**Ollama** (LLM models):

- `/cache/ollama` - downloaded model files

**Mojo/Pixi**:

- `/cache/pixi` - Pixi package cache
- `/cache/mojo/project` - Mojo project environment

**Cloudflare**:

- Uses npm caches (wrangler is an npm package)

______________________________________________________________________

## Cache Directory Structure

The complete `/cache` directory structure:

```text
/cache/
├── pip/                    # Python pip cache
├── poetry/                 # Python Poetry cache
├── pipx/                   # Python pipx installations
│   ├── venvs/             # Virtual environments
│   └── bin/               # Executable scripts
├── npm/                    # Node.js npm cache
├── npm-global/            # Global npm packages
│   └── bin/               # Global npm binaries
├── pnpm/                  # pnpm store
├── yarn/                  # Yarn cache
├── cargo/                 # Rust Cargo cache
│   ├── registry/          # Crate registry
│   └── git/               # Git dependencies
├── go/                    # Go cache
│   ├── mod/               # Module cache
│   └── build/             # Build cache
├── ruby/                  # Ruby cache
│   ├── gems/              # Installed gems
│   │   └── bin/           # Gem binaries
│   └── bundle/            # Bundle cache
├── r/                     # R cache
│   ├── library/           # R packages
│   └── tmp/               # Temporary files
├── maven/                 # Maven repository
├── gradle/                # Gradle cache
├── ollama/                # Ollama models
├── pixi/                  # Pixi cache
└── mojo/                  # Mojo environment
    └── project/           # Mojo project directory
```

### Ownership

All cache directories are owned by `${USER_UID}:${USER_GID}` (default:
`1000:1000`).

This ensures:

- Non-root user can write to caches
- No permission errors during package installation
- Consistent ownership across features

### Permissions

Directories created with mode `0755`:

- Owner: read, write, execute
- Group: read, execute
- Others: read, execute

This allows:

- User to install packages
- Other users to read cached packages (useful in multi-user containers)
