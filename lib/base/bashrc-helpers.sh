#!/bin/bash
# bashrc-helpers.sh - Utilities for safely creating and managing bashrc.d files
#
# This file provides:
# - Safety wrappers and best practices for bashrc.d scripts
# - Functions to create bashrc files without logging interference
# - Standard headers/footers to prevent terminal errors
# - Idempotent content management

# Function to add standard safety headers to bashrc.d scripts
add_bashrc_safety_header() {
    cat << 'BASHRC_SAFETY_HEADER'
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
BASHRC_SAFETY_HEADER
}

# Function to add standard safety footer to bashrc.d scripts
add_bashrc_safety_footer() {
    cat << 'BASHRC_SAFETY_FOOTER'
# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
BASHRC_SAFETY_FOOTER
}

# Recommended heredoc naming convention to avoid conflicts:
# - Feature-specific: FEATURE_BASHRC_EOF (e.g., NODE_DEV_BASHRC_EOF)
# - Script-specific: SCRIPTNAME_EOF (e.g., NODE_DEV_STARTUP_EOF)
# - Never use generic 'EOF' in nested scripts

# ----------------------------------------------------------------------------
# Safe bashrc.d file creation function (without logging interference)
# ----------------------------------------------------------------------------

# Write to a bashrc.d file from a heredoc without logging interference
# This function is IDEMPOTENT - running it multiple times with the same content is safe
# Usage: write_bashrc_content <filepath> <description> [content_id] << 'UNIQUE_EOF'
#        ... content ...
#        UNIQUE_EOF
#
# Parameters:
#   filepath    - Path to the bashrc.d file
#   description - Description of what's being written
#   content_id  - Optional: unique identifier for this content block (for idempotency)
#
# The function will:
# - Create the directory if it doesn't exist
# - Check if content already exists (using markers) and skip if found
# - Create new files or append to existing ones intelligently
# - Set proper permissions (755)
# - Log the operation after completion
write_bashrc_content() {
    local filepath="$1"
    local description="${2:-bashrc configuration}"
    local content_id="${3:-}"

    # Generate content ID from description if not provided
    if [ -z "$content_id" ]; then
        # Create a sanitized ID from the description
        content_id=$(echo "$description" | tr ' ' '_' | tr -cd '[:alnum:]_-')
    fi

    # Marker comments for idempotency
    local start_marker="# BEGIN_GENERATED_CONTENT: $content_id"
    local end_marker="# END_GENERATED_CONTENT: $content_id"

    # Ensure directory exists
    mkdir -p "$(dirname "$filepath")" || {
        echo "✗ Failed to create directory for $filepath" >&2
        return 1
    }

    # Use command to bypass any cat aliases
    local cat_cmd="command cat"

    # Check if content with this ID already exists
    if [ -f "$filepath" ] && grep -q "^${start_marker}$" "$filepath" 2>/dev/null; then
        echo "✓ Content '$description' already exists in $filepath (skipping)"
        # Consume the heredoc input to prevent it from going to stdout
        $cat_cmd > /dev/null
        return 0
    fi

    # Capture content to temp file
    local tmpfile
    tmpfile=$(mktemp)
    $cat_cmd > "$tmpfile" || {
        echo "✗ Failed to capture content for $filepath" >&2
        rm -f "$tmpfile"
        return 1
    }

    # Check if we captured anything
    if [ ! -s "$tmpfile" ]; then
        echo "⚠ Warning: No content provided for $filepath" >&2
        rm -f "$tmpfile"
        return 0
    fi

    # Prepare content with markers
    local marked_content
    marked_content=$(mktemp)
    {
        echo "$start_marker"
        $cat_cmd "$tmpfile"
        echo "$end_marker"
        echo ""  # Blank line for readability
    } > "$marked_content"

    # Clean up input temp file
    rm -f "$tmpfile"

    # Write to file
    if [ ! -f "$filepath" ]; then
        # Create new file with atomic write
        # Set permissions before moving
        chmod 755 "$marked_content"
        mv -f "$marked_content" "$filepath" || {
            echo "✗ Failed to create $filepath" >&2
            rm -f "$marked_content"
            return 1
        }
        echo "✓ Created $description at $filepath"
    else
        # Append to existing file
        $cat_cmd "$marked_content" >> "$filepath" || {
            echo "✗ Failed to append to $filepath" >&2
            rm -f "$marked_content"
            return 1
        }
        rm -f "$marked_content"
        echo "✓ Appended $description to $filepath"
    fi

    # Ensure proper permissions
    chmod 755 "$filepath" 2>/dev/null || true

    return 0
}

# Alternative approach: Replace content between markers (for updates)
# This allows updating specific sections without duplicating
update_bashrc_content() {
    local filepath="$1"
    local description="${2:-bashrc configuration}"
    local content_id="${3:-}"

    # Generate content ID from description if not provided
    if [ -z "$content_id" ]; then
        content_id=$(echo "$description" | tr ' ' '_' | tr -cd '[:alnum:]_-')
    fi

    # Marker comments
    local start_marker="# BEGIN_GENERATED_CONTENT: $content_id"
    local end_marker="# END_GENERATED_CONTENT: $content_id"

    # Use write_bashrc_content if markers don't exist
    if [ ! -f "$filepath" ] || ! grep -q "^${start_marker}$" "$filepath" 2>/dev/null; then
        write_bashrc_content "$@"
        return $?
    fi

    # Capture new content
    local tmpfile
    tmpfile=$(mktemp)
    command cat > "$tmpfile" || {
        echo "✗ Failed to capture content for $filepath" >&2
        rm -f "$tmpfile"
        return 1
    }

    # Create new file with updated content
    local newfile
    newfile=$(mktemp)
    awk -v start="$start_marker" -v end="$end_marker" -v tmpfile="$tmpfile" '
        BEGIN { printing = 1 }
        $0 == start {
            print
            system("cat " tmpfile)
            print end
            print ""
            printing = 0
            next
        }
        $0 == end {
            printing = 1
            next
        }
        printing { print }
    ' "$filepath" > "$newfile"

    # Atomic replace
    chmod 755 "$newfile"
    mv -f "$newfile" "$filepath" || {
        echo "✗ Failed to update $filepath" >&2
        rm -f "$newfile" "$tmpfile"
        return 1
    }

    rm -f "$tmpfile"
    echo "✓ Updated $description in $filepath"
    return 0
}

# Export functions for use in feature scripts
export -f write_bashrc_content
export -f update_bashrc_content
export -f add_bashrc_safety_header
export -f add_bashrc_safety_footer
