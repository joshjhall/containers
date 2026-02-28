# Runtime Volume Mounts

This page covers how to mount cache volumes for persistent caching across
container restarts, including Docker Compose patterns and volume management.

## Mounting Cache Volumes

For **persistent caches across container restarts**, mount `/cache` as a Docker
volume:

```bash
# Create named volume
docker volume create project-cache

# Mount at runtime
docker run -v project-cache:/cache myproject:dev
```

## Benefits of Volume Mounts

**Without volume mount**:

```bash
# First run: pip downloads packages
docker run myproject:dev pip install numpy pandas

# Container stopped, recreated
docker run myproject:dev pip install numpy pandas
# Downloads SAME packages again!
```

**With volume mount**:

```bash
# First run: pip downloads packages to volume
docker run -v project-cache:/cache myproject:dev pip install numpy pandas

# Container stopped, recreated
docker run -v project-cache:/cache myproject:dev pip install numpy pandas
# Reuses cached packages from volume - instant!
```

## Development Workflow

```bash
# Development environment with persistent caches
docker run -it \
  -v "$(pwd):/workspace/project" \
  -v "project-cache:/cache" \
  --name myproject-dev \
  myproject:dev
```

**Advantages**:

- Package installations persist across container restarts
- Faster iteration during development
- Shared caches across multiple containers (if using same volume)

## Docker Compose

```yaml
version: '3.8'

services:
  app:
    image: myproject:dev
    volumes:
      - .:/workspace/project
      - cache:/cache
    working_dir: /workspace/project

volumes:
  cache:
    driver: local
```

## Cache Volume Management

```bash
# List volumes
docker volume ls

# Inspect volume
docker volume inspect project-cache

# View cache size
docker run --rm -v project-cache:/cache alpine du -sh /cache/*

# Clear specific cache
docker run --rm -v project-cache:/cache alpine rm -rf /cache/pip

# Remove volume (clears all caches)
docker volume rm project-cache
```
