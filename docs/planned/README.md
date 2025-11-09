# Planned Features and Future Work

This directory contains design documents and roadmaps for features that are planned but not yet implemented.

## What Belongs Here

- **Design documents** for proposed features
- **Roadmaps** for planned improvements
- **Architecture proposals** awaiting implementation
- **Feature specifications** not yet prioritized

## Current Documents

### Security Enhancements

- **[security-hardening.md](security-hardening.md)** - Security hardening roadmap with 16 planned improvements
  - Command injection fixes
  - Sudo access controls
  - Container security hardening
  - Image signing and verification
  - **Status**: Active roadmap - work not yet started
  - **When complete**: Will be moved to `docs/archived/` as reference

- **[security-and-init-system.md](security-and-init-system.md)** - Comprehensive security scanning and project initialization system
  - Language-specific security tools (cargo-audit, npm audit, pip-audit, etc.)
  - Unified `dev-init` command for all languages
  - CI/CD template generation
  - **Status**: Design document - not yet prioritized

- **[security-scan-quick-reference.md](security-scan-quick-reference.md)** - Quick reference for planned security scanning features
  - Tool matrix for all supported languages
  - Command examples
  - **Status**: Quick reference for above design - not yet implemented

## Document Lifecycle

1. **Planned** (here) → Features designed but not implemented
2. **Active** (docs/) → Features being implemented or in use
3. **Archived** (docs/archived/) → Completed work preserved as reference

## When to Move Documents

**Move FROM planned/ TO docs/**:
- When starting implementation
- When a feature becomes active

**Move FROM planned/ TO docs/archived/**:
- When work is completed
- Rename to reflect completion (e.g., `security-hardening.md` → `security-hardening-completed.md`)

## Related Documentation

- [docs/archived/](../archived/) - Completed work and historical reference
- [docs/checksum-verification.md](../checksum-verification.md) - Example of completed security work
- [CHANGELOG.md](../../CHANGELOG.md) - Track when planned features are implemented
