# Plan: Issue #188 — Refactor check-container-versions.sh

## Context

`lib/runtime/check-container-versions.sh` (642 lines) has 6 audit findings:
16x duplicated check blocks, 4 bare `ggrep` calls that fail on Linux,
inconsistent arg parsing, a hardcoded Rust fallback, a debug comment, and
`get_latest_*` functions that belong in the shared library. This refactoring
eliminates duplication, fixes portability, and moves shared logic to
`version-api.sh`.

## Modified Files

1. `lib/runtime/check-container-versions.sh` — primary refactoring target
1. `lib/runtime/lib/version-api.sh` — receives migrated functions
1. `tests/unit/runtime/check-container-versions.sh` — update assertions

## Step 1: Quick standalone fixes in `check-container-versions.sh`

### 1a. Fix Rust hardcoded fallback (line 119)

```bash
# Before:
echo "1.88.0"  # Fallback to known version
# After:
echo "unknown"
```

### 1b. Remove debug comment (lines 591-592)

Delete:

```bash
# Debug: check array size
# echo "Debug: VERSION_STATUS has ${#VERSION_STATUS[@]} elements"
```

### 1c. Align arg parsing with `check-installed-versions.sh` pattern

Replace `OUTPUT_FORMAT="${1:-text}"` (line 48) with:

```bash
output_format="text"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) output_format="json"; shift ;;
        --help|-h)
            command head -n 16 "$0" | command grep "^#" | command sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done
```

Then rename all `OUTPUT_FORMAT` → `output_format` and change comparisons
from `"--json"` to `"json"` throughout (7 occurrences at lines 158, 195,
281, 350, 441, 582, 622).

## Step 2: Replace 4 bare `ggrep` with `_vapi_grep`

`_vapi_grep` is already available from the sourced `version-api.sh`.

| Line | Context                            | Change                 |
| ---- | ---------------------------------- | ---------------------- |
| 88   | `get_latest_ruby` rate limit check | `ggrep` → `_vapi_grep` |
| 115  | `get_latest_rust` fallback scrape  | `ggrep` → `_vapi_grep` |
| 148  | `extract_version` function         | `ggrep` → `_vapi_grep` |
| 614  | Summary rate-limit check           | `ggrep` → `_vapi_grep` |

## Step 3: Move functions to `lib/runtime/lib/version-api.sh`

Move these 8 functions from `check-container-versions.sh` (lines 74-149)
to `version-api.sh`, appended after existing `get_cran_version()` and
before `compare_version()`:

- `get_latest_python()` — uses endoflife.date API
- `get_latest_ruby()` — GitHub API with rate limit detection
- `get_latest_node()` — nodejs.org dist JSON (LTS filter)
- `get_latest_go()` — go.dev VERSION endpoint
- `get_latest_rust()` — GitHub + forge fallback (with "unknown" fix)
- `get_latest_java_lts()` — hardcoded "21"
- `get_latest_mojo()` — hardcoded "25.4"
- `extract_version()` — `_vapi_grep -oP` wrapper

All functions use `_vapi_grep` (already fixed in Step 2).

## Step 4: Extract `check_tool()` helper to replace 20 duplicate blocks

### 4a. Define `check_tool()` in `check-container-versions.sh`

```bash
# Check a pinned version against latest available.
# Args: <key> <print_name> <file> <pattern> <getter_fn> [getter_args...]
# If current version is "latest", short-circuits to status "up-to-date".
check_tool() {
    local key="$1" print_name="$2" file="$3" pattern="$4" getter_fn="$5"
    shift 5
    [ -f "$file" ] || return 0
    local current latest status
    current=$(extract_version "$file" "$pattern")
    if [ "$current" = "latest" ]; then
        latest="latest"
        status="up-to-date"
    else
        latest=$("$getter_fn" "$@")
        status=$(compare_version "$current" "$latest")
    fi
    CURRENT_VERSIONS["$key"]="$current"
    LATEST_VERSIONS["$key"]="$latest"
    VERSION_STATUS["$key"]="$status"
    print_result "$print_name" "$current" "$latest" "$status"
}
```

### 4b. Define thin wrapper functions for common patterns

```bash
# GitHub release tag with 'v' prefix stripped
_get_github_release_stripped() {
    get_github_release "$1" "${2:-}" | command sed 's/^v//'
}

# kubectl: custom stable.txt endpoint, major.minor only
_get_latest_kubectl() {
    command curl -Lsf https://dl.k8s.io/release/stable.txt \
        | command sed 's/^v//' | command cut -d. -f1,2 || echo "unknown"
}

# glab: GitLab API (not GitHub)
_get_latest_glab() {
    command curl -sf "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases" \
        | jq -r '.[0].tag_name' | command sed 's/^v//' || echo "unknown"
}
```

### 4c. Replace all 20 duplicate blocks

**Languages section** (replaces lines 200-275):

```bash
check_tool "Python"  "Python"     "$FEATURES_DIR/python.sh"  'PYTHON_VERSION="?\$\{PYTHON_VERSION:-\K[^"}]+' get_latest_python
check_tool "Ruby"    "Ruby"       "$FEATURES_DIR/ruby.sh"    'RUBY_VERSION="?\$\{RUBY_VERSION:-\K[^"}]+'    get_latest_ruby
check_tool "Node.js" "Node.js"    "$FEATURES_DIR/node.sh"    'NODE_VERSION="?\$\{NODE_VERSION:-\K[^"}]+'    get_latest_node
check_tool "Go"      "Go"         "$FEATURES_DIR/golang.sh"  'GO_VERSION="?\$\{GO_VERSION:-\K[^"}]+'        get_latest_go
check_tool "Rust"    "Rust"       "$FEATURES_DIR/rust.sh"    'RUST_VERSION="?\$\{RUST_VERSION:-\K[^"}]+'    get_latest_rust
check_tool "Java"    "Java (LTS)" "$FEATURES_DIR/java.sh"    'JAVA_VERSION="?\$\{JAVA_VERSION:-\K[^"}]+'    get_latest_java_lts
check_tool "Mojo"    "Mojo"       "$FEATURES_DIR/mojo.sh"    'MOJO_VERSION="?\$\{MOJO_VERSION:-\K[^"}]+'    get_latest_mojo
```

**Dev tools section** (replaces lines 288-344):

```bash
if [ -f "$FEATURES_DIR/dev-tools.sh" ]; then
    check_tool "direnv"  "direnv"  "$FEATURES_DIR/dev-tools.sh" 'DIRENV_VERSION="\K[^"]+'  _get_github_release_stripped "direnv/direnv"
    check_tool "lazygit" "lazygit" "$FEATURES_DIR/dev-tools.sh" 'LAZYGIT_VERSION="\K[^"]+' _get_github_release_stripped "jesseduffield/lazygit"
    check_tool "delta"   "delta"   "$FEATURES_DIR/dev-tools.sh" 'DELTA_VERSION="\K[^"]+'   _get_github_release_stripped "dandavison/delta"
    check_tool "mkcert"  "mkcert"  "$FEATURES_DIR/dev-tools.sh" 'MKCERT_VERSION="\K[^"]+'  _get_github_release_stripped "FiloSottile/mkcert"
    check_tool "act"     "act"     "$FEATURES_DIR/dev-tools.sh" 'ACT_VERSION="\K[^"]+'     _get_github_release_stripped "nektos/act"
    check_tool "glab"    "glab"    "$FEATURES_DIR/dev-tools.sh" 'GLAB_VERSION="\K[^"]+'    _get_latest_glab
fi
```

**Cloud/infra section** (replaces lines 357-436):

```bash
if [ -f "$FEATURES_DIR/terraform.sh" ]; then
    check_tool "Terraform"      "Terraform"      "$FEATURES_DIR/terraform.sh" 'TERRAFORM_VERSION="?\K[^"]+'                          _get_github_release_stripped "hashicorp/terraform"
    check_tool "Terragrunt"     "Terragrunt"     "$FEATURES_DIR/terraform.sh" 'TERRAGRUNT_VERSION="?\$\{TERRAGRUNT_VERSION:-\K[^"]+' _get_github_release_stripped "gruntwork-io/terragrunt"
    check_tool "terraform-docs" "terraform-docs" "$FEATURES_DIR/terraform.sh" 'TFDOCS_VERSION="?\$\{TFDOCS_VERSION:-\K[^"}]+'        _get_github_release_stripped "terraform-docs/terraform-docs"
fi

if [ -f "$FEATURES_DIR/kubernetes.sh" ]; then
    check_tool "kubectl" "kubectl" "$FEATURES_DIR/kubernetes.sh" 'KUBECTL_VERSION="?\$\{KUBECTL_VERSION:-\K[^"}]+' _get_latest_kubectl
    check_tool "k9s"    "k9s"    "$FEATURES_DIR/kubernetes.sh"  'K9S_VERSION="?\$\{K9S_VERSION:-\K[^"}]+'         _get_github_release_stripped "derailed/k9s"
    check_tool "krew"   "krew"   "$FEATURES_DIR/kubernetes.sh"  'KREW_VERSION="?\$\{KREW_VERSION:-\K[^"}]+'       _get_github_release_stripped "kubernetes-sigs/krew"
    check_tool "Helm"   "Helm"   "$FEATURES_DIR/kubernetes.sh"  'HELM_VERSION="?\$\{HELM_VERSION:-\K[^"}]+'       _get_github_release_stripped "helm/helm"
fi
```

The `current="latest"` special case for Terraform and Helm is handled
automatically by `check_tool`'s short-circuit logic.

Section headers (Development Tools:, Cloud & Infrastructure Tools:) and the
informational tools section (lines 438-576) remain unchanged.

## Step 5: Update tests

File: `tests/unit/runtime/check-container-versions.sh`

### 5a. Redirect function assertions to `version-api.sh`

Add a shared lib variable:

```bash
SHARED_LIB="$PROJECT_ROOT/lib/runtime/lib/version-api.sh"
```

Update these tests to check `SHARED_LIB` instead of `SOURCE_FILE`:

- `test_cv_get_latest_python_func`
- `test_cv_get_latest_node_func`
- `test_cv_get_latest_go_func`
- `test_cv_extract_version_func`

### 5b. Add test for new `check_tool` helper

```bash
test_cv_check_tool_func() {
    assert_file_contains "$SOURCE_FILE" "check_tool()" \
        "check-container-versions.sh defines check_tool function"
}
```

## What Does NOT Change

- `lib/runtime/check-installed-versions.sh` — unchanged
- Informational tools section (Python/Rust/Ruby/R dev tools arrays and loops)
- Summary section logic (just `output_format` rename + debug comment removal)
- JSON output serialization
- Section header formatting and output ordering

## Verification

```bash
./tests/run_unit_tests.sh
```

**After all implementation and testing is complete**, invoke `/next-issue-ship`
to commit, deliver, and close the issue.
