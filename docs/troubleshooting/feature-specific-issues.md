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
