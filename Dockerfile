# syntax=docker/dockerfile:1
# Universal Container Build System
# Version: 3.0.4
# Supports multiple contexts: devcontainer, agents, CI/CD, production

# Build arguments for base image selection
ARG BASE_IMAGE=debian:bookworm-slim
FROM ${BASE_IMAGE} AS base

# Path to the project root relative to the containers directory
# Default assumes containers is a submodule at project_root/containers
# Override with --build-arg PROJECT_PATH=. when testing containers standalone
ARG PROJECT_PATH=..

# Ensure consistent shell behavior
SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Copy all library scripts into image for reliable access
# Since Dockerfile is always in containers/, lib is always ./lib
COPY lib /tmp/build-scripts

# Base system setup - always needed
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    chmod +x /tmp/build-scripts/base/*.sh && \
    /tmp/build-scripts/base/setup.sh && \
    /tmp/build-scripts/base/setup-bashrc.d.sh

# User setup arguments
ARG USERNAME=developer
ARG USER_UID=1000
ARG USER_GID=$USER_UID

# Working directory and project name
ARG PROJECT_NAME=project
ARG WORKING_DIR=/workspace/${PROJECT_NAME}

# Create user - MUST happen before any feature installations that use su
# IMPORTANT: If the base image already uses the requested UID/GID, user.sh will
# automatically find and use alternative values. However, cache mounts in subsequent
# RUN commands still use the original ${USER_UID}/${USER_GID} values from build args.
# This is a Docker limitation - mount options are evaluated at parse time, not runtime.
# 
# Cache Strategy: We use /cache/* paths for all feature caches to be username-agnostic.
# This allows the same cache paths to work regardless of the USERNAME build arg.
# 
# Impact: If UID conflicts occur, cache directories may have incorrect ownership,
# potentially causing permission errors during builds. The actual builds will still
# work (scripts use the correct UID/GID), but caching may be ineffective.
#
# Workaround: If you encounter cache permission errors, either:
# 1. Use a different USER_UID/USER_GID that doesn't conflict
# 2. Remove the cache mounts for affected features
# 3. Clear the Docker build cache and rebuild
RUN /tmp/build-scripts/base/user.sh ${USERNAME} ${USER_UID} ${USER_GID} ${PROJECT_NAME} ${WORKING_DIR}

# Make all feature scripts executable
RUN chmod +x /tmp/build-scripts/features/*.sh /tmp/build-scripts/base/*.sh

# ============================================================================
# LANGUAGE INSTALLATIONS - Grouped with their development tools
# ============================================================================

# Python + Python development tools
ARG INCLUDE_PYTHON=false
ARG INCLUDE_PYTHON_DEV=false
ARG PYTHON_VERSION=3.13.7

# Handle optional Python project files only if Python is being installed
# Copy to temp location first since we're running as root and user doesn't exist yet
# The files will be properly placed with correct ownership later
RUN --mount=type=bind,source=.,target=/build_context \
    if [ "${INCLUDE_PYTHON}" = "true" ] || [ "${INCLUDE_PYTHON_DEV}" = "true" ]; then \
    mkdir -p /tmp/python-project-files; \
    if [ -f "/build_context/pyproject.toml" ]; then \
    cp /build_context/pyproject.toml /tmp/python-project-files/; \
    fi; \
    if [ -f "/build_context/poetry.lock" ]; then \
    cp /build_context/poetry.lock /tmp/python-project-files/; \
    fi; \
    if [ -f "/build_context/requirements.txt" ]; then \
    cp /build_context/requirements.txt /tmp/python-project-files/; \
    fi; \
    fi

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_PYTHON}" = "true" ] || [ "${INCLUDE_PYTHON_DEV}" = "true" ]; then \
    PYTHON_VERSION=${PYTHON_VERSION} /tmp/build-scripts/features/python.sh; \
    fi

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_PYTHON_DEV}" = "true" ]; then \
    /tmp/build-scripts/features/python-dev.sh; \
    fi

# Node.js + Node.js development tools
# Note: Installed early as it's a common dependency for other tools
ARG INCLUDE_NODE=false
ARG INCLUDE_NODE_DEV=false
ARG NODE_VERSION=22
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_NODE}" = "true" ] || [ "${INCLUDE_NODE_DEV}" = "true" ]; then \
    NODE_VERSION=${NODE_VERSION} /tmp/build-scripts/features/node.sh; \
    fi

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_NODE_DEV}" = "true" ]; then \
    /tmp/build-scripts/features/node-dev.sh; \
    fi

# Rust + Rust development tools
ARG INCLUDE_RUST=false
ARG INCLUDE_RUST_DEV=false
ARG RUST_VERSION=1.89.0
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_RUST}" = "true" ] || [ "${INCLUDE_RUST_DEV}" = "true" ]; then \
    RUST_VERSION=${RUST_VERSION} /tmp/build-scripts/features/rust.sh; \
    fi

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_RUST_DEV}" = "true" ]; then \
    /tmp/build-scripts/features/rust-dev.sh; \
    fi

# Ruby + Ruby development tools
ARG INCLUDE_RUBY=false
ARG INCLUDE_RUBY_DEV=false
ARG RUBY_VERSION=3.4.5
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_RUBY}" = "true" ] || [ "${INCLUDE_RUBY_DEV}" = "true" ]; then \
    RUBY_VERSION=${RUBY_VERSION} /tmp/build-scripts/features/ruby.sh; \
    fi

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_RUBY_DEV}" = "true" ]; then \
    /tmp/build-scripts/features/ruby-dev.sh; \
    fi

# R Statistical Computing
ARG INCLUDE_R=false
ARG INCLUDE_R_DEV=false
ARG R_VERSION=4.5.1
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_R}" = "true" ] || [ "${INCLUDE_R_DEV}" = "true" ]; then \
    R_VERSION=${R_VERSION} /tmp/build-scripts/features/r.sh; \
    fi

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_R_DEV}" = "true" ]; then \
    /tmp/build-scripts/features/r-dev.sh; \
    fi

# Go + Go development tools
ARG INCLUDE_GOLANG=false
ARG INCLUDE_GOLANG_DEV=false
ARG GO_VERSION=1.25.0
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_GOLANG}" = "true" ] || [ "${INCLUDE_GOLANG_DEV}" = "true" ]; then \
    GO_VERSION=${GO_VERSION} /tmp/build-scripts/features/golang.sh; \
    fi

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_GOLANG_DEV}" = "true" ]; then \
    /tmp/build-scripts/features/golang-dev.sh; \
    fi

# Mojo (x86_64/amd64 only)
ARG INCLUDE_MOJO=false
ARG INCLUDE_MOJO_DEV=false
ARG MOJO_VERSION=25.4
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_MOJO}" = "true" ] || [ "${INCLUDE_MOJO_DEV}" = "true" ]; then \
    ARCH=$(dpkg --print-architecture); \
    if [ "$ARCH" = "amd64" ]; then \
    MOJO_VERSION=${MOJO_VERSION} /tmp/build-scripts/features/mojo.sh; \
    else \
    echo "Warning: Skipping Mojo installation - only supported on x86_64/amd64 (current: $ARCH)"; \
    fi; \
    fi

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_MOJO_DEV}" = "true" ]; then \
    ARCH=$(dpkg --print-architecture); \
    if [ "$ARCH" = "amd64" ]; then \
    /tmp/build-scripts/features/mojo-dev.sh; \
    else \
    echo "Warning: Skipping Mojo dev tools - only supported on x86_64/amd64 (current: $ARCH)"; \
    fi; \
    fi

# Java
ARG INCLUDE_JAVA=false
ARG INCLUDE_JAVA_DEV=false
ARG JAVA_VERSION=21
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_JAVA}" = "true" ] || [ "${INCLUDE_JAVA_DEV}" = "true" ]; then \
    JAVA_VERSION=${JAVA_VERSION} /tmp/build-scripts/features/java.sh; \
    fi

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_JAVA_DEV}" = "true" ]; then \
    /tmp/build-scripts/features/java-dev.sh; \
    fi

# ============================================================================
# DEVELOPMENT TOOLS - General development utilities
# ============================================================================

# Docker CLI and tools
ARG INCLUDE_DOCKER=false
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_DOCKER}" = "true" ]; then \
    /tmp/build-scripts/features/docker.sh; \
    fi

# 1Password CLI
ARG INCLUDE_OP=false
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_OP}" = "true" ]; then \
    /tmp/build-scripts/features/op-cli.sh; \
    fi

# General development tools
ARG INCLUDE_DEV_TOOLS=false
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_DEV_TOOLS}" = "true" ]; then \
    /tmp/build-scripts/features/dev-tools.sh; \
    fi

# ============================================================================
# DATABASE TOOLS
# ============================================================================

# PostgreSQL client
ARG INCLUDE_POSTGRES_CLIENT=false
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_POSTGRES_CLIENT}" = "true" ]; then \
    /tmp/build-scripts/features/postgres-client.sh; \
    fi

# Redis client
ARG INCLUDE_REDIS_CLIENT=false
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_REDIS_CLIENT}" = "true" ]; then \
    /tmp/build-scripts/features/redis-client.sh; \
    fi

# SQLite client
ARG INCLUDE_SQLITE_CLIENT=false
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_SQLITE_CLIENT}" = "true" ]; then \
    /tmp/build-scripts/features/sqlite-client.sh; \
    fi

# ============================================================================
# AI/ML TOOLS
# ============================================================================

# Ollama
# Note: Ollama models can be very large (GB+), so cache mount is optional
# Consider using a volume mount for /cache/ollama in production
ARG INCLUDE_OLLAMA=false
RUN if [ "${INCLUDE_OLLAMA}" = "true" ]; then \
    /tmp/build-scripts/features/ollama.sh; \
    fi

# ============================================================================
# CLOUD AND INFRASTRUCTURE TOOLS
# ============================================================================

# Kubernetes tools
ARG INCLUDE_KUBERNETES=false
ARG KUBECTL_VERSION=1.31.0
ARG K9S_VERSION=0.50.9
ARG KREW_VERSION=0.4.5
ARG HELM_VERSION=latest
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_KUBERNETES}" = "true" ]; then \
    KUBECTL_VERSION=${KUBECTL_VERSION} K9S_VERSION=${K9S_VERSION} KREW_VERSION=${KREW_VERSION} HELM_VERSION=${HELM_VERSION} \
    /tmp/build-scripts/features/kubernetes.sh; \
    fi

# AWS CLI
ARG INCLUDE_AWS=false
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_AWS}" = "true" ]; then \
    /tmp/build-scripts/features/aws.sh; \
    fi

# Terraform
ARG INCLUDE_TERRAFORM=false
ARG TERRAGRUNT_VERSION=0.86.2
ARG TFDOCS_VERSION=0.20.0
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_TERRAFORM}" = "true" ]; then \
    TERRAGRUNT_VERSION=${TERRAGRUNT_VERSION} TFDOCS_VERSION=${TFDOCS_VERSION} \
    /tmp/build-scripts/features/terraform.sh; \
    fi

# Google Cloud SDK
ARG INCLUDE_GCLOUD=false
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_GCLOUD}" = "true" ]; then \
    /tmp/build-scripts/features/gcloud.sh; \
    fi

# Cloudflare tools
ARG INCLUDE_CLOUDFLARE=false
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [ "${INCLUDE_CLOUDFLARE}" = "true" ]; then \
    /tmp/build-scripts/features/cloudflare.sh; \
    fi

# Set up startup script system
RUN /tmp/build-scripts/runtime/setup-startup.sh

# Set up comprehensive PATH configuration
RUN /tmp/build-scripts/runtime/setup-paths.sh

# Copy entrypoint script
COPY lib/runtime/entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

# Clean up build scripts but keep runtime scripts
RUN cp -r /tmp/build-scripts/runtime /opt/container-runtime && \
    rm -rf /tmp/build-scripts

# Install check-build-logs script if it exists
RUN if [ -f /opt/container-runtime/check-build-logs.sh ]; then \
    cp /opt/container-runtime/check-build-logs.sh /usr/local/bin/check-build-logs.sh && \
    chmod +x /usr/local/bin/check-build-logs.sh; \
    fi

# Switch to user
USER ${USERNAME}
WORKDIR ${WORKING_DIR}

# Set up environment
# Note: Many paths are set dynamically by feature scripts based on /cache availability
# The scripts will configure the correct paths in ~/.bashrc.d files

# Core PATH for all users (feature scripts add their specific paths)
# This ensures basic functionality even in non-interactive shells
ENV PATH="/home/${USERNAME}/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

# Java environment variables (consistent across installations)
ENV JAVA_HOME="/usr/lib/jvm/default-java"

# Python environment variables (for tools that don't read shell config)
ENV POETRY_VIRTUALENVS_IN_PROJECT=true
ENV POETRY_NO_INTERACTION=1

# Google Cloud SDK environment variables
ENV CLOUDSDK_PYTHON="/usr/bin/python3"

# R environment variables (consistent across installations)
ENV R_LIBS_SITE="/usr/local/lib/R/site-library"

# Terminal settings (for better tool output)
ENV TERM=xterm-256color
ENV COLORTERM=truecolor

# Ensure non-interactive shells get proper environment
ENV BASH_ENV=/etc/bash_env

# Note on dynamic paths:
# The following are set by feature scripts based on /cache availability:
# - CARGO_HOME, RUSTUP_HOME (Rust)
# - GOPATH, GOCACHE (Go)
# - PIP_CACHE_DIR, POETRY_CACHE_DIR (Python)
# - npm_config_cache, YARN_CACHE_FOLDER, PNPM_STORE_DIR (Node.js)
# - TF_PLUGIN_CACHE_DIR (Terraform)
# - OLLAMA_MODELS (Ollama)
# - Ruby gem/bundle paths
# These are configured in shell initialization files and will be available
# in interactive sessions. For non-interactive use, explicitly set these
# environment variables or source the shell configuration.

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint"]

# Default command
CMD ["/bin/bash"]