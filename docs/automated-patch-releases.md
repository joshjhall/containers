# Automated Patch Release System

The automated patch release system handles version updates for dependencies with
zero manual intervention when tests pass.

## How It Works

### 1. Weekly Version Check (Scheduled)

Every Sunday at 2am UTC, the system:

- Checks for outdated versions of all tools (Python, Node, Rust, etc.)
- If updates are found:
  - Creates a new branch: `auto-patch/YYYYMMDD-HHMMSS`
  - Applies version updates to feature scripts
  - Bumps the patch version in Dockerfile and CHANGELOG
  - Commits and pushes the branch

### 2. Automatic CI Validation

The push to `auto-patch/*` triggers the full CI pipeline:

- Unit tests
- Shellcheck
- Secret scanning
- Docker image builds (all variants)
- Integration tests (all variants)
- Security scanning

### 3. Auto-Merge or Notify

**If CI passes:**

- Auto-merges the branch to `main`
- Creates and pushes a version tag (e.g., `v1.2.3`)
- Sends Pushover success notification
- Deletes the auto-patch branch

**If CI fails:**

- Sends Pushover failure notification with details
- Preserves the branch for manual review
- Includes links to the failed workflow and branch

## Pushover Notifications

The system sends notifications via Pushover for:

### Success Notifications

- Title: "✅ Patch Release v1.2.3 Deployed"
- Details: Version changes, all tests passed
- Priority: Normal
- Sound: Default

### Failure Notifications

- Title: "❌ Patch Release v1.2.3 Failed" or "⚠️ CI Failed"
- Details: What failed, branch preserved, links to review
- Priority: High
- Sound: Persistent (requires acknowledgment)

## Setup

### Required GitHub Secrets

Add these secrets to your repository settings:

1. **PUSHOVER_TOKEN**
   - Your Pushover application API token
   - Get it from: https://pushover.net/apps/build
   - Example: `azGDORePK8gMaC0QOYAMyEEuzJnyUi`

2. **PUSHOVER_USER**
   - Your Pushover user key
   - Get it from: https://pushover.net/
   - Example: `uQiRzpo4DXghDmr9QzzfQu27cmVRsG`

### Setting Up Pushover

1. Create a Pushover account at https://pushover.net
2. Install the Pushover app on your phone/desktop
3. Create a new application for this repository:
   - Go to: https://pushover.net/apps/build
   - Name: "Container Build System" (or similar)
   - Description: "Automated patch release notifications"
   - Get your API Token
4. Add both secrets to GitHub:
   - Go to: Repository Settings → Secrets and variables → Actions
   - Add `PUSHOVER_TOKEN` with your API token
   - Add `PUSHOVER_USER` with your user key

## Manual Triggers

You can manually trigger a version check:

```bash
# Via GitHub CLI
gh workflow run auto-patch.yml

# Via GitHub UI
Actions → Automated Patch Releases → Run workflow
```

## Monitoring

### Successful Releases

Check your Pushover notifications for success messages. You can also:

- View tags: `git tag -l "v*"`
- Check releases: https://github.com/your-org/containers/releases

### Failed Releases

If a release fails:

1. You'll receive a Pushover notification with details
2. The `auto-patch/*` branch is preserved
3. Review the branch and failed workflow
4. Fix issues manually or delete the branch
5. The next scheduled run will try again

### Viewing Auto-Patch Branches

```bash
# List all auto-patch branches
git branch -r | grep auto-patch

# Checkout a specific branch for review
git fetch origin
git checkout auto-patch/20251026-020000
```

## Customization

### Changing Schedule

Edit `.github/workflows/auto-patch.yml`:

```yaml
schedule:
  - cron: '0 2 * * 0' # Sundays at 2am UTC
```

Common schedules:

- Daily: `0 2 * * *`
- Mondays only: `0 2 * * 1`
- First of month: `0 2 1 * *`

### Notification Priorities

In the workflow file, adjust priority levels:

- `0` = Normal priority
- `1` = High priority (bypasses quiet hours)
- `2` = Emergency (requires acknowledgment)

## Workflow Files

- `.github/workflows/auto-patch.yml` - Automated patch release system
- `.github/workflows/ci.yml` - Main CI/CD pipeline (runs on auto-patch branches)

## Benefits

1. **Zero-touch version updates** - No manual PR reviews needed
2. **Automatic validation** - Full CI runs before merge
3. **Fast notifications** - Know immediately if something breaks
4. **Preserved branches** - Failed patches kept for review
5. **Audit trail** - Version tags and commit history maintained

## Troubleshooting

### No Notifications Received

1. Check Pushover app is installed and logged in
2. Verify secrets are set correctly in GitHub
3. Check workflow runs for errors
4. Test Pushover manually: https://pushover.net/

### Branch Not Auto-Merging

1. Check the workflow run logs
2. Verify all CI jobs passed
3. Check repository permissions for GitHub Actions
4. Ensure no branch protection rules block auto-merge

### Version Check Not Running

1. Check the schedule cron expression
2. Verify workflow is enabled in GitHub Actions
3. Manually trigger to test: `gh workflow run auto-patch.yml`
