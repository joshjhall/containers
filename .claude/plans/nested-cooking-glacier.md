# Issue #251: Undocumented path conventions and auto-init side effect

## Context

Audit finding (architecture scanner). Three locations lack explanatory comments
that could cause contributors to make incorrect "fixes":

1. `lib/base/setup-bashrc.d.sh:57` and `lib/base/user.sh:166` reference
   `/opt/container-runtime/shared/` inside build-time scripts. This looks wrong
   but is correct — these scripts write shell snippets (heredocs) that execute
   at **runtime**, not build-time. The Dockerfile copies `lib/shared/` →
   `/opt/container-runtime/shared/` (line 570), so the runtime path is correct.
   Without a comment, a contributor might "fix" these to `/tmp/build-scripts/`.

1. `lib/runtime/audit-logger.sh:319-327` auto-initializes (`mkdir`, `touch`,
   JSON write) when sourced. This breaks the project convention of side-effect-free
   sourcing. The entrypoint (line 84-86) documents this exception, but the module
   itself does not.

## Plan

### 1. `lib/base/setup-bashrc.d.sh` — Add path convention comment (line ~52)

Add a comment before the heredoc block (inside the `write_bashrc_content` call)
explaining that the `/opt/container-runtime/shared/` path is intentional because
this snippet runs at container runtime, not build-time.

### 2. `lib/base/user.sh` — Add path convention comment (line ~165)

Same pattern: add a comment above the `/opt/container-runtime/shared/` source
line explaining the build-time vs runtime distinction.

### 3. `lib/runtime/audit-logger.sh` — Add contract comment (line ~319)

Add a comment block above the auto-initialization section documenting:

- This is an intentional exception to the side-effect-free sourcing convention
- Why: audit logging must be initialized before any events can be recorded
- The `AUDIT_INITIALIZED` guard ensures it only runs once
- The entrypoint relies on this behavior (cross-reference)

## Files to modify

- `lib/base/setup-bashrc.d.sh` (~line 52)
- `lib/base/user.sh` (~line 165)
- `lib/runtime/audit-logger.sh` (~line 319)

## Verification

```bash
# Shellcheck all 3 files
shellcheck lib/base/setup-bashrc.d.sh lib/base/user.sh lib/runtime/audit-logger.sh

# Run existing unit tests to ensure no regressions
bash tests/run_unit_tests.sh
```

## After implementation

**After all implementation and testing is complete**, invoke `/next-issue-ship`
to commit, deliver, and close the issue.
