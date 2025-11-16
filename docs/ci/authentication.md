# GitHub Actions Authentication Setup

The automated version update feature requires GitHub Actions to push changes
back to the repository. This document explains how to configure the necessary
authentication.

## Default: GITHUB_TOKEN

By default, GitHub Actions provides a `GITHUB_TOKEN` that has limited
permissions. For basic operations:

```yaml
- name: Checkout code
  uses: actions/checkout@v4
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
```

**Limitations**: The default `GITHUB_TOKEN` cannot trigger other workflows or
push to protected branches.

### For Version Checking

The version check script uses the `GITHUB_TOKEN` to avoid API rate limits
(60/hour without auth, 5000/hour with auth):

```yaml
- name: Check versions
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: |
    ./bin/check-versions.sh --json
```

The default `GITHUB_TOKEN` is sufficient for reading public repositories and
checking versions.

## Automated Version Updates

The workflow automatically creates Pull Requests for version updates:

### Default Behavior (No Additional Setup Required)

1. **Weekly scan** runs every Sunday at 2am UTC
2. **Detects** outdated versions in feature scripts
3. **Creates PR** with all updates applied
4. **CI runs** all tests on the PR
5. **You review** and merge when ready

### Optional: Enable Auto-Merge

To fully automate the process (auto-merge PRs after tests pass):

1. **Enable auto-merge** in repository settings:
   - Settings → General → Pull Requests
   - Check "Allow auto-merge"

2. **Configure branch protection** (recommended):
   - Settings → Branches → Add rule for `main`
   - Require status checks to pass before merging
   - Include the "Run Tests" check

3. **The auto-merge workflow** will:
   - Wait for all CI checks to pass
   - Automatically squash and merge the PR
   - Delete the branch after merge

To disable auto-merge for specific updates, simply remove the `version-update`
label from the PR.

## For Custom Automation: Personal Access Token (PAT)

To enable more complex automation scenarios:

### 1. Create a Personal Access Token

1. Go to **Settings** → **Developer settings** → **Personal access tokens** →
   **Tokens (classic)**
2. Click **Generate new token**
3. Configure:
   - **Name**: `containers-ci`
   - **Expiration**: Set as needed
   - **Scopes**:
     - `repo` (full control of private repositories)
     - `workflow` (if updating GitHub Actions workflows)

4. Copy the generated token

### 2. Add as Repository Secret

1. Navigate to your repository's **Settings** → **Secrets and variables** →
   **Actions**
2. Click **New repository secret**
3. Add:
   - **Name**: `CI_PUSH_TOKEN`
   - **Secret**: The token you copied

### 3. Use in Workflow

```yaml
- name: Checkout with push access
  uses: actions/checkout@v4
  with:
    token: ${{ secrets.CI_PUSH_TOKEN }}

- name: Push changes
  run: |
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git add .
    git commit -m "Automated version updates"
    git push
```

## For Protected Branches

If pushing to protected branches like `main`:

### Option 1: Branch Protection Bypass

1. Create a PAT from an admin account
2. Add the admin user to the bypass list in branch protection settings

### Option 2: Pull Request Workflow

Instead of pushing directly, create pull requests:

```yaml
- name: Create Pull Request
  uses: peter-evans/create-pull-request@v5
  with:
    token: ${{ secrets.CI_PUSH_TOKEN }}
    commit-message: 'chore: automated version updates'
    title: 'Automated Version Updates'
    body: |
      ## Automated Version Updates

      This PR contains automated version updates detected by the weekly scan.

      See the changes in the files tab for details.
    branch: auto-update/versions-${{ github.run_number }}
    delete-branch: true
```

## Using GitHub App (Advanced)

For organizations, using a GitHub App provides better security:

1. Create a GitHub App with repository permissions
2. Install the app on your repository
3. Use the app's credentials in workflows:

```yaml
- name: Generate token
  uses: tibdex/github-app-token@v2
  id: generate-token
  with:
    app_id: ${{ secrets.APP_ID }}
    private_key: ${{ secrets.APP_PRIVATE_KEY }}

- name: Checkout
  uses: actions/checkout@v4
  with:
    token: ${{ steps.generate-token.outputs.token }}
```

## Image Signing with Cosign (OIDC)

For container image signing using Sigstore/Cosign, the workflow needs OIDC token
permissions:

```yaml
permissions:
  contents: write # For creating releases
  packages: read # For pulling images from GHCR
  id-token: write # Required for OIDC signing with Cosign
```

**Why `id-token: write` is needed:**

- Cosign uses GitHub Actions OIDC to perform keyless signing
- The OIDC token proves the identity of the workflow
- Signatures are tied to the specific repository and workflow
- No private keys need to be managed or stored

**Example in `.github/workflows/ci.yml`:**

```yaml
release:
  name: Create Release
  runs-on: ubuntu-latest
  needs: build
  if: startsWith(github.ref, 'refs/tags/v')
  permissions:
    contents: write
    packages: read
    id-token: write # Enable Cosign OIDC signing
  steps:
    - name: Install Cosign
      uses: sigstore/cosign-installer@v3

    - name: Sign container images
      env:
        COSIGN_EXPERIMENTAL: 1 # Enable keyless signing
      run: |
        cosign sign --yes "$IMAGE"
```

See `docs/security-hardening.md` issue #16 for complete implementation details.

## Security Best Practices

1. **Use least privilege**: Only grant necessary permissions
2. **Rotate tokens regularly**: Set expiration dates
3. **Use repository secrets**: Never hardcode tokens
4. **Prefer GitHub Apps** for organization repositories
5. **Use environment protection rules** for sensitive operations
6. **Enable OIDC for Cosign**: Use `id-token: write` for keyless image signing

## Troubleshooting

### Error: "refusing to allow a GitHub App to create or update workflow"

- Use a Personal Access Token with `workflow` scope instead of `GITHUB_TOKEN`

### Error: "Protected branch update failed"

- Ensure the token owner has bypass permissions
- Or use the pull request workflow instead

### Error: "Resource not accessible by integration"

- The default `GITHUB_TOKEN` lacks required permissions
- Switch to a Personal Access Token or GitHub App

## Testing the Configuration

1. Create a test branch and push a small change
2. Check Actions tab for workflow runs
3. Verify automated commits appear with correct author
4. Ensure subsequent workflows trigger (if needed)
