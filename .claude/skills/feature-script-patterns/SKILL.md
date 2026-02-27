---
description: Feature script structure and conventions for lib/features/*.sh. Use when creating, modifying, or reviewing feature installation scripts.
---

# Feature Script Patterns

## Required Structure

Every `lib/features/*.sh` script must follow this section order:

```bash
#!/bin/bash
# Feature Name - Short description
#
# Description:
#   What this feature installs and configures.
#
# Features:
#   - Bullet list of what's included
#
# Cache Strategy:
#   - Where cache directories are created
#
# Environment Variables:
#   - VERSION_VAR: Description (default: X.Y.Z)

set -euo pipefail

# 1. Source headers (MUST be this order)
source /tmp/build-scripts/base/feature-header.sh
source /tmp/build-scripts/base/apt-utils.sh
source /tmp/build-scripts/base/version-validation.sh    # if version pinned
source /tmp/build-scripts/base/version-resolution.sh    # if partial versions
source /tmp/build-scripts/base/download-verify.sh       # if downloading
source /tmp/build-scripts/base/checksum-verification.sh # if checksums
source /tmp/build-scripts/base/cache-utils.sh           # if cache dirs
source /tmp/build-scripts/base/path-utils.sh            # if modifying PATH

# 2. Version configuration
VERSION="${VERSION:-X.Y.Z}"
validate_<lang>_version "$VERSION" || { log_error "..."; exit 1; }

# 3. Start logging
log_feature_start "FeatureName" "${VERSION}"

# 4. Architecture detection (if downloading binaries)
ARCH=$(dpkg --print-architecture)

# 5. System dependencies
apt_update
apt_install curl ca-certificates git

# 6. Installation (download, verify, extract)
# 7. Cache and path configuration
create_cache_directories "/cache/tool" "/cache/tool-build"

# 8. Symlinks
create_symlink "/opt/tool/bin/cmd" "/usr/local/bin/cmd" "description"

# 9. Bashrc configuration (system-wide)
# Content lives in lib/features/lib/bashrc/<feature>.sh (plain shell snippet, no shebang)
# Feature script (content in lib/bashrc/feature.sh)
write_bashrc_content /etc/bashrc.d/50-feature.sh "description" \
    < /tmp/build-scripts/features/lib/bashrc/feature.sh

# 10. Startup scripts
cat > /etc/container/first-startup/30-feature-setup.sh << 'EOF'
#!/bin/bash
# ...
EOF
chmod +x /etc/container/first-startup/30-feature-setup.sh

# 11. Verification script
cat > /usr/local/bin/test-feature << 'EOF'
#!/bin/bash
# ...
EOF
chmod +x /usr/local/bin/test-feature

# 12. Final verification
log_command "Checking version" /usr/local/bin/tool --version

# 13. Feature summary (REQUIRED — powers check-installed-versions.sh)
log_feature_summary \
    --feature "FeatureName" \
    --version "${VERSION}" \
    --tools "cmd1,cmd2" \
    --paths "/cache/tool" \
    --env "VAR1,VAR2" \
    --commands "cmd1,alias1" \
    --next-steps "Run 'test-feature' to verify."

# 14. End logging
log_feature_end
```

## Key APIs

| Function                                  | Source               | Purpose                                  |
| ----------------------------------------- | -------------------- | ---------------------------------------- |
| `apt_update`                              | `apt-utils.sh`       | Update package lists with retry          |
| `apt_install pkg1 pkg2`                   | `apt-utils.sh`       | Install packages with retry              |
| `apt_install_conditional 11 12 pkg`       | `apt-utils.sh`       | Install only on Debian 11-12             |
| `is_debian_version 13`                    | `apt-utils.sh`       | Check Debian version                     |
| `log_feature_start "Name" "ver"`          | `logging.sh`         | Start feature log block                  |
| `log_feature_end`                         | `logging.sh`         | End feature log block                    |
| `log_message "text"`                      | `logging.sh`         | Info-level log                           |
| `log_warning "text"`                      | `logging.sh`         | Warning-level log                        |
| `log_error "text"`                        | `logging.sh`         | Error-level log                          |
| `log_command "desc" cmd args`             | `logging.sh`         | Log + execute command                    |
| `create_cache_directories dir1 dir2`      | `cache-utils.sh`     | Create cache dirs with correct ownership |
| `create_symlink target link "desc"`       | `feature-header.sh`  | Create verified symlink                  |
| `create_secure_temp_dir`                  | `feature-header.sh`  | Create temp dir (auto-cleaned)           |
| `write_bashrc_content path "desc" < file` | `bashrc-helpers.sh`  | Write to bashrc.d (file redirect)        |
| `safe_add_to_path "/new/path"`            | `path-utils.sh`      | Add to PATH with validation              |
| `verify_download type name ver file arch` | `download-verify.sh` | 4-tier checksum verification             |

## Conventions

- Cache dirs go under `/cache/<tool>` — enables volume mounting
- Bashrc files use `50-<feature>.sh` naming in `/etc/bashrc.d/`
- Bashrc content lives in `lib/features/lib/bashrc/<feature>.sh` — **never use heredocs**
- Startup scripts use `30-<feature>-setup.sh` in `/etc/container/first-startup/`
- Verification scripts go to `/usr/local/bin/test-<feature>`
- Variables from `feature-header.sh`: `$USERNAME`, `$USER_UID`, `$USER_GID`, `$WORKING_DIR`
- Bashrc scripts must start with `set +u` and `set +e` for interactive shell safety

## When NOT to Use

- Modifying `lib/base/` scripts (different conventions, no feature-header)
- Writing runtime scripts in `lib/runtime/` (no build-time sourcing)
- Writing test scripts (see test-framework-reference skill)
