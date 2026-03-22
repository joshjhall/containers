# Architecture & Design

This directory contains architectural design documents and technical analysis of
the container build system.

## Design Documents

### Core Architecture

- [**Architecture Review**](review.md) - Comprehensive system architecture and
  design patterns
- [**Caching Strategy**](caching.md) - BuildKit cache mounts and optimization
  approach
- [**Observability Design**](observability.md) - Metrics, logging, and
  monitoring architecture

### Security & Verification

- [**Checksum Verification**](checksum-verification.md) - 4-tier progressive
  checksum verification system and module hierarchy
- [**God Modules**](god-modules.md) - High fan-in infrastructure modules
  (`feature-header.sh`, `logging.sh`)

### Technical Analysis

- [**Version Resolution**](version-resolution.md) - Partial version resolution
  system (e.g., `3.3` → `3.3.10`)

### Future Design

- [**Security Scanning System**](security-scanning-system.md) - Comprehensive
  security scanning and project initialization (design phase)

## Module Dependency Map

```text
BUILD-TIME LAYER
═════════════════════════════════════════════════════════════════

Dockerfile
├── lib/base/setup.sh                 System packages, locale
├── lib/base/user.sh                  Non-root user creation
│
├── lib/features/*.sh                 Feature installation scripts
│   │
│   ├── feature-header.sh ◄────────── Sourced by ALL feature scripts (~42)
│   │   ├── arch-utils.sh               CPU architecture mapping
│   │   ├── cleanup-handler.sh          Trap-based temp dir cleanup
│   │   ├── logging.sh ◄──────────── Sourced by ~32 modules
│   │   │   ├── message-logging.sh       log_message, log_error, ...
│   │   │   ├── feature-logging.sh       log_feature_start/end
│   │   │   ├── json-logging.sh          Optional JSON output
│   │   │   └── secret-scrubbing.sh      Credential redaction
│   │   └── bashrc-helpers.sh            Shell config writers
│   │
│   ├── version-validation.sh         Input format checks
│   ├── version-resolution.sh         Partial → full version (3.12 → 3.12.7)
│   ├── download-verify.sh            curl wrapper with retry
│   ├── apt-utils.sh                  Debian version-aware apt
│   ├── cache-utils.sh                /cache directory setup
│   ├── path-utils.sh                 Secure PATH management
│   │
│   ├── setup-paths.sh               PATH and env initialization (build-time)
│   ├── setup-startup.sh             Startup directory structure (build-time)
│   │
│   └── checksum-verification.sh ◄─── Sourced by ~20 download features
│       ├── checksum-tier4.sh            TOFU fallback
│       ├── checksum-fetch.sh            Published checksum fetchers
│       └── signature-verify.sh          GPG + Sigstore (lazy-loaded)
│           ├── sigstore-verify.sh
│           └── gpg-verify.sh
│
└── lib/shared/                       Cross-layer utilities
    ├── export-utils.sh                 protected_export
    ├── logging.sh                      Minimal shared log functions
    ├── path-utils.sh                   Shared path helpers
    └── safe-eval.sh                    Safe command evaluation

RUNTIME LAYER
═════════════════════════════════════════════════════════════════

lib/runtime/entrypoint.sh             Container startup (PID 1 via tini)
├── validate-config.sh                Configuration validation
├── check-build-logs.sh               Build log inspection tool
├── check-installed-versions.sh       Version reporting tool
└── audit-logger.sh                   Security audit logging
    ├── audit-logger-events.sh
    ├── audit-logger-maintenance.sh
    └── audit-logger-shippers.sh
```

**Key dependency chains for contributors**:

- Adding a language feature: `feature-header.sh` → `version-validation.sh` →
  `version-resolution.sh` → `checksum-verification.sh` → `download-verify.sh`
- Adding a tool feature: `feature-header.sh` → `checksum-verification.sh` →
  `register_tool_checksum_fetcher` → `download-verify.sh`
- Adding a runtime script: `lib/runtime/` → `lib/shared/` (no `lib/base/`
  dependency)

## Purpose

These documents explain **why** the system is designed the way it is, providing
context for:

- Design decisions and trade-offs
- System architecture patterns
- Technical implementation approaches
- Feature design rationale

## For Contributors

When adding new features or making significant changes:

1. Review relevant architecture docs first
1. Consider whether your change affects the documented design
1. Update architecture docs if introducing new patterns
1. Add new analysis docs for complex features

## Related Documentation

- [Development](../development/) - How to build and contribute
- [Reference](../reference/) - Technical specifications and APIs
- [Operations](../operations/) - Deployment and management
