# High and Medium Severity Security Issues

This page documents the high and medium severity security issues identified
during the OWASP best practices audit and their resolutions.

______________________________________________________________________

## HIGH SEVERITY ISSUES

### #1: Command Injection via Eval with GITHUB_TOKEN

**Priority**: CRITICAL **Status**: COMPLETE (2025-11-09) **Actual Effort**:
30 minutes

**Affected Files**:

- `lib/runtime/check-container-versions.sh` (lines 81, 90, 113)
- `lib/runtime/check-installed-versions.sh` (lines 78, 86)

**Risk**: Command injection if `GITHUB_TOKEN` environment variable contains
shell metacharacters. An attacker who can control `GITHUB_TOKEN` could inject
arbitrary shell commands.

**Fix**: Instead of using `eval` with curl, pass the token directly:

```bash
if [ -n "${GITHUB_TOKEN:-}" ]; then
    response=$(curl -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/${repo}/releases/latest")
else
    response=$(curl "https://api.github.com/repos/${repo}/releases/latest")
fi
```

**Testing Requirements**:

- Test with valid GITHUB_TOKEN
- Test without GITHUB_TOKEN
- Test with token containing special characters (verify no injection)

______________________________________________________________________

### #2: Passwordless Sudo for Non-Root User

**Priority**: HIGH (for production), MEDIUM (for dev) **Status**: COMPLETE
(2025-11-09) **Actual Effort**: 1 hour

**Affected Files**:

- `lib/base/user.sh` (lines 92-94)

**Risk**: Container escape or privilege escalation. While convenient for
development, full passwordless sudo violates least privilege principle.

**Fix**: Made sudo conditional via `ENABLE_PASSWORDLESS_SUDO` build argument:

```bash
if [ "${ENABLE_PASSWORDLESS_SUDO}" = "true" ]; then
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME}
    chmod 0440 /etc/sudoers.d/${USERNAME}
    log_message "WARNING: Passwordless sudo enabled (development mode)"
else
    log_message "Passwordless sudo disabled (production mode)"
fi
```

**Additional Work**:

- Update Dockerfile to add `ARG ENABLE_PASSWORDLESS_SUDO=true`
- Document security implications in README
- Add examples for production vs development builds

______________________________________________________________________

## MEDIUM SEVERITY ISSUES

### #3: Multiple Eval Usages for Shell Initialization

**Priority**: MEDIUM **Status**: COMPLETE (2025-11-09) **Actual Effort**: 2
hours

**Affected Files**:

- `lib/base/aliases.sh` (line 122)
- `lib/runtime/setup-paths.sh` (line 32)
- `lib/base/aliases.sh` (line 145 — zoxide)
- `lib/features/lib/bashrc/dev-tools-extras.sh` (lines 25, 37-39 — direnv, just)

**Risk**: Command injection if tool outputs are compromised.

**Fix**: Created a `safe_eval()` wrapper that validates command output before
executing, checking for suspicious patterns like `rm -rf`, piped downloads, or
command substitution.

**Testing Requirements**:

- Test normal initialization paths
- Mock compromised output with malicious patterns
- Verify proper error handling and logging

______________________________________________________________________

### #4: Unvalidated File Path Operations in Entrypoint

**Priority**: MEDIUM **Status**: COMPLETE (2025-11-09) **Actual Effort**: 45
minutes

**Affected Files**:

- `lib/runtime/entrypoint.sh` (lines 54-64, 80-92)

**Risk**: Path traversal via symlink attacks if startup scripts are compromised.

**Fix**: Added symlink checks and `realpath` validation to ensure scripts are in
the expected directory before execution:

```bash
for script in /etc/container/first-startup/*.sh; do
    if [ -f "$script" ] && [ ! -L "$script" ]; then
        script_realpath=$(realpath "$script")
        if [[ "$script_realpath" == /etc/container/first-startup/* ]]; then
            # Execute script
        else
            echo "WARNING: Skipping script outside expected directory: $script"
        fi
    fi
done
```

**Testing Requirements**:

- Test normal startup scripts
- Test with symlinks pointing outside directory
- Test with relative path manipulations

______________________________________________________________________

### #5: Claude Code Installer Not Verified

**Priority**: MEDIUM **Status**: COMPLETE (2025-11-09) **Actual Effort**: 30
minutes

**Affected Files**:

- `lib/features/claude-code-setup.sh` (lines 41-43)

**Risk**: Code execution from compromised download source. While installer
claims internal verification, the installer script itself is not verified.

**Fix**: Added checksum verification for the downloaded installer using the
existing `download_and_verify` infrastructure. Two approaches available:

- **Option A**: Calculate checksum at download time (more flexible)
- **Option B**: Pin to specific version with known checksum (more secure)

______________________________________________________________________

### #6: Sensitive Data Exposure in 1Password Examples

**Priority**: MEDIUM **Status**: COMPLETE (2025-11-09) **Actual Effort**: 1
hour

**Affected Files**:

- `lib/features/op-cli.sh` (lines 184, 187, 216)

**Risk**: Credential exposure via command history, process listings, or debug
logs when using shell evaluation with credentials.

**Fix**: Created a safer `op-env-safe()` helper function that disables command
echoing before processing secrets and uses direct JSON parsing instead of
shell evaluation.

**Additional Work**:

- Update documentation and examples
- Add warnings about credential exposure
- Consider deprecating old `op-env` pattern
