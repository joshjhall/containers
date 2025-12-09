# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.12.5] - 2025-12-09

### Added

- Add INCLUDE_KEYBINDINGS feature for terminal shortcuts
- Add Shift+Return for soft line continuation
- Add tini for proper zombie process reaping

### CI/CD

- Exclude polyglot from security scans

### Fixed

- Set correct permissions on shell scripts
- Remove Shift+Return binding

### Miscellaneous

- Update la alias to show . and .. entries
- Fix formatting from pre-commit hooks

## [4.12.4] - 2025-12-07

### Added

- Add cargo-release and taplo-cli
- Track cargo-release and notify on updates
- Track toml_edit and notify on updates

### Fixed

- Ignore whitespace-only GPG key changes
- Pin cargo-release to 0.25.21
- Pin cargo-release to 0.25.18
- Build cargo-release from source with pinned toml_edit
- Fix permissions for cargo-release build temp directory
- Correct toml_edit git tag format
- Use latest cargo-release with pinned toml_edit

### Miscellaneous

- Automated version updates to v4.12.4
- Update compatibility matrix with passing test results

## [4.12.3] - 2025-12-06

### Added

- Add Biome linter/formatter
- Add Biome to automated version management

### Changed

- Replace Node tooling with pre-commit framework
- Migrate from custom .githooks to pre-commit framework
- Replace markdownlint-cli with pymarkdown

### Fixed

- Resolve shellcheck warnings across lib/ and bin/ scripts
- Remove cargo-edit dependency (superseded by cargo add/remove)
- Install pre-commit in postCreateCommand
- Correct healthcheck syntax and remove obsolete version
- Only alert on actual GPG key file changes

### Miscellaneous

- Exclude pre-commit config from line-length check
- Automated version updates to v4.12.3
- Update compatibility matrix with passing test results

### Testing

- Add Biome to unit tests

### Style

- Apply pre-commit linting and formatting fixes

## [4.12.2] - 2025-11-30

### Documentation

- Update documentation for recent Docker socket and base image changes
- Additional updates for Debian trixie default and rbenv removal
- Update examples and tests to use Debian 13 (trixie) as default

### Fixed

- Restore full changelog and fix auto-patch shallow clone
- Prevent double-counting in test framework pass/fail/skip
- Migrate template tests to main framework and fix flaky CI

## [4.12.1] - 2025-11-30

### Fixed

- Strip trailing blank lines from generated CHANGELOG
- Add execute permission to test framework script
- Handle timeout gracefully in JSON output validation test

### Miscellaneous

- Automated version updates to v4.12.1
- Update compatibility matrix with passing test results

## [4.12.0] - 2025-11-26

### Fixed

- Restore file and directory permissions
- Docker socket permissions via root entrypoint
- Run container as non-root with sudo for Docker socket

## [4.11.0] - 2025-11-25

### Added

- Add fixuid for runtime UID/GID remapping
- Add fixuid to version check and update scripts

### Changed

- Use parameter expansion for version overrides

### Fixed

- Add Docker socket permission fix in entrypoint
- Support parameter expansion in version check/update scripts

### Miscellaneous

- Remove host-side Docker socket setup
- Update tool versions

### Testing

- Add tests for Docker socket fix and fixuid
- Add tests for parameter expansion version extraction

## [4.10.1] - 2025-11-23

### Fixed

- Fix sed syntax errors in check-versions.sh
- Fix Dockerfile ARG pattern matching in update-versions.sh
- Fix spacing bugs in check-versions.sh commands

### Miscellaneous

- Update dependency versions

### Testing

- Add tests to catch syntax errors in check-versions.sh

## [4.10.0] - 2025-11-20

### Added

- Add production-ready Kubernetes deployment templates
- Add production-ready CI/CD pipeline templates
- Add comprehensive code quality checks and formatters
- Install quality check tools automatically
- Add comprehensive secret management integrations
- Add Docker Secrets and GCP Secret Manager integrations
- Add YAML validation to pre-push hook
- Add comprehensive observability stack
- Add GitHub CLI authentication via 1Password
- Add script to migrate roadmap to GitHub Issues
- Add pip-audit for vulnerability scanning
- Add cargo-audit and cargo-deny for security scanning
- Add go-security-check function for vulnerability scanning
- Add cargo-geiger for unsafe code detection
- Implement resource limits to prevent exhaustion (Fixes #6)
- Add container startup time metrics
- Add graceful shutdown handlers to entrypoint
- Implement Sigstore verification for Python 3.11.0+
- Install cosign for Sigstore verification
- Add cosign to version check/update scripts
- Add secure PATH validation (Issue #3)
- Add secure PATH validation (Issue #3)
- Add build dependency cleanup for production images (Issue #23)
- Add GPG verification for Node.js and Python
- Add GPG verification for Terraform/HashiCorp
- Complete Terraform GPG verification implementation
- Add cosign for Sigstore image/binary verification
- Add Sigstore verification for kubectl binaries
- Add Go (Golang) GPG signature verification
- Add automated GPG key updates with critical security notifications
- Add compliance documentation, logging levels, and security improvements
- Add custom health checks, shell completion tests, and benchmarks
- Enhance CI with markdown linting, Trivy scanning, and benchmarks
- Add JSON logging build arg and compliance documentation
- Add security testing automation and component inventory
- Add TLS/mTLS encryption in transit examples
- Add MFA integration documentation
- Add compliance validation mode to config validator
- Add security context, backup validation, and log analysis
- Add shell hardening for production environments
- Add mandatory audit logging system
- Add immutable storage configurations for audit logs
- Add Falco runtime security monitoring for compliance
- Add OPA Gatekeeper policy enforcement for compliance
- Add automated backup and disaster recovery with Velero
- Add runtime anomaly detection baseline and tuning
- Add retry logic to all GPG key downloads
- Add file permissions check to pre-commit and pre-push

### Changed

- Reorganize layer ordering for optimal caching
- Use shared retry-utils for component install

### Documentation

- Update progress summary with completed items
- Add pragmatic testing strategy
- Add Docker for Mac case-sensitivity guide
- Reorganize documentation into categorized structure
- Archive improvements roadmap after GitHub Issues migration
- Consolidate security scanning design and remove docs/planned
- Update security-checksums.md with completed signature verification
- Add encryption-at-rest docs, operational runbooks, and Trivy ignore
- Add incident response, data classification, and software allowlist
- Update build-args schema with all current build arguments

### Fixed

- Push branch before creating tag to validate commits
- Fix setup script, permissions, and linting support
- Add shellcheck disables to setup-git-ssh.sh
- Exclude setup-git-ssh.sh from pre-push shellcheck
- Exclude setup-git-ssh.sh from CI shellcheck
- Allow yamllint warnings, fail only on errors
- Skip Docker Compose validation if not installed
- Resolve shellcheck SC2155 in json-logging.sh
- Resolve shellcheck SC2155 in metrics-exporter.sh
- Remove unused variable in test_json_logging.sh
- Make library scripts executable
- Fix token handling and invalid Authorization header error
- Add run_tests helper and compatibility functions for observability tests
- Add package name validation and improve Debian version detection
- Allow version specifications in package name validation
- Fix apt_install_conditional to pass packages as separate args
- Use /tmp/container-metrics instead of /var/run
- Use separate .sig and .crt files for Python verification
- Ensure shell scripts are executable
- Complete PATH validation coverage
- Use graceful fallback for pipx PATH during build
- Add graceful fallback for Poetry installation PATH
- Add defensive WORKING_DIR checks in first-startup scripts
- Add graceful fallback for PATH validation in wrangler install
- Remove build-essential from base image
- Add build dependencies for development environments
- Preserve runtime libraries during production cleanup
- Remove build tools check from minimal integration test
- Add missing export for kubectl verification function
- Resolve SC2155 warnings in update-gpg-keys.sh
- Resolve markdown linting errors
- Resolve shellcheck warnings in inventory-components.sh
- Replace hard tabs with spaces in security-testing.md
- Update cosign to 3.0.2 and fix benchmark JSON output
- Fix benchmark JSON output breaking on empty lines
- Ignore non-exploitable mkcert CVEs in Trivy scan
- Restore execute permissions on shell scripts
- Update version compatibility matrix during auto-patch process
- Suppress PATH notices by default and add unit tests
- Disable MD060 table column alignment rule
- Fix benchmark JSON output and YAML lint warnings
- Handle bc decimal output without leading zero
- Use clearer placeholder names in GCP example
- Use awk instead of bc for benchmark calculations
- Add retry logic for gcloud components install
- Add robust numeric validation in benchmark script
- Remove duplicate YAML validation in pre-push hook
- Output valid JSON even when benchmark builds fail
- Redirect benchmark progress messages to stderr
- Break long lines in OPA Gatekeeper constraint templates
- Fix remaining long lines in OPA Gatekeeper constraint templates
- Only scan for vulnerabilities in blocking Trivy check
- Ignore npm dev tool transitive dependency CVEs
- Free up disk space before security scans
- Reduce security scan to representative variant subset

### Miscellaneous

- Remove TODO comment and track in GitHub issue #22

### Security

- Fix remaining linting issues for clean pre-commit

### Style

- Apply prettier formatting to all files
- Fix markdownlint issues across all markdown files
- Fix prettier formatting in Node.js GPG keys README
- Fix markdownlint issue - add language to code fence
- Fix prettier and markdownlint formatting in README
- Format TLS documentation files

## [4.9.2] - 2025-11-16

## [4.9.1] - 2025-11-16

### Added

- Add configuration validation framework for runtime validation
- Add case-sensitivity detection for cross-platform development

### Changed

- Use 'command find' consistently to avoid alias interference
- Add command prefix to avoid alias interference
- Add command prefix to sed, cat, rm, mv, cp, curl, wget

### Documentation

- Update roadmap to mark Item #15 complete
- Add configuration validation framework documentation
- Streamline roadmap by removing completed item details

### Fixed

- Handle grep -v edge case in path-utils when no PATH exists
- Add command prefix to remaining sed/cat/rm/mv/cp/curl instances
- Add command prefix to all test files for consistency

### Miscellaneous

- Make Mojo template test script executable
- Automated version updates to v4.9.1

## [4.9.0] - 2025-11-15

### Added

- Replace Docker socket auto-fix with secure group-based access [**BREAKING**]
- Add 4-tier checksum verification system with version resolution
- Add unified signature verification system with GPG + Sigstore support
- Integrate GPG/Sigstore signature verification into 4-tier checksum system
- Add pinned checksums database (lib/checksums.json) with Tier 2 verification
- Add automated checksum database maintenance script
- Complete automated checksum maintenance with workflow integration and documentation
- Add pre-push git hook with shellcheck and unit test validation
- Extract Node.js project templates to external files
- Extract R project templates from embedded code
- Extract Rust project templates from embedded code
- Extract Mojo project templates from embedded code
- Extract Java templates from embedded code

### Changed

- Extract cache-utils.sh shared utility to eliminate duplication
- Extract path-utils.sh shared utility to eliminate PATH manipulation duplication
- Extract Go project templates from go-new function (Item #23 WIP)
- Replace heredocs with Go template loader in golang.sh
- Standardize project scaffolding to {lang}-init naming convention
- Extract Ruby config templates to dedicated files

### Documentation

- Mark roadmap item #2 (passwordless sudo) as complete
- Mark roadmap item #3 (Docker socket auto-fix) as complete
- Add case-sensitive filesystem roadmap item and renumber
- Mark roadmap Item #4 as COMPLETE - flexible version resolution for all 6 languages
- Mark roadmap item #32 (Pre-Push Git Hook) as complete
- Mark roadmap Items #20 and #21 as complete
- Update roadmap to mark Item #23 complete for all languages

### Fixed

- Add production variant to build matrix
- Update unit tests for 4-tier verification system
- Set BUILD_LOG_DIR early to avoid permission errors in CI
- Implement proper fallback strategy for BUILD_LOG_DIR in rootless environments
- Fix shellcheck warnings in signature-verify.sh
- Fix shellcheck warnings in update-checksums.sh
- Align CI and pre-push hook to respect .gitignore
- Resolve shellcheck warnings across test suite
- Resolve remaining shellcheck warnings in test framework
- Make setup-bashrc.d unit test executable
- Eliminate command injection vectors in apt-utils.sh

### Miscellaneous

- Exclude checksum database backup files from git
- Update cspell dictionary with new technical terms

### Security

- Change ENABLE_PASSWORDLESS_SUDO default to false

### Testing

- Add unit tests for Go template system

## [4.8.6] - 2025-11-14

### Added

- Add production container examples and fix logging initialization

### Documentation

- Add HIGH priority item for pre-push git hook
- Update pre-push hook item to include unit tests
- Update roadmap with Ruby checksum fixes and flexible version resolution

### Fixed

- Fix Ruby checksum fetching and parameter order + add production tests to CI

### Testing

- Add production helper unit tests and multi-runtime integration test

## [4.8.5] - 2025-11-12

### Fixed

- Export DEV_TOOLS_CACHE, CAROOT, DIRENV_ALLOW_DIR variables
- Export missing variables for log_feature_summary (batch 1)
- Export missing variables for log_feature_summary (batch 2 - final)

## [4.8.4] - 2025-11-12

### Fixed

- Remove quotes from command in apt_retry to allow word splitting

## [4.8.3] - 2025-11-12

### Fixed

- Separate declaration and assignment in test-version-compatibility.sh

## [4.8.2] - 2025-11-12

### Fixed

- Allow release script flags in any position

## [4.8.1] - 2025-11-12

### Added

- Add comprehensive build metrics tracking system
- Add comprehensive version compatibility testing system

### Fixed

- Export all variables before log_feature_summary calls

### Testing

- Add comprehensive error message verification tests

## [4.8.0] - 2025-11-12

### Added

- Add list-features.sh script with JSON output and filtering
- Add standardized feature configuration summaries
- Add feature summaries to all 26 remaining feature scripts
- Add filtering and help to check-installed-versions.sh
- Add timeout configuration to all checksum fetch operations
- Add environment variable validation schema and validator
- Add download progress indicators and fix schema patterns
- Add centralized cleanup handling for interrupted builds
- Add comparison mode and fix bugs in check-installed-versions.sh

### Changed

- Deduplicate checksum fetching code

### Documentation

- Add comprehensive environment variables reference
- Expand troubleshooting guide with comprehensive build-time issues
- Add comprehensive production deployment guide
- Add comprehensive feature dependencies documentation
- Update roadmap with completed improvements
- Add comprehensive version migration guide
- Add comprehensive cache strategy documentation
- Update roadmap with Option A Quick Wins completion
- Add comprehensive contributing guidelines
- Update roadmap with Option B Code Quality completion
- Verify comment formatting already standardized
- Update roadmap with Option C: Reliability completion
- Update roadmap with Option D: Usability completion
- Add CHANGELOG format documentation
- Document exit code conventions in CONTRIBUTING.md
- Update roadmap with Option F: Minor Issues completion

### Fixed

- Prevent alias invasion in scripts and fix Cosign signing permissions
- Add trap handlers for interrupted download cleanup
- Use install command for atomic sudo file creation
- Improve entrypoint path traversal validation
- Fix shellcheck SC2181 warnings in check-installed-versions.sh
- Replace tilde with $HOME in log_feature_summary paths
- Replace example values with placeholders in .env.example

### Miscellaneous

- Remove .claude directory from version control

## [4.7.0] - 2025-11-11

### Added

- Add retry logic with exponential backoff for external API calls
- Add tidyverse to r-dev for modern R data science workflows
- Automate GitHub release creation in release script and auto-patch workflow
- Add comprehensive container healthcheck system

### Documentation

- Add container image security to hardening roadmap
- Comprehensive documentation cleanup and reorganization
- Update security hardening progress - Phases 1 & 2 complete
- Document secrets exposure risks in build arguments (Issue #11)
- Update security hardening status - Phases 3 & 4 complete
- Update SECURITY.md version and timestamp
- Mark issue #12 (Docker socket security) as complete
- Update security hardening status - Phase 5 complete
- Update README with security hardening improvements
- Update SECURITY.md with comprehensive security hardening details
- Remove outdated ANALYSIS.md file
- Move security-hardening.md to main docs directory
- Add comprehensive codebase review and improvements roadmap
- Update roadmap with completed credential protection work
- Add comprehensive emergency rollback procedures

### Fixed

- Export JMH_VERSION for runtime shell functions
- Remove stray 'n' characters causing shellcheck errors
- Quote variables to resolve SC2086 shellcheck warnings
- Remove stray 'n' character in rust.sh (SC2288)
- Quote all variables to resolve SC2086 shellcheck warnings
- Disable SC2016 in shellcheckrc and fix remaining info-level issues
- Critical bug in apt_install - unquote package list for word splitting
- Remove incorrect secure-temp.sh source references
- Redirect log_message to stderr in create_secure_temp_dir
- Remove EXIT trap from create_secure_temp_dir to prevent premature cleanup
- Change secure temp directory permissions from 700 to 755
- Prevent 'Argument list too long' error in tests by not exporting TEST_OUTPUT
- Add explicit cleanup for build temp directories in feature scripts
- Make Go dev tool installations non-fatal to handle transient network errors
- Resolve test framework double-counting bug and /cache/go ownership issue
- Add missing parent cache directory creation in R and Mojo features
- Resolve test framework multi-assertion counting bug and R test package errors
- Update expected Rscript version output in R integration test
- Fix Cosign signing digest extraction in CI release job
- Remove incorrect backslash escapes in single-quoted heredocs
- Fix healthcheck script installation and set -e interaction

### Miscellaneous

- Add cat to auto-approved bash commands for Claude Code
- Fix shellcheck warnings and add R to CI test matrix

### Security

- Add Docker socket security warnings (Issue #12)

### Testing

- Add integration test for R development environment

### Security

- Fix CRITICAL command injection vulnerability in version checking
- Add container image digests and Cosign signing
- Add optional passwordless sudo control
- Add safe_eval wrapper for tool initialization
- Add path validation for startup scripts
- Add checksum verification for Claude Code installer
- Add version validation to prevent shell injection
- Add safer 1Password credential handling (Issue #6)
- Implement atomic cache directory creation (#8)
- Validate completion outputs before sourcing (#9)
- Sanitize user function inputs to prevent injection (#10)
- Add secure temp directory pattern - Batch 1 (#13)
- Secure temp directories - Batch 2 (#13)
- Secure temp directories - Batch 3 Final (#13)
- Add comprehensive credential leak prevention system

## [4.5.0] - 2025-11-09

### Added

- Add .dockerignore to prevent secrets in build context
- Add checksum verification utilities for supply chain security
- Add checksum verification to kubernetes.sh
- Add automated checksum updater system
- Integrate krew tracking and checksum updates in version system
- Add dev-tools checksum updater script
- Add checksum verification to dev-tools.sh
- Add SHA256 checksum verification to golang.sh
- Add checksum verification to terraform.sh (Phase 5)
- Complete terraform.sh checksum integration (Phase 5)
- Complete rust.sh checksum integration (Phase 6 partial)
- Complete mojo.sh checksum integration (Phase 6 complete)
- Fix node.sh CRITICAL curl | bash vulnerability (Phase 7 - 1/2)
- Fix cloudflare.sh CRITICAL curl | bash vulnerability (Phase 7 complete)
- Add SHA256 verification to ruby.sh (Phase 8 - 1/4)
- Add partial version resolution support to Ruby
- Add partial version resolution support to Go
- Add GPG signature verification to AWS CLI v2 installation
- Add checksum verification to java-dev.sh tools
- Add checksum verification for dive .deb package (Phase 9 complete)
- Add checksum verification for terragrunt (Phase 10 started)
- Add checksum verification for duf and glab (Phase 10 complete)
- Secure install scripts - Ollama direct download, Claude verified safe (Phase 11 complete)
- Add calculated checksum verification for tools without published checksums (Phase 12 complete)
- Add checksum verification for JBang (Phase 13 - 1/4)
- Add JBang checksum verification and fix heredoc bug in java-dev
- Add checksum verification for all remaining downloads (Phase 13 complete)

### Changed

- Extract shared utilities to bin/lib/
- Implement dynamic checksum fetching for flexible version support
- Remove redundant fallback checksums from golang.sh
- Migrate kubernetes.sh to dynamic checksum fetching
- Migrate dev-tools.sh to dynamic checksum fetching
- Migrate docker.sh to dynamic checksum fetching for lazydocker

### Documentation

- Add SECURITY.md with vulnerability reporting procedures
- Add Docker socket security guidance to README
- Update checksum verification inventory
- Add Docker build testing guidance to CLAUDE.md
- Update checksum verification inventory with Phase 1 & 2 completion
- Document version update script behavior for golang
- Update checksum verification inventory with test completion
- Update checksum verification inventory with Phase 4 completion
- Update inventory with comprehensive security audit findings
- Update inventory - Phase 7 complete (node.sh + cloudflare.sh)
- Add partial version resolution analysis
- Update inventory for Phase 8 completion
- Remove outdated guide and add implementation section to inventory
- Rename checksum-verification-inventory.md to checksum-verification.md
- Add comprehensive security hardening roadmap

### Fixed

- Add header guards to prevent multiple sourcing
- Isolate require_command test in subshell
- Fix intermittent entrypoint error handling test
- Fix dynamic Go checksum fetching and enhance test script
- Resolve R version checker hanging and output issues
- Update-versions.sh now syncs ruby.sh default with Dockerfile
- Make AWS CLI GPG fingerprint verification case-insensitive
- Handle GPG fingerprint format with variable spaces in AWS CLI verification

### Testing

- Add comprehensive unit tests for refactored code
- Add comprehensive unit tests for dev-tools checksum verification
- Add quick feature test script for isolated feature testing
- Simplify dev-tools checksum tests to use pattern matching
- Remove obsolete kubernetes-checksums updater test
- Add checksum verification tests to kubernetes feature
- Add checksum verification tests to golang feature

## [4.4.0] - 2025-11-03

### Fixed

- Handle pnpm corepack signature verification failures gracefully
- Handle pnpm/yarn cache clean failures in node-deep-clean

### Testing

- Make pnpm integration test non-fatal for corepack issues

## [4.3.2] - 2025-11-01

### Added

- Add failure notification to version-check job

### Documentation

- Update README with accurate feature counts and Debian support
- Update README with complete test count including integration tests
- Update .env.example to focus on 1Password integration

### Fixed

- Prevent double-commit in auto-patch workflow
- Use fine-grained PAT to trigger CI on auto-patch branches
- Sanitize branch names in Docker tags for auto-patch branches
- Add version bump step and fix version extraction in auto-patch workflow

### Miscellaneous

- Automated version updates
- Roll back Rust to 1.90.0 to test auto-patch workflow
- Automated version updates to v4.3.2

## [4.3.1] - 2025-10-26

### Fixed

- Disable SHA-based Docker tags to prevent invalid tag format

## [4.3.0] - 2025-10-26

### Fixed

- Separate variable declaration and assignment in release script

## [4.2.0] - 2025-10-26

### Fixed

- Add automation guidance to release script cancellation message

### Miscellaneous

- Update cspell dictionary with binutils

## [4.1.0] - 2025-10-26

### Added

- Add Trivy container security scanning to CI/CD
- Add Gitleaks secret scanning to CI/CD
- Add shellcheck enforcement to CI with comprehensive fixes
- Add Trivy GitHub Action version tracking
- Pin Poetry version and update version tracking documentation
- Add Debian version detection and conditional package installation
- Add arm64 support to Maven Daemon installation
- Automated patch release system with Pushover notifications
- Automate CHANGELOG generation with git-cliff
- Add git-cliff to dev-tools feature
- Add eza support for modern ls replacement with Debian version detection

### CI/CD

- Add integration tests to workflow and status badges to README
- Switch testing from minimal to python-dev variant
- Switch testing from node-dev to cloud-ops variant
- Enable all integration test variants

### Changed

- Replace skipped tests with meaningful minimal image validation

### Documentation

- Update documentation for GitHub Actions migration
- Update version tracking documentation
- Add comprehensive troubleshooting guide
- Update ANALYSIS.md to reflect completed improvements
- Restructure README for better navigation
- Update README with improved test coverage
- Update ANALYSIS.md to reflect completed testing work
- Update CHANGELOG for post-4.0.0 improvements and fixes
- Remove completed file permissions issue from ANALYSIS.md
- Enhance troubleshooting guide with Debian compatibility and recent fixes
- Update ANALYSIS.md to reflect completed troubleshooting documentation
- Update CHANGELOG with integration test PROJECT_PATH fix
- Add comprehensive Debian version compatibility guide
- Update CHANGELOG with recent fixes and features

### Fixed

- Add executable permissions to feature and base scripts
- Configure Gitleaks to scan files instead of git history
- Remove invalid args parameter from gitleaks action
- Fetch full git history for Gitleaks scanning
- Only upload Trivy results if scan succeeds
- Correct image tag format in security scan
- Use simple branch-variant tag for security scanning
- Add backwards compatibility for apt-key deprecation
- Add PROJECT_PATH=. to all integration tests for standalone builds
- Resolve shellcheck warnings in apt-utils.sh
- Remove Debian 12+ requirement to support Debian 11
- CRITICAL - Fix CI build args format preventing feature installation
- Use dynamic Debian codename in R repository URL
- CRITICAL - Integration tests now use pre-built images from registry
- CRITICAL - Correct YAML multiline interpolation in build args
- Add rust-golang variant to build job to match integration tests
- CI integration tests and add incremental testing support
- Minimal test workspace path for CI-built images
- Skip custom build tests when testing pre-built minimal image
- Prevent double-counting skipped tests in test framework
- Test for actual utilities in minimal image, not vim
- Prevent double-counting failed tests in test framework
- Integration test runner exits with code 1 even when tests pass
- Use valid Python code in ruff test
- Node-dev tests - ts-node and dev tools
- Simplify ts-node test to avoid output capture issues
- Add --validate=false to kubectl test to work without API server
- Use KUBECONFIG=/dev/null for kubectl test without cluster
- Replace kubectl manifest test with output format test
- TypeScript test uses file-based compilation instead of stdin
- Add build-essential to golang-dev for CGO compilation
- Add build-essential to rust-dev and node-dev for native compilation
- Explicitly add binutils to golang-dev for ld linker
- Install binutils-gold for Go external linking on ARM64
- Update Go compilation test for Go 1.24+ module requirements
- Include rust-golang variant in security scanning

### Miscellaneous

- Bump version correctly
- Use correct github action version
- Remove GitLab CI/CD configuration files
- Update GitHub Actions to latest versions
- Migrate base image from Debian Bookworm to Trixie
- Update language and tool versions
- Update tool versions in feature scripts
- Simplify VS Code workspace settings
- Make setup-git-ssh.sh executable
- Fix inconsistent version pinning for Helm
- Clean up outdated pyenv/rbenv references
- Add example names to cSpell dictionary
- Update Trivy action to v0.30.0
- Update dependency versions

### Testing

- Add comprehensive integration test suite
- Add Debian version compatibility matrix to CI
- Add comprehensive python-dev integration tests
- Add comprehensive node-dev tests and enable in CI
- Enhance cloud-ops, polyglot, and rust-golang integration tests

## [4.0.0] - 2025-10-01

### Added

- Add standalone Docker socket permission fix script
- Add VS Code devcontainer configuration
- Add comprehensive version tracking for all hardcoded tools
- Migrate key feature scripts to use centralized apt-utils
- Migrate more feature scripts to use apt-utils
- Migrate -dev scripts to use apt-utils
- Update remaining -dev scripts and AWS to use apt-utils
- Complete migration of all feature scripts to apt-utils
- Migrate to Debian Trixie and GitHub (v4.0.0)

### Documentation

- Add unit test documentation to README
- Update CI push authentication to reflect current implementation
- Add comprehensive security scanning and project initialization design

### Fixed

- Add Docker socket permission handling in docker.sh
- Add flexible authentication for CI push operations
- Add complete version checking and updating for Java dev tools
- Fix Node.js installation and add version pinning support
- Resolve CI branch switching conflict with version-updates.json
- Resolve CI push conflicts in version update job
- Fix Node.js installation script logging initialization order
- Add version validation to prevent null values and fix GitLab CI schedule
- Handle full kubectl version format in kubernetes.sh
- Add retry mechanism for apt operations to handle network issues
- Complete R feature migration to apt-utils
- Update base setup and unit tests to use apt-utils
- Export apt_retry function for use in other scripts
- Add missing apt_retry function definition
- Fix apt-utils test patterns to match actual function definitions

### Miscellaneous

- Bump version to 1.0.1
- Add results/ directory to .gitignore
- Fix Python feature script permissions
- Add cspell configuration for spell checking
- Complete version tracking and update to 2.2.8
- Remove unused env_manager.sh and buildkit dependency
- Update cspell dictionary with project-specific terms
- Update dependency versions
- Release patch version with dependency updates
- Apply automated formatting
- Update dependency versions
- Release patch version with dependency updates
- Update dependency versions
- Release patch version with dependency updates
- Update cspell dictionary with new project words
- Update cspell dictionary with new project words
- Add executable permissions to shell scripts

### Security

- Remove deprecated npm packages from Node.js dev tools

### Testing

- Add comprehensive unit test framework
- Add comprehensive tests for new version tracking features
- Add tests for release cancellation message and auto-confirmation
- Fix release tests to prevent modifying actual VERSION file
- Fix release auto-confirmation test to avoid version bumps

### Improve

- Add helpful error message when release is cancelled
- Add VS Code workspace settings and improve gitignore

[4.12.5]: https://github.com/joshjhall/containers/compare/v4.12.4...v4.12.5
[4.12.4]: https://github.com/joshjhall/containers/compare/v4.12.3...v4.12.4
[4.12.3]: https://github.com/joshjhall/containers/compare/v4.12.2...v4.12.3
[4.12.2]: https://github.com/joshjhall/containers/compare/v4.12.1...v4.12.2
[4.12.1]: https://github.com/joshjhall/containers/compare/v4.12.0...v4.12.1
[4.12.0]: https://github.com/joshjhall/containers/compare/v4.11.0...v4.12.0
[4.11.0]: https://github.com/joshjhall/containers/compare/v4.10.1...v4.11.0
[4.10.1]: https://github.com/joshjhall/containers/compare/v4.10.0...v4.10.1
[4.10.0]: https://github.com/joshjhall/containers/compare/v4.9.2...v4.10.0
[4.9.2]: https://github.com/joshjhall/containers/compare/v4.9.1...v4.9.2
[4.9.1]: https://github.com/joshjhall/containers/compare/v4.9.0...v4.9.1
[4.9.0]: https://github.com/joshjhall/containers/compare/v4.8.6...v4.9.0
[4.8.6]: https://github.com/joshjhall/containers/compare/v4.8.5...v4.8.6
[4.8.5]: https://github.com/joshjhall/containers/compare/v4.8.4...v4.8.5
[4.8.4]: https://github.com/joshjhall/containers/compare/v4.8.3...v4.8.4
[4.8.3]: https://github.com/joshjhall/containers/compare/v4.8.2...v4.8.3
[4.8.2]: https://github.com/joshjhall/containers/compare/v4.8.1...v4.8.2
[4.8.1]: https://github.com/joshjhall/containers/compare/v4.8.0...v4.8.1
[4.8.0]: https://github.com/joshjhall/containers/compare/v4.7.0...v4.8.0
[4.7.0]: https://github.com/joshjhall/containers/compare/v4.5.0...v4.7.0
[4.5.0]: https://github.com/joshjhall/containers/compare/v4.4.0...v4.5.0
[4.4.0]: https://github.com/joshjhall/containers/compare/v4.3.2...v4.4.0
[4.3.2]: https://github.com/joshjhall/containers/compare/v4.3.1...v4.3.2
[4.3.1]: https://github.com/joshjhall/containers/compare/v4.3.0...v4.3.1
[4.3.0]: https://github.com/joshjhall/containers/compare/v4.2.0...v4.3.0
[4.2.0]: https://github.com/joshjhall/containers/compare/v4.1.0...v4.2.0
[4.1.0]: https://github.com/joshjhall/containers/compare/v4.0.0...v4.1.0
[4.0.0]: https://github.com/joshjhall/containers/compare/b2699c052d341b50ab3567775e4918a77ee78277...v4.0.0
