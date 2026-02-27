#!/bin/bash
# 1Password CLI setup

if command -v op &> /dev/null; then
    echo "=== 1Password CLI ==="
    echo "Version: $(op --version)"
    echo ""
    echo "To get started:"
    echo "  1. Sign in: op signin"
    echo "  2. List vaults: op vault list"
    echo "  3. Get item: op item get <item-name>"
    echo ""
    echo "Shortcuts available: ops, opl, opg, opi"
    echo "Load env vars: eval \$(op-env Vault/Item)"
fi
