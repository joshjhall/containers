#!/bin/bash
# Ollama - Local LLM runtime for AI development
#
# Description:
#   Installs Ollama for running Large Language Models locally. Provides a
#   simple API-compatible interface for AI development without cloud dependencies.
#
# Features:
#   - Ollama CLI and service for local LLM inference
#   - Helper scripts for service management
#   - Default model pulling utilities
#   - Automatic service startup
#   - Persistent model storage configuration
#   - GPU support (when available)
#
# Cache Strategy:
#   - If /cache directory exists and OLLAMA_MODELS isn't set, uses /cache/ollama
#   - Otherwise uses standard home directory location ~/.ollama
#   - This allows volume mounting for persistent model storage across container rebuilds
#
# Models:
#   - Default pulls: codellama:7b, mistral:7b
#   - Run 'ollama list' to see available models
#   - Run 'ollama pull model:tag' to download models
#
# Environment Variables:
#   - OLLAMA_MODELS: Model storage directory (default: /cache/ollama or ~/.ollama)
#   - OLLAMA_HOST: API host (default: 0.0.0.0:11434)
#   - OLLAMA_ORIGINS: Allowed CORS origins
#
# Common Commands:
#   - ollama serve: Start the Ollama service
#   - ollama list: List downloaded models
#   - ollama pull: Download a model
#   - ollama run: Run a model interactively
#
# Note:
#   Models are large (GB+). Initial downloads may take time.
#   GPU support requires nvidia-docker or appropriate GPU passthrough.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source download verification utilities for secure binary downloads
source /tmp/build-scripts/base/download-verify.sh

# Source checksum utilities for secure binary downloads
source /tmp/build-scripts/base/checksum-fetch.sh

# Start logging
log_feature_start "Ollama"

# ============================================================================
# Model Storage Configuration
# ============================================================================
log_message "Configuring Ollama model storage..."

# ALWAYS use /cache/ollama for consistency
# This will either use cache mount (faster rebuilds) or be created in the image
OLLAMA_MODELS_DIR="/cache/ollama"
log_message "Ollama model storage path: ${OLLAMA_MODELS_DIR}"

# Create model directory with correct ownership
# This ensures it exists in the image even without cache mounts
log_command "Creating Ollama model directory" \
    mkdir -p "${OLLAMA_MODELS_DIR}"

log_command "Setting model directory ownership" \
    chown -R "${USER_UID}:${USER_GID}" "${OLLAMA_MODELS_DIR}"

# ============================================================================
# Ollama Installation
# ============================================================================
log_message "Installing Ollama..."

# Get latest Ollama version from GitHub
OLLAMA_VERSION="0.12.10"  # Can be overridden with OLLAMA_VERSION build arg
ARCH=$(dpkg --print-architecture)

# Map Debian arch to Ollama arch
if [ "$ARCH" = "amd64" ]; then
    OLLAMA_ARCH="amd64"
elif [ "$ARCH" = "arm64" ]; then
    OLLAMA_ARCH="arm64"
else
    log_warning "Ollama not available for architecture $ARCH, skipping..."
    log_feature_end
    exit 0
fi

# Download Ollama directly from GitHub releases with checksum verification
OLLAMA_TARBALL="ollama-linux-${OLLAMA_ARCH}.tgz"
OLLAMA_URL="https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/${OLLAMA_TARBALL}"

# Fetch checksum from GitHub releases
log_message "Fetching Ollama checksum from GitHub..."
OLLAMA_CHECKSUMS_URL="https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/sha256sum.txt"

# The sha256sum.txt format includes "./" prefix, so we need to match "./ollama-linux-${OLLAMA_ARCH}.tgz"
if ! OLLAMA_CHECKSUM=$(fetch_github_checksums_txt "$OLLAMA_CHECKSUMS_URL" "./${OLLAMA_TARBALL}" 2>/dev/null); then
    log_error "Failed to fetch checksum for Ollama ${OLLAMA_VERSION}"
    log_error "Please verify version exists: https://github.com/ollama/ollama/releases/tag/v${OLLAMA_VERSION}"
    log_feature_end
    exit 1
fi

log_message "Expected SHA256: ${OLLAMA_CHECKSUM}"

BUILD_TEMP=$(create_secure_temp_dir)

# Download and verify Ollama tarball
log_message "Downloading and verifying Ollama..."
download_and_verify \
    "$OLLAMA_URL" \
    "$OLLAMA_CHECKSUM" \
    "${BUILD_TEMP}/ollama.tgz"

log_message "✓ Ollama v${OLLAMA_VERSION} verified successfully"

# Extract directly to /usr/local
log_command "Extracting Ollama to /usr/local" \
    tar -xzf "${BUILD_TEMP}/ollama.tgz" -C /usr/local

# Verify installation
if ! [ -f /usr/local/bin/ollama ]; then
    log_error "Ollama binary not found after extraction at /usr/local/bin/ollama"
    log_feature_end
    exit 1
fi

log_message "✓ Ollama installed successfully"

if command -v ollama >/dev/null 2>&1; then
    log_message "Ollama installation successful"

    # ============================================================================
    # Helper Scripts
    # ============================================================================
    log_message "Creating Ollama helper scripts..."

    # Create a helper script to start Ollama in the background
    command cat > /usr/local/bin/start-ollama << 'EOF'
#!/bin/bash
# Start Ollama service in the background

start_ollama_service() {
    if command -v ollama &> /dev/null; then
        echo "Starting Ollama service..."
        export OLLAMA_MODELS="${OLLAMA_MODELS:-/cache/ollama}"

        # Create log directory if needed
        mkdir -p /var/log
        touch /var/log/ollama.log 2>/dev/null || {
            # If /var/log is not writable, use user's home
            LOG_FILE="$HOME/.ollama.log"
            echo "Using log file: $LOG_FILE"
        }
        LOG_FILE="${LOG_FILE:-/var/log/ollama.log}"

        ollama serve > "$LOG_FILE" 2>&1 &
        local ollama_pid=$!
        echo "Ollama service started (PID: $ollama_pid)"
        echo "Logs available at: $LOG_FILE"
        echo "Model storage: ${OLLAMA_MODELS}"

        # Wait for Ollama to be ready
        echo -n "Waiting for Ollama to be ready..."
        local max_attempts=30
        local attempt=0
        while [ $attempt -lt $max_attempts ]; do
            if ollama list >/dev/null 2>&1; then
                echo " Ready!"
                return 0
            fi
            echo -n "."
            sleep 1
            ((attempt++))
        done
        echo " Timeout!"
        echo "Ollama may not be fully ready. Check logs at $LOG_FILE"
        return 1
    else
        echo "Ollama not found. Please install it first."
        exit 1
    fi
}

# Call the function
start_ollama_service
EOF

    log_command "Setting start-ollama permissions" \
        chmod +x /usr/local/bin/start-ollama

    # Create a helper script to pull common models
    command cat > /usr/local/bin/ollama-pull-defaults << 'EOF'
#!/bin/bash
# Pull commonly used models for development
echo "=== Pulling default Ollama models ==="
echo "This may take a while depending on your internet connection..."

# Start Ollama if not running
if ! pgrep -x "ollama" > /dev/null; then
    echo "Starting Ollama service..."
    if ! start-ollama; then
        echo "Failed to start Ollama service"
        exit 1
    fi
fi

# Pull lightweight models suitable for development
# These are small, fast models good for testing
echo "Pulling codellama:7b (code-focused model)..."
ollama pull codellama:7b || echo "Failed to pull codellama:7b"

echo "Pulling mistral:7b (general purpose)..."
ollama pull mistral:7b || echo "Failed to pull mistral:7b"

echo "=== Model pull complete ==="
echo "Available models:"
ollama list
EOF

    log_command "Setting ollama-pull-defaults permissions" \
        chmod +x /usr/local/bin/ollama-pull-defaults

    # ============================================================================
    # Container Startup Scripts
    # ============================================================================
    log_message "Creating Ollama startup scripts..."

    # Create startup directory if it doesn't exist
    log_command "Creating container startup directory" \
        mkdir -p /etc/container/startup

    # Create startup script to start Ollama service (runs every container start)
    command cat > /etc/container/startup/20-ollama-start.sh << 'EOF'
#!/bin/bash
# Start Ollama service if available
if command -v ollama &> /dev/null; then
    if ! pgrep -x "ollama" > /dev/null; then
        echo "Starting Ollama service..."
        if ! start-ollama; then
            echo "Warning: Failed to start Ollama service automatically"
            echo "You can start it manually with: start-ollama"
        fi
    else
        echo "Ollama service already running"
    fi
fi
EOF

    log_command "Setting Ollama startup script permissions" \
        chmod +x /etc/container/startup/20-ollama-start.sh

    # ============================================================================
    # Environment Configuration
    # ============================================================================
    log_message "Configuring Ollama environment..."

    # Ensure /etc/bashrc.d exists
    log_command "Creating bashrc.d directory" \
        mkdir -p /etc/bashrc.d

    # Create system-wide Ollama configuration (content in lib/bashrc/ollama.sh)
    write_bashrc_content /etc/bashrc.d/70-ollama.sh "Ollama configuration" \
        < /tmp/build-scripts/features/lib/bashrc/ollama.sh

    log_command "Setting Ollama bashrc script permissions" \
        chmod +x /etc/bashrc.d/70-ollama.sh

    # ============================================================================
    # Verification Script
    # ============================================================================
    log_message "Creating Ollama verification script..."

    command cat > /usr/local/bin/test-ollama << 'EOF'
#!/bin/bash
echo "=== Ollama Status ==="
if command -v ollama &> /dev/null; then
    echo "✓ Ollama is installed"
    echo "  Version: $(ollama --version 2>/dev/null || echo "version unknown")"
    echo "  Binary: $(which ollama)"
else
    echo "✗ Ollama is not installed"
    exit 1
fi

echo ""
echo "=== Service Status ==="
if pgrep -x "ollama" > /dev/null; then
    echo "✓ Ollama service is running"
    echo "  PID: $(pgrep -x ollama)"
else
    echo "✗ Ollama service is not running"
    echo "  Run 'start-ollama' to start the service"
fi

echo ""
echo "=== Configuration ==="
echo "  OLLAMA_MODELS: ${OLLAMA_MODELS:-/cache/ollama}"
echo "  OLLAMA_HOST: ${OLLAMA_HOST:-0.0.0.0:11434}"

if [ -d "${OLLAMA_MODELS:-/cache/ollama}" ]; then
    echo "  ✓ Model directory exists"
    # Count models if service is running
    if pgrep -x "ollama" > /dev/null; then
        echo ""
        echo "=== Installed Models ==="
        ollama list 2>/dev/null || echo "  Unable to list models"
    fi
else
    echo "  ✗ Model directory not found"
fi

echo ""
echo "Commands:"
echo "  start-ollama         - Start the Ollama service"
echo "  ollama-pull-defaults - Download starter models"
echo "  ollama list          - List installed models"
echo "  ollama run <model>   - Run a model interactively"
EOF

    log_command "Setting test-ollama permissions" \
        chmod +x /usr/local/bin/test-ollama

else
    log_warning "Ollama installation failed, but build continues..."
    log_message "This may be expected on some architectures or environments"
fi

# ============================================================================
# Final Messages
# ============================================================================
log_message "Ollama setup complete"
log_message "Model storage configured at: ${OLLAMA_MODELS_DIR}"

# Log feature summary
# Export models directory path for feature summary
export OLLAMA_MODELS_DIR="/cache/ollama"

log_feature_summary \
    --feature "Ollama" \
    --tools "ollama" \
    --paths "${OLLAMA_MODELS_DIR}" \
    --env "OLLAMA_MODELS,OLLAMA_HOST,OLLAMA_ORIGINS" \
    --commands "ollama,start-ollama,stop-ollama,ollama-status,ollama-pull-defaults,ollama-chat" \
    --next-steps "Run 'test-ollama' to verify installation. Use 'start-ollama' to start service, 'ollama-pull-defaults' for starter models, 'ollama run <model>' to interact."

# End logging
log_feature_end

echo ""
echo "Run 'test-ollama' to verify installation"
echo "Run 'start-ollama' to start the service"
echo "Run 'ollama-pull-defaults' to download starter models"
echo "Run 'check-build-logs.sh ollama' to review installation logs"
