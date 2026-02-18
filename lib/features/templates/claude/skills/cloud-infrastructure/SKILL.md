---
description: Cloud infrastructure tools and patterns available in this container. Use when working with cloud services, infrastructure-as-code, or container deployment.
---

# Cloud Infrastructure

## Available Tools

<!-- DYNAMIC: This section is replaced at runtime with actual installed tools -->

Check which cloud tools are installed:

- Feature flags: `cat /etc/container/config/enabled-features.conf`
- Installed versions: `check-installed-versions.sh`

## Container-Specific Patterns

- Cloud CLI credentials are passed via environment variables, never baked
  into images — use `OP_*_REF` convention or direct env vars
- Terraform state files belong in remote backends, never in the container
- Use `setup-gh` / `setup-glab` commands for GitHub/GitLab CLI authentication
- Cloud CLIs cache to `/cache/` subdirectories when applicable

## When to Use

- Working with cloud CLIs (aws, gcloud, kubectl, terraform)
- Writing infrastructure-as-code
- Configuring cloud service authentication in containers

## When NOT to Use

- Application code that calls cloud APIs via SDKs (use language-specific guidance)
- Docker/container development (use `docker-development` skill)
