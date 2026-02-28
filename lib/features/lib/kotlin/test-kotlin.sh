#!/bin/bash
echo "=== Kotlin Installation Status ==="
if command -v kotlinc &> /dev/null; then
    echo "✓ Kotlin is installed"
    kotlinc -version 2>&1 | command head -n 1 | command sed 's/^/  /'
    echo "  KOTLIN_HOME: ${KOTLIN_HOME:-/opt/kotlin}"
    echo "  Binary: $(which kotlinc)"
else
    echo "✗ Kotlin is not installed"
fi

echo ""
echo "=== Kotlin Tools ==="
for cmd in kotlin kotlinc kotlinc-native cinterop klib; do
    if command -v $cmd &> /dev/null; then
        echo "✓ $cmd is available"
    else
        echo "✗ $cmd is not found"
    fi
done

echo ""
echo "=== Java Environment ==="
if command -v java &> /dev/null; then
    java -version 2>&1 | command head -n 1
else
    echo "Java not found (required for Kotlin/JVM)"
fi

echo ""
echo "=== Quick Test ==="
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR" || exit 1
echo 'fun main() { println("Kotlin works!") }' > test.kt
if kotlinc test.kt -include-runtime -d test.jar 2>/dev/null; then
    result=$(kotlin test.jar 2>/dev/null)
    if [ "$result" = "Kotlin works!" ]; then
        echo "✓ Kotlin compilation and execution works"
    else
        echo "✗ Kotlin execution failed"
    fi
else
    echo "✗ Kotlin compilation failed"
fi
cd /
command rm -rf "$TEMP_DIR"

echo ""
echo "=== Cache Directory ==="
echo "Kotlin: ${KOTLIN_CACHE_DIR:-/cache/kotlin}"
[ -d "${KOTLIN_CACHE_DIR:-/cache/kotlin}" ] && echo "  Directory exists"
