# Secret Management Integration Examples

This directory contains examples for integrating various secret management
providers with the container runtime.

## Table of Contents

- [Overview](#overview)
- [Supported Providers](#supported-providers)
- [Environment Variables](#environment-variables)
- [Examples](#examples)
  - [Docker Secrets](#docker-secrets)
  - [HashiCorp Vault](#hashicorp-vault)
  - [AWS Secrets Manager](#aws-secrets-manager)
  - [Azure Key Vault](#azure-key-vault)
  - [GCP Secret Manager](#gcp-secret-manager)
  - [1Password](#1password)
  - [Kubernetes Secrets](#kubernetes-secrets)
- [Docker Compose Examples](#docker-compose-examples)
- [Testing](#testing)

## Overview

The container runtime includes built-in support for loading secrets from
multiple secret management providers at container startup. Secrets are
automatically injected as environment variables, making them available to your
application without code changes.

### Features

- **Multi-provider support**: Docker Secrets, HashiCorp Vault, AWS, Azure, GCP,
  1Password
- **Automatic loading**: Secrets loaded during container startup
- **Flexible authentication**: Multiple auth methods per provider
- **Error handling**: Configurable fail-on-error behavior
- **Priority-based loading**: Control which providers load first
- **Health checks**: Verify provider connectivity
- **Auto-detection**: Docker Secrets automatically detected when available

## Supported Providers

| Provider                | Authentication Methods                  | Use Case                     |
| ----------------------- | --------------------------------------- | ---------------------------- |
| **Docker Secrets**      | File-based (auto-detected)              | Docker Swarm, Docker Compose |
| **HashiCorp Vault**     | Token, AppRole, Kubernetes              | Enterprise, multi-cloud      |
| **AWS Secrets Manager** | IAM, Access Keys, IRSA                  | AWS-native applications      |
| **Azure Key Vault**     | Managed Identity, Service Principal     | Azure-native applications    |
| **GCP Secret Manager**  | Workload Identity, Service Account, ADC | GCP-native applications      |
| **1Password**           | Connect Server, Service Account, CLI    | Development, SMB             |

## Environment Variables

### Universal Secret Loader

```bash
# Enable/disable secret loading (default: true)
SECRET_LOADER_ENABLED=true

# Provider priority (comma-separated, default: "docker,1password,vault,aws,azure,gcp")
SECRET_LOADER_PRIORITY="docker,vault,aws,azure,gcp,1password"

# Fail container startup if secret loading fails (default: false)
SECRET_LOADER_FAIL_ON_ERROR=false
```

### Provider-Specific Variables

See individual provider sections below for detailed configuration.

## Examples

### Docker Secrets

Docker Secrets provides a simple, file-based secret management system for Docker
Swarm and Docker Compose. Secrets are mounted as files in `/run/secrets/` and
automatically detected by the container runtime.

#### Configuration

```bash
# Docker secrets are auto-detected by default (no configuration needed!)
# Customize behavior with optional environment variables:

# Enable/disable Docker secrets (default: auto-detect)
DOCKER_SECRETS_ENABLED="auto"

# Secret directory (default: /run/secrets)
DOCKER_SECRETS_DIR="/run/secrets"

# Prefix for exported environment variables
DOCKER_SECRET_PREFIX="APP_"

# Load only specific secrets (comma-separated, default: all)
DOCKER_SECRET_NAMES="db_password,api_key"

# Convert secret names to uppercase (default: true)
DOCKER_SECRETS_UPPERCASE="true"
```

#### Example: Docker Compose

```yaml
version: '3.8'

services:
  app:
    image: myapp:latest
    secrets:
      - db_password
      - api_key
    environment:
      # Docker secrets are auto-detected - no config needed!
      # Optionally customize:
      # DOCKER_SECRET_PREFIX: "APP_"

secrets:
  db_password:
    file: ./secrets/db_password.txt
  api_key:
    file: ./secrets/api_key.txt
```

#### Example: Docker Swarm

```bash
# Create secrets in Swarm
echo "super-secret-password" | docker secret create db_password -
echo "my-api-key-12345" | docker secret create api_key -

# Deploy service with secrets
docker service create \
  --name myapp \
  --secret db_password \
  --secret api_key \
  myapp:latest
```

**Key Features:**

- **Auto-detection**: Automatically loads secrets if `/run/secrets/` exists
- **Zero configuration**: Works out-of-the-box with Docker Compose/Swarm
- **Simple**: Just mount secrets, they're loaded as environment variables
- **Secure**: Secrets never stored in images or environment variables

### HashiCorp Vault

HashiCorp Vault is an enterprise-grade secret management solution with extensive
authentication options and dynamic secret support.

#### Configuration

```bash
# Enable Vault integration
VAULT_ENABLED=true

# Vault server address (required)
VAULT_ADDR="https://vault.example.com:8200"

# Authentication method: token, approle, kubernetes
VAULT_AUTH_METHOD="token"

# Token authentication
VAULT_TOKEN="hvs.CAESI..."

# AppRole authentication (alternative to token)
VAULT_ROLE_ID="role-id-here"
VAULT_SECRET_ID="secret-id-here"

# Kubernetes authentication (alternative to token/approle)
VAULT_K8S_ROLE="myapp-role"

# Secret path (KV v2 format)
VAULT_SECRET_PATH="secret/data/myapp/production"

# Optional: Vault namespace (Enterprise only)
VAULT_NAMESPACE="myapp"

# Optional: Prefix for exported environment variables
VAULT_SECRET_PREFIX="VAULT_"
```

#### Example: Token Authentication

```bash
docker run -it --rm \
  -e VAULT_ENABLED=true \
  -e VAULT_ADDR="https://vault.example.com:8200" \
  -e VAULT_AUTH_METHOD="token" \
  -e VAULT_TOKEN="hvs.CAESI..." \
  -e VAULT_SECRET_PATH="secret/data/myapp/production" \
  myapp:latest
```

#### Example: Kubernetes Authentication

For containers running in Kubernetes with Vault integration:

```yaml
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: myapp
  containers:
    - name: app
      image: myapp:latest
      env:
        - name: VAULT_ENABLED
          value: 'true'
        - name: VAULT_ADDR
          value: 'https://vault.default.svc.cluster.local:8200'
        - name: VAULT_AUTH_METHOD
          value: 'kubernetes'
        - name: VAULT_K8S_ROLE
          value: 'myapp-role'
        - name: VAULT_SECRET_PATH
          value: 'secret/data/myapp/production'
```

### AWS Secrets Manager

AWS Secrets Manager provides native AWS integration with automatic rotation
support.

#### Configuration

```bash
# Enable AWS Secrets Manager integration
AWS_SECRETS_ENABLED=true

# Secret name or ARN (required)
AWS_SECRET_NAME="myapp/production/secrets"

# AWS region (optional, defaults to AWS CLI config or us-east-1)
AWS_REGION="us-east-1"

# Optional: Specific version ID
AWS_SECRET_VERSION_ID="version-id-here"

# Optional: Version stage (default: AWSCURRENT)
AWS_SECRET_VERSION_STAGE="AWSCURRENT"

# Optional: Prefix for exported environment variables
AWS_SECRET_PREFIX="AWS_"

# Optional: Custom environment variable name (for non-JSON secrets)
AWS_SECRET_ENV_VAR="DATABASE_URL"
```

#### Authentication

AWS Secrets Manager uses the standard AWS authentication chain:

1. Environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
2. AWS CLI config files (`~/.aws/credentials`, `~/.aws/config`)
3. IAM instance profile (EC2)
4. ECS task role (ECS)
5. IRSA - IAM Roles for Service Accounts (EKS)

#### Example: EC2 with IAM Instance Profile

```bash
docker run -it --rm \
  -e AWS_SECRETS_ENABLED=true \
  -e AWS_SECRET_NAME="myapp/production/secrets" \
  -e AWS_REGION="us-east-1" \
  myapp:latest
```

#### Example: EKS with IRSA

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: myapp
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/myapp-secrets-role
---
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: myapp
  containers:
    - name: app
      image: myapp:latest
      env:
        - name: AWS_SECRETS_ENABLED
          value: 'true'
        - name: AWS_SECRET_NAME
          value: 'myapp/production/secrets'
        - name: AWS_REGION
          value: 'us-east-1'
```

### Azure Key Vault

Azure Key Vault integrates with Azure Managed Identity for secure,
credential-free access.

#### Configuration

```bash
# Enable Azure Key Vault integration
AZURE_KEYVAULT_ENABLED=true

# Key Vault name (required)
AZURE_KEYVAULT_NAME="myapp-keyvault"

# Optional: Full vault URL (constructed from name if not provided)
AZURE_KEYVAULT_URL="https://myapp-keyvault.vault.azure.net"

# Optional: Specific secret names (comma-separated, all secrets if not set)
AZURE_SECRET_NAMES="database-password,api-key,encryption-key"

# Optional: Prefix for exported environment variables
AZURE_SECRET_PREFIX="AZURE_"

# Service Principal authentication (if not using Managed Identity)
AZURE_TENANT_ID="tenant-id-here"
AZURE_CLIENT_ID="client-id-here"
AZURE_CLIENT_SECRET="client-secret-here"
```

#### Authentication

Azure Key Vault supports:

1. **Managed Identity** (Recommended for Azure VMs, AKS, Azure Container
   Instances)
2. **Service Principal** (Environment variables)
3. **Azure CLI authentication** (Development)

#### Example: AKS with Managed Identity

```yaml
apiVersion: v1
kind: Pod
metadata:
  labels:
    aadpodidbinding: myapp-identity
spec:
  containers:
    - name: app
      image: myapp:latest
      env:
        - name: AZURE_KEYVAULT_ENABLED
          value: 'true'
        - name: AZURE_KEYVAULT_NAME
          value: 'myapp-keyvault'
        - name: AZURE_SECRET_NAMES
          value: 'database-password,api-key'
```

#### Example: Service Principal

```bash
docker run -it --rm \
  -e AZURE_KEYVAULT_ENABLED=true \
  -e AZURE_KEYVAULT_NAME="myapp-keyvault" \
  -e AZURE_TENANT_ID="tenant-id" \
  -e AZURE_CLIENT_ID="client-id" \
  -e AZURE_CLIENT_SECRET="client-secret" \
  myapp:latest
```

### GCP Secret Manager

Google Cloud Secret Manager provides native GCP integration with automatic
rotation support and Workload Identity for GKE.

#### Configuration

```bash
# Enable GCP Secret Manager integration
GCP_SECRETS_ENABLED=true

# GCP project ID (required, or uses gcloud default)
GCP_PROJECT_ID="my-project-id"

# Comma-separated list of secret names (optional, all if not set)
GCP_SECRET_NAMES="db-password,api-key,encryption-key"

# Secret version (default: latest)
GCP_SECRET_VERSION="latest"

# Prefix for exported environment variables
GCP_SECRET_PREFIX="APP_"

# Service account key file path (optional, for non-ADC auth)
GCP_SERVICE_ACCOUNT_KEY="/path/to/key.json"
```

#### Authentication

GCP Secret Manager uses the standard GCP authentication chain:

1. Service account key file (`GCP_SERVICE_ACCOUNT_KEY`)
2. Application Default Credentials (ADC)
3. Workload Identity (GKE)
4. Compute Engine metadata server
5. gcloud CLI authentication

#### Example: GKE with Workload Identity

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: myapp
  annotations:
    iam.gke.io/gcp-service-account: myapp-secrets@PROJECT_ID.iam.gserviceaccount.com
---
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: myapp
  containers:
    - name: app
      image: myapp:latest
      env:
        - name: GCP_SECRETS_ENABLED
          value: 'true'
        - name: GCP_PROJECT_ID
          value: 'my-project-id'
        - name: GCP_SECRET_NAMES
          value: 'db-password,api-key'
```

#### Example: Local with Service Account

```bash
docker run -it --rm \
  -e GCP_SECRETS_ENABLED=true \
  -e GCP_PROJECT_ID="my-project-id" \
  -e GCP_SERVICE_ACCOUNT_KEY="/secrets/gcp-key.json" \
  -e GCP_SECRET_NAMES="db-password,api-key" \
  -v ./gcp-key.json:/secrets/gcp-key.json:ro \
  myapp:latest
```

### 1Password

1Password provides both Connect Server (for production) and CLI-based (for
development) secret management.

#### Configuration

```bash
# Enable 1Password integration
OP_ENABLED=true

# Method 1: Connect Server (recommended for production)
OP_CONNECT_HOST="https://connect.1password.com"
OP_CONNECT_TOKEN="connect-token-here"

# Method 2: Service Account (CLI-based)
OP_SERVICE_ACCOUNT_TOKEN="<your-1password-service-account-token>"

# Method 3: CLI Session (requires interactive signin)
# No token required, but requires `op signin` before running container

# Optional: Vault name or ID
OP_VAULT="Production"

# Optional: Specific item names (comma-separated)
OP_ITEM_NAMES="Database Credentials,API Keys,SSL Certificate"

# Optional: Secret references (op://vault/item/field format)
OP_SECRET_REFERENCES="op://Production/Database/password,op://Production/API/key"

# Optional: Prefix for exported environment variables
OP_SECRET_PREFIX="OP_"
```

#### Example: Connect Server

```bash
docker run -it --rm \
  -e OP_ENABLED=true \
  -e OP_CONNECT_HOST="https://connect.1password.com" \
  -e OP_CONNECT_TOKEN="eyJhbGci..." \
  -e OP_VAULT="Production" \
  -e OP_ITEM_NAMES="Database Credentials" \
  myapp:latest
```

#### Example: Service Account

```bash
docker run -it --rm \
  -e OP_ENABLED=true \
  -e OP_SERVICE_ACCOUNT_TOKEN="<your-1password-service-account-token>" \
  -e OP_SECRET_REFERENCES="op://Production/Database/password" \
  myapp:latest
```

### Kubernetes Secrets

While the container supports external secret providers, you can also inject
Kubernetes secrets directly as environment variables.

#### Example: Environment Variables from Secrets

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: myapp-secrets
type: Opaque
stringData:
  database-password: 'super-secret'
  api-key: 'api-key-here'
---
apiVersion: v1
kind: Pod
spec:
  containers:
    - name: app
      image: myapp:latest
      env:
        - name: DATABASE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: myapp-secrets
              key: database-password
        - name: API_KEY
          valueFrom:
            secretKeyRef:
              name: myapp-secrets
              key: api-key
```

#### Example: External Secrets Operator

Use [External Secrets Operator](https://external-secrets.io/) to sync from
external providers to Kubernetes secrets:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: 'https://vault.example.com'
      path: 'secret'
      version: 'v2'
      auth:
        kubernetes:
          mountPath: 'kubernetes'
          role: 'myapp-role'
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: myapp-secrets
    creationPolicy: Owner
  data:
    - secretKey: database-password
      remoteRef:
        key: myapp/production
        property: database_password
```

## Docker Compose Examples

See `docker-compose-*.yml` files in this directory for complete examples.

### Multi-Provider Example

```yaml
version: '3.8'

services:
  app:
    image: myapp:latest
    environment:
      # Universal loader configuration
      SECRET_LOADER_ENABLED: 'true'
      SECRET_LOADER_PRIORITY: 'vault,aws,1password'
      SECRET_LOADER_FAIL_ON_ERROR: 'false'

      # HashiCorp Vault
      VAULT_ENABLED: 'true'
      VAULT_ADDR: 'https://vault.example.com:8200'
      VAULT_TOKEN: '${VAULT_TOKEN}'
      VAULT_SECRET_PATH: 'secret/data/myapp/production'

      # AWS Secrets Manager
      AWS_SECRETS_ENABLED: 'true'
      AWS_SECRET_NAME: 'myapp/production/secrets'
      AWS_REGION: 'us-east-1'

      # 1Password
      OP_ENABLED: 'true'
      OP_SERVICE_ACCOUNT_TOKEN: '${OP_SERVICE_ACCOUNT_TOKEN}'
```

## Testing

Test secret loading locally:

```bash
# Test with environment variables
docker run -it --rm \
  -e VAULT_ENABLED=true \
  -e VAULT_ADDR="https://vault.example.com:8200" \
  -e VAULT_TOKEN="your-token" \
  -e VAULT_SECRET_PATH="secret/data/test" \
  myapp:latest /bin/bash

# Verify secrets are loaded
printenv | grep VAULT_

# Test secret loader health check
source /opt/container-runtime/secrets/load-secrets.sh
check_all_providers_health
```

## Troubleshooting

### Secrets not loading

1. Check if secret loading is enabled:

   ```bash
   echo $SECRET_LOADER_ENABLED
   ```

2. Check container logs for error messages:

   ```bash
   docker logs <container-id>
   ```

3. Verify provider-specific environment variables are set

4. Test provider health manually:

   ```bash
   # Vault
   vault status

   # AWS
   aws secretsmanager list-secrets

   # Azure
   az keyvault secret list --vault-name myapp-keyvault

   # 1Password
   op account get
   ```

### Authentication errors

- **Vault**: Verify token is valid with `vault token lookup`
- **AWS**: Check IAM permissions include `secretsmanager:GetSecretValue`
- **Azure**: Verify managed identity or service principal has `Secret/Get`
  permission
- **1Password**: Verify Connect server is accessible or service account token is
  valid

### Missing dependencies

Secret loading requires:

- `jq` - JSON parsing (all providers)
- `vault` - HashiCorp Vault CLI (Vault provider)
- `aws` - AWS CLI (AWS Secrets Manager provider)
- `az` - Azure CLI (Azure Key Vault provider)
- `op` - 1Password CLI (1Password provider)
- `curl` - HTTP requests (1Password Connect)

Install missing tools or disable the corresponding provider.

## Security Best Practices

1. **Never commit secrets** to version control
2. **Use IAM roles** instead of access keys when possible
3. **Enable secret rotation** in your secret management provider
4. **Limit secret access** using least-privilege IAM policies
5. **Audit secret access** using provider audit logs
6. **Use namespaces/projects** to isolate secrets by environment
7. **Set expiration** on temporary credentials
8. **Monitor for anomalies** in secret access patterns

## Related Documentation

- [Production Deployment Guide](../../docs/production-deployment.md)
- [Environment Variables](../../docs/environment-variables.md)
- [Security Hardening](../../docs/security-hardening.md)
