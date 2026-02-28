# Troubleshooting Guide

This guide covers common issues and their solutions when using the container
build system. Each topic area has its own detailed page.

> **Important**: If you're experiencing build failures with Terraform, Google
> Cloud, or Kubernetes features, see
> [Debian Version Compatibility](troubleshooting/debian-compatibility.md) first.
> A critical fix was added in v4.0.1 for apt-key deprecation in Debian Trixie.

## Topics

| Guide                                                                 | Description                                                             |
| --------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| [Build Issues](troubleshooting/build-issues.md)                       | Build failures, Buildx differences, cache issues, compilation errors    |
| [Debian Compatibility](troubleshooting/debian-compatibility.md)       | apt-key deprecation, Trixie differences, writing compatible scripts     |
| [Runtime Issues](troubleshooting/runtime-issues.md)                   | PATH problems, UID/GID conflicts, permission issues, bindfs/FUSE        |
| [Network Issues](troubleshooting/network-issues.md)                   | Download failures, proxy config, checksum/GPG verification, rate limits |
| [Feature-Specific Issues](troubleshooting/feature-specific-issues.md) | Python, Node.js, Rust, Docker, Kubernetes                               |
| [CI/CD Issues](troubleshooting/ci-cd-issues.md)                       | Integration test failures, GitHub Actions timeouts, security scanning   |
| [Debugging Tools](troubleshooting/debugging-tools.md)                 | Built-in diagnostics, log inspection, getting help                      |

## Platform-Specific Guides

| Guide                                                                       | Description                               |
| --------------------------------------------------------------------------- | ----------------------------------------- |
| [Case-Sensitive Filesystems](troubleshooting/case-sensitive-filesystems.md) | Linux container filesystem issues         |
| [Docker for Mac](troubleshooting/docker-mac-case-sensitivity.md)            | macOS-specific Docker and VirtioFS issues |

## Related Documentation

- [Version Tracking](reference/versions.md) - Managing tool versions
- [Testing Framework](development/testing.md) - Testing guide
- [Security Hardening](security-hardening.md) - Security model
- [README](../README.md) - Getting started
- [CHANGELOG](../CHANGELOG.md) - Recent changes and fixes
