# Security Scanning Quick Reference

## Summary

Comprehensive security scanning and project initialization system for all supported languages in the container build system.

## Core Commands (Planned)

```bash
# Unified commands (will work for all languages)
dev-init --init        # Initialize project with best practices
dev-init --scan        # Run security scans
dev-init --update      # Check for outdated dependencies
dev-init --ci          # Generate CI/CD configs
```

## Language-Specific Security Tools

### Rust

- **cargo-audit** - Vulnerability database scanning
- **cargo-deny** - Supply chain security & license checks
- **cargo-geiger** - Unsafe code detection
- **cargo-public-api** - API surface tracking
- **cargo-outdated** - Dependency freshness
- **cargo-udeps** - Unused dependency detection

### Node.js

- **npm audit** - Built-in vulnerability scanning
- **better-npm-audit** - Enhanced npm audit
- **snyk** - Comprehensive security platform
- **npm-check-updates** - Dependency updates
- **depcheck** - Unused dependency finder

### Python

- **pip-audit** - Vulnerability scanning
- **safety** - Security database checks
- **bandit** - Security linter
- **pip-review** - Update checking
- **vulture** - Dead code detection

### Go

- **nancy** / **gosec** - Security scanning
- **go mod audit** - Native vulnerability scanning (Go 1.21+)
- **go-licenses** - License checking

### Ruby

- **bundler-audit** - Vulnerability scanning
- **brakeman** - Security scanner for Rails
- **bundle-leak** - Memory leak detection

### Java

- **dependency-check** - OWASP vulnerability scanner
- **snyk** - Cross-language security
- **find-sec-bugs** - Security bug patterns

## Implementation Timeline

### Current Status

- ✅ Design documented
- ⏸️ Implementation paused pending Stibbons evaluation (3-4 weeks)

### Short-term (Bash-based)

- Quick implementation possible
- Works with current infrastructure
- No new dependencies

### Long-term (Stibbons-based)

- Type-safe Rust implementation
- Advanced multi-environment support
- Plugin architecture
- Better performance and security

## Key Features

1. **Unified Interface** - Same commands for all languages
2. **CI/CD Ready** - Identical commands locally and in pipelines
3. **Non-invasive** - Opt-in, won't modify without permission
4. **Extensible** - Easy to add new tools and languages
5. **Best Practices** - Includes configs, hooks, and documentation

## Why Wait?

- Stibbons (Rust CLI tool) coming in 3-4 weeks
- Avoid duplicate implementation effort
- Better long-term solution
- More maintainable and secure

## Quick Implementation

If needed before Stibbons:

```bash
# Add to rust-dev.sh
cargo install cargo-audit cargo-deny cargo-outdated

# Create simple scanner
cat > /usr/local/bin/rust-scan << 'EOF'
#!/bin/bash
cargo audit
cargo outdated
cargo deny check 2>/dev/null || true
EOF
chmod +x /usr/local/bin/rust-scan
```

## Related Files

- [Full Design Document](./SECURITY-AND-INIT-SYSTEM.md)
- Stibbons Project (when available)
- Feature files in `lib/features/*-dev.sh`

---

*Quick reference for security scanning system. See full design document for complete details.*
