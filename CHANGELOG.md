# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Automated CHANGELOG generation with git-cliff
- Enhanced release script with non-interactive mode for CI/CD
- Comprehensive release documentation (docs/releasing.md)
- git-cliff configuration for consistent changelog formatting

### Fixed

- **golang-dev**: Install binutils-gold for Go external linking on ARM64
  - Go 1.24 requires gold linker for external linking (see Go issue #22040)
  - Matches Debian's official golang-go package dependency
  - Added detailed documentation explaining deprecation status
- **rust-dev**: Add build-essential for Rust crates with C dependencies
- **node-dev**: Add build-essential for Node.js native addon compilation
- **Tests**: Update Go compilation test for Go 1.24+ module requirements
  - Tests now create proper Go modules before building
  - Better reflects real-world Go development practices
- **CRITICAL**: Fixed CI build args format causing features to not install
  - Build args in CI workflow were space-separated on single line
  - Docker build-push-action requires each arg on separate line
  - All variants (python-dev, node-dev, cloud-ops, polyglot) now properly install features
  - Previous builds had NO features installed except base system packages
- **CRITICAL**: Removed Debian 12+ version requirement to support Debian 11
  - feature-header.sh was blocking all builds on Debian 11 (Bullseye)
  - Now supports Debian 11, 12, and 13 with version detection in apt-utils.sh
  - Version-specific packages handled via apt_install_conditional function
- **CRITICAL**: Added backwards compatibility for apt-key deprecation
  - terraform.sh, gcloud.sh, kubernetes.sh now auto-detect Debian version
  - Debian 11/12 (Bookworm): Uses legacy apt-key method
  - Debian 13+ (Trixie): Uses modern signed-by GPG method
  - Fixes build failures when using Terraform, Google Cloud, or Kubernetes features
- **CRITICAL**: Fixed integration tests to use PROJECT_PATH=. for standalone builds
  - Integration tests now correctly build containers standalone
  - All 6 tests updated with proper PROJECT_PATH argument
  - Fixes "tools not in PATH" failures where builds succeeded but features weren't installed

### Added

- Poetry version pinning (2.2.1) - now properly tracked and automated
- Comprehensive integration test suite (6 test suites covering all CI variants)
- Integration tests now run in CI pipeline
- Build status badges in README
- **Debian version compatibility system**:
  - Automatic Debian version detection (11, 12, 13) in apt-utils.sh
  - Conditional package installation based on Debian version
  - Python feature now installs correct packages for each Debian version
  - CI matrix testing for Debian 11 (Bullseye), 12 (Bookworm), 13 (Trixie)
  - Ensures backwards compatibility while supporting latest Debian releases

### Improved

- Test coverage: 488 unit tests (99% pass rate) + 6 integration test suites
- All version pinning now complete and tracked (duf, entr, Poetry, Helm)
- Updated documentation for version tracking and testing infrastructure

## [4.0.0] - 2025-10-01

### Changed

- **BREAKING**: Upgraded base image from Debian Bookworm to Debian Trixie (debian:trixie-slim)
- Migrated from GitLab CI/CD to GitHub Actions
- Simplified branch strategy - now using main branch only (removed develop branch)
- Open sourced under MIT License

### Added

- GitHub Actions CI/CD workflow (.github/workflows/ci.yml)
- Support for GitHub Container Registry (ghcr.io)
- Automated issue creation for version updates

### Improved

- All features fully compatible with Debian Trixie
- Streamlined release process for open source distribution

## [1.0.0] - 2025-01-10

### Added

- Initial release of the Universal Container Build System
- Modular Dockerfile with 20+ configurable features
- Support for languages: Python, Node.js, Rust, Go, Ruby, Java, R, Mojo
- Development tools integration (VS Code, debugging, linting)
- Cloud platform support (AWS, GCP, Kubernetes, Terraform)
- Database client support (PostgreSQL, Redis, SQLite)
- Comprehensive test framework
- BuildKit cache optimization
- Non-root user security model
- Git submodule integration support
- Example configurations for various use cases
- Documentation and environment variable templates

### Security

- Non-root user by default with configurable UID/GID
- Proper file permissions throughout build process
- Validated installation scripts for all features

[Unreleased]: https://github.com/yourusername/containers/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/yourusername/containers/releases/tag/v1.0.0
