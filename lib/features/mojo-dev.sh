#!/bin/bash
# Mojo Development Tools - Essential development utilities for Mojo
#
# Description:
#   Installs essential development tools for Mojo programming, focusing on
#   the most commonly used utilities for debugging, testing, and Python interop.
#
# Tools Installed:
#   - LLDB debugger support for Mojo
#   - Python interop packages (numpy, matplotlib)
#   - Jupyter notebook support
#   - Basic project scaffolding tool
#
# Requirements:
#   - Mojo must be installed (via INCLUDE_MOJO=true)
#   - Python recommended for interop features
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Start logging
log_feature_start "Mojo Development Tools"

# ============================================================================
# Prerequisites Check
# ============================================================================
log_message "Checking prerequisites..."

# Check if Mojo is available
if [ ! -f "/usr/local/bin/mojo" ]; then
    log_error "mojo not found at /usr/local/bin/mojo"
    log_error "The INCLUDE_MOJO feature must be enabled before mojo-dev tools can be installed"
    log_feature_end
    exit 1
fi

# Check if Python is available (recommended for interop)
if ! command -v python3 &> /dev/null; then
    log_warning "Python3 not found. Python interop features will be limited"
fi

# ============================================================================
# System Dependencies
# ============================================================================
log_message "Installing system dependencies for Mojo dev tools..."

# Update package lists with retry logic
apt_update

# Install LLDB for debugging
log_message "Installing debugging tools"
apt_install \
    lldb

# ============================================================================
# Python Interop Development Tools
# ============================================================================
log_message "Setting up Python interop for Mojo..."

# Check if Python is installed
if ! command -v python3 &> /dev/null; then
    log_message "Python3 not found - installing Python3..."
    log_message "Installing Python3"
    apt_install \
        python3 \
        python3-venv
fi

# Check if pip is available
if ! python3 -m pip --version &> /dev/null; then
    log_message "pip not found - installing pip..."
    log_message "Installing pip"
    apt_install \
        python3-pip
fi

# Now install only missing Python packages for Mojo interop
log_message "Checking and installing required Python packages..."

# On Debian 12+, we need to handle PEP 668 restrictions
# First try to install from apt, then fall back to pip with --break-system-packages

# Map Python packages to their Debian package names
declare -A APT_PACKAGES=(
    ["numpy"]="python3-numpy"
    ["matplotlib"]="python3-matplotlib"
    ["jupyter"]="jupyter-core"
    ["notebook"]="jupyter-notebook"
)

# Check each package and install only if missing
for py_package in numpy matplotlib jupyter notebook; do
    if python3 -c "import $py_package" 2>/dev/null; then
        log_message "✓ $py_package is already installed"
    else
        apt_package="${APT_PACKAGES[$py_package]}"

        # First try to install from apt
        if [ -n "$apt_package" ]; then
            log_message "Installing $py_package from apt ($apt_package)..."
            if log_message "Installing $apt_package" && \
                apt_install "$apt_package"; then
                continue
            else
                log_warning "Failed to install $apt_package from apt, trying pip..."
            fi
        fi

        # Fall back to pip with --break-system-packages
        # This is acceptable in a container environment
        log_message "Installing $py_package with pip..."
        PIP_CACHE_DIR="${PIP_CACHE_DIR:-/cache/pip}"
        log_command "Installing $py_package via pip" \
            su - "${USERNAME}" -c "export PIP_CACHE_DIR='${PIP_CACHE_DIR}' && python3 -m pip install --no-cache-dir --break-system-packages '$py_package'"
    fi
done

# ============================================================================
# Development Helper Scripts
# ============================================================================
log_message "Creating Mojo development helper scripts..."

# Simple project initializer
cat > /usr/local/bin/mojo-init << 'EOF'
#!/bin/bash
# Initialize a new Mojo project with basic structure

set -euo pipefail

PROJECT_NAME="${1:-mojo_project}"

echo "Creating Mojo project: $PROJECT_NAME"

# Create basic project structure
mkdir -p "$PROJECT_NAME"/{src,tests}
cd "$PROJECT_NAME"

# Create README
cat > README.md << README
# $PROJECT_NAME

A Mojo project.

## Structure
- src/    - Source code
- tests/  - Test files

## Running
\`\`\`bash
mojo run src/main.mojo
\`\`\`

## Testing
\`\`\`bash
mojo test tests/
\`\`\`
README

# Create .gitignore
cat > .gitignore << 'GITIGNORE'
# Mojo
*.mojopkg
.mojo-cache/
build/

# Python
__pycache__/
*.pyc
.ipynb_checkpoints/

# IDE
.vscode/
.idea/
GITIGNORE

# Create main file
cat > src/main.mojo << 'MAIN'
fn main():
    print("Hello from Mojo! 🔥")
MAIN

# Create test file
cat > tests/test_main.mojo << 'TEST'
from testing import assert_equal

fn test_basic():
    """Basic test example."""
    assert_equal(1 + 1, 2)
TEST

echo "Project '$PROJECT_NAME' created!"
echo "cd $PROJECT_NAME && mojo run src/main.mojo"
EOF

log_command "Setting mojo-init permissions" \
    chmod +x /usr/local/bin/mojo-init

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up Mojo development helpers..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Add mojo-dev aliases and helpers
write_bashrc_content /etc/bashrc.d/65-mojo-dev.sh "Mojo development tools" << 'MOJO_DEV_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Mojo Development Tools Configuration and Helpers
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi

# Defensive programming - check for required commands
_check_command() {
    command -v "$1" >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
# Mojo Development Aliases
# ----------------------------------------------------------------------------
# Common shortcuts
alias mjr='mojo run'
alias mjb='mojo build'
alias mjt='mojo test'
alias mjf='mojo format'

# Build variants
alias mjbo='mojo build -O3'        # Optimized build
alias mjbd='mojo build --debug-info'  # Debug build

# ----------------------------------------------------------------------------
# mojo-debug - Debug Mojo program with LLDB
# ----------------------------------------------------------------------------
mojo-debug() {
    if [ -z "$1" ]; then
        echo "Usage: mojo-debug <mojo-file>"
        return 1
    fi

    mojo debug "$1" "${@:2}"
}

# ----------------------------------------------------------------------------
# mojo-jupyter - Start Jupyter with Mojo kernel
# ----------------------------------------------------------------------------
mojo-jupyter() {
    if ! command -v jupyter &> /dev/null; then
        echo "Jupyter not installed. Install with: pip install jupyter"
        return 1
    fi

    echo "Starting Jupyter with Mojo kernel..."
    jupyter notebook "$@"
}

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
MOJO_DEV_BASHRC_EOF

log_command "Setting Mojo dev bashrc script permissions" \
    chmod +x /etc/bashrc.d/65-mojo-dev.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating mojo-dev startup script..."

cat > /etc/container/first-startup/45-mojo-dev-setup.sh << 'EOF'
#!/bin/bash
# Mojo development tools configuration
if command -v mojo &> /dev/null; then
    echo "=== Mojo Development Tools ==="

    # Check for Mojo project
    if [ -f ${WORKING_DIR}/*.mojo ] || [ -f ${WORKING_DIR}/src/*.mojo ]; then
        echo "Mojo project detected!"
        echo ""
        echo "Commands available:"
        echo "  mojo run <file>   - Run Mojo code"
        echo "  mojo test <dir>   - Run tests"
        echo "  mojo debug <file> - Debug with LLDB"
        echo "  mojo format       - Format code"
        echo ""
        echo "Shortcuts: mjr, mjb, mjt, mjf"
    fi

    # Check for Python
    if command -v python3 &> /dev/null; then
        if python3 -c "import numpy" 2>/dev/null; then
            echo ""
            echo "Python interop ready (NumPy installed)"
        fi
    fi
fi
EOF

log_command "Setting Mojo dev startup script permissions" \
    chmod +x /etc/container/first-startup/45-mojo-dev-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating mojo-dev verification script..."

cat > /usr/local/bin/test-mojo-dev << 'EOF'
#!/bin/bash
echo "=== Mojo Development Tools Status ==="

# Check LLDB
echo ""
if command -v lldb &> /dev/null; then
    echo "✓ LLDB debugger is installed"
else
    echo "✗ LLDB is not found"
fi

# Check Python interop
if command -v python3 &> /dev/null; then
    echo "✓ Python3 is installed"

    # Check key packages
    for pkg in numpy matplotlib jupyter; do
        if python3 -c "import $pkg" 2>/dev/null; then
            echo "  ✓ $pkg is available"
        else
            echo "  ✗ $pkg is not available"
        fi
    done
else
    echo "✗ Python3 is not installed"
fi

# Check helper tools
echo ""
if command -v mojo-init &> /dev/null; then
    echo "✓ mojo-init is available"
else
    echo "✗ mojo-init is not found"
fi

echo ""
echo "Run 'mojo-init <project-name>' to create a new project"
EOF

log_command "Setting test-mojo-dev script permissions" \
    chmod +x /usr/local/bin/test-mojo-dev

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying Mojo development tools..."

log_command "Checking LLDB installation" \
    lldb --version || log_warning "LLDB not installed properly"

# ============================================================================
# Final ownership fix
# ============================================================================
log_message "Ensuring correct ownership of cache directories..."
PIP_CACHE_DIR="${PIP_CACHE_DIR:-/cache/pip}"
log_command "Final ownership fix for cache directories" \
    chown -R "${USER_UID}:${USER_GID}" "${PIP_CACHE_DIR}" || true

# Log feature summary
log_feature_summary \
    --feature "Mojo Development Tools" \
    --tools "lldb,numpy,matplotlib,jupyter,notebook,mojo-init" \
    --paths "${PIP_CACHE_DIR}" \
    --env "PIP_CACHE_DIR" \
    --commands "lldb,mojo-debug,mojo-jupyter,mojo-init,mjr,mjb,mjt,mjf" \
    --next-steps "Run 'test-mojo-dev' to check installed tools. Use 'mojo-init <project-name>' to create new projects. Use 'mojo-jupyter' to start Jupyter with Mojo kernel."

# End logging
log_feature_end

echo ""
echo "Run 'test-mojo-dev' to check installed tools"
echo "Run 'check-build-logs.sh mojo-development-tools' to review installation logs"
