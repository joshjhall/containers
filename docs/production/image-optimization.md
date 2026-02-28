# Image Optimization

This page covers techniques for minimizing production image size, including
feature selection, multi-stage builds, and layer optimization.

## Minimize Image Size

Only include necessary features for production:

```bash
# DON'T: Include all dev tools in production
docker build \
  --build-arg INCLUDE_PYTHON_DEV=true \
  --build-arg INCLUDE_NODE_DEV=true \
  --build-arg INCLUDE_DEV_TOOLS=true \
  -t myapp:prod .

# DO: Only runtime dependencies
docker build \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_NODE=true \
  -t myapp:prod .
```

## Multi-Stage Builds

Create optimized production images:

```dockerfile
# Build stage - includes dev tools
FROM ghcr.io/joshjhall/containers:full-dev AS builder

WORKDIR /build
COPY . .

# Build your application
RUN pip install --no-cache-dir -r requirements.txt && \
    python setup.py build

# Production stage - minimal runtime
FROM ghcr.io/joshjhall/containers:python-runtime AS production

WORKDIR /app
COPY --from=builder /build/dist ./dist
COPY --from=builder /build/app ./app

USER developer
CMD ["python", "app/main.py"]
```

## Layer Optimization

Minimize layer count and size:

```dockerfile
# Bad: Many layers, cache busting
RUN apt-get update
RUN apt-get install -y package1
RUN apt-get install -y package2
RUN rm -rf /var/lib/apt/lists/*

# Good: Single layer, clean cache
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      package1 \
      package2 && \
    rm -rf /var/lib/apt/lists/*
```

## Multi-Stage Build Pattern: Build + Runtime

```dockerfile
# Stage 1: Build environment with dev tools
FROM myproject:full-dev AS builder

WORKDIR /build
COPY requirements.txt pyproject.toml ./
RUN pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir build

COPY src/ ./src/
RUN python -m build

# Stage 2: Minimal runtime image
FROM myproject:python-runtime AS production

# Copy only built artifacts
COPY --from=builder /build/dist/*.whl /tmp/
RUN pip install --no-cache-dir /tmp/*.whl && \
    rm /tmp/*.whl

# Copy application
COPY app/ /app/
WORKDIR /app

# Run as non-root
USER developer

# Health check
HEALTHCHECK CMD curl -f http://localhost:8080/health || exit 1

CMD ["python", "-m", "app"]
```
