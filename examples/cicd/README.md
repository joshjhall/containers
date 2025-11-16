# CI/CD Pipeline Templates

This directory contains production-ready CI/CD pipeline templates for building
and deploying containers across multiple platforms.

## Table of Contents

- [Overview](#overview)
- [Available Templates](#available-templates)
- [GitHub Actions](#github-actions)
- [GitLab CI](#gitlab-ci)
- [Jenkins](#jenkins)
- [Deployment Strategies](#deployment-strategies)
- [Quick Start](#quick-start)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## Overview

These templates provide complete CI/CD pipelines with:

- **Multi-stage pipelines**: Test → Build → Security Scan → Deploy
- **Multiple environments**: Development, Staging, Production
- **Security scanning**: Trivy vulnerability scanning, secret detection
- **Deployment strategies**: Rolling, Blue-Green, Canary
- **Automatic rollback**: On deployment failures
- **Manual approval gates**: For production deployments
- **Container registry integration**: GHCR, GitLab Registry, Docker Hub

## Available Templates

### CI/CD Platforms

- **[GitHub Actions](./github-actions/)** - Native GitHub CI/CD
  - `build-and-test.yml` - Build and test containers
  - `deploy-staging.yml` - Deploy to staging environment
  - `deploy-production.yml` - Deploy to production with approval
  - `rollback.yml` - Manual rollback workflow

- **[GitLab CI](./gitlab-ci/)** - GitLab CI/CD
  - `.gitlab-ci.yml` - Complete pipeline with stages

- **[Jenkins](./jenkins/)** - Jenkins Declarative Pipeline
  - `Jenkinsfile` - Multi-stage pipeline with parallel builds

### Deployment Strategies

- **[Blue-Green Deployment](./deployment-strategies/blue-green-deployment.sh)**
  - Zero-downtime deployments
  - Instant rollback capability
  - Test new version before switching traffic

- **[Canary Deployment](./deployment-strategies/canary-deployment.sh)**
  - Gradual traffic shifting (10% → 25% → 50% → 100%)
  - Monitor new version with real traffic
  - Automatic rollback on issues

## GitHub Actions

### Quick Start

1. Copy workflow files to your repository:

   ```bash
   mkdir -p .github/workflows
   cp examples/cicd/github-actions/*.yml .github/workflows/
   ```

2. Customize for your project:
   - Update `IMAGE_NAME` environment variable
   - Modify container variants in the build matrix
   - Adjust build arguments for your features

3. Configure secrets in GitHub:
   - Go to Settings → Secrets → Actions
   - Add: `KUBE_CONFIG_STAGING`, `KUBE_CONFIG_PRODUCTION`

4. Push to main branch or create a pull request

### Workflows

#### Build and Test (`build-and-test.yml`)

Runs on every push and pull request:

- Unit tests (no Docker required)
- Code quality (shellcheck, gitleaks)
- Build container variants in parallel
- Integration tests with actual containers
- Security scanning with Trivy

**Trigger:**

```yaml
on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]
```

**Matrix builds:**

```yaml
strategy:
  matrix:
    variant:
      - name: minimal
      - name: python-dev
      - name: node-dev
```

#### Deploy to Staging (`deploy-staging.yml`)

Automatically deploys to staging after successful builds on main:

- Waits for build workflow to complete
- Deploys to Kubernetes staging namespace
- Runs smoke tests
- Sends notifications

**Trigger:**

```yaml
on:
  workflow_run:
    workflows: ['Build and Test']
    types: [completed]
    branches: [main]
```

**Environment:**

```yaml
environment:
  name: staging
  url: https://staging.example.com
```

#### Deploy to Production (`deploy-production.yml`)

Manual deployment to production with multiple strategies:

- Requires manual approval
- Pre-deployment validation (image exists, security scan)
- Supports rolling, blue-green, or canary deployment
- Automated health checks
- Automatic rollback on failure

**Trigger:**

```yaml
on:
  workflow_dispatch:
    inputs:
      image_tag: ...
      deployment_strategy: ...
```

**Manual approval:**

```yaml
environment:
  name: production # Requires approval in GitHub settings
```

#### Rollback (`rollback.yml`)

Manual rollback workflow:

- Rolls back to previous image version
- Creates GitHub issue for tracking
- Sends notifications
- Preserves audit trail

### Configuration

#### Required Secrets

| Secret                   | Description                                       |
| ------------------------ | ------------------------------------------------- |
| `KUBE_CONFIG_STAGING`    | Kubernetes config for staging (base64 encoded)    |
| `KUBE_CONFIG_PRODUCTION` | Kubernetes config for production (base64 encoded) |
| `SLACK_WEBHOOK`          | (Optional) Slack webhook for notifications        |

#### Creating Kubernetes Config Secret

```bash
# Encode your kubeconfig
cat ~/.kube/config | base64 -w 0

# Add to GitHub: Settings → Secrets → Actions → New repository secret
# Name: KUBE_CONFIG_STAGING
# Value: <paste base64 output>
```

#### Environment Protection

Configure production environment protection:

1. Go to Settings → Environments → production
2. Enable "Required reviewers"
3. Add reviewers who can approve deployments
4. (Optional) Set deployment branches to `main` only

## GitLab CI

### Quick Start

1. Copy to your repository:

   ```bash
   cp examples/cicd/gitlab-ci/.gitlab-ci.yml .
   ```

2. Configure CI/CD variables in GitLab:
   - Settings → CI/CD → Variables
   - Add: `KUBE_CONFIG_STAGING`, `KUBE_CONFIG_PRODUCTION`

3. Push to repository

### Pipeline Stages

```
test → build → security-scan → deploy-staging → deploy-production
```

### Features

- **Parallel builds**: Multiple variants build simultaneously
- **Docker-in-Docker**: Builds containers within GitLab runners
- **Manual gates**: Production deployment requires manual trigger
- **Artifact retention**: Build artifacts kept for 30 days
- **Environment URLs**: Links to staging/production in UI

### Configuration

#### CI/CD Variables

| Variable                 | Description           | Protected | Masked |
| ------------------------ | --------------------- | --------- | ------ |
| `KUBE_CONFIG_STAGING`    | Staging kubeconfig    | No        | Yes    |
| `KUBE_CONFIG_PRODUCTION` | Production kubeconfig | Yes       | Yes    |
| `PROJECT_NAME`           | Project name          | No        | No     |

#### Runners

Ensure runners have:

- Docker executor
- Privileged mode enabled (for Docker-in-Docker)
- Sufficient resources (2+ CPUs, 4GB+ RAM)

## Jenkins

### Quick Start

1. Copy Jenkinsfile to your repository:

   ```bash
   cp examples/cicd/jenkins/Jenkinsfile .
   ```

2. Create Jenkins credentials:
   - Credentials → Add Credentials
   - Add: `github-container-registry`, `kube-config-staging`,
     `kube-config-production`

3. Create Jenkins pipeline job:
   - New Item → Pipeline
   - Pipeline → Definition → Pipeline script from SCM
   - SCM → Git → Add repository URL

4. Run pipeline

### Pipeline Structure

```groovy
pipeline {
    stages {
        Test (parallel: Unit Tests, Code Quality)
        Build (parallel: minimal, python-dev, node-dev)
        Security Scan
        Deploy to Staging
        Deploy to Production (manual approval)
    }
}
```

### Parameters

The pipeline accepts parameters for customization:

```groovy
parameters {
    choice(name: 'DEPLOYMENT_ENVIRONMENT', ...)
    choice(name: 'VARIANT', ...)
    booleanParam(name: 'RUN_SECURITY_SCAN', ...)
}
```

### Required Plugins

- Docker Pipeline
- Kubernetes CLI
- Git
- Pipeline
- Credentials Binding

### Credentials

| ID                          | Type              | Description           |
| --------------------------- | ----------------- | --------------------- |
| `github-container-registry` | Username/Password | GitHub username + PAT |
| `kube-config-staging`       | Secret file       | Staging kubeconfig    |
| `kube-config-production`    | Secret file       | Production kubeconfig |

## Deployment Strategies

### Blue-Green Deployment

**When to use:**

- Zero-downtime deployments required
- Instant rollback capability needed
- Testing new version before switching traffic

**How it works:**

1. Deploy new version to "green" environment
2. Test green environment thoroughly
3. Switch all traffic from "blue" to "green"
4. Keep blue environment for quick rollback

**Usage:**

```bash
./deployment-strategies/blue-green-deployment.sh \
    ghcr.io/myorg/app:v1.2.3 \
    production
```

**Variables:**

- `AUTO_APPROVE=true` - Skip manual approval
- `KEEP_OLD=false` - Delete old deployment after switch

**Example:**

```bash
# Automated blue-green deployment
AUTO_APPROVE=true \
KEEP_OLD=false \
./deployment-strategies/blue-green-deployment.sh \
    ghcr.io/myorg/app:v1.2.3 \
    production
```

### Canary Deployment

**When to use:**

- Testing with real production traffic
- Gradual rollout to minimize risk
- Monitoring new version behavior

**How it works:**

1. Deploy canary alongside current version
2. Route small percentage to canary (e.g., 10%)
3. Monitor canary for issues
4. Gradually increase canary traffic
5. Promote canary to replace main deployment

**Usage:**

```bash
./deployment-strategies/canary-deployment.sh \
    ghcr.io/myorg/app:v1.2.3 \
    production \
    10  # 10% traffic to canary
```

**Variables:**

- `MONITORING_DURATION=300` - Monitoring period in seconds
- `AUTO_PROMOTE=true` - Automatically promote canary
- `AUTO_ROLLBACK=true` - Auto-rollback on issues

**Example:**

```bash
# Canary with 10% traffic, 10-minute monitoring
MONITORING_DURATION=600 \
AUTO_ROLLBACK=true \
./deployment-strategies/canary-deployment.sh \
    ghcr.io/myorg/app:v1.2.3 \
    production \
    10
```

## Quick Start

### 1. Choose Your Platform

Pick the CI/CD platform you're using:

- GitHub → Use GitHub Actions templates
- GitLab → Use GitLab CI template
- Jenkins → Use Jenkinsfile

### 2. Copy Templates

```bash
# For GitHub Actions
mkdir -p .github/workflows
cp examples/cicd/github-actions/*.yml .github/workflows/

# For GitLab CI
cp examples/cicd/gitlab-ci/.gitlab-ci.yml .

# For Jenkins
cp examples/cicd/jenkins/Jenkinsfile .
```

### 3. Customize

Edit the copied files:

- Update `PROJECT_NAME` variable
- Modify container variants
- Adjust build arguments
- Update deployment namespaces

### 4. Configure Secrets

Add credentials in your CI/CD platform:

- Kubernetes configs (base64 encoded)
- Container registry credentials
- Notification webhooks (optional)

### 5. Test

Start with a pull request or feature branch:

- Verify builds work
- Check tests pass
- Review security scans

## Best Practices

### Security

1. **Never commit secrets**
   - Use CI/CD platform secret management
   - Rotate credentials regularly
   - Use least-privilege service accounts

2. **Scan for vulnerabilities**
   - Run Trivy on every build
   - Fail builds on CRITICAL vulnerabilities
   - Review and patch HIGH vulnerabilities

3. **Sign and verify images**
   - Use Cosign for image signing
   - Verify signatures before deployment
   - Use SBOM (Software Bill of Materials)

4. **Use minimal base images**
   - Prefer slim/distroless images
   - Remove unnecessary packages
   - Keep images updated

### Deployment

1. **Test thoroughly**
   - Unit tests before build
   - Integration tests after build
   - Smoke tests after deployment

2. **Use staging environments**
   - Mirror production configuration
   - Test deployments in staging first
   - Validate with production-like data

3. **Implement progressive delivery**
   - Start with canary deployments
   - Gradually increase traffic
   - Monitor metrics continuously

4. **Have rollback procedures**
   - Document rollback steps
   - Test rollback regularly
   - Keep previous versions available

### Monitoring

1. **Track key metrics**
   - Deployment frequency
   - Lead time for changes
   - Mean time to recovery
   - Change failure rate

2. **Set up alerts**
   - Deployment failures
   - High error rates
   - Resource exhaustion
   - Security vulnerabilities

3. **Log everything**
   - Structured logging (JSON)
   - Centralized log aggregation
   - Retention policies
   - Correlation IDs

## Troubleshooting

### Build Failures

**Problem**: Docker build fails with "no space left on device"

**Solution**:

```bash
# GitHub Actions: Clean up Docker
docker system prune -af

# GitLab CI: Increase runner disk space or enable cleanup
# Jenkins: Configure disk cleanup plugin
```

**Problem**: Build args not being recognized

**Solution**:

```bash
# Ensure build args are defined in Dockerfile:
ARG PROJECT_NAME
ARG INCLUDE_PYTHON_DEV=false

# Pass with --build-arg:
--build-arg PROJECT_NAME=myproject
--build-arg INCLUDE_PYTHON_DEV=true
```

### Deployment Failures

**Problem**: kubectl commands fail with "Unauthorized"

**Solution**:

```bash
# Verify kubeconfig is correct and base64 encoded:
cat ~/.kube/config | base64 -w 0

# Check kubeconfig has correct context:
kubectl config get-contexts

# Ensure service account has proper RBAC:
kubectl auth can-i create deployments --namespace=production
```

**Problem**: Pods stuck in "ImagePullBackOff"

**Solution**:

```bash
# Check image exists:
docker pull ghcr.io/myorg/app:v1.2.3

# Verify image registry credentials:
kubectl get secret regcred -n production -o yaml

# Check pod events:
kubectl describe pod <pod-name> -n production
```

### Rollback Issues

**Problem**: Rollback fails because backup is missing

**Solution**:

```bash
# List previous revisions:
kubectl rollout history deployment/myapp -n production

# Rollback to specific revision:
kubectl rollout undo deployment/myapp -n production --to-revision=2
```

**Problem**: Traffic not switching during blue-green

**Solution**:

```bash
# Verify service selector:
kubectl get service myapp -n production -o yaml | grep -A 5 selector

# Check pod labels:
kubectl get pods -n production --show-labels

# Manually patch service:
kubectl patch service myapp -n production \
    -p '{"spec":{"selector":{"deployment":"green"}}}'
```

## Additional Resources

- [Container Build System Documentation](../../README.md)
- [Kubernetes Deployment Guide](../kubernetes/README.md)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [GitLab CI/CD Documentation](https://docs.gitlab.com/ee/ci/)
- [Jenkins Pipeline Documentation](https://www.jenkins.io/doc/book/pipeline/)
- [Docker Best Practices](https://docs.docker.com/develop/dev-best-practices/)

## Support

For issues and questions:

- [GitHub Issues](https://github.com/joshjhall/containers/issues)
- [Project Documentation](../../docs/)

## License

This project is licensed under the MIT License - see the
[LICENSE](../../LICENSE) file for details.
