# Security Scanning and Project Initialization System

## Status

**Design Phase** - Implementation paused pending evaluation of Stibbons
(Rust-based CLI tool)

**Related Issues:**

- #18: Add cargo-audit and cargo-deny to rust-dev.sh
- #19: Add pip-audit to python-dev.sh
- #20: Add cargo-geiger to rust-dev.sh
- #21: Add govulncheck to golang-dev.sh

## Overview

This document outlines the design for a comprehensive security scanning and
project initialization system for the container build system. The goal is to
provide consistent, language-specific security tools and project scaffolding
that works seamlessly across all development environments.

## Core Objectives

1. **Security First**: Built-in vulnerability scanning for all supported
   languages
2. **Consistency**: Unified commands that work across all languages
3. **CI/CD Ready**: Same tools work locally and in CI pipelines
4. **Extensibility**: Easy to add new languages and tools
5. **Non-invasive**: Opt-in system that doesn't modify projects without
   permission

## Language-Specific Security Tools

### Currently Installed

| Language | Tool           | Purpose                  | Status       |
| -------- | -------------- | ------------------------ | ------------ |
| Rust     | cargo-outdated | Outdated dependencies    | ✅ Installed |
| Python   | bandit         | Code security linting    | ✅ Installed |
| Ruby     | brakeman       | Rails security scanner   | ✅ Installed |
| Ruby     | bundler-audit  | Vulnerability scanning   | ✅ Installed |
| Go       | gosec          | Security static analysis | ✅ Installed |

### Planned Additions

| Language | Tool         | Purpose                | Issue |
| -------- | ------------ | ---------------------- | ----- |
| Rust     | cargo-audit  | Vulnerability scanning | #18   |
| Rust     | cargo-deny   | Supply chain security  | #18   |
| Python   | pip-audit    | Vulnerability scanning | #19   |
| Rust     | cargo-geiger | Unsafe code detection  | #20   |
| Go       | govulncheck  | Vulnerability scanning | #21   |

### Future Considerations

#### Rust

- **cargo-public-api**: Track public API changes
- **cargo-semver-checks**: Verify semver compliance
- **cargo-udeps**: Find unused dependencies
- **cargo-tree**: Visualize dependency tree
- **cargo-doc-coverage**: Document coverage reporting
- **cargo-rdme**: README generation from doc comments

#### Node.js

- **npm audit**: Built-in vulnerability scanning
- **better-npm-audit**: Enhanced npm audit
- **npm-audit-resolver**: Interactive audit resolver
- **snyk**: Comprehensive security platform
- **npm-check-updates**: Update package.json
- **depcheck**: Find unused dependencies
- **npm-check**: Check for outdated, incorrect deps

#### Python

- **safety**: Security vulnerability checker (alternative to pip-audit)
- **pip-review**: Check for updates
- **pipdeptree**: Visualize dependency tree
- **pip-autoremove**: Remove unused dependencies
- **vulture**: Find dead code
- **prospector**: Code analysis
- **radon**: Code metrics

#### Go

- **nancy**: Alternative security scanner
- **go-licenses**: License checking

#### Ruby

- **bundle-leak**: Memory leak detection

#### Java

- **dependency-check**: OWASP vulnerability scanner
- **snyk**: Cross-language security
- **find-sec-bugs**: Security bug patterns

## Short-Term Implementation (Bash-based)

### Unified Command System

Single entry point: `/usr/local/bin/dev-init`

```bash
# Commands
dev-init --init        # Initialize project with best practices
dev-init --scan        # Run security scans for all detected languages
dev-init --update      # Check for outdated dependencies
dev-init --ci          # Generate CI/CD configurations
dev-init --hooks       # Install git hooks
dev-init --docs        # Generate documentation
dev-init --all         # Apply all enhancements

# Options
--force               # Overwrite existing files
--language <lang>     # Target specific language (auto-detect by default)
--dry-run            # Show what would be done without doing it
```

### Directory Structure

```text
lib/
├── features/
│   ├── rust-dev.sh
│   ├── node-dev.sh
│   ├── python-dev.sh
│   └── ...
├── templates/           # Language-specific templates
│   ├── rust/
│   │   ├── ci/
│   │   │   ├── gitlab-ci.yml
│   │   │   ├── github-workflows/
│   │   │   └── pre-commit-config.yaml
│   │   ├── hooks/
│   │   │   ├── pre-commit
│   │   │   ├── pre-push
│   │   │   └── commit-msg
│   │   ├── config/
│   │   │   ├── deny.toml           # cargo-deny config
│   │   │   ├── audit.toml          # cargo-audit config
│   │   │   ├── rustfmt.toml        # Formatting rules
│   │   │   └── clippy.toml         # Linting rules
│   │   ├── docs/
│   │   │   ├── README.md.template
│   │   │   ├── CONTRIBUTING.md
│   │   │   └── SECURITY.md
│   │   └── scripts/
│   │       ├── security-scan.sh
│   │       ├── api-check.sh
│   │       └── release.sh
│   ├── node/
│   ├── python/
│   ├── go/
│   └── common/
│       ├── gitignore-patterns/
│       ├── editorconfig/
│       └── security-policies/
└── base/
    ├── feature-header.sh
    └── template-manager.sh  # NEW: Shared template functions
```

### Template Manager Functions

New file: `lib/base/template-manager.sh`

```bash
#!/bin/bash
# Template management functions for feature installations

# Copy template with protection against overwriting
copy_template() {
    local src_dir="$1"
    local dest="$2"
    local force="${3:-false}"

    if [ -e "$dest" ] && [ "$force" != "true" ]; then
        echo "⚠️  $dest exists (use --force to overwrite)"
        return 1
    fi

    cp -r "$src_dir"/* "$dest"
    echo "✓ Copied templates to $dest"
}

# Install feature templates during build
install_feature_templates() {
    local feature="$1"
    local template_src="/tmp/build-scripts/templates/$feature"
    local template_dest="/usr/share/dev-templates/$feature"

    if [ -d "$template_src" ]; then
        mkdir -p "$template_dest"
        cp -r "$template_src"/* "$template_dest/"
        log_message "Installed $feature templates"
    fi
}

# Detect project type based on files present
detect_project_type() {
    local types=()

    [ -f "Cargo.toml" ] && types+=("rust")
    [ -f "package.json" ] && types+=("node")
    [ -f "pyproject.toml" ] || [ -f "requirements.txt" ] && types+=("python")
    [ -f "go.mod" ] && types+=("go")
    [ -f "Gemfile" ] && types+=("ruby")
    [ -f "pom.xml" ] || [ -f "build.gradle" ] && types+=("java")

    echo "${types[@]}"
}

# Safe file creation with backup
safe_create_file() {
    local file="$1"
    local content="$2"
    local force="${3:-false}"

    if [ -f "$file" ]; then
        if [ "$force" = "true" ]; then
            cp "$file" "$file.backup"
            echo "✓ Backed up existing $file"
        else
            echo "⚠️  $file exists (use --force to overwrite)"
            return 1
        fi
    fi

    echo "$content" > "$file"
    echo "✓ Created $file"
}
```

### Example Security Scanner

`/usr/local/bin/dev-scan` (unified security scanner):

```bash
#!/bin/bash
# Unified security scanner for all languages

set -euo pipefail

# Detect project types
PROJECT_TYPES=($(detect_project_type))

if [ ${#PROJECT_TYPES[@]} -eq 0 ]; then
    echo "No recognized project type found"
    exit 1
fi

echo "=== Development Security Scan ==="
echo "Detected project types: ${PROJECT_TYPES[*]}"
echo ""

# Run language-specific scanners
for type in "${PROJECT_TYPES[@]}"; do
    case "$type" in
        rust)
            echo "→ Rust Security Scan"
            cargo audit || true
            cargo outdated --root-deps-only || true
            if [ -f deny.toml ]; then
                cargo deny check || true
            fi
            if command -v cargo-geiger &>/dev/null; then
                cargo geiger || true
            fi
            ;;

        node)
            echo "→ Node.js Security Scan"
            npm audit || true
            if command -v better-npm-audit &>/dev/null; then
                better-npm-audit audit || true
            fi
            ;;

        python)
            echo "→ Python Security Scan"
            if command -v pip-audit &>/dev/null; then
                pip-audit || true
            fi
            if command -v safety &>/dev/null; then
                safety check || true
            fi
            bandit -r . || true
            ;;

        go)
            echo "→ Go Security Scan"
            gosec ./... || true
            if command -v govulncheck &>/dev/null; then
                govulncheck ./... || true
            fi
            ;;

        ruby)
            echo "→ Ruby Security Scan"
            bundle-audit check || true
            brakeman -q || true
            ;;
    esac
    echo ""
done

echo "=== Scan Complete ==="
echo "Run 'dev-init --scan --report' to generate detailed reports"
```

## Long-Term Vision (Stibbons Integration)

### Overview

Migrate core functionality to Stibbons, a Rust-based CLI environment management
tool, providing:

- Type safety and memory safety
- Cross-platform binary (works on Alpine, Debian, etc.)
- Advanced multi-environment orchestration
- Plugin architecture for extensibility

### Architecture Concept

```rust
// Core trait for all development environments
pub trait DevEnvironment {
    /// Detect if this environment applies to the current project
    fn detect_project(&self, path: &Path) -> bool;

    /// Initialize project with best practices
    fn init_project(&self, config: InitConfig) -> Result<()>;

    /// Run security scans
    fn security_scan(&self, options: ScanOptions) -> SecurityReport;

    /// Check and update dependencies
    fn update_dependencies(&self, mode: UpdateMode) -> Result<UpdateReport>;

    /// Generate CI/CD configurations
    fn generate_ci_config(&self, platform: CIPlatform) -> Result<String>;

    /// Install development hooks
    fn install_hooks(&self, hook_type: HookType) -> Result<()>;
}

// Multi-environment orchestration
pub struct ProjectEnvironment {
    environments: Vec<Box<dyn DevEnvironment>>,
}

impl ProjectEnvironment {
    pub fn detect_all(path: &Path) -> Self {
        // Auto-detect all applicable environments
    }

    pub fn init_all(&self, config: InitConfig) -> Result<()> {
        // Initialize all environments with proper merging
    }
}
```

### Stibbons Features

1. **Multi-branch Development**
   - Manage multiple development environments across git branches
   - Isolate dependencies and configurations per branch
   - Enable parallel development by multiple AI agents

2. **Security First**
   - Built-in SBOM generation
   - Dependency license checking
   - Security policy enforcement
   - Automated CVE tracking

3. **Project Templates**
   - Rich project scaffolding
   - Interactive project initialization
   - Custom template repositories
   - Organization-specific defaults

4. **CI/CD Integration**
   - Generate CI configs for multiple platforms
   - Automatic security gates
   - Performance benchmarking
   - Release automation

### Stibbons CLI Interface

```bash
# Project initialization
stibbons init                    # Interactive project setup
stibbons init --template rust-api # Use specific template
stibbons init --from-git <url>   # Clone and enhance

# Security operations
stibbons scan                    # Run all security scans
stibbons scan --fix              # Auto-fix where possible
stibbons scan --report json      # Generate JSON report

# Dependency management
stibbons deps update             # Update all dependencies
stibbons deps outdated           # List outdated deps
stibbons deps tree               # Visualize dependency tree
stibbons deps license-check      # Verify license compliance

# Environment management
stibbons env create feature-x    # Create isolated environment
stibbons env switch feature-x    # Switch to environment
stibbons env sync                # Sync with current branch

# CI/CD operations
stibbons ci generate gitlab      # Generate GitLab CI
stibbons ci validate             # Validate CI config
stibbons ci run --local          # Run CI pipeline locally
```

### Migration Strategy

#### Phase 1: Parallel Development (Months 1-3)

- Implement bash-based system as designed above
- Begin Stibbons development in parallel
- Define plugin API for Stibbons
- Create compatibility layer

#### Phase 2: Hybrid Operation (Months 3-6)

- Stibbons handles complex operations
- Bash scripts detect and call Stibbons when available
- Gradual feature migration
- A/B testing of implementations

#### Phase 3: Stibbons Primary (Months 6+)

- Stibbons becomes primary interface
- Bash scripts become thin wrappers
- Advanced features enabled
- Plugin ecosystem development

## Implementation Priorities

### Immediate (Current sprint)

1. Add cargo-audit and cargo-deny (#18)
2. Add pip-audit (#19)
3. Add cargo-geiger (#20)
4. Add govulncheck (#21)

### Short-term (Next 3-4 weeks)

1. Wait for Stibbons initial release
2. Evaluate Stibbons capabilities
3. Decide on implementation approach
4. Begin integration if Stibbons is ready

### Medium-term (2-3 months)

1. Create template directory structure
2. Implement template-manager.sh
3. Create dev-init unified command
4. Full security scanning for all languages
5. CI/CD template generation
6. Git hooks automation
7. Documentation generation

### Long-term (6+ months)

1. Full Stibbons integration
2. Multi-environment orchestration
3. Plugin ecosystem
4. Advanced AI agent support

## Benefits

### For Developers

- Immediate security feedback
- Consistent tooling across projects
- Best practices by default
- Reduced setup time

### For Organizations

- Security compliance automation
- Standardized development practices
- Reduced vulnerability exposure
- Audit trail for security scans

### For CI/CD

- Consistent commands across environments
- Automated security gates
- Dependency update automation
- Performance tracking

## Risks and Mitigations

### Risk: Tool Maintenance Burden

**Mitigation**: Use well-maintained tools, automate updates, community
contributions

### Risk: Image Size Growth

**Mitigation**: Optional features, multi-stage builds, lazy loading of tools

### Risk: Complexity Creep

**Mitigation**: Clear boundaries, plugin architecture, user choice

### Risk: Stibbons Delay

**Mitigation**: Bash implementation works standalone, easy migration path

## Decision Points

### Why Wait for Stibbons?

- Avoid duplicate effort
- Better long-term solution
- More maintainable
- Advanced features

### Why Document Now?

- Preserve design thinking
- Enable parallel development
- Community input opportunity
- Clear roadmap

## Related Documentation

- [Architecture Review](review.md)
- [CLAUDE.md](../../CLAUDE.md)
- Individual feature documentation in `lib/features/`
