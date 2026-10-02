#!/bin/bash
# test-rust — verify the toolchain and tools installed by the rust feature.
#
# Exits 1 if any required tool is missing, 0 otherwise. rust-analyzer is a
# rustup component (and the LSP), so it is reported but never fails the check.

missing=0

check_tools() {
    local tool
    for tool in "$@"; do
        if command -v "$tool" &>/dev/null; then
            echo "✓ $tool is installed"
        else
            echo "✗ $tool is not found"
            missing=$((missing + 1))
        fi
    done
}

echo "=== Rust Installation Status ==="

echo ""
echo "Toolchain:"
check_tools rustc cargo rustup
# First line of each --version, read with the `read` builtin so the script
# needs no external tool beyond the ones it is checking.
for tool in rustc cargo; do
    if command -v "$tool" &>/dev/null; then
        IFS= read -r version < <("$tool" --version 2>&1)
        echo "  ${version}"
    fi
done

echo ""
echo "Development and documentation tools:"
check_tools cargo-watch mdbook

echo ""
echo "Optional components:"
if command -v rust-analyzer &>/dev/null; then
    echo "✓ rust-analyzer is installed"
else
    echo "- rust-analyzer is not installed (optional)"
fi

echo ""
echo "CARGO_HOME: ${CARGO_HOME:-not set}"
echo "RUSTUP_HOME: ${RUSTUP_HOME:-not set}"

echo ""
if [ "$missing" -gt 0 ]; then
    echo "✗ $missing required tool(s) missing"
    exit 1
fi
echo "✓ All Rust tools found"
