# Feature-Specific Issues

This section covers issues specific to individual language runtimes and tools
installed by the container build system.

## Python: pip install fails

**Symptom**: Python packages fail to install.

**Solution**:

```bash
# Check Python version
python3 --version

# Upgrade pip
pip3 install --upgrade pip

# Use cache mount
docker build --mount=type=cache,target=/cache/pip .

# Check for conflicting packages
pip3 check
```

## Python: Poetry version mismatch

**Symptom**: Poetry commands fail or behave unexpectedly.

**Solution**:

```bash
# Check installed Poetry version
poetry --version

# The system pins Poetry to 2.2.1 (as of v4.0.1)
# To use a different version, update POETRY_VERSION in lib/features/python.sh

# Clear Poetry cache
poetry cache clear pypi --all

# Reinstall Poetry (inside container)
python3 -m pipx reinstall poetry==2.2.1
```

## Node.js: npm install hangs

**Symptom**: npm install is extremely slow or hangs.

**Solution**:

```bash
# Clear npm cache
npm cache clean --force

# Use npm ci instead
npm ci

# Increase timeout
npm install --timeout=120000

# Check registry
npm config get registry
```

## Rust: cargo build fails

**Symptom**: Cargo compilation errors.

**Solution**:

```bash
# Update Rust toolchain
rustup update stable

# Clean cargo cache
cargo clean

# Check for disk space
df -h /cache/cargo

# Rebuild with verbose output
cargo build --verbose
```

## Rust: `cargo` not found in the devcontainer

**Symptom**: The `cargo-lint` (pre-commit) or `cargo-test` (pre-push) hook
fails with `cargo not found: this image was built without the Rust feature
(stale image?)`, or startup logs
`rust-ensure-pinned-components: rustup not found`.

**Cause**: The running image is stale relative to
`.devcontainer/docker-compose.yml`. Compose sets `INCLUDE_RUST_DEV: "true"`,
but the image was built before that, so `enabled-features.conf` records
`INCLUDE_RUST_DEV=false`. The image/compose drift check (`post-create.sh`, step
4) reports this mismatch at container create.

**Solution**: Rebuild the devcontainer (for example, "Rebuild Container" in
your editor, or `docker compose build` and then recreate the container). Don't
install rustup by hand into `/cache/rustup`.

**Decision: no `rustup` in post-create** (#1060). Post-create deliberately
does not install a Rust toolchain:

- `lib/features/rust.sh` already owns the toolchain: the version pin, checksum
  verification, components, and MSRV holds. A first-startup hook,
  `rust-ensure-pinned-components`, also reconciles a `rust-toolchain.toml`
  pin. A second install path in post-create would duplicate that work and
  drift from it.
- It would only hide a stale image. The same image would still lack anything
  else that changed in compose. A rebuild fixes everything at once, and the
  drift check (#1059) points you to the rebuild.

## Docker: Cannot start Docker daemon in container

**Symptom**: docker: Cannot connect to the Docker daemon.

**Solution**:

```bash
# For Docker-in-Docker, you need privileged mode
docker run --privileged myproject:dev

# Or use Docker socket mounting (Docker-out-of-Docker)
docker run -v /var/run/docker.sock:/var/run/docker.sock myproject:dev

# Check Docker is installed
docker --version
```

## Kubernetes: kubectl not configured

**Symptom**: kubectl: command not found or not configured.

**Solution**:

```bash
# Check if kubectl is installed
kubectl version --client

# Configure kubeconfig
export KUBECONFIG=/path/to/kubeconfig

# Or mount kubeconfig
docker run -v ~/.kube:/home/vscode/.kube myproject:dev
```
