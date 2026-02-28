# ----------------------------------------------------------------------------
# Terraform configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi


# Terraform plugin cache location (may be in /cache for volume persistence)
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE}"

# Terraform aliases
alias tf='terraform'
alias tfi='terraform init'
alias tfp='terraform plan'
alias tfa='terraform apply'
alias tfd='terraform destroy'
alias tfv='terraform validate'
alias tff='terraform fmt'
alias tfs='terraform state'
alias tfw='terraform workspace'

# Terragrunt aliases
alias tg='terragrunt'
alias tgi='terragrunt init'
alias tgp='terragrunt plan'
alias tga='terragrunt apply'
alias tgd='terragrunt destroy'

# Terraform auto-completion
if command -v terraform &> /dev/null; then
    complete -C /usr/bin/terraform terraform
    complete -C /usr/bin/terraform tf
fi

# Helper function to clean Terraform cache
tf-clean() {
    command find . -type d -name ".terraform" -exec command rm -rf {} + 2>/dev/null || true
    command find . -type f -name ".terraform.lock.hcl" -delete 2>/dev/null || true
    echo "Cleaned Terraform cache files"
}

# Helper function to format all Terraform files
tf-fmt-all() {
    command find . -name "*.tf" -exec terraform fmt {} \;
    echo "Formatted all Terraform files"
}

# ----------------------------------------------------------------------------
# Provider Security Functions
# ----------------------------------------------------------------------------

# Initialize with locked providers (verify checksums from lock file)
# Use this for CI/CD and production to ensure reproducible builds
tf-init-locked() {
    if [ ! -f ".terraform.lock.hcl" ]; then
        echo "ERROR: No .terraform.lock.hcl found!"
        echo "Run 'terraform init' first, then commit the lock file to version control."
        echo "The lock file ensures provider integrity across all environments."
        return 1
    fi
    echo "Initializing with locked providers (verifying checksums)..."
    terraform init -upgrade=false
}

# Initialize with provider signature verification (most secure)
# This verifies both checksums and GPG signatures from HashiCorp
tf-init-secure() {
    echo "Initializing with signature verification..."
    # Use -lockfile=readonly to strictly enforce lock file
    if [ -f ".terraform.lock.hcl" ]; then
        terraform init -lockfile=readonly
    else
        echo "WARNING: No lock file found. Creating one with checksums..."
        terraform init
        echo ""
        echo "IMPORTANT: Commit .terraform.lock.hcl to version control!"
        echo "This ensures all team members and CI use verified providers."
    fi
}

# Update providers and regenerate lock file with multi-platform checksums
# Run this when intentionally updating provider versions
tf-providers-update() {
    echo "Updating providers and generating checksums for all platforms..."
    terraform init -upgrade
    # Generate checksums for multiple platforms (needed for cross-platform teams)
    terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_amd64 -platform=darwin_arm64
    echo ""
    echo "Lock file updated. Review changes and commit .terraform.lock.hcl"
    echo "to ensure all team members use these verified provider versions."
}

# Check provider versions against lock file
tf-providers-check() {
    if [ ! -f ".terraform.lock.hcl" ]; then
        echo "No .terraform.lock.hcl found"
        return 1
    fi
    echo "Locked providers in .terraform.lock.hcl:"
    command grep -E "^\s+version\s*=" .terraform.lock.hcl | sed 's/.*= "//; s/"//' | while read version; do
        echo "  $version"
    done
    echo ""
    echo "Provider constraints in configuration:"
    command grep -h "required_providers" -A 20 *.tf 2>/dev/null | command grep -E "^\s+version\s*=" | head -10 || echo "  (none found)"
}


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
