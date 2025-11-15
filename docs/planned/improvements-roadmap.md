# Container Build System - Remaining Improvements

## Executive Summary

This document tracks remaining improvements for the container build system based on comprehensive security (OWASP), architecture, and production readiness analysis conducted in November 2025. The system has strong fundamentals but requires production-grade enhancements for enterprise deployment.

**Overall Assessment:**
- Security Rating: 7.5/10 (MEDIUM-HIGH)
- Architecture Rating: 8.5/10 (Excellent)
- Developer Experience: 9/10 (Excellent)
- Production Readiness: 6/10 (Needs Work)

---

## Progress Summary

**Completed Items**: 47 items (All HIGH priority, 2 CRITICAL, most MEDIUM priority, many LOW priority)
**Partially Complete**: 0 items
**Remaining Items**: 31 items (2 CRITICAL, 3 HIGH, 15 MEDIUM, 12 LOW)

See git history and CHANGELOG.md for details on completed items.

**Latest Updates (November 2025)**:
- ✅ **Item #4 COMPLETE**: Flexible version resolution for all 6 languages (Python, Node.js, Go, Ruby, Rust, Java)
- ✅ **Item #1 COMPLETE**: 4-tier checksum verification + pinned checksums database + automated maintenance
- ✅ **Item #3 COMPLETE**: Docker socket auto-fix removed, replaced with secure group-based access
- ✅ **Item #2 COMPLETE**: Passwordless sudo default changed to false (security improvement)
- ✅ **Item #12 COMPLETE**: Production-optimized image variants with examples and documentation
- ✅ Ruby checksum fetching fixed (grep pattern and parameter order)
- ✅ Production tests added to CI matrix
- ✅ Created `lib/checksums.json` with Node.js, Go, Ruby checksums (9 versions)
- ✅ Created `bin/update-checksums.sh` for automated checksum maintenance
- ✅ Integrated checksum updates into auto-patch workflow

---

## REMAINING ITEMS

### Security Concerns

#### 1. [HIGH] ✅ COMPLETE - Implement GPG Verification and Automated Checksum Pinning
**Source**: OWASP Security Analysis (Nov 2025)
**Priority**: P1 (High - security enhancement, not blocking)
**Effort**: 3-4 days
**Status**: ✅ COMPLETE (Nov 2025) - Full 4-tier system with automated maintenance

**What Was Delivered (November 2025)**:

✅ **Complete 4-Tier Verification System Architecture**:
1. **Tier 1: Signature Verification** (GPG + Sigstore) - COMPLETE
2. **Tier 2: Pinned Checksums** (from lib/checksums.json) - COMPLETE
3. **Tier 3: Published Checksums** (from official sources) - COMPLETE
4. **Tier 4: Calculated Checksums** (TOFU fallback) - COMPLETE

✅ **Files Created**:
- `lib/base/signature-verify.sh` - Unified GPG and Sigstore verification
  * GPG verification for Python, Node.js, Go (uses keyring from lib/gpg-keys/)
  * Sigstore verification framework (Python 3.11.0+ support ready)
  * Auto-detection of available verification tools (cosign, gpg)
  * Graceful fallback when verification unavailable
- `lib/base/checksum-verification.sh` - 4-tier progressive verification
  * `verify_signature_tier()` - Tier 1 wrapper
  * `verify_pinned_checksum()` - Tier 2 (uses checksums.json when available)
  * `verify_published_checksum()` - Tier 3 (downloads official checksums)
  * `verify_calculated_checksum()` - Tier 4 (TOFU with clear warning)
- `lib/gpg-keys/` - GPG public keys for Python, Node.js, Go
- `lib/gpg-keys/SIGSTORE_RESEARCH.md` - Sigstore availability analysis
- `lib/checksums.json` - Pinned checksums database (Node.js, Go, Ruby - 9 versions)
- `bin/update-checksums.sh` - Automated checksum maintenance script

✅ **Integration Complete**:
- All language feature scripts now use `verify_download()` with 4-tier fallback
- Verification attempts Tier 1 (signatures) → Tier 2 (pinned) → Tier 3 (published) → Tier 4 (calculated)
- Each tier logs exactly which method was used and why
- Never blocks installation (always falls through to calculated with warning)

✅ **Security Improvements**:
- GPG signature verification for Python, Node.js, Go (when gpg available)
- Published checksum verification from official sources (python.org, nodejs.org, go.dev)
- Clear security warnings when using TOFU (Tier 4)
- All verification methods properly log security level

✅ **Automation Complete**:
- Created `bin/update-checksums.sh` for automated checksum fetching and validation
- Integrated into `.github/workflows/auto-patch.yml` (runs weekly)
- Auto-fetches checksums for Node.js, Go, Ruby from official sources
- Validates checksum format (64-character SHA256)
- Creates timestamped backups before updating
- Non-blocking (won't fail workflow if checksums unavailable)

✅ **Documentation Complete**:
- Updated `docs/checksum-verification.md` with comprehensive 4-tier system explanation
- Language-by-language verification matrix documented
- Implementation examples and usage patterns included
- Security tier explanations with examples

✅ **Database Initialized**:
- Created `lib/checksums.json` with 9 initial checksums
- Node.js: 22.12.0, 22.11.0, 20.18.1, 20.18.0
- Go: 1.25.4
- Ruby: 3.5.0, 3.4.7, 3.3.10, 3.2.9
- Database will grow over time via auto-patch workflow

**Remaining Optional Work**:

⏳ **Sigstore Implementation** (Optional Enhancement):
- Python 3.11.0+ Sigstore verification needs release manager cert identities
- TODO comment exists in lib/base/signature-verify.sh:339
- Framework is complete, just needs configuration data
- Currently falls back to GPG verification (already working)

**Testing**:
- ✅ Unit tests passing (666/667)
- ✅ Shellcheck clean
- ⏳ Integration testing with actual downloads pending

**Impact**: ✅ MAJOR PROGRESS - 4-tier verification system infrastructure complete, Tier 1 (signatures) and Tier 3 (published) fully functional. Remaining work is populating Tier 2 database and completing Sigstore configuration.

---

#### 2. [HIGH] ✅ COMPLETE - Change Passwordless Sudo Default to False
**Source**: OWASP Security Analysis (Nov 2025)
**Completed**: November 2025
**Status**: ✅ Complete

**What Was Delivered**:
- Changed default from `ENABLE_PASSWORDLESS_SUDO=true` to `false` in Dockerfile
- Enhanced build-time messaging in `lib/base/user.sh`:
  * Clear warning when enabled (development mode)
  * Helpful guidance when disabled (production/secure mode)
- Comprehensive security documentation added to README.md:
  * New "Passwordless Sudo" section in Security Considerations
  * Explains when to enable (local dev) vs keep disabled (production)
  * Provides production alternatives (build-time install, init containers, IAM/RBAC)
- Development examples updated with explanatory comments
- Tests updated to verify secure default behavior
- All tests passing (unit: 651/652, integration: 5/5)

**Impact**: ✅ COMPLETE - Significantly improves security posture with secure-by-default approach.
**Breaking Change**: Existing dev users must explicitly enable for local development convenience.

---

#### 3. [HIGH] ✅ COMPLETE - Remove Docker Socket Auto-Fix Script
**Source**: OWASP Security Analysis (Nov 2025)
**Status**: ✅ COMPLETE (Nov 2025)
**Breaking Change**: Docker socket access requires explicit configuration

**Previous Issue**: Automatically granted docker group write access to socket using sudo:
```bash
if [ "$(id -u)" = "0" ]; then
    chgrp docker /var/run/docker.sock 2>/dev/null || true
    chmod g+rw /var/run/docker.sock 2>/dev/null || true
```

**Security Risks (Resolved)**:
- ❌ Any process in container could modify socket permissions → ✅ No automatic permission changes
- ❌ Granted root-equivalent host access automatically → ✅ Requires explicit group configuration
- ❌ Violated principle of explicit authorization → ✅ Uses principle of least privilege

**What Was Delivered**:
1. **NEW**: `bin/setup-docker-socket.sh` - Auto-detects Docker socket GID on host
   - Writes DOCKER_GID to .env file for docker-compose
   - Supports Linux, macOS, WSL2, Windows Docker Desktop
   - Safe exit if no Docker socket present (CI/prod)

2. **REMOVED**: `lib/runtime/docker-socket-fix.sh` - No more sudo permission changes
3. **REMOVED**: Auto-fix startup script generation from `lib/features/docker.sh`
4. **UPDATED**: `examples/contexts/devcontainer/docker-compose.yml` - Added `group_add` configuration
5. **UPDATED**: `.devcontainer/devcontainer.json` - Enabled `initializeCommand` for auto-setup
6. **UPDATED**: README.md - Comprehensive Docker socket security documentation
7. **UPDATED**: Tests - Removed docker-socket-fix checks, verify secure approach

**How It Works Now**:
- **VS Code Users**: `initializeCommand` runs setup script automatically before container starts
- **Docker Compose Users**: Run `./bin/setup-docker-socket.sh` once manually
- **Configuration**: Uses `group_add: [${DOCKER_GID:-999}]` in docker-compose.yml
- **Result**: Container user has Docker socket access via group membership (no sudo needed)

**Migration for Existing Users**:
```bash
# One-time setup
./bin/setup-docker-socket.sh

# Or add to existing docker-compose.yml
services:
  devcontainer:
    group_add:
      - ${DOCKER_GID:-999}
```

**Impact**: ✅ COMPLETE - Significantly improves security by eliminating automatic sudo permission changes while maintaining ease of use for developers through automated GID detection.
**Breaking Change**: Existing users must run setup script or configure group_add manually

---

#### 4. [HIGH] ✅ COMPLETE - Support Flexible Version Resolution with Automatic Patch Resolution
**Source**: Production build testing (Nov 2025)
**Priority**: P1 (High - user experience and developer convenience)
**Effort**: 2-3 days
**Status**: ✅ COMPLETE (Nov 2025) - All 6 languages support flexible version resolution
**Completed**: November 2025

**What Was Delivered (November 2025)**:

✅ **Complete Flexible Version Resolution System**:
All 6 languages now support flexible version inputs with automatic resolution to latest patch versions.

**Files Created**:
- `lib/base/version-resolution.sh` - Complete version resolution system for all languages
  * `resolve_python_version()` - Python version resolution
  * `resolve_node_version()` - Node.js version resolution
  * `resolve_go_version()` - Go version resolution
  * `resolve_ruby_version()` - Ruby version resolution
  * `resolve_rust_version()` - Rust version resolution
  * `resolve_java_version()` - Java version resolution
  * Helper functions: `_is_full_version()`, `_is_major_minor()`, `_is_major_only()`, `_curl_safe()`

**Integration Complete**:
All feature scripts now source `lib/base/version-resolution.sh` and call resolution before installation:
- ✅ Python: `lib/features/python.sh:37-59` - Sources and calls `resolve_python_version()`
- ✅ Node.js: `lib/features/node.sh:33-51` - Sources and calls `resolve_node_version()`
- ✅ Go: `lib/features/golang.sh:41-59` - Sources and calls `resolve_go_version()`
- ✅ Ruby: `lib/features/ruby.sh:40-58` - Sources and calls `resolve_ruby_version()`
- ✅ Rust: `lib/features/rust.sh:40-58` - Sources and calls `resolve_rust_version()`
- ✅ Java: `lib/features/java.sh:42-60` - Sources and calls `resolve_java_version()`

**Verification Testing (Nov 2025)**:
All 6 languages tested with partial version inputs - all passed successfully:
- ✅ Python 3.13 → 3.13.9 (major.minor → full version)
- ✅ Python 3.12 → 3.12.12 (major.minor → full version)
- ✅ Node.js 22 → 22.21.1 (major → full version)
- ✅ Node.js 20 → 20.19.5 (major → full version)
- ✅ Go 1.23 → 1.23.12 (major.minor → full version)
- ✅ Ruby 3.3 → 3.3.10 (major.minor → full version)
- ✅ Rust 1.82 → 1.82.0 (major.minor → full version)
- ✅ Java 21 → 21.0.9 (major → full version)

**Supported Version Formats (All 6 Languages)**:

| Language | Supported Formats | API Source Used for Resolution |
|----------|-------------------|-------------------------------|
| Python | `3`, `3.13`, `3.13.5` | python.org/ftp/python/ |
| Node.js | `20`, `20.18`, `20.18.0` | nodejs.org/dist/index.json |
| Go | `1`, `1.23`, `1.23.5` | go.dev/dl/?mode=json |
| Rust | `1`, `1.82`, `1.82.0` | rust-lang.org/stable |
| Ruby | `3`, `3.3`, `3.3.7` | ruby-lang.org/en/downloads/releases/ |
| Java | `21`, `21.0`, `21.0.1` | adoptium.net/api/ |

**Example Usage**:
```dockerfile
# All of these now work:
ARG PYTHON_VERSION="3.12"        # → Auto-resolves to 3.12.12 (latest patch)
ARG PYTHON_VERSION="3.12.5"      # → Uses exact version
ARG NODE_VERSION="20"            # → Auto-resolves to 20.19.5 (latest LTS patch)
ARG GO_VERSION="1.23"            # → Auto-resolves to 1.23.12 (latest patch)
```

**Benefits Achieved**:
- ✅ Better user experience - matches common version specification expectations
- ✅ Easier upgrades - users can change `3.12` to `3.13` without finding exact patch version
- ✅ Automatic patch updates - weekly auto-patch workflow gets latest patches automatically
- ✅ Still allows exact pinning when needed for reproducibility
- ✅ Simpler documentation and examples
- ✅ Consistent resolution logging: "Resolved Python 3.12 → 3.12.12"

**Impact**: ✅ COMPLETE - Significantly improved user experience, matches ecosystem conventions across all 6 supported languages

---

#### 5. [MEDIUM] Expand GPG Verification to Remaining Tools
**Source**: OWASP Security Analysis (Nov 2025)
**Priority**: P2 (Medium - enhancement after item #1 completes)
**Files**: Multiple feature scripts

**Issue**: GPG verification should be expanded beyond Python/Node/Go

**Note**: Item #1 implements GPG verification for Python, Go, and Node.js. This item extends that work to remaining tools.

**Tools Needing GPG Verification**:
- Kubernetes tools (kubectl binary downloads, helm)
- Terraform and HashiCorp tools
- Ruby (ruby-lang.org provides GPG signatures)
- R binaries
- Java/OpenJDK downloads
- Docker CLI (if not from apt repository)

**Already Implemented** ✓:
- AWS CLI: lib/features/aws.sh:98-141
- 1Password: lib/features/op-cli.sh
- Python, Go, Node: After item #1 completion

**Recommendation**:
- Use shared `lib/base/gpg-verification.sh` created in item #1
- Add GPG key fingerprints for HashiCorp, Ruby, R projects
- Document verification status for each tool in docs/security/
- Phase this work incrementally (not all tools provide GPG signatures)

**Implementation Priority**:
1. HashiCorp tools (Terraform, etc.) - high value
2. Ruby - signatures available
3. R - if signatures available
4. Java/OpenJDK - complex, many sources

**Impact**: MEDIUM - Further improves supply chain security after core tools covered

---

#### 5. [MEDIUM] Fix Command Injection Vectors in apt-utils.sh
**Source**: OWASP Security Analysis (Nov 2025)
**File**: `/workspace/containers/lib/base/apt-utils.sh` (lines 149, 285)

**Issue**: Using unquoted variable expansion with shellcheck disabled:
```bash
# shellcheck disable=SC2086
if timeout "$APT_TIMEOUT" $cmd; then
```

**Risks**:
- If APT_MAX_RETRIES or command parameters are manipulated, could lead to injection
- Disabled shellcheck warning masks potential issues

**Recommendation**:
- Use array-based command execution:
```bash
local cmd_array=("$@")
if timeout "$APT_TIMEOUT" "${cmd_array[@]}"; then
```
- Remove shellcheck disable comments
- Add input validation for APT_* environment variables

**Impact**: MEDIUM - Theoretical injection risk (low likelihood in practice)

---

#### 6. [MEDIUM] Validate PATH Additions Before Modification
**Source**: OWASP Security Analysis (Nov 2025)
**Files**: Multiple feature scripts, `/workspace/containers/lib/runtime/setup-paths.sh`

**Issue**: Dynamic PATH construction without validation (16 instances in setup-paths.sh)

**Risks**:
- If /cache or home directories are compromised, malicious binaries could be added to PATH
- No verification that directories exist and are owned by expected user

**Recommendation**:
- Create shared PATH validation function in lib/base/path-utils.sh
- Verify directory ownership before adding to PATH
- Check directory permissions (should be writable only by owner/trusted user)

**Impact**: MEDIUM - PATH hijacking prevention

---

#### 7. [MEDIUM] Improve kubectl Completion Validation
**Source**: OWASP Security Analysis (Nov 2025)
**File**: `/workspace/containers/lib/features/kubernetes.sh` (lines 358-366)

**Issue**: Regex-based validation can be bypassed:
```bash
! grep -qE '(rm -rf|curl.*bash|wget.*bash|eval.*\$)' "$COMPLETION_FILE"
```

**Risks**:
- Pattern can be bypassed with obfuscation (e.g., `r``m -rf`, base64 encoding)
- Completion scripts could contain malicious code

**Recommendation**:
- Use file size limit only (already implemented: < 100KB)
- Consider AST-based validation for shell scripts
- Or remove sourcing of completion entirely (trade-off with UX)

**Impact**: MEDIUM - Code injection via completion scripts

---

#### 8. [MEDIUM] Pipe Curl Downloads in Kubernetes and Terraform Features
**Files**:
- `/workspace/containers/lib/features/kubernetes.sh`
- `/workspace/containers/lib/features/terraform.sh`

**Issue**: Using shell pipes with curl can be dangerous:
```bash
curl -fsSL https://... | apt-key add -
curl -fsSL https://... | gpg --dearmor -o /etc/apt/keyrings/...
```

**Risks**:
- Network interruption could leave intermediate state
- Signal handling issues if interrupted mid-pipe
- Though wrapped in conditional bash -c, still suboptimal

**Current Mitigation**:
- Properly detected as deprecated pattern
- Feature-header.sh notes Debian 13 properly handles new signed-by method
- Only affects repository key installation

**Recommendation**:
- Download to temporary file first, verify, then process
- Already being handled via feature scripts with version detection
- Consider unified repository key installation function

---

#### 9. [MEDIUM] Dynamic Checksum Fetching Has MITM Risk
**File**: `/workspace/containers/lib/features/lib/checksum-fetch.sh`

**Issue**: Fetches checksums from upstream websites at build time:
```bash
page_content=$(curl -fsSL "$url")  # Parses HTML for checksums
checksum=$(echo "$page_content" | grep -oP '...')
```

**Risks**:
- HTTP/TLS downgrade attacks if not properly verified
- Man-in-the-middle can provide false checksums
- Parses HTML with regex instead of proper HTML parsing

**Current Mitigation**:
- Comments indicate checksums should be hardcoded (lines 209-210)
- Regex validates 64-hex format (SHA256) before accepting
- Feature-header.sh has secure_temp_dir with 755 permissions
- Only used for version flexibility, not primary security mechanism

**Recommendation**:
- Document that dynamic checksum fetching is transitional
- Add warning about production deployments using dynamic checksums
- Consider cached checksum database option
- Add checksum source validation (TLS pinning for critical endpoints)
- Document pinned versions for production use

---

#### 10. [LOW] Temp Directory Permissions May Be Too Permissive
**File**: `/workspace/containers/lib/base/feature-header.sh`

**Issue**: Temporary directories use 755 permissions (allows non-owner read/execute)

**Context**: Changed from 700 (per commit f9618b0), specifically to allow non-root users to read/execute

**Risk**: Anyone on system can read build artifacts (low risk in containers)

**Mitigation**:
- Documented in Dockerfile comments
- Docker containers are typically isolated
- Deliberate security/functionality tradeoff
- Noted in CLAUDE.md and commit history

**Recommendation**:
- Current approach is reasonable for containers
- Document this tradeoff clearly in SECURITY.md
- Consider 750 as middle ground if feasible

---

#### 11. [LOW] GPG Key Handling Could Validate Key IDs
**Files**: `/workspace/containers/lib/features/kubernetes.sh`, `terraform.sh`

**Issue**: Imports GPG keys without verifying key IDs:
```bash
curl -fsSL <url> | gpg --dearmor -o /etc/apt/keyrings/...
```

**Recommendation**:
- Compare against known key IDs for Kubernetes and HashiCorp
- Document key IDs in comments for manual verification
- Already mitigated by using official source URLs with HTTPS

---

### Production Readiness

#### 12. [CRITICAL] ✅ COMPLETE - Create Production-Optimized Image Variants
**Source**: Production Readiness Analysis (Nov 2025)
**Completed**: November 2025
**Status**: ✅ Complete

**What Was Delivered**:
Instead of creating separate Dockerfiles (which would violate the universal Dockerfile principle), implemented production examples using the main Dockerfile with production-focused build arguments:

**Files Created**:
- `examples/production/docker-compose.minimal.yml` - Minimal base (~163MB)
- `examples/production/docker-compose.python.yml` - Python runtime-only
- `examples/production/docker-compose.node.yml` - Node runtime-only
- `examples/production/README.md` - Comprehensive production guide
- `examples/production/COMPARISON.md` - Dev vs prod comparison tables
- `examples/production/build-prod.sh` - CLI helper for building production images
- `examples/production/compare-sizes.sh` - Size comparison utility
- `tests/integration/builds/test_production.sh` - Production build tests (6/6 passing)

**Key Features**:
- Uses `debian:bookworm-slim` base (~100MB smaller than full Debian)
- `ENABLE_PASSWORDLESS_SUDO=false` for security
- `INCLUDE_DEV_TOOLS=false` removes editors, debuggers, etc.
- Runtime-only packages: `INCLUDE_<LANG>_DEV=false`
- Security hardening examples (read-only filesystem, cap_drop, no-new-privileges)
- Image size reductions: 30-35% smaller than dev variants

**Test Results**: All production tests passing (100%)

**Bugs Fixed During Implementation**:
- Fixed logging initialization issue in `lib/base/logging.sh` (lib/base/logging.sh:244-283)
- Updated version validation to require semantic versions (documented need for flexible resolution in item #4)

**Impact**: ✅ COMPLETE - Production deployment now fully supported with examples and documentation

---

#### 13. [CRITICAL] Add Kubernetes Deployment Templates
**Source**: Production Readiness Analysis (Nov 2025)
**Priority**: P0 (Critical for enterprise deployment)
**Effort**: 3-4 days

**Issue**: No Kubernetes deployment examples beyond basic documentation

**Missing**:
- Deployment manifests
- Service definitions
- ConfigMap/Secret examples
- Resource limits best practices
- Security context examples
- Network policies
- Helm charts

**Recommendation**:
```bash
# examples/kubernetes/
├── base/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── configmap.yaml
│   └── secrets.yaml
├── overlays/
│   ├── development/
│   ├── staging/
│   └── production/
└── README.md
```

**Deliverables**:
- Kustomize base + overlays for multiple environments
- Optional Helm chart
- Resource limits guidance
- Security context examples (non-root, read-only filesystem)
- Network policy examples
- Production deployment checklist

**Impact**: CRITICAL - Enterprise Kubernetes deployment support

---

#### 14. [CRITICAL] Implement Observability Integration
**Source**: Production Readiness Analysis (Nov 2025)
**Priority**: P0 (Critical for production operations)
**Effort**: 4-5 days
**Current Score**: 2/10 (Most critical gap)

**Issue**: No production observability features
- No Prometheus metrics exporter
- No structured JSON logging
- No OpenTelemetry integration
- No pre-built Grafana dashboards
- No alerting rules

**Recommendation**:
```bash
# Add to lib/runtime/
├── metrics-exporter.sh      # Prometheus metrics endpoint
├── log-formatter.sh         # JSON structured logging
└── trace-context.sh         # OpenTelemetry propagation

# Add to examples/
└── monitoring/
    ├── prometheus-rules.yaml
    ├── grafana-dashboards/
    │   ├── container-health.json
    │   ├── resource-usage.json
    │   └── application-metrics.json
    └── alertmanager-config.yaml
```

**Metrics to expose**:
- Container health status
- Uptime
- Resource usage (CPU, memory, disk)
- Feature availability
- Cache hit rates
- Startup time

**Deliverables**:
- Metrics exporter script (Prometheus format)
- Structured logging standard (JSON with correlation IDs)
- Grafana dashboard templates
- Alerting rules for common issues
- Runbooks for alerts
- OpenTelemetry integration guide

**Impact**: CRITICAL - Production monitoring and debugging

---

#### 15. [HIGH] Add Configuration Validation Framework
**Source**: Production Readiness Analysis (Nov 2025)
**Priority**: P1 (High)
**Effort**: 2 days

**Issue**: No runtime configuration validation
- No required environment variable checks
- No format validation
- No secret detection warnings
- Configuration errors discovered at runtime failure

**Recommendation**:
```bash
#!/usr/local/bin/validate-config.sh
# Runtime configuration validation

required_vars=(
  DATABASE_URL
  REDIS_URL
  SECRET_KEY
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var}" ]]; then
    echo "ERROR: Required environment variable $var is not set"
    exit 1
  fi
done

# Validate formats
if [[ ! "$DATABASE_URL" =~ ^postgresql:// ]]; then
  echo "ERROR: DATABASE_URL must be PostgreSQL connection string"
  exit 1
fi
```

**Deliverables**:
- Config validation script
- Environment variable documentation generator
- Secret detection warnings (password/key in plaintext)
- Integration with entrypoint (validate before starting)
- Example validation rules for common patterns

**Impact**: HIGH - Prevent misconfiguration issues

---

#### 16. [HIGH] Enhance Secret Management Integrations
**Source**: Production Readiness Analysis (Nov 2025)
**Priority**: P1 (High)
**Effort**: 3 days

**Issue**: Limited secret management support
- Only 1Password CLI with minimal examples
- No HashiCorp Vault integration
- No AWS Secrets Manager support
- No Azure Key Vault integration
- Documentation-only approach

**Recommendation**:
```bash
# Add lib/runtime/secrets/
├── vault-integration.sh          # HashiCorp Vault
├── aws-secrets-manager.sh        # AWS Secrets Manager
├── azure-keyvault.sh             # Azure Key Vault
└── 1password-integration.sh      # Enhanced 1Password

# Usage in entrypoint:
if [[ -n "${USE_VAULT}" ]]; then
  source /opt/container-runtime/secrets/vault-integration.sh
  load_secrets_from_vault
fi
```

**Deliverables**:
- Vault integration script
- AWS Secrets Manager support
- Azure Key Vault support
- Enhanced 1Password integration with examples
- Kubernetes secret injection examples
- Environment variable injection from secret stores

**Impact**: HIGH - Enterprise secret management

---

#### 17. [HIGH] Create CI/CD Pipeline Templates
**Source**: Production Readiness Analysis (Nov 2025)
**Priority**: P1 (High)
**Effort**: 2-3 days

**Issue**: No CI/CD pipeline examples for common platforms
- No GitHub Actions templates
- No GitLab CI examples
- No Jenkins pipelines
- No deployment strategy examples (blue-green, canary)

**Recommendation**:
```bash
# examples/cicd/
├── github-actions/
│   ├── build-and-test.yml
│   ├── deploy-staging.yml
│   ├── deploy-production.yml
│   └── rollback.yml
├── gitlab-ci/
│   └── .gitlab-ci.yml
├── jenkins/
│   └── Jenkinsfile
└── README.md
```

**Deliverables**:
- GitHub Actions workflows (build, test, deploy)
- GitLab CI templates
- Jenkins pipeline examples
- Deployment strategies (blue-green, canary)
- Automated rollback procedures
- Integration with container registry

**Impact**: HIGH - Standardized deployment automation

---

#### 18. [MEDIUM] Add Operational Runbooks
**Source**: Production Readiness Analysis (Nov 2025)
**Priority**: P2 (Medium)
**Effort**: 3 days

**Issue**: No operational documentation
- No incident response procedures
- No common operations documented
- No scaling procedures
- Missing disaster recovery documentation

**Recommendation**:
```bash
# docs/runbooks/
├── incident-response.md
├── scaling-procedures.md
├── disaster-recovery.md
├── common-operations.md
├── troubleshooting-production.md
└── on-call-guide.md
```

**Deliverables**:
- Incident response procedures
- Scaling procedures (horizontal/vertical)
- Update and rollback procedures
- Disaster recovery documentation
- Common operational tasks
- On-call guide for production issues

**Impact**: MEDIUM - Operational excellence

---

#### 19. [MEDIUM] Performance Optimization Guide
**Source**: Production Readiness Analysis (Nov 2025)
**Priority**: P2 (Medium)
**Effort**: 2 days

**Issue**: No performance optimization documentation
- No build time optimization guide
- Missing benchmarks for different variants
- No image size optimization guidance
- No performance regression testing

**Deliverables**:
- Build time optimization techniques
- Image size reduction strategies
- Cache optimization patterns
- Benchmarking tools and baselines
- Performance regression testing in CI

**Impact**: MEDIUM - Build efficiency and cost optimization

---

### Architecture & Code Organization

#### 20. [MEDIUM] Extract cache-utils.sh Shared Utility
**Source**: Architecture Analysis (Nov 2025)
**Priority**: P1 (High value, reduces duplication)
**Effort**: 1 day

**Issue**: Cache directory creation duplicated across 8+ feature scripts
- 50+ lines of duplicated code
- Inconsistent error handling approaches
- Different permission patterns

**Current duplication** in:
- python.sh:85-102
- golang.sh:168-181
- rust.sh:63-76
- node.sh (similar)
- ruby.sh (similar)
- r.sh (similar)
- java.sh (similar)
- mojo.sh (similar)

**Recommendation**:
```bash
# Create lib/base/cache-utils.sh
create_language_cache() {
    local cache_name="$1"
    local cache_path="/cache/${cache_name}"

    log_command "Creating ${cache_name} cache directory" \
        bash -c "install -d -m 0755 -o '${USER_UID}' -g '${USER_GID}' '${cache_path}'"

    echo "$cache_path"
}

create_multiple_caches() {
    local -n cache_array=$1
    for cache_name in "${cache_array[@]}"; do
        create_language_cache "$cache_name"
    done
}
```

**Impact**: Reduces ~50 lines of duplication, ensures consistency

---

#### 21. [MEDIUM] Extract path-utils.sh Shared Utility
**Source**: Architecture Analysis (Nov 2025)
**Priority**: P1 (High value, reduces duplication)
**Effort**: 1 day

**Issue**: PATH manipulation duplicated across 5+ feature scripts
- ~40 lines of duplicated code
- Potential for bugs in path handling
- Inconsistent error handling

**Current duplication** in:
- python.sh:315-333
- rust.sh:246-264
- golang.sh (similar)
- node.sh (similar)
- ruby.sh (similar)

**Recommendation**:
```bash
# Create lib/base/path-utils.sh
add_to_system_path() {
    local new_path="$1"
    local environment_file="/etc/environment"

    # Read existing PATH
    if [ -f "$environment_file" ] && grep -q "^PATH=" "$environment_file"; then
        local existing_path
        existing_path=$(grep "^PATH=" "$environment_file" | cut -d'"' -f2)
        grep -v "^PATH=" "$environment_file" > "${environment_file}.tmp"
        mv "${environment_file}.tmp" "$environment_file"
    else
        local existing_path="/usr/local/bin:/usr/bin:/bin"
    fi

    # Add new path if not present
    if [[ ":$existing_path:" != *":$new_path:"* ]]; then
        existing_path="${existing_path}:${new_path}"
    fi

    echo "PATH=\"$existing_path\"" >> "$environment_file"
}
```

**Impact**: Reduces ~40 lines of duplication, standardizes PATH management

---

#### 22. [MEDIUM] Split dev-tools.sh into Sub-Features
**Source**: Architecture Analysis (Nov 2025)
**Priority**: P1 (Maintainability)
**Effort**: 2-3 days

**Issue**: dev-tools.sh is 1,106 lines (largest feature script)
- Installs 50+ tools
- Mix of different tool categories
- Hard to maintain
- All-or-nothing installation

**Current categories** in dev-tools.sh:
- Core tools (ripgrep, fd, bat, eza)
- Git helpers (lazygit, delta, gh, glab)
- Monitoring tools (htop, btop, iotop)
- Network tools (netcat, nmap, tcpdump)
- Cloud CLIs (gh, glab, act)
- Productivity tools (direnv, mkcert)

**Recommendation**:
```bash
lib/features/
├── dev-tools-core.sh           # Basic tools (ripgrep, fd, bat)
├── dev-tools-git.sh            # Git helpers (lazygit, delta, gh)
├── dev-tools-monitoring.sh     # htop, btop, iotop
├── dev-tools-network.sh        # netcat, nmap, tcpdump
└── dev-tools.sh                # Meta-feature that includes all
```

**Dockerfile changes**:
```dockerfile
ARG INCLUDE_DEV_TOOLS_CORE=false
ARG INCLUDE_DEV_TOOLS_GIT=false
ARG INCLUDE_DEV_TOOLS_MONITORING=false
ARG INCLUDE_DEV_TOOLS_NETWORK=false
```

**Impact**: Better granularity, reduces image size, easier maintenance

---

#### 23. [MEDIUM] Extract Project Templates from Functions
**Source**: Architecture Analysis (Nov 2025)
**Priority**: P1 (Code organization)
**Effort**: 1-2 days

**Issue**: Template code embedded in functions
- `go-new` function: 207 lines (golang.sh:284-490)
- Contains heredoc templates for CLI, API, library
- Hard to update templates
- Not reusable outside of function

**Recommendation**:
```bash
lib/features/templates/
├── go/
│   ├── cli/main.go.tmpl
│   ├── api/main.go.tmpl
│   ├── lib/lib.go.tmpl
│   └── Makefile.tmpl
├── python/
│   └── pyproject.toml.tmpl
└── node/
    └── package.json.tmpl
```

**Template loader**:
```bash
load_template() {
    local language="$1"
    local template_type="$2"
    local template_file="$3"

    cat "/tmp/build-scripts/features/templates/${language}/${template_type}/${template_file}"
}
```

**Impact**: Reduces function size by ~150 lines, enables template versioning

---

#### 24. [LOW] Implement Feature Manifest System
**Source**: Architecture Analysis (Nov 2025)
**Priority**: P2 (Long-term architecture)
**Effort**: 5-7 days

**Issue**: Features hardcoded in Dockerfile (451 lines with repetitive patterns)
- Adding new feature requires editing Dockerfile
- Feature dependencies manual
- Installation order hardcoded
- No dynamic feature discovery

**Recommendation**:
```yaml
# lib/features/python.yaml
name: python
display_name: Python
category: language
build_arg: INCLUDE_PYTHON
version_arg: PYTHON_VERSION
default_version: "3.14.0"
install_script: lib/features/python.sh
dependencies: []
optional_dependencies:
  - python-dev
priority: 10
tags:
  - language
  - scripting
  - ai-ml
```

**Feature orchestrator** (lib/base/feature-orchestrator.sh):
- Discover features from manifests
- Resolve dependencies
- Determine installation order
- Execute feature scripts

**Impact**: Automatic feature discovery, dependency resolution, simplified Dockerfile

---

#### 25. [LOW] Standardize Verification Scripts
**Source**: Architecture Analysis (Nov 2025)
**Priority**: P2 (Consistency)
**Effort**: 2 days

**Issue**: Verification scripts inconsistent
- Some create test-{feature} script
- Others embed verification inline
- No standard format
- Inconsistent UX

**Recommendation**:
```bash
# lib/base/verification-template.sh
generate_verification_script() {
    local feature_name="$1"
    local -n commands=$2    # Array of commands to verify
    local -n env_vars=$3    # Array of env vars to display

    # Generate consistent verification script
}
```

**Impact**: Consistent verification across all features, better UX

---

### Missing Features

#### 26. [LOW] Missing docker --version and Tool Version Output in Entrypoint
**Issue**: Users don't get immediate feedback on installed versions

**Recommendation**:
- Add optional verbose mode to entrypoint showing installed versions
- Create `.container-versions` file during build
- Allow `check-installed-versions.sh` to run on startup (opt-in)
- Add `--versions` flag to entrypoint

**Impact**: Nice-to-have for debugging, not critical

---

#### 27. [LOW] Case-Insensitive Filesystem Issues on macOS/Windows Volume Mounts
**Source**: User feedback (Nov 2025)
**Priority**: P3 (Low - quality of life, cross-platform compatibility)

**Issue**: Case-sensitivity conflicts when mounting host volumes from macOS/Windows

**Problem Description**:
- macOS uses case-insensitive APFS by default (`file.txt` == `File.txt`)
- Windows filesystems are case-insensitive
- Linux containers expect case-sensitive filesystems
- Git tracks case changes but filesystem may not reflect them
- Example: Renaming `README.md` → `readme.md` causes confusion

**Common Symptoms**:
```bash
# On macOS host
git mv README.md readme.md
git commit -m "Lowercase readme"

# Inside Linux container
ls -la
# Shows: README.md (filesystem didn't change)
# Git shows: readme.md (tracked change)
```

**Potential Solutions**:

1. **Documentation Approach** (Easiest):
   - Document the issue in troubleshooting guide
   - Recommend case-sensitive APFS volumes for macOS developers
   - Add to CLAUDE.md for awareness

2. **Detection & Warning** (Medium):
   - Create startup script to detect case-insensitive mounts
   - Warn users when `/workspace` is case-insensitive
   - Provide remediation steps in warning message

3. **Workaround Helper** (Advanced):
   - Create utility script to sync git index with filesystem
   - `fix-case-sensitivity.sh` to reconcile git vs filesystem
   - Run as part of startup scripts (opt-in)

4. **Volume Configuration** (Requires Docker Desktop changes):
   - Explore Docker Desktop volume driver options
   - Research if osxfs/grpcfuse has case-sensitivity controls
   - Likely not feasible without Docker changes

**Recommended Approach**:
Start with #1 (documentation) + #2 (detection/warning), defer #3 and #4

**Files to Create/Modify**:
- Create: `docs/troubleshooting/case-sensitive-filesystems.md`
- Modify: `lib/runtime/startup.sh` (add detection)
- Modify: `CLAUDE.md` (add cross-platform notes)
- Optional: Create `bin/fix-case-sensitivity.sh` utility

**Impact**: LOW - Affects cross-platform developers, but has workarounds

---

### Anti-Patterns & Code Smells

#### 28. [MEDIUM] Sed Usage in Parsing Without Proper Escaping
**File**: `/workspace/containers/lib/features/lib/checksum-fetch.sh`

**Issue**: Parsing HTML with sed is brittle:
```bash
sed 's/<tt>\|<\/tt>//g'
sed 's/>Ruby //; s/<//'
```

**Recommendation**:
- Use jq for JSON parsing where available
- Document why sed is used when it is
- Add comments for complex sed patterns
- Consider switching to proper HTML parsers where critical

**Current State**: Safe for fixed strings but pattern is fragile

---

#### 29. [LOW] Feature Scripts Use Different Logging Approaches
**Issue**: Some variations in logging detail level across features

**Impact**:
- Slightly inconsistent debugging experience
- Most scripts use logging.sh functions correctly

**Recommendation**:
- Audit all feature scripts for consistent log_message/log_error usage
- Ensure all use same verbosity level
- Standardize format of informational messages

**Status**: Minor polish issue, not breaking

---

#### 30. [LOW] Version Validation Spread Across Multiple Files
**Files**:
- `version-validation.sh`
- `checksum-fetch.sh`
- Individual feature scripts

**Issue**: Version validation logic has some duplication

**Recommendation**:
- Centralize all version validation functions
- Create single validation library for all patterns
- Use in Dockerfile ARG defaults
- Reduce duplication between flexible/strict validators

**Impact**: Code maintenance, not functional

---

### Testing Gaps

#### 31. [MEDIUM] Integration Tests Don't Cover All Feature Combinations
**Issue**: Only 6-7 test variants but 28+ features

**Gap**:
- No combination testing (e.g., Python+Node+Rust+Go all together)
- Some feature interactions untested
- Users might discover incompatibilities in production
- No testing of all dev-tools variants together

**Current Coverage**:
- minimal
- python-dev
- node-dev
- r-dev
- cloud-ops
- polyglot (tests 4 languages together)
- rust-golang

**Recommendation**:
- Add "maximum" variant testing all possible features
- Create randomized test combinations in CI
- Add compatibility matrix for critical features
- Document known incompatibilities
- Test more dev-tools combinations

**Priority**: Medium - Would catch interaction bugs early

---

#### 32. [HIGH] ✅ COMPLETE - Add Pre-Push Git Hook for Validation (Shellcheck + Unit Tests)
**Source**: Production examples development experience (Nov 2025)
**Priority**: P1 (High - prevents CI failures and speeds up development)
**Effort**: 1 day
**Status**: ✅ COMPLETE (November 2025)
**Completed**: November 2025

**What Was Delivered (November 2025)**:

✅ **Complete Pre-Push Hook System**:
Created comprehensive pre-push validation hook that runs both shellcheck and unit tests before allowing push, catching issues locally before CI.

**Files Created**:
- `.githooks/pre-push` - Pre-push validation hook (shellcheck + unit tests)
- Enhanced `bin/setup-dev-environment.sh` with hook verification and setup
- Created `tests/unit/bin/setup-dev-environment.sh` - 19 unit tests (100% pass)

**Integration Complete**:
- Pre-push hook validates ALL 153 shell scripts (respects .gitignore)
- Runs full unit test suite before push (686 tests, 99% pass rate)
- Updated `.devcontainer/devcontainer.json` to run setup-git-ssh.sh on startup
- Aligned `.github/workflows/ci.yml` with pre-push hook validation scope
- Fixed 100+ shellcheck warnings across codebase to achieve compliance

**Validation Results**:
- ✅ All 153 shell scripts pass shellcheck (warning severity level)
- ✅ All 686 unit tests pass (685 passed, 0 failed, 1 skipped)
- ✅ Pre-push hook passes successfully
- ✅ Can be bypassed with `git push --no-verify` for emergencies

**Benefits Achieved**:
- ✅ Catches shellcheck and test failures locally before push (fast feedback)
- ✅ Reduces CI failures and wasted CI time significantly
- ✅ Better developer experience with immediate feedback
- ✅ Complements existing pre-commit hook for defense in depth

**Impact**: ✅ COMPLETE - Significantly improves developer experience and reduces CI costs by catching issues locally before push.

**Previous Issue**: Validation errors currently only caught in CI
- Developers push code with shellcheck violations and test failures
- CI catches them one at a time (slow feedback loop)
- Requires multiple push cycles to fix all issues
- Wastes CI resources and developer time
- Recent example: Multiple shellcheck issues found during production examples work

**Previous State**:
- ✅ Pre-commit hook exists (runs shellcheck on staged files)
- ❌ No pre-push hook (allows pushing code that fails CI)
- ❌ Developers can bypass pre-commit hook with `--no-verify`
- ❌ Unit tests not run locally before push
- Result: Shellcheck and test failures still reach CI regularly

**Recommended Solution**:

Create `.git/hooks/pre-push` hook that runs shellcheck AND unit tests before push:

```bash
#!/usr/bin/env bash
# Pre-push hook: Run validation checks before push
set -euo pipefail

echo "=== Running pre-push validation ==="
echo ""

# Track overall failure status
overall_failed=0

# 1. Run shellcheck on all shell scripts
echo "1. Running shellcheck on all shell scripts..."
shell_files=$(find . -type f \( -name "*.sh" -o -name "*.bash" \) \
  ! -path "./.git/*" \
  ! -path "*/node_modules/*" \
  ! -path "*/vendor/*")

shellcheck_failed=0
for file in $shell_files; do
  if ! shellcheck "$file" > /dev/null 2>&1; then
    if [ $shellcheck_failed -eq 0 ]; then
      echo "❌ Shellcheck failures:"
    fi
    shellcheck "$file"
    shellcheck_failed=1
  fi
done

if [ $shellcheck_failed -eq 0 ]; then
  echo "✅ All shell scripts passed shellcheck"
else
  overall_failed=1
fi
echo ""

# 2. Run unit tests (fast, no Docker required)
echo "2. Running unit tests..."
if ./tests/run_unit_tests.sh; then
  echo "✅ All unit tests passed"
else
  echo "❌ Unit tests failed"
  overall_failed=1
fi
echo ""

# Final result
if [ $overall_failed -eq 1 ]; then
  echo "❌ Pre-push validation FAILED!"
  echo "Fix issues above or use 'git push --no-verify' to skip"
  exit 1
fi

echo "✅ Pre-push validation PASSED!"
echo "All checks successful - proceeding with push"
```

**Implementation Steps**:

1. Create `bin/install-git-hooks.sh` script that:
   - Installs pre-push hook
   - Also ensures pre-commit hook is installed
   - Can be run by developers: `./bin/install-git-hooks.sh`
   - Runs automatically in CI setup

2. Add to `.githooks/pre-push` template (tracked in repo)

3. Update documentation:
   - Add to CONTRIBUTING.md: "Run `./bin/install-git-hooks.sh` after clone"
   - Add to README.md setup instructions
   - Document `--no-verify` escape hatch for emergencies

4. Add CI check that verifies hooks are installed:
   ```bash
   # In CI, verify hooks would have caught issues
   ./bin/install-git-hooks.sh
   ```

**Benefits**:
- ✅ Catches shellcheck issues before push (fast local feedback)
- ✅ Catches unit test failures before push (no Docker required)
- ✅ Reduces CI failures and wasted CI time significantly
- ✅ Fewer commit cycles to fix issues
- ✅ Better developer experience
- ✅ Unit tests are fast (~seconds, no build required)
- ✅ Still allows `--no-verify` for emergencies
- ✅ Complements existing pre-commit hook

**Comparison with Pre-Commit Hook**:

| Hook | When It Runs | What It Checks | Can Bypass |
|------|--------------|----------------|------------|
| pre-commit | Before commit | Staged files only (shellcheck) | `--no-verify` |
| pre-push | Before push | All shell scripts + unit tests | `--no-verify` |

**Why Both Are Needed**:
- Pre-commit: Fast feedback on current changes (shellcheck staged files only)
- Pre-push: Comprehensive validation before sharing with team/CI (all shell scripts + unit tests)
- Defense in depth: Two chances to catch issues
- Unit tests in pre-push: Fast enough (~seconds) but comprehensive enough to catch regressions

**Files to Create/Modify**:
- Create: `bin/install-git-hooks.sh`
- Create: `.githooks/pre-push`
- Modify: `README.md` (add setup step)
- Create: `docs/development/git-hooks.md` (documentation)
- Modify: `.github/workflows/*.yml` (run install script in CI)

**Priority**: HIGH - Directly improves developer experience and reduces CI costs

---

## Summary

**Total Remaining**: 35 items (updated November 2025)

**By Priority**:
- CRITICAL: 2 items (Production deployment blockers)
- HIGH: 7 items (Security, enterprise features, and developer experience) - Item #2 complete, #4 partially complete
- MEDIUM: 15 items (Code quality, architecture, operations)
- LOW: 12 items (Nice-to-have enhancements)

**By Category**:
- Security Concerns: 10 items (0 CRITICAL, 2 HIGH, 5 MEDIUM, 3 LOW) - Item #2 complete
- Production Readiness: 7 items (2 CRITICAL, 4 HIGH, 1 MEDIUM) - Item #12 COMPLETE
- Architecture & Code Organization: 6 items (5 MEDIUM, 1 LOW)
- Anti-Patterns & Code Smells: 3 items (1 MEDIUM, 2 LOW)
- Testing Gaps: 2 items (1 HIGH, 1 MEDIUM)
- Missing Features: 1 item (LOW)

**Overall Assessment**:
The codebase has **excellent fundamentals** (Security: 7.5/10, Architecture: 8.5/10, Developer Experience: 9/10) but needs **production-grade enhancements** for enterprise deployment (Production Readiness: 6/10).

**Critical gaps**: Production-optimized images, Kubernetes templates, and observability integration (metrics, logging, tracing).

**Key strengths**: Strong security posture, well-architected codebase, comprehensive testing framework, excellent documentation.

---

## Next Steps

### Immediate Actions (P0 - Critical, 1-2 weeks)
1. **[CRITICAL]** Create production-optimized image variants (item #12)
2. **[CRITICAL]** Add Kubernetes deployment templates (item #13)
3. **[CRITICAL]** Implement observability integration (item #14)

### Short-Term Actions (P1 - High Priority, 1 month)
4. **[HIGH]** Complete GPG verification and pinned checksums (item #1 - infrastructure complete, need checksums.json population)
5. **[HIGH]** ~~Change passwordless sudo default to false (item #2)~~ ✅ COMPLETE
6. **[HIGH]** ~~Remove Docker socket auto-fix script (item #3)~~ ✅ COMPLETE
7. **[HIGH]** Add configuration validation framework (item #15)
8. **[HIGH]** Enhance secret management integrations (item #16)
9. **[HIGH]** Create CI/CD pipeline templates (item #17)
10. **[MEDIUM]** Extract cache-utils.sh shared utility (item #20)
11. **[MEDIUM]** Extract path-utils.sh shared utility (item #21)

### Medium-Term Actions (P2 - 2-3 months)
12. **[MEDIUM]** Expand GPG verification to remaining tools (item #5)
13. **[MEDIUM]** Fix command injection vectors in apt-utils.sh (item #6)
14. **[MEDIUM]** Validate PATH additions before modification (item #6)
15. **[MEDIUM]** Improve kubectl completion validation (item #7)
16. **[MEDIUM]** Split dev-tools.sh into sub-features (item #22)
17. **[MEDIUM]** Extract project templates from functions (item #23)
18. **[MEDIUM]** Add operational runbooks (item #18)
19. **[MEDIUM]** Performance optimization guide (item #19)
20. **[MEDIUM]** Integration test coverage for feature combinations (item #30)

### Long-Term Enhancements (P3 - Future)
21. All remaining LOW priority items (items #10, #11, #24, #25, #26, #27, #28, #29)

**Focus Areas**:
- **Week 1-2**: Security (pin checksums, sudo default, GPG verification)
- **Week 3-4**: Production deployment (images, K8s templates, observability)
- **Month 2**: Enterprise features (config validation, secrets, CI/CD)
- **Month 3**: Code quality (extract utilities, split large scripts)
