# Low Severity Security Issues

This page documents the low severity security issues identified during the OWASP
best practices audit and their resolutions.

______________________________________________________________________

## #7: Missing Input Validation on Version Numbers

**Priority**: LOW **Status**: COMPLETE (2025-11-09) **Actual Effort**: 2
hours

**Affected Files**:

- `lib/features/python.sh` (line 36)
- `lib/features/node.sh`
- `lib/features/rust.sh`
- `lib/features/golang.sh`
- `lib/features/ruby.sh`
- `lib/features/java-dev.sh`
- And other feature scripts with version variables

**Risk**: Shell injection if VERSION environment variables contain malicious
input. While build-time only, malicious build args could inject commands.

**Current Code**:

```bash
PYTHON_VERSION="${PYTHON_VERSION:-3.13.5}"
# Version used directly in URLs and file paths
```

**Recommended Fix**:

Create a shared validation function in `lib/base/version-validation.sh`:

```bash
#!/bin/bash
# Version validation utilities

# Validate semantic version format (X.Y.Z)
validate_semver() {
    local version="$1"
    local variable_name="${2:-VERSION}"

    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid $variable_name format: $version"
        log_error "Expected format: X.Y.Z (e.g., 3.13.5)"
        return 1
    fi

    return 0
}

# Validate version with optional patch (X.Y or X.Y.Z)
validate_version_flexible() {
    local version="$1"
    local variable_name="${2:-VERSION}"

    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        log_error "Invalid $variable_name format: $version"
        log_error "Expected format: X.Y or X.Y.Z (e.g., 20.0 or 3.13.5)"
        return 1
    fi

    return 0
}

# Validate Go version format (X.Y.Z or X.Y)
validate_go_version() {
    local version="$1"

    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        log_error "Invalid GO_VERSION format: $version"
        log_error "Expected format: X.Y or X.Y.Z (e.g., 1.21 or 1.21.5)"
        return 1
    fi

    return 0
}
```

**Usage in Feature Scripts**:

```bash
# Source validation utilities
source /tmp/build-scripts/base/version-validation.sh

# Validate Python version
PYTHON_VERSION="${PYTHON_VERSION:-3.13.5}"
validate_semver "$PYTHON_VERSION" "PYTHON_VERSION" || exit 1
```

**Testing Requirements**:

- Unit tests for validation functions
- Integration tests with invalid versions
- Verify proper error messages

______________________________________________________________________

## #8: Path Traversal via mkdir/chown Race Condition

**Priority**: LOW **Status**: COMPLETE (2025-11-09) **Actual Effort**: 1 hour

**Affected Files**:

- `lib/features/python.sh` (lines 88-92)
- `lib/features/node.sh`
- `lib/features/rust.sh`
- Other feature scripts creating cache directories

**Risk**: Permission issues or security context confusion during parallel builds
due to non-atomic operations.

**Current Code**:

```bash
log_command "Creating Python cache directories" \
    mkdir -p "${PIP_CACHE_DIR}" "${POETRY_CACHE_DIR}" "${PIPX_HOME}" "${PIPX_BIN_DIR}"

log_command "Setting cache directory ownership" \
    chown -R ${USER_UID}:${USER_GID} "${PIP_CACHE_DIR}" "${POETRY_CACHE_DIR}" "${PIPX_HOME}"
```

**Recommended Fix**:

```bash
# Create directories with correct ownership atomically using install
log_command "Creating Python cache directories with correct permissions" \
    bash -c "
    install -d -m 0755 -o ${USER_UID} -g ${USER_GID} '${PIP_CACHE_DIR}'
    install -d -m 0755 -o ${USER_UID} -g ${USER_GID} '${POETRY_CACHE_DIR}'
    install -d -m 0755 -o ${USER_UID} -g ${USER_GID} '${PIPX_HOME}'
    install -d -m 0755 -o ${USER_UID} -g ${USER_GID} '${PIPX_BIN_DIR}'
    "
```

**Benefits**:

- Atomic directory creation with ownership
- Explicit permission setting
- No race condition window

______________________________________________________________________

## #9: Command Injection via Completion Scripts

**Priority**: LOW **Status**: COMPLETE (2025-11-09) **Actual Effort**: 1 hour

**Affected Files**:

- `lib/features/kubernetes.sh` (line 358)
- `lib/features/lib/bashrc/dev-tools-extras.sh` (lines 37-39)

**Risk**: Command injection if tool outputs are compromised. Similar to eval but
harder to defend against.

**Current Code**:

```bash
source <(kubectl completion bash)
source <(just --completions bash)
```

**Recommended Fix**:

```bash
# Validate tool exists and generate completions to file for inspection
if command -v kubectl >/dev/null 2>&1; then
    COMPLETION_FILE="/tmp/kubectl-completion.bash"
    if kubectl completion bash > "$COMPLETION_FILE" 2>/dev/null; then
        # Basic validation - check file isn't suspiciously large or contains dangerous patterns
        if [ $(wc -c < "$COMPLETION_FILE") -lt 100000 ] && \
           ! grep -qE '(rm -rf|curl.*bash|wget.*bash)' "$COMPLETION_FILE"; then
            source "$COMPLETION_FILE"
        else
            log_warning "kubectl completion failed validation"
        fi
        rm -f "$COMPLETION_FILE"
    fi
fi
```

**Alternative Approach**:

```bash
# Generate and cache completions at build time instead of runtime
# In feature script during build:
if command -v kubectl >/dev/null 2>&1; then
    kubectl completion bash > /etc/bash_completion.d/kubectl
fi
```

______________________________________________________________________

## #10: Insufficient Path Sanitization in User Functions

**Priority**: LOW **Status**: COMPLETE (2025-11-09) **Actual Effort**: 2
hours

**Affected Files**:

- `lib/features/aws.sh` (lines 277-298)
- `lib/features/golang.sh` (lines 270-448)

**Risk**: Command injection via function parameters. User input passed to
commands without validation.

**Example from aws.sh**:

```bash
aws-assume-role() {
    local role_arn="$1"
    local session_name="${2:-cli-session-$(date +%s)}"

    local creds=$(aws sts assume-role \
        --role-arn "$role_arn" \
        --role-session-name "$session_name" \
        --output json)
```

**Recommended Fix**:

```bash
aws-assume-role() {
    local role_arn="$1"
    local session_name="${2:-cli-session-$(date +%s)}"

    # Validate ARN format
    if ! [[ "$role_arn" =~ ^arn:aws:iam::[0-9]{12}:role/[a-zA-Z0-9+=,.@_/-]+$ ]]; then
        echo "Error: Invalid IAM role ARN format" >&2
        echo "Expected: arn:aws:iam::<account-id>:role/<role-name>" >&2
        return 1
    fi

    # Sanitize session name (AWS allows alphanumeric and =,.@_-)
    session_name=$(echo "$session_name" | tr -cd 'a-zA-Z0-9=,.@_-' | cut -c1-64)

    if [ -z "$session_name" ]; then
        echo "Error: Invalid session name after sanitization" >&2
        return 1
    fi

    local creds=$(aws sts assume-role \
        --role-arn "$role_arn" \
        --role-session-name "$session_name" \
        --output json)
```

**Similar Fixes Needed**:

- Golang helper functions for module/package names
- Any other user functions accepting paths or identifiers
