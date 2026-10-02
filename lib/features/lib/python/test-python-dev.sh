#!/bin/bash
# test-python-dev — verify the tools installed by the python-dev feature.
#
# Exits 1 if any required tool is missing, 0 otherwise. CHECK_LSP is baked in
# at build time by lib/features/python-dev.sh from SKIP_LSP_INSTALL (a build
# arg that is not visible at runtime); an unsubstituted placeholder checks the
# LSP tools too, so a packaging slip errs toward reporting more, never less.
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

echo "=== Python Development Tools Status ==="

echo ""
echo "Testing tools:"
check_tools pytest tox

echo ""
echo "Formatting tools:"
check_tools black isort ruff

echo ""
echo "Linting and security tools:"
check_tools flake8 mypy pylint bandit pip-audit

echo ""
echo "Interactive and workflow tools:"
check_tools ipython jupyter pre-commit

echo ""
if [ "$CHECK_LSP" = "false" ]; then
    echo "Language servers: skipped (built with SKIP_LSP_INSTALL=true)"
else
    echo "Language servers:"
    check_tools pylsp pyright
fi

echo ""
if [ "$missing" -gt 0 ]; then
    echo "✗ $missing required tool(s) missing"
    exit 1
fi
echo "✓ All Python development tools found"
