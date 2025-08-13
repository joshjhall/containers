# Security Scanning and Project Initialization System

## Overview

This document outlines the design for a comprehensive security scanning and project initialization system for the container build system. The goal is to provide consistent, language-specific security tools and project scaffolding that works seamlessly across all development environments.

## Core Objectives

1. **Security First**: Built-in vulnerability scanning for all supported languages
2. **Consistency**: Unified commands that work across all languages
3. **CI/CD Ready**: Same tools work locally and in CI pipelines
4. **Extensibility**: Easy to add new languages and tools
5. **Non-invasive**: Opt-in system that doesn't modify projects without permission

## Short-Term Implementation (Bash + Templates)

### Directory Structure

```
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
│   │   ├── ci/
│   │   ├── hooks/
│   │   ├── config/
│   │   └── scripts/
│   ├── python/
│   │   └── ...
│   └── common/
│       ├── gitignore-patterns/
│       ├── editorconfig/
│       └── security-policies/
└── base/
    ├── feature-header.sh
    └── template-manager.sh  # NEW: Shared template functions
```

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

### Language-Specific Security Tools

#### Rust (`rust-dev.sh`)
```bash
# Security & Auditing
cargo-audit          # Security vulnerabilities
cargo-deny           # Supply chain security
cargo-geiger         # Unsafe code detection

# API & Privacy Analysis
cargo-public-api     # Track public API changes
cargo-semver-checks  # Verify semver compliance

# Dependency Management
cargo-outdated       # Check for outdated dependencies
cargo-udeps          # Find unused dependencies
cargo-tree           # Visualize dependency tree

# Documentation
cargo-doc-coverage   # Document coverage reporting
cargo-rdme           # README generation from doc comments

# Code Quality
cargo-expand         # Macro expansion
cargo-bloat          # Binary size analysis
```

#### Node.js (`node-dev.sh`)
```bash
# Security
npm audit            # Built-in vulnerability scanning
better-npm-audit     # Enhanced npm audit
npm-audit-resolver   # Interactive audit resolver
snyk                 # Comprehensive security platform

# Dependency Management
npm-check-updates    # Update package.json
depcheck            # Find unused dependencies
npm-check           # Check for outdated, incorrect deps

# Code Quality
lighthouse          # Performance auditing
bundlesize          # Bundle size checking
source-map-explorer # Analyze bundle composition
```

#### Python (`python-dev.sh`)
```bash
# Security
pip-audit           # Vulnerability scanning
safety              # Security vulnerability checker
bandit              # Security linter for Python code

# Dependency Management
pip-review          # Check for updates
pipdeptree          # Visualize dependency tree
pip-autoremove      # Remove unused dependencies

# Code Quality
vulture             # Find dead code
prospector          # Code analysis
radon               # Code metrics
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

# Merge multiple CI configs intelligently
merge_ci_configs() {
    local output_file="$1"
    shift
    local configs=("$@")
    
    # Use yq or custom merger to combine YAML files
    # This ensures rust + node = combined CI pipeline
    # Implementation depends on available tools
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

### Example Security Scan Implementation

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
            pip-audit || true
            if command -v safety &>/dev/null; then
                safety check || true
            fi
            if command -v bandit &>/dev/null; then
                bandit -r . || true
            fi
            ;;
    esac
    echo ""
done

echo "=== Scan Complete ==="
echo "Run 'dev-init --scan --report' to generate detailed reports"
```

## Long-Term Vision (Stibbons Integration)

### Overview

Migrate core functionality to Stibbons, a Rust-based CLI environment management tool, providing:
- Type safety and memory safety
- Cross-platform binary (works on Alpine, Debian, etc.)
- Advanced multi-environment orchestration
- Plugin architecture for extensibility

### Architecture

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

// Language-specific implementations
pub struct RustEnvironment {
    cargo_path: PathBuf,
    tools: Vec<RustTool>,
}

impl DevEnvironment for RustEnvironment {
    // Implementation details...
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

## Implementation Priorities

### Immediate (If implementing now)
1. Create template directory structure
2. Implement `template-manager.sh`
3. Create `dev-init` unified command
4. Add security tools to `rust-dev.sh`

### Short-term (Next 3-4 weeks)
1. Wait for Stibbons initial release
2. Evaluate Stibbons capabilities
3. Decide on implementation approach
4. Begin integration if Stibbons is ready

### Medium-term (2-3 months)
1. Full security scanning for all languages
2. CI/CD template generation
3. Git hooks automation
4. Documentation generation

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
**Mitigation**: Use well-maintained tools, automate updates, community contributions

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

## Next Steps

1. **Review and refine this design document**
2. **Wait for Stibbons initial release (3-4 weeks)**
3. **Evaluate Stibbons capabilities**
4. **Decide on implementation approach**
5. **Begin development based on decision**

## Related Documents

- [CLAUDE.md](../CLAUDE.md) - Overall project context
- [README.md](../README.md) - Project overview
- Individual feature documentation in `lib/features/`

## Contributors

- Design and documentation: Claude + User collaboration
- Implementation: TBD based on Stibbons timeline

---

*This document represents the current design thinking for security scanning and project initialization. It will be updated as the implementation progresses.*