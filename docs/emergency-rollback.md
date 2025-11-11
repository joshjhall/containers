# Emergency Rollback Procedures

This document provides step-by-step procedures for rolling back problematic releases, including automated patch releases.

## Table of Contents
- [Quick Reference](#quick-reference)
- [Identifying the Issue](#identifying-the-issue)
- [Rollback Procedures](#rollback-procedures)
- [Post-Rollback Actions](#post-rollback-actions)
- [Prevention](#prevention)

---

## Quick Reference

### Emergency Rollback Commands

```bash
# 1. Identify last known good version
git tag -l --sort=-version:refname | head -10

# 2. Revert to previous version (replace vX.Y.Z with target version)
git revert --no-commit <bad_commit_hash>..HEAD
git commit -m "emergency: Rollback to vX.Y.Z"

# 3. Create emergency patch release
./bin/release.sh patch
git tag -a v4.6.1 -m "Emergency rollback from v4.6.2"
git push origin main v4.6.1

# 4. Delete problematic release and tag
gh release delete vX.Y.Z --yes
git push --delete origin vX.Y.Z
```

---

## Identifying the Issue

### Symptoms of a Problematic Release

1. **Build Failures**
   - CI builds failing on main branch
   - Integration tests failing
   - Security scans failing

2. **Runtime Issues**
   - Containers won't start
   - Features not working as expected
   - Performance degradation

3. **User Reports**
   - Multiple issue reports for same problem
   - Production deployments failing

### Determine the Problematic Version

```bash
# View recent releases
gh release list --limit 10

# View recent tags
git tag -l --sort=-version:refname | head -10

# Check if it's an auto-patch release
git log --oneline | grep "automated version updates"

# View CI status for recent commits
gh run list --limit 10
```

---

## Rollback Procedures

### Option 1: Quick Revert (Recommended for Auto-Patch)

Use this when an automated patch release introduced a bug:

```bash
# 1. Identify the bad commit
git log --oneline --decorate | head -20
# Look for: "chore: automated version updates to vX.Y.Z"

# 2. Revert the problematic commit(s)
git revert --no-commit <bad_commit_sha>
git commit -m "emergency: Rollback automated patch vX.Y.Z

Reason: [Brief description of issue]
Symptoms: [What broke]
Reverted commits: <commit_sha>

This emergency rollback restores functionality.
Manual patch will follow after fix is verified."

# 3. Push the revert
git push origin main

# 4. Delete the bad release
gh release delete vX.Y.Z --yes --cleanup-tag

# 5. Create new patch release with fix
./bin/release.sh --full-auto patch
```

### Option 2: Emergency Hotfix Release

Use this when you need to fix forward rather than revert:

```bash
# 1. Create hotfix branch from last good release
git checkout -b hotfix/vX.Y.Z vPREVIOUS.Y.Z

# 2. Apply fixes
# ... make your changes ...

# 3. Test locally
./tests/run_all.sh

# 4. Create emergency release
./bin/release.sh --full-auto patch

# 5. Merge back to main
git checkout main
git merge --no-ff hotfix/vX.Y.Z
git push origin main
git push --delete origin hotfix/vX.Y.Z
```

### Option 3: Hard Reset (LAST RESORT)

**⚠️ DANGER**: This rewrites history. Only use if absolutely necessary and team is coordinated.

```bash
# 1. Backup current state
git tag backup-before-reset-$(date +%Y%m%d-%H%M%S)

# 2. Reset to last good commit
git reset --hard vLAST.GOOD.VERSION

# 3. Force push (DANGEROUS - coordinate with team first!)
git push --force origin main

# 4. Re-tag
git tag -a vX.Y.Z -m "Emergency release after reset"
git push origin vX.Y.Z

# 5. Notify all users to re-clone
# Post announcement in all channels
```

---

## Post-Rollback Actions

### Immediate Actions

1. **Verify rollback successful**
   ```bash
   # Check CI passes
   gh run watch

   # Verify release exists
   gh release view vX.Y.Z

   # Test key functionality
   ./tests/run_integration_tests.sh
   ```

2. **Notify stakeholders**
   - Post incident report
   - Update GitHub release notes
   - Notify dependent projects

3. **Update container images**
   - Verify new images are built and pushed
   - Update documentation if tags changed

### Follow-Up Actions

1. **Root Cause Analysis**
   - Document what went wrong
   - Identify gaps in testing
   - Update tests to catch similar issues

2. **Process Improvements**
   - Add integration tests for failure scenario
   - Update auto-patch workflow if needed
   - Improve monitoring/alerting

3. **Documentation**
   - Update CHANGELOG.md with rollback notes
   - Document the incident in docs/incidents/
   - Update roadmap with lessons learned

---

## Prevention

### Pre-Release Checklist

Before manual releases:
- [ ] All tests passing (`./tests/run_all.sh`)
- [ ] Shellcheck passes (`shellcheck lib/**/*.sh bin/*.sh`)
- [ ] Integration tests pass for all variants
- [ ] Security scans pass (gitleaks, vulnerability scanning)
- [ ] CHANGELOG.md updated
- [ ] Documentation updated

For auto-patch releases:
- Auto-patch workflow validates:
  - All unit tests
  - Integration tests for 6+ variants
  - Security scans
  - Build succeeds for all variants
  - Auto-merge only on full CI success

### Monitoring Best Practices

1. **Watch CI After Release**
   ```bash
   # Monitor the release build
   gh run watch
   ```

2. **Test Immediately After Release**
   ```bash
   # Pull and test new release
   docker pull ghcr.io/joshjhall/containers:vX.Y.Z-minimal
   docker run --rm ghcr.io/joshjhall/containers:vX.Y.Z-minimal check-installed-versions.sh
   ```

3. **Check GitHub Issues/Discussions**
   - Monitor for user reports
   - Check CI status badges

### Release Channel Strategy

**Stable Channel** (Manual Releases):
- `v4.6.0` - Major/minor releases
- `v4.6.1` - Manual patches
- Thoroughly tested
- Documented changes

**Auto-Patch Channel** (Automated):
- `v4.6.0` with commit message containing "automated version updates"
- Automated dependency updates
- Full CI validation required
- May revert more frequently

**Pinning Recommendations**:
- **Production**: Pin to specific stable version (e.g., `v4.6.0`)
- **Development**: Use `:latest` or auto-patch
- **CI/CD**: Pin to specific version, update deliberately

---

## Examples

### Example 1: Auto-Patch Broke Node.js

```bash
# Symptom: Node dev containers won't start
# Root cause: Auto-patch updated Node to incompatible version

# 1. Identify bad release
git log --oneline | grep "automated version updates"
# Output: abc1234 chore: automated version updates to v4.6.2

# 2. Revert the patch
git revert --no-commit abc1234
git commit -m "emergency: Rollback v4.6.2 (Node incompatibility)"

# 3. Remove bad release
gh release delete v4.6.2 --yes --cleanup-tag

# 4. Create fix
# Edit lib/features/node.sh to pin compatible version

# 5. Release emergency patch
./bin/release.sh --full-auto patch
# Creates v4.6.3 with fix
```

### Example 2: Critical Security Issue in Latest

```bash
# Symptom: Security vulnerability reported
# Action: Immediate rollback required

# 1. Delete release immediately
gh release delete v4.7.0 --yes

# 2. Revert changes
git revert --no-commit HEAD
git commit -m "security: Emergency rollback v4.7.0 (CVE-2025-XXXX)"

# 3. Apply security patch
# ... fix vulnerability ...

# 4. Create patched release
./bin/release.sh --full-auto minor  # v4.8.0 with fix

# 5. Post security advisory
gh api repos/joshjhall/containers/security-advisories \
  -f summary="Critical: Reverted v4.7.0" \
  -f description="..."
```

---

## Contact

For emergency assistance:
- Open GitHub issue with `[URGENT]` prefix
- Check GitHub Actions logs
- Review docs/troubleshooting.md
