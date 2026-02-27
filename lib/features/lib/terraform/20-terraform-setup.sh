#!/bin/bash
# Initialize Terraform if in a Terraform project
if [ -f "${WORKING_DIR}/main.tf" ] || [ -f "${WORKING_DIR}/terraform.tf" ]; then
    echo "=== Terraform Project Detected ==="
    cd "${WORKING_DIR}" || return

    # Check if .terraform directory exists
    if [ ! -d .terraform ]; then
        echo "Running terraform init..."
        terraform init || echo "Terraform init failed, continuing..."
    fi

    # Run validation
    echo "Running terraform validate..."
    terraform validate || echo "Terraform validation failed, continuing..."
fi

# Check for Terragrunt
if [ -f "${WORKING_DIR}/terragrunt.hcl" ]; then
    echo "=== Terragrunt Project Detected ==="
    echo "Run 'terragrunt init' to initialize"
fi
