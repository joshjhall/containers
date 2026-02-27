# ----------------------------------------------------------------------------
# Kotlin environment configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    return 0
fi

# Source base utilities for secure PATH management
if [ -f /opt/container-runtime/base/logging.sh ]; then
    source /opt/container-runtime/base/logging.sh
fi
if [ -f /opt/container-runtime/base/path-utils.sh ]; then
    source /opt/container-runtime/base/path-utils.sh
fi

# Kotlin installation
export KOTLIN_HOME=/opt/kotlin
if command -v safe_add_to_path >/dev/null 2>&1; then
    safe_add_to_path "$KOTLIN_HOME/bin" 2>/dev/null || export PATH="$KOTLIN_HOME/bin:$PATH"
else
    export PATH="$KOTLIN_HOME/bin:$PATH"
fi

# Kotlin/Native (if installed)
if [ -d "/opt/kotlin-native" ]; then
    export KOTLIN_NATIVE_HOME=/opt/kotlin-native
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "$KOTLIN_NATIVE_HOME/bin" 2>/dev/null || export PATH="$KOTLIN_NATIVE_HOME/bin:$PATH"
    else
        export PATH="$KOTLIN_NATIVE_HOME/bin:$PATH"
    fi
fi

# Kotlin cache directory
export KOTLIN_CACHE_DIR="/cache/kotlin"
