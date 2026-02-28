#!/bin/bash
echo "=== Terraform Status ==="
if command -v terraform &> /dev/null; then
    echo "✓ Terraform is installed"
    echo "  Version: $(terraform version -json 2>/dev/null | jq -r '.terraform_version' || terraform version | command head -1)"
    echo "  Binary: $(which terraform)"
else
    echo "✗ Terraform is not installed"
    exit 1
fi

echo ""
echo "=== Additional Tools ==="
if command -v terragrunt &> /dev/null; then
    echo "✓ Terragrunt is installed"
    echo "  Version: $(terragrunt --version 2>&1 | command grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | command head -1)"
    echo "  Binary: $(which terragrunt)"
else
    echo "✗ Terragrunt is not installed"
fi

if command -v terraform-docs &> /dev/null; then
    echo "✓ terraform-docs is installed"
    echo "  Version: $(terraform-docs --version 2>&1 | command grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | command head -1)"
    echo "  Binary: $(which terraform-docs)"
else
    echo "✗ terraform-docs is not installed"
fi

if command -v tflint &> /dev/null; then
    echo "✓ tflint is installed"
    echo "  Version: $(tflint --version 2>&1 | command grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | command head -1)"
    echo "  Binary: $(which tflint)"
else
    echo "✗ tflint is not installed"
fi

if command -v trivy &> /dev/null; then
    echo "✓ Trivy is installed (replaces deprecated tfsec)"
    echo "  Version: $(trivy --version 2>&1 | command grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | command head -1)"
    echo "  Binary: $(which trivy)"
    echo "  Usage: trivy fs . (for Terraform scanning)"
else
    echo "✗ Trivy is not installed"
fi

echo ""
echo "=== Configuration ==="
echo "  TF_PLUGIN_CACHE_DIR: ${TF_PLUGIN_CACHE_DIR:-/cache/terraform}"
if [ -d "${TF_PLUGIN_CACHE_DIR:-/cache/terraform}" ]; then
    echo "  ✓ Plugin cache directory exists"
    # Count cached providers if any
    provider_count=$(command find "${TF_PLUGIN_CACHE_DIR:-/cache/terraform}" -name "terraform-provider-*" 2>/dev/null | command wc -l)
    if [ $provider_count -gt 0 ]; then
        echo "  Cached providers: $provider_count"
    fi
else
    echo "  ✗ Plugin cache directory not found"
fi

# Check for .terraformrc
if [ -f ~/.terraformrc ]; then
    echo "  ✓ .terraformrc file exists"
else
    echo "  ✗ .terraformrc file not found"
fi
