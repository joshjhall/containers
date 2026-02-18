---
description: Custom test framework API and patterns for tests/. Use when writing unit tests, integration tests, or test assertions for container build features.
---

# Test Framework Reference

## Running Tests

```bash
./tests/run_all.sh              # Unit + integration
./tests/run_unit_tests.sh       # Unit only (no Docker)
./tests/run_integration_tests.sh           # All integration tests
./tests/run_integration_tests.sh python_dev # Single integration test
./tests/test_feature.sh golang             # Quick feature test
```

## Unit Test Structure

```bash
#!/usr/bin/env bash
# Unit tests for lib/features/<feature>.sh
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"
init_test_framework

test_suite "Feature Name Tests"

setup() {
    export TEST_TEMP_DIR="$RESULTS_DIR/test-feature"
    mkdir -p "$TEST_TEMP_DIR"
    # Mock environment variables
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
}

test_something() {
    assert_equals "expected" "$actual" "Description"
}

run_test test_something "Description of what is tested"
generate_report
```

## Integration Test Structure

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../framework.sh"
init_test_framework

export BUILD_CONTEXT="$CONTAINERS_DIR"
test_suite "Feature Integration"

test_feature_builds() {
    local image="test-feature-$$"

    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test \
        --build-arg INCLUDE_FEATURE=true \
        -t "$image"

    assert_file_in_image "$image" "/path/to/expected/file"
    assert_command_in_container "$image" "command --version" "expected output"
}

run_test test_feature_builds "Feature builds and installs correctly"
generate_report
```

## Assertion API

### Core (`assertions/core.sh`)

| Assertion                        | Usage                                   | Purpose             |
| -------------------------------- | --------------------------------------- | ------------------- |
| `assert_true cmd args "msg"`     | `assert_true [ -f "$f" ] "File exists"` | Command exits 0     |
| `assert_false cmd args "msg"`    | `assert_false [ -d "$d" ] "Dir gone"`   | Command exits non-0 |
| `assert_exit_code exp act "msg"` | `assert_exit_code 2 $? "Returns 2"`     | Exact exit code     |
| `pass_test`                      | `pass_test`                             | Manually pass       |
| `fail_test "reason"`             | `fail_test "Not implemented"`           | Manually fail       |
| `skip_test "reason"`             | `skip_test "Docker unavailable"`        | Skip with reason    |

### Equality (`assertions/equality.sh`)

| Assertion                              | Usage            |
| -------------------------------------- | ---------------- |
| `assert_equals "exp" "$act" "msg"`     | Values are equal |
| `assert_not_equals "bad" "$act" "msg"` | Values differ    |

### String (`assertions/string.sh`)

| Assertion                                   | Usage             |
| ------------------------------------------- | ----------------- |
| `assert_contains "$hay" "needle" "msg"`     | Substring present |
| `assert_not_contains "$hay" "needle" "msg"` | Substring absent  |
| `assert_matches "$str" "regex" "msg"`       | Regex matches     |
| `assert_starts_with "$str" "pre" "msg"`     | Prefix check      |
| `assert_ends_with "$str" "suf" "msg"`       | Suffix check      |
| `assert_empty "$val" "msg"`                 | Value is empty    |
| `assert_not_empty "$val" "msg"`             | Value has content |

### File (`assertions/file.sh`)

| Assertion                                      | Usage                |
| ---------------------------------------------- | -------------------- |
| `assert_file_exists "$path" "msg"`             | File exists          |
| `assert_file_not_exists "$path" "msg"`         | File absent          |
| `assert_dir_exists "$path" "msg"`              | Directory exists     |
| `assert_executable "$path" "msg"`              | File is executable   |
| `assert_file_contains "$path" "pattern" "msg"` | Grep pattern in file |
| `assert_file_not_contains "$path" "pat" "msg"` | Pattern absent       |

### Docker (`assertions/docker.sh`)

| Assertion                                        | Usage                 |
| ------------------------------------------------ | --------------------- |
| `assert_build_succeeds "Dockerfile" args...`     | Build exits 0         |
| `assert_build_fails "Dockerfile" args...`        | Build exits non-0     |
| `assert_image_exists "$img" "msg"`               | Image in registry     |
| `assert_file_in_image "$img" "/path" "msg"`      | File in image         |
| `assert_dir_in_image "$img" "/path" "msg"`       | Dir in image          |
| `assert_command_in_container "$img" "cmd" "exp"` | Run cmd, check output |
| `assert_command_fails_in_container "$img" "cmd"` | Cmd fails in image    |
| `assert_executable_in_path "$img" "cmd"`         | Cmd in image PATH     |
| `assert_env_var_set "$img" "VAR" "val"`          | Env var set in image  |
| `assert_image_size_less_than "$img" MB`          | Image under size      |

### Helpers (`framework/helpers.sh`)

| Function                                         | Purpose                                   |
| ------------------------------------------------ | ----------------------------------------- |
| `capture_result cmd args`                        | Sets `$TEST_OUTPUT` and `$TEST_EXIT_CODE` |
| `build_test_image "tag" args...`                 | Build + track for cleanup                 |
| `exec_in_container "$img" "cmd"`                 | Run command in throwaway container        |
| `get_image_size_mb "$img"`                       | Image size in MB                          |
| `wait_for_container "$name" timeout "check_cmd"` | Wait for ready                            |

## Conventions

- Unit tests: `tests/unit/<category>/<feature>.sh`
- Integration tests: `tests/integration/builds/test_<feature>.sh`
- Namespace prefixes: `tf_` (framework), `tfc_` (core), `tfe_` (equality), `tfs_` (string), `tff_` (file), `tfh_` (helpers)
- Image tags in integration tests: `"test-<feature>-$$"` (PID suffix avoids collisions)
- `BUILD_CONTEXT` must be set to `$CONTAINERS_DIR` for standalone builds
- Always end test files with `generate_report`

## When NOT to Use

- Testing non-container code (use the project's own test framework)
- Docker commands outside tests (use the integration test framework, not raw `docker build`)
