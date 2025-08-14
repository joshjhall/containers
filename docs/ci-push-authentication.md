# GitLab CI Push Authentication Setup

The automated version update feature requires GitLab CI to push changes back to the repository. This document explains how to configure the necessary authentication.

## Option 1: Project Access Token (Recommended)

1. Navigate to **Project Settings** → **Access Tokens**
2. Create a new token with:
   - **Name**: `ci-version-updater`
   - **Role**: `Developer` or `Maintainer`
   - **Scopes**: `write_repository`
   - **Expiration**: Set as needed (or leave blank for no expiration)

3. Copy the generated token

4. Go to **Settings** → **CI/CD** → **Variables**
5. Add a new variable:
   - **Key**: `CI_PUSH_TOKEN`
   - **Value**: The token you copied
   - **Type**: Variable
   - **Protected**: Yes (if pushing to protected branches)
   - **Masked**: Yes
   - **Expand variable reference**: No

6. The `.gitlab-ci.yml` is already configured to use this token automatically:

```yaml
# Line 359 in .gitlab-ci.yml already contains:
git push "https://oauth2:${CI_PUSH_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" HEAD:develop
```

**Note:** No changes needed - the CI pipeline will automatically detect and use the `CI_PUSH_TOKEN` variable.

## Option 2: Deploy Token

1. Navigate to **Project Settings** → **Repository** → **Deploy Tokens**
2. Create a new token with:
   - **Name**: `ci-version-updater`
   - **Username**: `gitlab-ci-token` (or custom)
   - **Scopes**: `read_repository`, `write_repository`

3. Copy the username and token

4. Add CI/CD variables:
   - `CI_DEPLOY_USER`: The username
   - `CI_DEPLOY_PASSWORD`: The token

5. Update `.gitlab-ci.yml`:

```yaml
git push "https://${CI_DEPLOY_USER}:${CI_DEPLOY_PASSWORD}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" HEAD:develop
```

## Option 3: SSH Deploy Key

1. Generate an SSH key pair:

```bash
ssh-keygen -t ed25519 -C "ci-version-updater" -f deploy_key
```

2. Navigate to **Project Settings** → **Repository** → **Deploy Keys**
3. Add the public key (`deploy_key.pub`) with write access enabled

4. Add the private key as a CI/CD variable:
   - **Key**: `CI_DEPLOY_KEY`
   - **Value**: Contents of `deploy_key` (private key)
   - **Type**: File

5. Update `.gitlab-ci.yml` to use SSH:

```yaml
before_script:
  - apt-get update && apt-get install -y curl jq bash git openssh-client
  - eval $(ssh-agent -s)
  - echo "$CI_DEPLOY_KEY" | ssh-add -
  - mkdir -p ~/.ssh
  - ssh-keyscan -H gitlab.com >> ~/.ssh/known_hosts
  
script:
  # ... existing script ...
  # For pushing:
  - git remote set-url origin git@${CI_SERVER_HOST}:${CI_PROJECT_PATH}.git
  - git push origin HEAD:develop
```

## Testing the Configuration

After setting up authentication:

1. Manually trigger the scheduled pipeline:
   - Go to **CI/CD** → **Schedules**
   - Click the play button next to your schedule

2. Check the job logs for:
   - Successful version checks
   - Successful commits (if updates were found)
   - Successful push to develop branch

## Troubleshooting

### Error: "remote: You are not allowed to push code to this project"

- Ensure the token has `write_repository` scope
- Check that the token hasn't expired
- Verify the branch protection rules allow the token's role to push

### Error: "fatal: unable to access ... The requested URL returned error: 403"

- The token may not have sufficient permissions
- Check that the CI/CD variable is properly set and masked
- Ensure you're using the correct variable name in the pipeline

### Protected Branch Issues

If pushing to a protected branch (like `develop`):

1. Either grant the token/key sufficient permissions
2. Or temporarily unprotect the branch for CI pushes
3. Or use a separate branch for automated updates that gets merged via MR

## Security Considerations

- Always mask sensitive tokens in CI/CD variables
- Use protected variables for production branches
- Rotate tokens periodically
- Limit token scopes to minimum required permissions
- Consider using short-lived tokens where possible

## Alternative: Merge Request Workflow

Instead of pushing directly to develop, create MRs:

```bash
# Create a feature branch
git checkout -b auto-update/versions-$(date +%Y%m%d)

# Apply updates
./bin/update-versions.sh --input version-updates.json

# Push the branch
git push origin HEAD

# Use GitLab API to create MR
curl --request POST \
  --header "PRIVATE-TOKEN: ${CI_PUSH_TOKEN}" \
  --data "source_branch=auto-update/versions-$(date +%Y%m%d)" \
  --data "target_branch=develop" \
  --data "title=Automated version updates" \
  --data "remove_source_branch=true" \
  "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests"
```

This approach provides better visibility and allows for review before merging.
