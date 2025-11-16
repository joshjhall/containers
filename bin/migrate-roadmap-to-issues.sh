#!/bin/bash
set -euo pipefail

# Migrate Roadmap to GitHub Issues
# Version: 1.0.0
#
# Purpose: Migrate remaining items from docs/planned/improvements-roadmap.md
#          to GitHub Issues with labels and a project board
#
# Usage:
#   ./bin/migrate-roadmap-to-issues.sh [--dry-run]
#
# Requirements:
#   - GitHub CLI (gh) authenticated
#   - Repository: joshjhall/containers

# ============================================================================
# Configuration
# ============================================================================

REPO="joshjhall/containers"
PROJECT_TITLE="Improvement Backlog"
DRY_RUN=false

# Parse command line arguments
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "🔍 DRY RUN MODE - No changes will be made"
    echo ""
fi

# ============================================================================
# Functions
# ============================================================================

log_info() {
    echo "ℹ️  $*"
}

log_success() {
    echo "✅ $*"
}

log_error() {
    echo "❌ $*" >&2
}

log_step() {
    echo ""
    echo "===================================="
    echo "$*"
    echo "===================================="
    echo ""
}

# Create labels if they don't exist
create_labels() {
    log_step "Step 1: Creating Labels"

    local labels=(
        # Priority labels
        "priority/critical|P0 - Critical priority|#d73a4a"
        "priority/high|P1 - High priority|#ff9800"
        "priority/medium|P2 - Medium priority|#fbca04"
        "priority/low|P3 - Low priority|#0e8a16"

        # Category labels
        "category/security|Security-related improvements|#b60205"
        "category/architecture|Architecture and code organization|#1d76db"
        "category/operations|Operations and deployment|#5319e7"
        "category/testing|Testing and quality assurance|#006b75"
        "category/anti-patterns|Code smells and anti-patterns|#e99695"
        "category/features|Missing features|#a2eeef"

        # Type labels
        "type/enhancement|New feature or request|#84b6eb"
        "type/refactor|Code refactoring|#c5def5"

        # Migration label
        "migrated-from-roadmap|Migrated from improvements-roadmap.md|#ededed"
    )

    for label_spec in "${labels[@]}"; do
        IFS='|' read -r name description color <<< "$label_spec"

        if $DRY_RUN; then
            echo "  Would create label: $name"
        else
            # Check if label exists
            if gh label list --repo "$REPO" --limit 1000 | grep -q "^$name"; then
                log_info "Label already exists: $name"
            else
                if gh label create "$name" \
                    --repo "$REPO" \
                    --description "$description" \
                    --color "$color"; then
                    log_success "Created label: $name"
                else
                    log_error "Failed to create label: $name"
                fi
            fi
        fi
    done
}

# Create GitHub Project
create_project() {
    log_step "Step 2: Creating GitHub Project"

    if $DRY_RUN; then
        echo "  Would create project: $PROJECT_TITLE"
        echo "  Project URL: https://github.com/users/joshjhall/projects/..."
        return 0
    fi

    # Check if project already exists
    local existing_project
    existing_project=$(gh project list --owner joshjhall --format json | \
        jq -r ".projects[] | select(.title == \"$PROJECT_TITLE\") | .number" || echo "")

    if [ -n "$existing_project" ]; then
        log_info "Project already exists: $PROJECT_TITLE (Project #$existing_project)"
        echo "$existing_project"
        return 0
    fi

    # Create new project
    local project_number
    project_number=$(gh project create \
        --owner joshjhall \
        --title "$PROJECT_TITLE" \
        --format json | jq -r '.number')

    if [ -n "$project_number" ]; then
        log_success "Created project: $PROJECT_TITLE (Project #$project_number)"
        echo "$project_number"
    else
        log_error "Failed to create project"
        return 1
    fi
}

# Create a single issue
create_issue() {
    local priority="$1"
    local title="$2"
    local category="$3"
    local body="$4"

    # Determine priority label
    local priority_label
    case "$priority" in
        CRITICAL) priority_label="priority/critical" ;;
        HIGH) priority_label="priority/high" ;;
        MEDIUM) priority_label="priority/medium" ;;
        LOW) priority_label="priority/low" ;;
        *) priority_label="priority/medium" ;;
    esac

    # Determine category label
    local category_label="category/other"
    case "$category" in
        security) category_label="category/security" ;;
        architecture) category_label="category/architecture" ;;
        operations) category_label="category/operations" ;;
        testing) category_label="category/testing" ;;
        anti-patterns) category_label="category/anti-patterns" ;;
        features) category_label="category/features" ;;
    esac

    local issue_labels="$priority_label,$category_label,type/enhancement,migrated-from-roadmap"

    if $DRY_RUN; then
        echo ""
        echo "  Would create issue:"
        echo "    Title: [$priority] $title"
        echo "    Labels: $issue_labels"
        echo "    Body preview: ${body:0:100}..."
        return 0
    fi

    # Create the issue
    local issue_url
    issue_url=$(gh issue create \
        --repo "$REPO" \
        --title "[$priority] $title" \
        --body "$body" \
        --label "$issue_labels" \
        2>&1)

    if [[ "$issue_url" =~ https://github.com/.*/issues/([0-9]+) ]]; then
        local issue_number="${BASH_REMATCH[1]}"
        log_success "Created issue #$issue_number: $title"
        echo "$issue_number"
    else
        log_error "Failed to create issue: $title"
        log_error "Output: $issue_url"
        return 1
    fi
}

# Add issue to project
add_to_project() {
    local project_number="$1"
    local issue_number="$2"

    if $DRY_RUN; then
        echo "  Would add issue #$issue_number to project #$project_number"
        return 0
    fi

    if gh project item-add "$project_number" \
        --owner joshjhall \
        --url "https://github.com/$REPO/issues/$issue_number" \
        >/dev/null 2>&1; then
        log_info "Added issue #$issue_number to project"
    else
        log_error "Failed to add issue #$issue_number to project"
    fi
}

# Create all issues
create_issues() {
    log_step "Step 3: Creating GitHub Issues"

    local project_number="$1"
    local created_issues=()

    # Item 5: Expand GPG Verification
    local issue_number
    issue_number=$(create_issue "MEDIUM" \
        "Expand GPG Verification to Remaining Tools" \
        "security" \
        "$(cat <<'EOF'
**Source**: OWASP Security Analysis (Nov 2025)
**Priority**: P2 (Medium - enhancement after 4-tier system)
**Effort**: 2-3 days

## Issue
GPG verification should be expanded beyond Python/Node/Go

## Tools Needing GPG Verification
- Kubernetes tools (kubectl binary downloads, helm)
- Terraform and HashiCorp tools
- Ruby (ruby-lang.org provides GPG signatures)
- R binaries
- Java/OpenJDK downloads
- Docker CLI (if not from apt repository)

## Already Implemented
- ✅ Python: GPG + Sigstore verification
- ✅ Node.js: Tier 2 (pinned) + Tier 3 (published checksums)
- ✅ Go: Tier 2 (pinned) + Tier 3 (published checksums)

## Implementation
Extend `lib/base/signature-verify.sh` with GPG keys for additional tools.

## Related
- Built on 4-tier verification system (#1 - completed)
- Reference: `docs/reference/security-checksums.md`

---
_Migrated from docs/planned/improvements-roadmap.md - Item #5_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    # Item 6: Fix Command Injection Vectors
    issue_number=$(create_issue "MEDIUM" \
        "Fix Command Injection Vectors in apt-utils.sh" \
        "security" \
        "$(cat <<'EOF'
**Source**: OWASP Security Analysis (Nov 2025)
**Priority**: P2 (Medium)
**Effort**: 1 day

## Issue
The `apt_install()` function doesn't sanitize package names before passing to apt-get, creating potential command injection risk.

## Current Code
```bash
apt-get install -y "$@"  # $@ not validated
```

## Recommendation
Add package name validation:
```bash
for pkg in "$@"; do
    if [[ ! "$pkg" =~ ^[a-zA-Z0-9._+-]+$ ]]; then
        log_error "Invalid package name: $pkg"
        return 1
    fi
done
```

## Files
- `lib/base/apt-utils.sh`

## Impact
Low risk (controlled build environment) but worth fixing for defense-in-depth.

---
_Migrated from docs/planned/improvements-roadmap.md - Item #6_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    # Item 7: Validate PATH Additions
    issue_number=$(create_issue "MEDIUM" \
        "Validate PATH Additions Before Modification" \
        "security" \
        "$(cat <<'EOF'
**Source**: OWASP Security Analysis (Nov 2025)
**Priority**: P2 (Medium)
**Effort**: 2 days

## Issue
PATH modifications aren't validated before being added to user profiles.

## Current Pattern
```bash
export PATH="/some/path:$PATH"  # No validation
```

## Recommendation
Validate directories before adding to PATH:
```bash
validate_and_add_to_path() {
    local dir="$1"

    # Check exists and is directory
    [ ! -d "$dir" ] && return 1

    # Check not world-writable
    [ -w "$dir" ] && [ "$(stat -c %a "$dir")" = "777" ] && return 1

    # Check ownership (root or current user)
    local owner=$(stat -c %U "$dir")
    [ "$owner" != "root" ] && [ "$owner" != "$USER" ] && return 1

    export PATH="$dir:$PATH"
}
```

## Files to Update
- All feature scripts that modify PATH
- Common in golang.sh, rust.sh, python-dev.sh, etc.

---
_Migrated from docs/planned/improvements-roadmap.md - Item #7_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    # Item 8: Improve kubectl Completion Validation
    issue_number=$(create_issue "MEDIUM" \
        "Improve kubectl Completion Validation" \
        "security" \
        "$(cat <<'EOF'
**Source**: OWASP Security Analysis (Nov 2025)
**Priority**: P2 (Medium)
**Effort**: 1 day

## Issue
kubectl completion is sourced directly without validation.

## Current Code
```bash
source <(kubectl completion bash)  # Unsanitized
```

## Recommendation
Generate to file, validate, then source:
```bash
local completion_file="/tmp/kubectl-completion-$$"
kubectl completion bash > "$completion_file"

# Validate file
if grep -q "unexpected" "$completion_file"; then
    log_error "Invalid completion script"
    return 1
fi

source "$completion_file"
rm -f "$completion_file"
```

## Files
- `lib/features/kubernetes.sh`

---
_Migrated from docs/planned/improvements-roadmap.md - Item #8_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    # Item 9: Review Terraform Provider Security
    issue_number=$(create_issue "MEDIUM" \
        "Review Terraform Provider Security" \
        "security" \
        "$(cat <<'EOF'
**Source**: OWASP Security Analysis (Nov 2025)
**Priority**: P2 (Medium)
**Effort**: 2 days

## Issue
Terraform providers are installed without checksum verification.

## Current Behavior
Provider plugins downloaded by `terraform init` aren't verified.

## Recommendation
Options:
1. Pin provider versions in lock file
2. Use Terraform's built-in checksum verification
3. Pre-download and verify providers

## Files
- `lib/features/terraform.sh`
- Related: Terragrunt installation (already has checksums)

---
_Migrated from docs/planned/improvements-roadmap.md - Item #9_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    # Item 10: Implement File Descriptor Limits
    issue_number=$(create_issue "MEDIUM" \
        "Implement File Descriptor Limits" \
        "security" \
        "$(cat <<'EOF'
**Source**: OWASP Security Analysis (Nov 2025)
**Priority**: P2 (Medium)
**Effort**: 1 day

## Issue
No limits on file descriptors during builds could lead to resource exhaustion.

## Recommendation
Set ulimits in container:
```dockerfile
# In Dockerfile
RUN ulimit -n 1024
```

Or in feature scripts:
```bash
ulimit -n 1024 2>/dev/null || true
```

## Impact
Prevents accidental resource exhaustion during builds.

---
_Migrated from docs/planned/improvements-roadmap.md - Item #10_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    # Item 11: Extract apt-utils.sh
    issue_number=$(create_issue "LOW" \
        "Extract apt-utils.sh to Shared Utility" \
        "architecture" \
        "$(cat <<'EOF'
**Source**: Architecture Review (Nov 2025)
**Priority**: P3 (Low - nice to have)
**Effort**: 1 day

## Current State
Each feature script sources apt-utils.sh functions inline or has copy-paste code.

## Recommendation
Create `lib/base/apt-utils.sh` as shared utility library.

## Benefits
- Reduce code duplication
- Centralize apt-related logic
- Easier maintenance

## Related
Similar to completed extractions:
- ✅ cache-utils.sh (completed)
- ✅ path-utils.sh (completed)

---
_Migrated from docs/planned/improvements-roadmap.md - Item #11_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    # Item 19: Add Operational Runbooks
    issue_number=$(create_issue "MEDIUM" \
        "Expand Operational Runbooks" \
        "operations" \
        "$(cat <<'EOF'
**Source**: Production Readiness Analysis (Nov 2025)
**Priority**: P2 (Medium)
**Effort**: 2-3 days

## Current State
Observability runbooks exist (completed with observability feature).

## Needed Runbooks
1. **Container Won't Start** - Debug container startup failures
2. **Build Failures** - Systematic build troubleshooting
3. **Slow Builds** - Performance investigation
4. **Cache Issues** - BuildKit cache problems
5. **Network Issues** - Connectivity troubleshooting
6. **Permission Issues** - File permission debugging

## Structure
```
docs/operations/runbooks/
├── README.md (index)
├── container-startup-failures.md
├── build-failures.md
├── slow-builds.md
├── cache-issues.md
├── network-issues.md
└── permission-issues.md
```

## Related
- Observability runbooks: docs/observability/runbooks/ (completed)

---
_Migrated from docs/planned/improvements-roadmap.md - Item #19_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    # Item 22: Consolidate Error Messages
    issue_number=$(create_issue "LOW" \
        "Consolidate Error Messages" \
        "anti-patterns" \
        "$(cat <<'EOF'
**Source**: Architecture Review (Nov 2025)
**Priority**: P3 (Low)
**Effort**: 2 days

## Issue
Error messages are inconsistent across feature scripts.

## Recommendation
Create `lib/base/error-messages.sh` with standardized messages:
```bash
error_package_not_found() {
    log_error "Package $1 not found in repositories"
    log_error "Try: apt-cache search $1"
}

error_checksum_mismatch() {
    log_error "Checksum verification failed for $1"
    log_error "Expected: $2"
    log_error "Got: $3"
}
```

## Benefits
- Consistent user experience
- Easier to add telemetry/metrics
- Centralized error handling

---
_Migrated from docs/planned/improvements-roadmap.md - Item #22_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    # Item 24: Reduce Log Verbosity
    issue_number=$(create_issue "LOW" \
        "Reduce Log Verbosity in Successful Builds" \
        "anti-patterns" \
        "$(cat <<'EOF'
**Source**: Architecture Review (Nov 2025)
**Priority**: P3 (Low)
**Effort**: 1-2 days

## Issue
Successful builds produce excessive log output.

## Current Behavior
Every step logs multiple INFO messages, making it hard to spot issues.

## Recommendation
Implement log levels:
```bash
LOG_LEVEL=${LOG_LEVEL:-INFO}  # Default: INFO

# Adjust verbosity
if [ "$LOG_LEVEL" = "ERROR" ]; then
    # Only errors
elif [ "$LOG_LEVEL" = "WARN" ]; then
    # Errors + warnings
elif [ "$LOG_LEVEL" = "INFO" ]; then
    # Normal verbosity
else
    # DEBUG: Full verbosity
fi
```

## Benefits
- Cleaner build logs
- Easier to spot problems
- Faster log parsing

---
_Migrated from docs/planned/improvements-roadmap.md - Item #24_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    # Item 25: Add Performance Benchmarks
    issue_number=$(create_issue "LOW" \
        "Add Performance Benchmarks" \
        "testing" \
        "$(cat <<'EOF'
**Source**: Architecture Review (Nov 2025)
**Priority**: P3 (Low)
**Effort**: 3-4 days

## Current State
No performance testing or benchmarks.

## Recommendation
Add benchmark suite:
```bash
tests/benchmarks/
├── benchmark-minimal.sh       # Minimal variant
├── benchmark-python-dev.sh    # Python dev
├── benchmark-full.sh          # Full polyglot
└── compare-results.sh         # Compare with baseline
```

## Metrics to Track
- Build time
- Image size
- Layer count
- Cache hit rate
- Memory usage

## Related
- Build metrics tracking (completed): docs/ci/build-metrics.md

---
_Migrated from docs/planned/improvements-roadmap.md - Item #25_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    # Item 26: Improve Debian Version Detection
    issue_number=$(create_issue "LOW" \
        "Improve Debian Version Detection Robustness" \
        "features" \
        "$(cat <<'EOF'
**Source**: Architecture Review (Nov 2025)
**Priority**: P3 (Low)
**Effort**: 1 day

## Current State
Debian version detection works but could be more robust.

## Current Implementation
Uses `/etc/os-release` parsing.

## Recommendation
Add fallback methods:
1. `/etc/os-release` (current)
2. `/etc/debian_version`
3. `lsb_release -cs`

## Benefits
- More reliable detection
- Better error messages
- Supports edge cases (sid, testing)

## Files
- `lib/base/apt-utils.sh`

---
_Migrated from docs/planned/improvements-roadmap.md - Item #26_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    # Item 28: Add Shell Completion Testing
    issue_number=$(create_issue "LOW" \
        "Add Shell Completion Testing" \
        "testing" \
        "$(cat <<'EOF'
**Source**: Architecture Review (Nov 2025)
**Priority**: P3 (Low)
**Effort**: 2 days

## Current State
No automated testing for shell completions.

## Recommendation
Test that completions:
1. Are installed
2. Load without errors
3. Provide expected completions

```bash
test_kubectl_completion() {
    source /etc/bash_completion.d/kubectl

    # Test completion function exists
    [ "$(type -t _kubectl)" = "function" ]

    # Test basic completion
    COMP_WORDS=(kubectl get)
    COMP_CWORD=2
    _kubectl
    # Verify COMPREPLY contains expected resources
}
```

## Files
- `tests/unit/features/test_kubernetes_completion.sh`

---
_Migrated from docs/planned/improvements-roadmap.md - Item #28_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    # Item 29: Add Startup Time Metrics
    issue_number=$(create_issue "LOW" \
        "Add Container Startup Time Metrics" \
        "features" \
        "$(cat <<'EOF'
**Source**: Architecture Review (Nov 2025)
**Priority**: P3 (Low)
**Effort**: 1 day

## Recommendation
Track container startup time:
```bash
# In entrypoint.sh
START_TIME=$(date +%s)

# After initialization
END_TIME=$(date +%s)
STARTUP_TIME=$((END_TIME - START_TIME))

echo "Container started in ${STARTUP_TIME}s"

# Expose as metric
echo "container_startup_seconds $STARTUP_TIME" >> /var/run/metrics.txt
```

## Benefits
- Identify slow initializations
- Track performance over time
- Optimize container startup

## Related
- Observability metrics (completed): lib/runtime/metrics-exporter.sh

---
_Migrated from docs/planned/improvements-roadmap.md - Item #29_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    # Item 30: Add Container Exit Handlers
    issue_number=$(create_issue "LOW" \
        "Add Container Exit Handlers" \
        "features" \
        "$(cat <<'EOF'
**Source**: Architecture Review (Nov 2025)
**Priority**: P3 (Low)
**Effort**: 1-2 days

## Recommendation
Add graceful shutdown handlers:
```bash
cleanup_on_exit() {
    log_message "Container shutting down..."

    # Flush metrics
    if [ -f /var/run/metrics.txt ]; then
        send_final_metrics || true
    fi

    # Save logs
    sync_logs || true

    log_message "Shutdown complete"
}

trap cleanup_on_exit EXIT TERM INT
```

## Benefits
- Clean shutdowns
- No lost metrics/logs
- Proper resource cleanup

---
_Migrated from docs/planned/improvements-roadmap.md - Item #30_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    # Item 31: Add Health Check Customization
    issue_number=$(create_issue "LOW" \
        "Add Health Check Customization" \
        "features" \
        "$(cat <<'EOF'
**Source**: Architecture Review (Nov 2025)
**Priority**: P3 (Low)
**Effort**: 2 days

## Current State
Healthcheck is fixed and not customizable.

## Recommendation
Allow custom health checks:
```bash
# /etc/healthcheck.d/custom-checks/
10-database.sh
20-redis.sh
30-external-api.sh

# healthcheck.sh runs all scripts
for check in /etc/healthcheck.d/custom-checks/*; do
    [ -x "$check" ] && "$check" || exit 1
done
```

## Benefits
- Application-specific health checks
- Modular health monitoring
- Easy to add checks

## Related
- Healthcheck guide: docs/healthcheck.md

---
_Migrated from docs/planned/improvements-roadmap.md - Item #31_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    # Item 33: Integration Test Coverage for Feature Combinations
    issue_number=$(create_issue "MEDIUM" \
        "Add Integration Tests for Feature Combinations" \
        "testing" \
        "$(cat <<'EOF'
**Source**: Architecture Review (Nov 2025)
**Priority**: P2 (Medium)
**Effort**: 4-5 days

## Current State
Integration tests cover individual features, not combinations.

## Issue
Feature interactions untested:
- Python + Node (polyglot)
- Docker + Kubernetes
- AWS + Terraform
- Multiple dev-tools together

## Recommendation
Add combination tests:
```bash
tests/integration/combinations/
├── test_python_node.sh
├── test_docker_kubernetes.sh
├── test_aws_terraform.sh
├── test_all_dev_tools.sh
└── test_cloud_stack.sh
```

## Benefits
- Catch interaction bugs
- Ensure compatibility
- Test real-world scenarios

## Priority
Medium - Would catch interaction bugs early

---
_Migrated from docs/planned/improvements-roadmap.md - Item #33_
EOF
)")

    if [ -n "$issue_number" ]; then
        created_issues+=("$issue_number")
        add_to_project "$project_number" "$issue_number"
    fi

    log_success "Created ${#created_issues[@]} issues"

    if [ ${#created_issues[@]} -gt 0 ]; then
        echo ""
        echo "Created issues:"
        for issue in "${created_issues[@]}"; do
            echo "  #$issue: https://github.com/$REPO/issues/$issue"
        done
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo ""
    echo "========================================"
    echo "Migrate Roadmap to GitHub Issues"
    echo "========================================"
    echo ""
    echo "Repository: $REPO"
    echo "Project: $PROJECT_TITLE"
    echo ""

    # Check if gh is authenticated
    if ! gh auth status >/dev/null 2>&1; then
        log_error "GitHub CLI is not authenticated"
        log_error "Run: gh auth login"
        exit 1
    fi

    log_success "GitHub CLI is authenticated"

    # Step 1: Create labels
    create_labels

    # Step 2: Create project
    local project_number
    project_number=$(create_project)

    # Step 3: Create issues
    create_issues "$project_number"

    echo ""
    log_success "Migration complete!"
    echo ""

    if ! $DRY_RUN; then
        echo "Next steps:"
        echo "  1. Review issues: gh issue list --repo $REPO --label migrated-from-roadmap"
        echo "  2. View project: https://github.com/users/joshjhall/projects/$project_number"
        echo "  3. Archive roadmap: git mv docs/planned/improvements-roadmap.md docs/planned/archived/"
        echo ""
    fi
}

main "$@"
