# Checksum Verification Implementation Inventory

## Status: Implementation In Progress
**Date Started**: 2025-11-07
**Last Updated**: 2025-11-08

## Priority Classification

### 🔴 CRITICAL - Installation Scripts (curl | bash)
These download and execute code directly. Highest priority for security.

| Script | Line | Pattern | Status | Notes |
|--------|------|---------|--------|-------|
| `rust.sh` | 73 | `curl https://sh.rustup.rs \| sh` | ⏳ Pending | Official rustup - consider mirroring |
| `kubernetes.sh` | 141 | `curl helm/get-helm-3 \| bash` | ⏳ Pending | Helm install script |
| `terraform.sh` | 146 | `curl tflint/install_linux.sh \| bash` | ⏳ Pending | tflint install script |
| `mojo.sh` | 119 | `curl pixi.sh/install.sh \| bash` | ⏳ Pending | pixi installer |
| `node.sh` | 97, 116 | `curl nodesource setup \| bash` | ⏳ Review | Repository setup, GPG verified after |
| `cloudflare.sh` | 74 | `curl nodesource setup \| bash` | ⏳ Review | Repository setup, GPG verified after |

### 🟠 HIGH - Direct Binary Downloads (curl | tar)
These download binaries and extract directly without verification.

| Script | Line | Binary | Status | Notes |
|--------|------|--------|--------|-------|
| `kubernetes.sh` | 140, 149 | k9s | ✅ **DONE** | v0.50.16 with SHA256 verification |
| `kubernetes.sh` | 189, 197 | krew | ✅ **DONE** | v0.4.5 with individual .sha256 files |
| `dev-tools.sh` | 412, 415 | lazygit | ⏳ Pending | Check for checksums |
| `dev-tools.sh` | 426, 431 | delta | ⏳ Pending | Check for checksums |
| `dev-tools.sh` | 458, 461 | act | ⏳ Pending | Check for checksums |
| `dev-tools.sh` | 472, 477 | git-cliff | ⏳ Pending | Check for checksums |
| `docker.sh` | 131, 134 | lazydocker | ⏳ Pending | Downloads to file first (easier) |
| `golang.sh` | 104 | Go tarball | ⏳ Pending | Official Go releases have checksums |
| `terraform.sh` | 137, 140 | terraform-docs | ⏳ Pending | Check for checksums |

### 🟢 LOW/OK - GPG Key Downloads
These are GPG keys piped to verification tools. Less critical but should review.

| Script | Line | Pattern | Status | Notes |
|--------|------|---------|--------|-------|
| `gcloud.sh` | 67 | GPG key → apt-key | ✅ OK | Part of repo setup |
| `terraform.sh` | 95 | GPG key → gpg | ✅ OK | Part of repo setup |

### ✅ VERIFIED - Already Using Package Managers
These use apt/cargo/npm with GPG verification. No changes needed.

| Script | Method | Status |
|--------|--------|--------|
| `op-cli.sh` | apt + debsig verification | ✅ Already Secure |
| `aws.sh` | Official AWS installer | 🔍 Review |
| `python.sh` | Builds from source | 🔍 Review |
| `ruby.sh` | rbenv/ruby-build | 🔍 Review |
| `java.sh` | apt packages | ✅ Already Secure |
| `r.sh` | apt packages | ✅ Already Secure |

## Implementation Order

### Phase 1: kubernetes.sh ✅ **COMPLETED**
- ✅ Well-documented project (k9s)
- ✅ Clear checksums available
- ✅ Good test case for our utilities
- ✅ k9s v0.50.16 with checksum verification implemented
- ✅ krew v0.4.5 with checksum verification implemented
- ✅ Container build tested and verified
- ⚠️ helm installer still uses curl | bash (TODO marked)

### Phase 2: dev-tools.sh
- 4 binaries: lazygit, delta, act, git-cliff
- All from GitHub releases
- Need to verify checksum availability

### Phase 3: golang.sh
- Official Go releases
- Well-documented checksums
- Single tarball

### Phase 4: docker.sh
- lazydocker (already downloads to file first - easiest)

### Phase 5: terraform.sh
- terraform-docs binary
- tflint installer script

### Phase 6: Installation Scripts Review
- rust.sh - rustup installer
- mojo.sh - pixi installer
- node.sh / cloudflare.sh - NodeSource scripts (review if verification needed)

## Checksum Sources

### Where to Find Official Checksums

1. **GitHub Releases** - Look for:
   - `checksums.txt`
   - `SHA256SUMS`
   - `*.sha256` files alongside binaries

2. **Project Documentation**
   - Installation guides often include verification steps
   - Security pages may list checksums

3. **Official Downloads**
   - Go: https://go.dev/dl/ (SHA256 for all releases)
   - Rust: https://rust-lang.github.io/rustup/ (checksums available)

## Notes

- Some projects don't provide checksums (need to report upstream)
- For scripts without checksums, consider mirroring in repo
- Test each change in isolation
- Document checksum verification date in comments

---

## Completed Work

### ✅ kubernetes.sh (2025-11-08)
- **Checksums Added**:
  - K9S_AMD64_SHA256="bda09dc030a08987fe2b3bed678b15b52f23d6705e872d561932d4ca07db7818"
  - K9S_ARM64_SHA256="7f3b414bc5e6b584fbcb97f9f4f5b2c67a51cdffcbccb95adcadbaeab904e98e"
  - KREW_AMD64_SHA256="bacc06800bda14ec063cd0b6f377a961fdf4661c00366bf9834723cd28bfabc7"
  - KREW_ARM64_SHA256="e02bdb8fe67cd6641b9ed6b45c6d084f7aa5b161fe49191caf5b1d5e83b0c0f9"

- **Functions Used**: `download_and_extract()` from `lib/base/download-verify.sh`
- **Build Test**: ✅ Passed (image: `test-k8s:checksum-verify`)
- **Runtime Test**: ✅ Passed (k9s v0.50.16, kubectl v1.31.0)

### ✅ Checksum Update System (2025-11-08)
- **Created**: `bin/update-versions/helpers.sh` - Shared utilities
- **Created**: `bin/update-versions/kubernetes-checksums.sh` - K8s-specific updater
- **Tested**: ✅ Successfully updates checksums automatically
- **Integrates**: Ready for integration into `bin/update-versions.sh`

---

**Next Action**: Create atomic commits, then continue with dev-tools.sh
