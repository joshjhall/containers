# Scheduled Version Checks

This document explains how to set up automated weekly version checks with Pushover notifications in GitLab CI.

## Overview

The container build system includes a scheduled job that:

1. Runs weekly to check for new versions of pinned dependencies
2. Sends Pushover notifications when updates are available
3. Creates artifacts with update details

## Setup Instructions

### 1. Configure GitLab CI/CD Variables

Navigate to your **project's** Settings → CI/CD → Variables (not group variables) and add:

| Variable | Type | Protected | Masked | Expanded | Description | Example |
|----------|------|-----------|--------|----------|-------------|---------|
| `PUSHOVER_USER_KEY` | Variable | ✅ | ✅ | ❌ | Your Pushover user key | `u1234567890abcdef` |
| `PUSHOVER_APP_TOKEN` | Variable | ✅ | ✅ | ❌ | Your Pushover app token | `a1234567890abcdef` |
| `GITHUB_TOKEN` | Variable | ✅ | ✅ | ❌ | GitHub token (optional, for API rate limits) | `ghp_1234567890` |

**Important Configuration Notes:**

- **Scope**: Add as PROJECT variables (not group variables)
- **Protected**: Enable to restrict access to protected branches/tags only
  - If using protected variables, ensure your target branch (develop/main) is also protected
  - Go to Settings → Repository → Protected branches to protect the branch
- **Masked**: Enable to hide values in job logs (values must meet masking requirements)
- **Expanded**: Keep DISABLED - we need the literal token values, not variable expansion

### 2. Create a Pipeline Schedule

1. Navigate to **Build → Pipeline schedules**
2. Click **New schedule**
3. Configure:
   - **Description**: `Weekly version check`
   - **Interval pattern**: `0 9 * * 1` (Every Monday at 9 AM)
   - **Cron timezone**: Your preferred timezone
   - **Target branch**: `develop` or `main`
   - **Variables**: (optional) Add any schedule-specific variables

**Note**: When triggered by a schedule, ONLY the version check job will run. Regular build and test jobs are automatically skipped to save CI resources.

### 3. Pushover Setup

If you don't have Pushover:

1. Create an account at [pushover.net](https://pushover.net)
2. Install the mobile app
3. Create an application for notifications:
   - Go to [pushover.net/apps/build](https://pushover.net/apps/build)
   - Name: `Container Version Checker`
   - Type: `Script`
   - Copy the generated token

## Notification Format

When updates are available, you'll receive a notification like:

```text
Container Build System - Version Updates Available

Found 3 version update(s):

• Python: 3.11.2 → 3.11.9
• Node.js: 22.10.0 → 22.11.0
• Poetry: 1.8.4 → 1.8.5

Repository: https://gitlab.example.com/org/containers
```

## Testing

To test the scheduled job manually:

1. Go to **Build → Pipeline schedules**
2. Find your schedule
3. Click the **Play** button

## Customization

### Notification Priority

Edit `.gitlab-ci.yml` to change priority:

- `-2`: Lowest (no notification)
- `-1`: Low (no sound/vibration)
- `0`: Normal (default)
- `1`: High (bypass quiet hours)
- `2`: Emergency (requires acknowledgment)

### Check Frequency

Modify the cron pattern in the schedule:

- Daily: `0 9 * * *`
- Weekly: `0 9 * * 1` (Mondays)
- Monthly: `0 9 1 * *` (First day of month)

### Skip Checks

To temporarily disable version checks, set a variable in the schedule:

- Variable: `SKIP_VERSION_CHECK`
- Value: `true`

## Troubleshooting

### No Notifications Received

1. Check job logs for "WARNING: Pushover credentials not configured"
2. Verify variables are set correctly in CI/CD settings
3. Ensure Pushover app is installed and logged in
4. Check Pushover API status at [status.pushover.net](https://status.pushover.net)

### Rate Limiting

If you see GitHub API rate limit errors:

1. Add `GITHUB_TOKEN` variable with a personal access token
2. Create token at [github.com/settings/tokens](https://github.com/settings/tokens)
3. No special permissions needed for public repos

### Version Check Failures

The job uses `|| true` to prevent pipeline failures. Check:

1. Job artifacts for `version-updates.json`
2. Job logs for error messages
3. Ensure `./bin/check-versions.sh` is executable

## Alternative Notification Methods

While this implementation uses Pushover, you can modify the job to use:

- Email (using GitLab's built-in email)
- Slack webhooks
- Discord webhooks
- Microsoft Teams
- Custom webhooks

Example for Slack:

```yaml
# Replace Pushover section with:
curl -X POST -H 'Content-type: application/json' \
  --data "{\"text\":\"${MESSAGE}\"}" \
  "${SLACK_WEBHOOK_URL}"
```

## Related Documentation

- [Version Management](version-management.md)
- [GitLab CI/CD Variables](https://docs.gitlab.com/ee/ci/variables/)
- [Pipeline Schedules](https://docs.gitlab.com/ee/ci/pipelines/schedules.html)
- [Pushover API](https://pushover.net/api)
