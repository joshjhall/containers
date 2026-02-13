---
description: Cloud infrastructure tools available in this container
---

# Cloud Infrastructure

This skill describes which cloud and infrastructure tools are available
in this container environment.

## Available Tools

<!-- DYNAMIC: This section is replaced at runtime with actual installed tools -->

See /etc/container/config/enabled-features.conf for build-time feature flags.

## General Patterns

- Use infrastructure-as-code (Terraform, CloudFormation, etc.)
- Keep credentials in environment variables, never in code
- Use least-privilege IAM roles and service accounts
- Tag resources for cost tracking and ownership
- Use separate environments (dev, staging, production)
