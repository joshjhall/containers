#!/bin/bash
# 40-project-health-check.sh — Check and fix .gitignore/.dockerignore in project root
#
# Runs on every container start. Detects missing entries based on enabled
# container features and appends them. Non-destructive and idempotent.
#
# Skip with: SKIP_PROJECT_HEALTH_CHECK=true

# ============================================================================
# Skip gate
# ============================================================================

if [ "${SKIP_PROJECT_HEALTH_CHECK:-false}" = "true" ]; then
    exit 0
fi

# ============================================================================
# Configuration
# ============================================================================

PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
ENABLED_FEATURES_FILE="${ENABLED_FEATURES_FILE:-/etc/container/config/enabled-features.conf}"
COMMENT_MARKER="# Added by devcontainer health check"

# ============================================================================
# Project root validation
# ============================================================================

if [ ! -d "${PROJECT_ROOT}/.git" ]; then
    exit 0
fi

# ============================================================================
# Feature detection
# ============================================================================

if [ -z "${HAVE_DEV_TOOLS+x}" ]; then
    HAVE_DEV_TOOLS=false
    if [ -f "$ENABLED_FEATURES_FILE" ] && /usr/bin/grep -qE '^INCLUDE_DEV_TOOLS=true$' "$ENABLED_FEATURES_FILE" 2>/dev/null; then
        HAVE_DEV_TOOLS=true
    fi
fi

if [ -z "${HAVE_BINDFS+x}" ]; then
    HAVE_BINDFS=false
    if command -v bindfs >/dev/null 2>&1; then
        HAVE_BINDFS=true
    fi
fi

# ============================================================================
# Helper functions
# ============================================================================

# Check if a file contains an exact line (literal match, no regex)
# Args: $1=file, $2=line
file_has_entry() {
    /usr/bin/grep -qFx "$2" "$1" 2>/dev/null
}

# Ensure file exists and ends with a newline
# Args: $1=file
ensure_file_ready() {
    if [ ! -f "$1" ]; then
        /usr/bin/touch "$1" 2>/dev/null || return 1
    fi

    # If file is non-empty and doesn't end with newline, add one
    if [ -s "$1" ]; then
        if [ "$(/usr/bin/tail -c 1 "$1" | /usr/bin/wc -l)" -eq 0 ]; then
            printf '\n' >> "$1" 2>/dev/null || return 1
        fi
    fi

    return 0
}

# Append missing entries to a file under a comment section
# Args: $1=file, $2=section label, $3..=entries
append_missing_entries() {
    local file="$1"
    local section="$2"
    shift 2

    local missing=()
    for entry in "$@"; do
        if ! file_has_entry "$file" "$entry"; then
            missing+=("$entry")
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        return 0
    fi

    # Write section header and entries
    {
        echo ""
        echo "$COMMENT_MARKER"
        echo "# ${section}"
        for entry in "${missing[@]}"; do
            echo "$entry"
        done
    } >> "$file" 2>/dev/null || {
        echo "[health-check] Warning: could not write to $file (read-only?)" >&2
        return 1
    }

    echo "[health-check] Added ${#missing[@]} entries to $(basename "$file") (${section})" >&2
    return 0
}

# ============================================================================
# Gitignore check
# ============================================================================

check_gitignore() {
    local gitignore="${PROJECT_ROOT}/.gitignore"

    if ! ensure_file_ready "$gitignore"; then
        echo "[health-check] Warning: cannot create/write .gitignore (read-only?)" >&2
        return 1
    fi

    # Unconditional entries (always needed)
    append_missing_entries "$gitignore" "Environment and OS files" \
        "**/.env" \
        "**/.env.*" \
        "!**/.env.example" \
        "!**/.env.*.example" \
        ".DS_Store" \
        "Thumbs.db"

    # Conditional: FUSE artifacts (bindfs or dev-tools which auto-triggers bindfs)
    if [ "$HAVE_BINDFS" = "true" ] || [ "$HAVE_DEV_TOOLS" = "true" ]; then
        append_missing_entries "$gitignore" "FUSE artifacts (bindfs)" \
            ".fuse_hidden*"
    fi

    # Conditional: Claude Code state (dev-tools)
    if [ "$HAVE_DEV_TOOLS" = "true" ]; then
        append_missing_entries "$gitignore" "Claude Code local state" \
            ".claude/settings.local.json" \
            ".claude/memory/tmp/"
    fi
}

# ============================================================================
# Dockerignore check
# ============================================================================

check_dockerignore() {
    local dockerignore="${PROJECT_ROOT}/.dockerignore"

    # Only create .dockerignore if Docker-related files exist in project
    local has_docker_files=false
    if [ -f "${PROJECT_ROOT}/Dockerfile" ]; then
        has_docker_files=true
    elif /usr/bin/find "$PROJECT_ROOT" -maxdepth 1 \
            \( -name "docker-compose*.yml" -o -name "docker-compose*.yaml" \
            -o -name "compose*.yml" -o -name "compose*.yaml" \) \
            -print -quit 2>/dev/null | /usr/bin/grep -q .; then
        has_docker_files=true
    fi

    if [ "$has_docker_files" != "true" ]; then
        return 0
    fi

    if ! ensure_file_ready "$dockerignore"; then
        echo "[health-check] Warning: cannot create/write .dockerignore (read-only?)" >&2
        return 1
    fi

    append_missing_entries "$dockerignore" "Build context exclusions" \
        ".git/" \
        "**/.env" \
        "**/.env.*" \
        "!**/.env.example" \
        "!**/.env.*.example" \
        ".claude/"
}

# ============================================================================
# Main
# ============================================================================

check_gitignore
check_dockerignore
