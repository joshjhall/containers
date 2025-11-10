# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.6.0] - 2025-11-10

### Added

- Add retry logic with exponential backoff for external API calls
- Add tidyverse to r-dev for modern R data science workflows

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

[4.6.0]: https://github.com/joshjhall/containers/compare/v4.5.0...v4.6.0
[4.5.0]: https://github.com/joshjhall/containers/compare/v4.4.0...v4.5.0
[4.4.0]: https://github.com/joshjhall/containers/compare/v4.3.2...v4.4.0
[4.3.2]: https://github.com/joshjhall/containers/compare/v4.3.1...v4.3.2
[4.3.1]: https://github.com/joshjhall/containers/compare/v4.3.0...v4.3.1
[4.3.0]: https://github.com/joshjhall/containers/compare/v4.2.0...v4.3.0
[4.2.0]: https://github.com/joshjhall/containers/compare/v4.1.0...v4.2.0
[4.1.0]: https://github.com/joshjhall/containers/compare/v4.0.0...v4.1.0
[4.0.0]: https://github.com/joshjhall/containers/compare/eaf66b40b4bcdf36e8b6da1113b349e3509fb26c...v4.0.0

