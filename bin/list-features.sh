#!/bin/bash
# List available container features with descriptions and metadata
#
# Description:
#   Displays all available features that can be included in container builds,
#   along with their descriptions, dependencies, and build argument names.
#   Supports both human-readable and JSON output formats.
#
# Usage:
#   list-features.sh [OPTIONS]
#
# Options:
#   --json              Output in JSON format for CI/CD integration
#   --filter <category> Filter by category (language, dev, cloud, database, tool)
#   --help              Show this help message
#
# Examples:
#   list-features.sh
#   list-features.sh --json
#   list-features.sh --filter language
#
# Output Format (JSON):
#   {
#     "features": [
#       {
#         "name": "python",
#         "build_arg": "INCLUDE_PYTHON",
#         "category": "language",
#         "description": "...",
#         "dependencies": ["python-dev"],
#         "version_arg": "PYTHON_VERSION"
#       }
#     ]
#   }

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
FEATURES_DIR="/tmp/build-scripts/features"
# If running from installed container, use /tmp path
# If running from source, use relative path
if [ ! -d "$FEATURES_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    FEATURES_DIR="${SCRIPT_DIR}/../lib/features"
fi

# ============================================================================
# Helper Functions
# ============================================================================

show_help() {
    head -n 30 "$0" | grep "^#" | command sed 's/^# \?//'
}

# Extract description from feature script
extract_description() {
    local script="$1"
    local desc=""

    # Look for "Description:" section in header
    desc=$(awk '
        /^# Description:/ { found=1; next }
        found && /^#   / { gsub(/^#   /, ""); print; next }
        found && /^#$/ { next }
        found && /^# [A-Z]/ { exit }
        found { exit }
    ' "$script" | tr '\n' ' ' | command sed 's/  */ /g; s/^ //; s/ $//')

    echo "$desc"
}

# Extract dependencies from feature script
extract_dependencies() {
    local script="$1"
    local deps=""

    # Look for "Note:" or "Dependencies:" mentioning required features
    deps=$(awk '
        /^# (Note|Dependencies):/ { found=1; next }
        found && /^#   / { print; next }
        found && /^#$/ { next }
        found { exit }
    ' "$script" | grep -i "requires\|depends" | command sed 's/^#   //; s/feature to be enabled.*//; s/Requires //; s/INCLUDE_//' | tr -d '.' | xargs)

    echo "$deps"
}

# Categorize feature based on name
categorize_feature() {
    local name="$1"

    case "$name" in
        python|node|rust|ruby|golang|java|r|mojo)
            echo "language"
            ;;
        python-dev|node-dev|rust-dev|ruby-dev|golang-dev|java-dev|r-dev|mojo-dev|dev-tools)
            echo "dev-tools"
            ;;
        kubernetes|terraform|aws|gcloud|cloudflare)
            echo "cloud"
            ;;
        postgres-client|redis-client|sqlite-client)
            echo "database"
            ;;
        docker|op-cli|ollama)
            echo "tool"
            ;;
        *)
            echo "other"
            ;;
    esac
}

# ============================================================================
# Main Logic
# ============================================================================

OUTPUT_FORMAT="table"
FILTER_CATEGORY=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)
            OUTPUT_FORMAT="json"
            shift
            ;;
        --filter)
            FILTER_CATEGORY="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
done

# Check if features directory exists
if [ ! -d "$FEATURES_DIR" ]; then
    echo "Error: Features directory not found: $FEATURES_DIR" >&2
    exit 1
fi

# Collect feature information
declare -a FEATURES=()

for script in "$FEATURES_DIR"/*.sh; do
    [ -e "$script" ] || continue

    # Skip library scripts (in features/lib/ subdirectory)
    [[ "$script" == */features/lib/* ]] && continue

    # Get feature name from filename
    feature_name=$(basename "$script" .sh)

    # Get category
    category=$(categorize_feature "$feature_name")

    # Apply filter if specified
    if [ -n "$FILTER_CATEGORY" ] && [ "$category" != "$FILTER_CATEGORY" ]; then
        continue
    fi

    # Get description
    description=$(extract_description "$script")

    # Get dependencies
    dependencies=$(extract_dependencies "$script")

    # Determine build arg name
    build_arg="INCLUDE_$(echo "$feature_name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"

    # Determine version arg if applicable
    version_arg=""
    if [[ ! "$feature_name" =~ -dev$ ]] && [[ "$category" == "language" ]]; then
        version_arg="$(echo "$feature_name" | tr '[:lower:]' '[:upper:]')_VERSION"
    fi

    # Store feature info
    FEATURES+=("$feature_name|$build_arg|$category|$description|$dependencies|$version_arg")
done

# Sort features by category then name
mapfile -t FEATURES < <(printf '%s\n' "${FEATURES[@]}" | sort -t'|' -k3,3 -k1,1)

# Output based on format
if [ "$OUTPUT_FORMAT" == "json" ]; then
    # JSON output
    echo "{"
    echo '  "features": ['

    first=true
    for feature_data in "${FEATURES[@]}"; do
        IFS='|' read -r name build_arg category description dependencies version_arg <<< "$feature_data"

        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi

        echo -n "    {"
        echo -n '"name": "'"$name"'"'
        echo -n ', "build_arg": "'"$build_arg"'"'
        echo -n ', "category": "'"$category"'"'
        echo -n ', "description": "'"$description"'"'

        # Dependencies as array
        echo -n ', "dependencies": ['
        if [ -n "$dependencies" ]; then
            deps_json="${dependencies// /\", \"}"
            echo -n '"'"$deps_json"'"'
        fi
        echo -n ']'

        # Version arg (optional)
        if [ -n "$version_arg" ]; then
            echo -n ', "version_arg": "'"$version_arg"'"'
        fi

        echo -n "}"
    done

    echo ""
    echo "  ]"
    echo "}"
else
    # Table output
    echo "Available Container Features"
    echo "============================"
    echo ""

    current_category=""
    for feature_data in "${FEATURES[@]}"; do
        IFS='|' read -r name build_arg category description dependencies version_arg <<< "$feature_data"

        # Print category header
        if [ "$category" != "$current_category" ]; then
            current_category="$category"
            echo ""
            case "$category" in
                language)
                    echo "LANGUAGES"
                    ;;
                dev-tools)
                    echo "DEVELOPMENT TOOLS"
                    ;;
                cloud)
                    echo "CLOUD PLATFORMS"
                    ;;
                database)
                    echo "DATABASE CLIENTS"
                    ;;
                tool)
                    echo "TOOLS"
                    ;;
                *)
                    echo "OTHER"
                    ;;
            esac
            echo "----------"
        fi

        # Print feature info
        printf "  %-20s %s\n" "$name" "$build_arg"
        if [ -n "$description" ]; then
            echo "    $description" | fold -s -w 76 | command sed '1!s/^/    /'
        fi
        if [ -n "$version_arg" ]; then
            echo "    Version: $version_arg"
        fi
        if [ -n "$dependencies" ]; then
            echo "    Depends on: $dependencies"
        fi
        echo ""
    done

    echo ""
    echo "Usage: docker build --build-arg <BUILD_ARG>=true ..."
    echo "Example: docker build --build-arg INCLUDE_PYTHON=true --build-arg INCLUDE_PYTHON_DEV=true ..."
fi
