# shellcheck disable=SC2155,SC2064

# ----------------------------------------------------------------------------
# Kotlin Aliases - Common development commands
# ----------------------------------------------------------------------------
alias kt='kotlin'
alias ktc='kotlinc'
alias kts='kotlinc -script'

# Compile with runtime included (creates standalone JAR)
alias ktjar='kotlinc -include-runtime -d'

# ----------------------------------------------------------------------------
# kotlin-version - Show detailed Kotlin version information
# ----------------------------------------------------------------------------
kotlin-version() {
    echo "=== Kotlin Environment ==="
    echo "Kotlin Version:"
    kotlinc -version 2>&1
    echo ""
    echo "KOTLIN_HOME: ${KOTLIN_HOME:-/opt/kotlin}"

    if [ -n "${KOTLIN_NATIVE_HOME:-}" ] && [ -d "${KOTLIN_NATIVE_HOME}" ]; then
        echo ""
        echo "Kotlin/Native Version:"
        kotlinc-native -version 2>&1 || echo "  Not available"
        echo "KOTLIN_NATIVE_HOME: ${KOTLIN_NATIVE_HOME}"
    fi

    echo ""
    echo "Java Version:"
    java -version 2>&1 | head -n 1
    echo ""
    echo "Cache Directory: ${KOTLIN_CACHE_DIR:-/cache/kotlin}"
}

# ----------------------------------------------------------------------------
# kt-compile - Compile Kotlin file to JAR with runtime
#
# Arguments:
#   $1 - Source file (required)
#   $2 - Output JAR name (optional, defaults to source name)
#
# Example:
#   kt-compile hello.kt
#   kt-compile hello.kt myapp.jar
# ----------------------------------------------------------------------------
kt-compile() {
    if [ -z "$1" ]; then
        echo "Usage: kt-compile <source.kt> [output.jar]"
        return 1
    fi

    local source="$1"
    local output="${2:-$(basename "$source" .kt).jar}"

    echo "Compiling $source to $output..."
    kotlinc "$source" -include-runtime -d "$output"

    if [ -f "$output" ]; then
        echo "Success: $output created"
        echo "Run with: kotlin $output"
    fi
}

# ----------------------------------------------------------------------------
# kt-run - Compile and run Kotlin file
#
# Arguments:
#   $1 - Source file (required)
#   $@ - Arguments to pass to the program
#
# Example:
#   kt-run hello.kt
#   kt-run hello.kt arg1 arg2
# ----------------------------------------------------------------------------
kt-run() {
    if [ -z "$1" ]; then
        echo "Usage: kt-run <source.kt> [args...]"
        return 1
    fi

    local source="$1"
    shift

    local tempjar=$(mktemp --suffix=.jar)
    trap "command rm -f $tempjar" EXIT

    echo "Compiling $source..."
    if kotlinc "$source" -include-runtime -d "$tempjar" 2>/dev/null; then
        echo "Running..."
        kotlin "$tempjar" "$@"
    else
        echo "Compilation failed"
        return 1
    fi
}

# ----------------------------------------------------------------------------
# kt-native - Compile Kotlin to native binary (if Kotlin/Native available)
#
# Arguments:
#   $1 - Source file (required)
#   $2 - Output binary name (optional)
#
# Example:
#   kt-native hello.kt
#   kt-native hello.kt myapp
# ----------------------------------------------------------------------------
kt-native() {
    if ! command -v kotlinc-native &>/dev/null; then
        echo "Kotlin/Native is not installed"
        echo "It may not be available for your architecture"
        return 1
    fi

    if [ -z "$1" ]; then
        echo "Usage: kt-native <source.kt> [output]"
        return 1
    fi

    local source="$1"
    local output="${2:-$(basename "$source" .kt)}"

    echo "Compiling $source to native binary..."
    kotlinc-native "$source" -o "$output"

    if [ -f "$output.kexe" ]; then
        echo "Success: $output.kexe created"
        echo "Run with: ./$output.kexe"
    fi
}

# ----------------------------------------------------------------------------
# kt-repl - Start Kotlin REPL
# ----------------------------------------------------------------------------
alias kt-repl='kotlinc'
