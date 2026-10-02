#!/bin/bash
# test-ruby-dev — verify the tools installed by the ruby-dev feature.
#
# Exits 1 if any required tool is missing, 0 otherwise. CHECK_LSP is baked in
# at build time by lib/features/ruby-dev.sh from SKIP_LSP_INSTALL (a build arg
# that is not visible at runtime); an unsubstituted placeholder checks the LSP
# too, so a packaging slip errs toward reporting more, never less.
CHECK_LSP="__CHECK_LSP__"

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

echo "=== Ruby Development Tools Status ==="

echo ""
echo "Testing tools:"
check_tools rspec

echo ""
echo "Code quality and security tools:"
check_tools rubocop reek brakeman bundle-audit

echo ""
echo "Debugging and documentation tools:"
check_tools pry yard

echo ""
echo "Framework tools:"
check_tools rails

echo ""
if [ "$CHECK_LSP" = "false" ]; then
    echo "Language server: skipped (built with SKIP_LSP_INSTALL=true)"
else
    echo "Language server:"
    check_tools solargraph
fi

echo ""
if [ "$missing" -gt 0 ]; then
    echo "✗ $missing required tool(s) missing"
    exit 1
fi
echo "✓ All Ruby development tools found"
