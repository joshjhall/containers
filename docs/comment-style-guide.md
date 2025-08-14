# Comment Style Guide for Container Scripts

This guide defines the consistent comment style used throughout the container scripts.

## File Header Template

```bash
#!/bin/bash
# Script Title - Brief one-line description
#
# Description:
#   More detailed description of what the script does
#   Can be multiple lines
#
# Features:
#   - Feature 1
#   - Feature 2
#   - Feature 3
#
# Environment Variables:
#   - VAR_NAME: Description (default: value)
#   - ANOTHER_VAR: Description
#
# Cache Strategy: (if applicable)
#   - Explanation of cache usage
#
# Note: (if applicable)
#   Any important notes or warnings
#
set -euo pipefail
```

## Section Headers

Use double-line separators for major sections:

```bash
# ============================================================================
# Section Title
# ============================================================================
echo "=== Section Title ==="
```

## Subsection Headers

Use single-line separators for subsections:

```bash
# ----------------------------------------------------------------------------
# Subsection Title
# ----------------------------------------------------------------------------
```

## Inline Comments

- Place comments above the code they describe
- Use complete sentences with proper capitalization
- Explain "why" not just "what"

```bash
# Create cache directory with correct ownership
# This ensures the user can write to cache locations
mkdir -p "${CACHE_DIR}"
chown -R ${USER_UID}:${USER_GID} "${CACHE_DIR}"
```

## Alias and Function Documentation

### For Alias Groups

```bash
# ----------------------------------------------------------------------------
# Category Name - Brief description
# ----------------------------------------------------------------------------
alias example='command'
```

### For Functions

```bash
# ----------------------------------------------------------------------------
# function_name - Brief description
# 
# Arguments:
#   $1 - Description
#   $2 - Description (optional)
#
# Returns:
#   0 - Success
#   1 - Error condition
# ----------------------------------------------------------------------------
function_name() {
    # Function implementation
}
```

## Error Handling Comments

Always explain error handling:

```bash
# Install tool, but don't fail the build if it's not available
command || echo "Warning: Tool installation failed, continuing..."

# Silent failure for optional features
optional_command || true
```

## Configuration Blocks

Group related configurations with clear headers:

```bash
# ----------------------------------------------------------------------------
# Tool Configuration
# ----------------------------------------------------------------------------
export TOOL_HOME="/path/to/tool"
export TOOL_CONFIG="/etc/tool.conf"
```

## Examples

### Good

```bash
# Determine cache paths based on availability
# Priority: 1) Already set env vars, 2) /cache if available, 3) home directory
if [ -d "/cache" ] && [ -z "${VAR:-}" ]; then
    CACHE_DIR="/cache/tool"
else
    CACHE_DIR="${VAR:-/home/${USERNAME}/.tool}"
fi
```

### Avoid

```bash
# Set cache dir
CACHE_DIR="/cache/tool"  # cache directory
```

## Consistency Rules

1. Always use `echo "=== Action ==="` for user-visible progress messages
2. Use `# ===...` for section separators in code
3. Use `# ---...` for subsection separators
4. Keep separator lines to exactly 76 characters (fits in 80-char terminal)
5. Use complete sentences in comments
6. Document all environment variables in the file header
7. Explain any non-obvious commands or logic
8. Group related operations under clear section headers
