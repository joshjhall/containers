# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

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
