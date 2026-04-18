#!/bin/bash
# Generic logging functions for feature installations
#
# This script provides consistent logging functionality across all feature
# installations, capturing output, errors, and generating summaries.
#
# It sources shared/logging.sh for core functions (_get_log_level_num,
# _should_log, log_message, log_info, log_debug, log_error, log_warning)
# and extends them with build-specific features: file-based logging,
# feature start/end, command logging, counters, JSON output, and secret
# scrubbing.
#
# Usage:
#   Source this file in your feature script:
#     source /tmp/build-scripts/base/logging.sh
#
#   Then use:
#     log_feature_start "Python" "3.13.5"
#     log_command "Installing Python dependencies" apt-get install -y ...
#     log_feature_end
#
#   Enable JSON logging (optional):
#     export ENABLE_JSON_LOGGING=true
#
# API Contract (see docs/architecture/god-modules.md for full details):
#   Feature lifecycle: log_feature_start, log_command, log_feature_end,
#                      log_feature_summary
#   Message logging:   log_message, log_info, log_debug, log_error, log_warning
#   Utilities:         safe_eval, _get_log_level_num, _should_log
#   State variables:   CURRENT_FEATURE, CURRENT_LOG_FILE, CURRENT_ERROR_FILE,
#                      CURRENT_SUMMARY_FILE, COMMAND_COUNT, ERROR_COUNT,
#                      WARNING_COUNT, BUILD_LOG_DIR
#   Include guard:     _LOGGING_LOADED
#

# Prevent multiple sourcing
if [ -n "${_LOGGING_LOADED:-}" ]; then
    return 0
fi
_LOGGING_LOADED=1

set -euo pipefail

# Source export utilities
# shellcheck source=lib/shared/export-utils.sh
if [ -f "/tmp/build-scripts/shared/export-utils.sh" ]; then
    source "/tmp/build-scripts/shared/export-utils.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/../shared/export-utils.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../shared/export-utils.sh"
fi

# Source shared logging (core log level system and basic log functions)
# shellcheck source=lib/shared/logging.sh
if [ -f "/tmp/build-scripts/shared/logging.sh" ]; then
    source "/tmp/build-scripts/shared/logging.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/../shared/logging.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../shared/logging.sh"
fi

# Source JSON logging utilities if enabled
if [ "${ENABLE_JSON_LOGGING:-false}" = "true" ]; then
    # shellcheck source=lib/base/json-logging.sh
    if [ -f "/tmp/build-scripts/base/json-logging.sh" ]; then
        source "/tmp/build-scripts/base/json-logging.sh"
    elif [ -f "$(dirname "${BASH_SOURCE[0]}")/json-logging.sh" ]; then
        source "$(dirname "${BASH_SOURCE[0]}")/json-logging.sh"
    fi
fi

# Source secret scrubbing utilities
# shellcheck source=lib/base/secret-scrubbing.sh
if [ -f "/tmp/build-scripts/base/secret-scrubbing.sh" ]; then
    source "/tmp/build-scripts/base/secret-scrubbing.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/secret-scrubbing.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/secret-scrubbing.sh"
fi

# ============================================================================
# Log Directory Initialization
# ============================================================================
# Allow BUILD_LOG_DIR to be overridden (e.g., for tests)
if [ -z "${BUILD_LOG_DIR:-}" ]; then
    # Try /var/log/container-build first (for root or proper permissions)
    if mkdir -p /var/log/container-build 2>/dev/null; then
        export BUILD_LOG_DIR="/var/log/container-build"
    else
        # Fallback to /tmp for non-root or restricted environments
        export BUILD_LOG_DIR="/tmp/container-build"
        mkdir -p "$BUILD_LOG_DIR" 2>/dev/null || {
            echo "ERROR: Cannot create log directory at /var/log/container-build or /tmp/container-build" >&2
            exit 1
        }
    fi
else
    # BUILD_LOG_DIR was explicitly set, use it and ensure it exists
    mkdir -p "$BUILD_LOG_DIR" 2>/dev/null || {
        echo "ERROR: Cannot create log directory at $BUILD_LOG_DIR" >&2
        exit 1
    }
fi

# ============================================================================
# Source Sub-Modules
# ============================================================================
# Feature lifecycle logging (log_feature_start, log_command, log_feature_end)
# shellcheck source=lib/base/feature-logging.sh
if [ -f "/tmp/build-scripts/base/feature-logging.sh" ]; then
    source "/tmp/build-scripts/base/feature-logging.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/feature-logging.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/feature-logging.sh"
fi

# Message logging (log_message, log_info, log_debug, log_error, log_warning)
# shellcheck source=lib/base/message-logging.sh
if [ -f "/tmp/build-scripts/base/message-logging.sh" ]; then
    source "/tmp/build-scripts/base/message-logging.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/message-logging.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/message-logging.sh"
fi

# Source shared safe_eval function
# shellcheck source=lib/shared/safe-eval.sh
if [ -f "/tmp/build-scripts/shared/safe-eval.sh" ]; then
    source "/tmp/build-scripts/shared/safe-eval.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/../shared/safe-eval.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../shared/safe-eval.sh"
fi

# ============================================================================
# log_feature_summary - Output user-friendly configuration summary
#
# This function should be called BEFORE log_feature_end() to provide users
# with actionable information about what was installed and configured.
#
# Arguments:
#   --feature <name>       Feature name (e.g., "Python")
#   --version <version>    Version installed
#   --tools <tool1,tool2>  Comma-separated list of tools
#   --paths <path1,path2>  Comma-separated list of important paths
#   --env <VAR1,VAR2>      Comma-separated list of environment variables
#   --commands <cmd1,cmd2> Comma-separated list of available commands
#   --next-steps <text>    Next steps for the user
#
# Example:
#   log_feature_summary \
#       --feature "Python" \
#       --version "${PYTHON_VERSION}" \
#       --tools "pip,poetry,pipx" \
#       --paths "${PIP_CACHE_DIR},${POETRY_CACHE_DIR}" \
#       --env "PIP_CACHE_DIR,POETRY_CACHE_DIR,PIPX_HOME" \
#       --commands "python3,pip,poetry" \
#       --next-steps "Run 'test-python' to verify installation"
# ============================================================================
log_feature_summary() {
    local feature="" version="" tools="" paths="" env_vars="" commands="" next_steps=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --feature)
                feature="$2"
                shift 2
                ;;
            --version)
                version="$2"
                shift 2
                ;;
            --tools)
                tools="$2"
                shift 2
                ;;
            --paths)
                paths="$2"
                shift 2
                ;;
            --env)
                env_vars="$2"
                shift 2
                ;;
            --commands)
                commands="$2"
                shift 2
                ;;
            --next-steps)
                next_steps="$2"
                shift 2
                ;;
            *)
                log_warning "Unknown argument to log_feature_summary: $1"
                shift
                ;;
        esac
    done

    # Generate summary output
    {
        echo ""
        echo "================================================================================"
        echo "${feature} Configuration Summary"
        echo "================================================================================"
        echo ""

        if [ -n "$version" ]; then
            echo "Version:      $version"
        fi

        if [ -n "$tools" ]; then
            echo "Tools:        ${tools//,/, }"
        fi

        if [ -n "$commands" ]; then
            echo "Commands:     ${commands//,/, }"
        fi

        if [ -n "$paths" ]; then
            echo ""
            echo "Paths:"
            IFS=',' read -ra PATH_ARRAY <<<"$paths"
            for path in "${PATH_ARRAY[@]}"; do
                echo "  - $path"
            done
        fi

        if [ -n "$env_vars" ]; then
            echo ""
            echo "Environment Variables:"
            IFS=',' read -ra ENV_ARRAY <<<"$env_vars"
            for var in "${ENV_ARRAY[@]}"; do
                # Try to get the value
                value="${!var:-<not set>}"
                # Mask secret values to avoid exposing them in build logs
                local _upper_var
                _upper_var=$(printf '%s' "$var" | command tr '[:lower:]' '[:upper:]')
                case "$_upper_var" in
                    *_TOKEN | *_SECRET | *_PASSWORD | *_KEY | *_CREDENTIAL*)
                        if [ "$value" != "<not set>" ]; then
                            if [ "${#value}" -ge 8 ]; then
                                value="${value:0:4}****"
                            else
                                value="****"
                            fi
                        fi
                        ;;
                esac
                echo "  - $var=$value"
            done
        fi

        if [ -n "$next_steps" ]; then
            echo ""
            echo "Next Steps:"
            echo "  $next_steps"
        fi

        echo ""
        echo "Run 'check-build-logs.sh $(echo "$feature" | command tr '[:upper:]' '[:lower:]')' to review installation logs"
        echo "================================================================================"
        echo ""
    } | command tee -a "$CURRENT_LOG_FILE"
}

# Print standard post-install instructions for a feature.
# Usage: log_feature_instructions "test-golang" "golang"
log_feature_instructions() {
    local test_cmd="$1"
    local log_slug="$2"
    echo ""
    echo "Run '${test_cmd}' to verify installation"
    echo "Run 'check-build-logs.sh ${log_slug}' to review installation logs"
}

# ============================================================================
# Export Declarations
# ============================================================================
protected_export log_feature_start log_command log_feature_end log_feature_summary log_feature_instructions
protected_export log_message log_info log_debug log_error log_warning
protected_export safe_eval _get_log_level_num _should_log
protected_export _get_last_command_start_line _count_patterns_since
