# God Modules: High Fan-In Infrastructure Modules

## Overview

`feature-header.sh` and `logging.sh` are **infrastructure modules** with high
fan-in (many dependents). This is expected and intentional — every feature
installation script sources them for consistent environment setup and logging.

High fan-in is acceptable for infrastructure modules when:

- The API surface is stable and well-documented
- Changes follow a careful protocol (see below)
- Test coverage protects against regressions
- The module is decomposed into sub-modules where appropriate

## feature-header.sh API Contract

**Location**: `lib/base/feature-header.sh`
**Fan-in**: ~42 dependents (all feature scripts in `lib/features/`)

### Include Guard

```bash
_FEATURE_HEADER_LOADED=1  # Prevents re-execution when sourced multiple times
```

### Exported Variables

| Variable         | Default              | Source                          |
| ---------------- | -------------------- | ------------------------------- |
| `DEBIAN_VERSION` | detected             | `/etc/os-release` (Debian only) |
| `UBUNTU_VERSION` | detected             | `/etc/os-release` (Ubuntu only) |
| `USERNAME`       | `developer`          | `/tmp/build-env` or detection   |
| `USER_UID`       | `1000`               | `/tmp/build-env` `ACTUAL_UID`   |
| `USER_GID`       | `1000`               | `/tmp/build-env` `ACTUAL_GID`   |
| `WORKING_DIR`    | `/workspace/project` | `/tmp/build-env` or default     |

### Sourced Sub-Modules

| Module               | Functions / Exports Provided                                     |
| -------------------- | ---------------------------------------------------------------- |
| `os-validation.sh`   | `DEBIAN_VERSION`, `UBUNTU_VERSION` (Bash/OS validation)          |
| `user-env.sh`        | `USERNAME`, `USER_UID`, `USER_GID`, `WORKING_DIR`                |
| `arch-utils.sh`      | `map_arch`, `map_arch_or_skip`                                   |
| `cleanup-handler.sh` | `cleanup_on_interrupt`, `register_cleanup`, `unregister_cleanup` |
| `logging.sh`         | Full logging system (see below)                                  |
| `bashrc-helpers.sh`  | `write_bashrc_content`                                           |
| `feature-utils.sh`   | `create_symlink`, `create_secure_temp_dir`                       |

### Functions

```bash
create_symlink <target> <link_name> [description]
    # Creates symlink, makes target executable, verifies link.
    # Returns 1 if target or link_name is empty.

create_secure_temp_dir
    # Returns path to a new temp dir with 755 permissions.
    # Dir is registered for automatic cleanup via cleanup-handler.sh.
```

### Change Protocol

1. Any change to exported variables or function signatures is a **breaking change**
1. Run `./tests/run_unit_tests.sh` — all feature-header tests must pass
1. Run `./tests/run_integration_tests.sh` for at least 2 feature builds
1. Update this document if the API surface changes

## logging.sh API Contract

**Location**: `lib/base/logging.sh`
**Fan-in**: ~32 dependents (via feature-header.sh)

### Module Hierarchy

```text
logging.sh (orchestrator)
├── shared/export-utils.sh      — protected_export utility
├── shared/logging.sh           — core log levels, _should_log, basic log functions
├── feature-logging.sh          — log_feature_start, log_command, log_feature_end
├── message-logging.sh          — log_message, log_info, log_debug, log_error, log_warning
├── json-logging.sh             — JSON output (optional, ENABLE_JSON_LOGGING=true)
├── secret-scrubbing.sh         — scrub_secrets for sensitive data
└── shared/safe-eval.sh         — safe_eval utility
```

### Public Functions

**Feature Lifecycle** (from `feature-logging.sh`):

```bash
log_feature_start <feature_name> [version]
    # Initialize logging for a feature. Creates log/error/summary files.
    # Resets COMMAND_COUNT, ERROR_COUNT, WARNING_COUNT to 0.

log_command <description> <command...>
    # Execute command with output capture. Increments COMMAND_COUNT.
    # Extracts ERROR/WARNING patterns from output into counters.

log_feature_end
    # Finalize logging, generate summary, append to master-summary.log.
    # Resets CURRENT_FEATURE, CURRENT_LOG_FILE, etc.

log_feature_summary --feature <name> --version <ver> [--tools ...] [--paths ...] [--env ...] [--commands ...] [--next-steps ...]
    # Output user-friendly configuration summary.
```

**Message Logging** (from `message-logging.sh`, overrides `shared/logging.sh`):

```bash
log_message <msg>    # INFO level, writes to CURRENT_LOG_FILE or stdout
log_info <msg>       # Alias for log_message
log_debug <msg>      # DEBUG level only (LOG_LEVEL=DEBUG)
log_error <msg>      # Always shown, increments ERROR_COUNT
log_warning <msg>    # WARN level, increments WARNING_COUNT
```

**Internal Functions** (not part of the public API):

```bash
_get_log_level_num   # Convert LOG_LEVEL string to numeric
_should_log <level>  # Check if message at given level should be logged
_get_last_command_start_line <log_file>  # Find last command marker
_count_patterns_since <log_file> <start_line> <pattern>  # Count regex matches
```

**Utility** (from `shared/safe-eval.sh`):

```bash
safe_eval <command_string>  # Evaluate a command string safely
```

### Exported State Variables

| Variable               | Reset By                              | Description         |
| ---------------------- | ------------------------------------- | ------------------- |
| `CURRENT_FEATURE`      | `log_feature_start`/`log_feature_end` | Active feature name |
| `CURRENT_LOG_FILE`     | `log_feature_start`/`log_feature_end` | Path to current log |
| `CURRENT_ERROR_FILE`   | `log_feature_start`/`log_feature_end` | Path to error log   |
| `CURRENT_SUMMARY_FILE` | `log_feature_start`/`log_feature_end` | Path to summary     |
| `COMMAND_COUNT`        | `log_feature_start`                   | Commands executed   |
| `ERROR_COUNT`          | `log_feature_start`                   | Errors detected     |
| `WARNING_COUNT`        | `log_feature_start`                   | Warnings detected   |
| `BUILD_LOG_DIR`        | initialization                        | Log directory path  |

### Change Protocol

1. Changes to public functions or exported state are **breaking changes**
1. Sub-module changes should be tested via the parent `logging.sh` interface
1. Run `./tests/run_unit_tests.sh` — all logging tests must pass
1. Update this document if the public function surface changes

## Coupling Analysis

### Current Fan-In Counts

Measured by `tests/unit/base/coupling-guard.sh`:

| Module              | Dependents | Expected Range | Category                            |
| ------------------- | ---------- | -------------- | ----------------------------------- |
| `feature-header.sh` | ~42        | 30–55          | Feature scripts, base modules       |
| `logging.sh`        | ~32        | 25–45          | Via feature-header.sh, base modules |

### Dependent Categories

**feature-header.sh** dependents:

- `lib/features/*.sh` — all feature installation scripts (~35)
- `lib/base/*.sh` — base modules that need user/OS context (~7)

**logging.sh** dependents:

- Indirectly via `feature-header.sh` (all feature scripts)
- Directly by `lib/base/` modules that need logging before feature-header

### When to Investigate

The coupling guard test (`tests/unit/base/coupling-guard.sh`) will fail if
fan-in exceeds the expected ranges. If it fails:

1. Check if new feature scripts were added (expected growth)
1. Verify no non-feature scripts are unnecessarily sourcing these modules
1. If the growth is justified, update the expected ranges in the test
