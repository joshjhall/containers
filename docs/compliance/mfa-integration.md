# Multi-Factor Authentication Integration

This document provides guidance for implementing MFA for privileged access in
container deployments to meet compliance requirements.

## Compliance Coverage

| Framework | Requirement                 | Section       |
| --------- | --------------------------- | ------------- |
| HIPAA     | Access control              | §164.312(d)   |
| ISO 27001 | User access management      | A.9.2         |
| SOC 2     | Logical access controls     | CC6.1         |
| PCI DSS   | Unique identification       | Requirement 8 |
| FedRAMP   | Identification & Auth       | IA-2          |
| CMMC      | Multi-factor authentication | IA.L2-3.5.3   |

## Architecture Overview

MFA for container environments operates at multiple layers:

```text
┌─────────────────────────────────────────────────┐
│              User Access Layer                   │
│  (Console, CLI, API with MFA enforcement)       │
└──────────────────────┬──────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────┐
│           Identity Provider Layer                │
│  (Azure AD, GCP IAM, AWS IAM, Okta)             │
└──────────────────────┬──────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────┐
│          Workload Identity Layer                 │
│  (Service Accounts, Workload Identity)          │
└──────────────────────┬──────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────┐
│           Container Runtime Layer                │
│  (Kubernetes, Docker with RBAC)                 │
└─────────────────────────────────────────────────┘
```

## Implementation Options

### Option 1: GCP Workload Identity with MFA

Best for: GCP-native Kubernetes deployments

#### Step 1: Enable Workload Identity

```bash
# Enable Workload Identity on cluster
gcloud container clusters update CLUSTER_NAME \
  --workload-pool=PROJECT_ID.svc.id.goog

# Configure node pool
gcloud container node-pools update NODE_POOL \
  --cluster=CLUSTER_NAME \
  --workload-metadata=GKE_METADATA
```

#### Step 2: Create Service Account with IAM Conditions

```bash
# Create GCP service account
gcloud iam service-accounts create k8s-workload \
  --display-name="Kubernetes Workload Identity"

# Create IAM policy with MFA condition
cat > mfa-condition.yaml << 'EOF'
title: "Require MFA for access"
description: "Requires MFA for privileged operations"
expression: >
  request.auth.claims.amr.exists(amr, amr == 'mfa') ||
  request.auth.claims.acr == 'http://schemas.openid.net/pape/policies/2007/06/multi-factor'
EOF

# Bind with condition
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:k8s-workload@PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/container.developer" \
  --condition-from-file=mfa-condition.yaml
```

#### Step 3: Kubernetes Service Account Binding

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workload-sa
  namespace: default
  annotations:
    iam.gke.io/gcp-service-account: k8s-workload@PROJECT_ID.iam.gserviceaccount.com
---
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  serviceAccountName: workload-sa
  containers:
    - name: app
      image: gcr.io/PROJECT_ID/app:latest
```

### Option 2: AWS IAM with MFA Requirements

Best for: AWS EKS deployments

#### Step 1: Create IAM Policy with MFA Condition

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "RequireMFAForEKS",
      "Effect": "Allow",
      "Action": [
        "eks:*",
        "ecr:GetAuthorizationToken",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "*",
      "Condition": {
        "Bool": {
          "aws:MultiFactorAuthPresent": "true"
        },
        "NumericLessThan": {
          "aws:MultiFactorAuthAge": "3600"
        }
      }
    },
    {
      "Sid": "DenyWithoutMFA",
      "Effect": "Deny",
      "Action": [
        "eks:DeleteCluster",
        "eks:UpdateClusterConfig",
        "ecr:DeleteRepository"
      ],
      "Resource": "*",
      "Condition": {
        "BoolIfExists": {
          "aws:MultiFactorAuthPresent": "false"
        }
      }
    }
  ]
}
```

#### Step 2: IRSA (IAM Roles for Service Accounts)

```bash
# Create OIDC provider for EKS
eksctl utils associate-iam-oidc-provider \
  --cluster CLUSTER_NAME \
  --approve

# Create service account with IAM role
eksctl create iamserviceaccount \
  --cluster CLUSTER_NAME \
  --namespace default \
  --name app-sa \
  --attach-policy-arn arn:aws:iam::ACCOUNT:policy/RequireMFAPolicy \
  --approve
```

#### Step 3: Session Policy for Temporary Credentials

```bash
# Get temporary credentials with MFA
aws sts get-session-token \
  --serial-number arn:aws:iam::ACCOUNT:mfa/username \
  --token-code 123456 \
  --duration-seconds 3600
```

### Option 3: Azure AD Integration

Best for: Azure AKS deployments

#### Step 1: Enable Azure AD Integration

```bash
# Enable Azure AD for AKS
az aks update \
  --resource-group RESOURCE_GROUP \
  --name CLUSTER_NAME \
  --enable-aad \
  --aad-admin-group-object-ids ADMIN_GROUP_ID
```

#### Step 2: Conditional Access Policy

```json
{
  "displayName": "Require MFA for AKS Access",
  "state": "enabled",
  "conditions": {
    "applications": {
      "includeApplications": ["6dae42f8-4368-4678-94ff-3960e28e3630"]
    },
    "users": {
      "includeGroups": ["aks-administrators-group-id"]
    }
  },
  "grantControls": {
    "operator": "AND",
    "builtInControls": ["mfa", "compliantDevice"]
  },
  "sessionControls": {
    "signInFrequency": {
      "value": 1,
      "type": "hours"
    }
  }
}
```

#### Step 3: Kubernetes RBAC Binding

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aks-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: 'AZURE_AD_GROUP_OBJECT_ID'
```

## SSH MFA for Bastion Access

### Google OS Login with 2FA

```bash
# Enable OS Login on project
gcloud compute project-info add-metadata \
  --metadata enable-oslogin=TRUE,enable-oslogin-2fa=TRUE

# Create bastion with OS Login
gcloud compute instances create bastion \
  --zone=us-central1-a \
  --metadata enable-oslogin=TRUE,enable-oslogin-2fa=TRUE \
  --tags=bastion

# Grant OS Login access
gcloud compute os-login ssh-keys add \
  --key-file=~/.ssh/id_rsa.pub
```

### PAM-based MFA for SSH

#### Install and Configure Google Authenticator

```bash
# Install PAM module
apt-get install libpam-google-authenticator

# Configure PAM for SSH
cat >> /etc/pam.d/sshd << 'EOF'
# MFA using Google Authenticator
auth required pam_google_authenticator.so nullok
EOF

# Update SSH config
cat >> /etc/ssh/sshd_config << 'EOF'
# Enable challenge-response authentication
ChallengeResponseAuthentication yes
AuthenticationMethods publickey,keyboard-interactive
EOF

# Restart SSH
systemctl restart sshd
```

#### User Setup

```bash
# Generate TOTP secret
google-authenticator -t -d -f -r 3 -R 30 -w 3

# Follow prompts to set up authenticator app
```

### AWS Session Manager with MFA

```bash
# Start session with MFA
aws ssm start-session \
  --target i-1234567890abcdef0 \
  --document-name AWS-StartInteractiveCommand

# Session Manager plugin handles MFA automatically when IAM requires it
```

## Break-Glass Emergency Access

### Purpose

Emergency access procedures for when normal MFA flows are unavailable.

### Break-Glass Account Setup

```yaml
# Kubernetes Secret for break-glass credentials
apiVersion: v1
kind: Secret
metadata:
  name: break-glass-credentials
  namespace: kube-system
  labels:
    emergency: 'true'
type: Opaque
stringData:
  # Encrypted with KMS/Vault
  username: emergency-admin
  # Rotate after each use
  password: ENC[AES256_GCM,data:...,type:str]
```

### Emergency Access Procedure

1. **Authorization Required**
   - Minimum two authorized personnel must approve
   - Document business justification
   - Notify security team immediately

2. **Access Retrieval**

   ```bash
   # Retrieve break-glass credentials from secure vault
   vault kv get -field=password secret/emergency/k8s-admin

   # Or from cloud secret manager
   gcloud secrets versions access latest \
     --secret=break-glass-admin
   ```

3. **Session Logging**

   ```bash
   # All break-glass sessions must be recorded
   script -a /var/log/emergency-access-$(date +%Y%m%d-%H%M%S).log

   # Or use cloud logging
   gcloud logging write emergency-access \
     "Break-glass access initiated by $USER"
   ```

4. **Post-Incident Actions**
   - Rotate all break-glass credentials
   - Review audit logs
   - Document incident timeline
   - Update procedures if needed

### Break-Glass Audit Trail

```yaml
# Falco rule for break-glass detection
- rule: Break Glass Account Used
  desc: Emergency break-glass account was used
  condition: >
    spawned_process and user.name = "emergency-admin"
  output: >
    Break-glass account used (user=%user.name command=%proc.cmdline
    container=%container.id)
  priority: CRITICAL
  tags: [emergency, audit]
```

## Session Timeout Policies

### Kubernetes Session Configuration

```yaml
# API server audit policy for session tracking
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: Metadata
    users: ['*']
    verbs: ['create', 'delete', 'update', 'patch']
    resources:
      - group: ''
        resources: ['secrets', 'configmaps']
```

### Cloud Provider Session Limits

#### GCP

```bash
# Set session duration for service account keys
gcloud iam service-accounts keys create key.json \
  --iam-account=sa@project.iam.gserviceaccount.com \
  --key-file-type=json

# Configure organization policy for session duration
gcloud resource-manager org-policies set-policy policy.yaml \
  --organization=ORG_ID
```

Policy file:

```yaml
constraint: constraints/iam.allowServiceAccountCredentialLifetimeExtension
listPolicy:
  deniedValues:
    - 'under:organizations/ORG_ID'
```

#### AWS

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "*",
      "Condition": {
        "NumericLessThanEquals": {
          "sts:DurationSeconds": "3600"
        }
      }
    }
  ]
}
```

#### Azure

```json
{
  "sessionControls": {
    "signInFrequency": {
      "value": 1,
      "type": "hours",
      "isEnabled": true
    },
    "persistentBrowser": {
      "mode": "never",
      "isEnabled": true
    }
  }
}
```

### Recommended Timeout Values

| Access Type     | Maximum Session | Re-auth Frequency |
| --------------- | --------------- | ----------------- |
| Console/Portal  | 12 hours        | 1 hour for admin  |
| CLI/API         | 1 hour          | Every request     |
| Service Account | 1 hour          | Auto-rotate       |
| Break-glass     | 30 minutes      | Every use         |
| SSH Bastion     | 8 hours         | Session start     |

## Verification

### Pre-Deployment Checklist

- [ ] MFA enabled for all admin accounts
- [ ] Conditional access policies configured
- [ ] Break-glass procedures documented
- [ ] Session timeouts enforced
- [ ] Audit logging enabled
- [ ] Emergency contacts documented

### Runtime Verification

```bash
# Verify GCP MFA requirement
gcloud organizations get-iam-policy ORG_ID \
  --format="json" | jq '.bindings[] | select(.condition)'

# Verify AWS MFA condition
aws iam get-policy-version \
  --policy-arn arn:aws:iam::ACCOUNT:policy/RequireMFA \
  --version-id v1 | jq '.PolicyVersion.Document'

# Verify Azure Conditional Access
az rest --method get \
  --uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies'
```

### Test MFA Enforcement

```bash
# Test without MFA (should fail)
gcloud container clusters get-credentials CLUSTER --zone ZONE
# Expected: ERROR: MFA required

# Test with MFA
gcloud auth login --enable-gdrive-access
gcloud container clusters get-credentials CLUSTER --zone ZONE
# Expected: Success after MFA prompt
```

## Monitoring and Alerting

### MFA Bypass Attempts

```yaml
# Prometheus alert for MFA bypass attempts
- alert: MFABypassAttempt
  expr: |
    increase(authentication_failures_total{reason="mfa_required"}[5m]) > 5
  for: 1m
  labels:
    severity: critical
  annotations:
    summary: Multiple MFA bypass attempts detected
```

### Break-Glass Usage

```yaml
- alert: BreakGlassAccountUsed
  expr: |
    increase(authentication_success_total{user="emergency-admin"}[1m]) > 0
  for: 0m
  labels:
    severity: critical
  annotations:
    summary: Emergency break-glass account was used
```

### Session Anomalies

```yaml
- alert: UnusualSessionDuration
  expr: |
    session_duration_seconds > 43200
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: Session exceeds 12-hour maximum
```

## Audit Evidence

Collect and retain:

- MFA enrollment records
- Conditional access policy configurations
- Authentication logs with MFA status
- Break-glass usage records
- Session duration logs
- Policy exception documentation

### Evidence Collection Script

```bash
#!/bin/bash
# Collect MFA audit evidence

# GCP IAM policies with conditions
gcloud organizations get-iam-policy ORG_ID \
  --format=yaml > gcp-iam-mfa-policies.yaml

# AWS IAM policies with MFA conditions
aws iam list-policies --scope Local --output json | \
  jq -r '.Policies[].Arn' | \
  xargs -I {} aws iam get-policy-version \
    --policy-arn {} \
    --version-id v1 > aws-mfa-policies.json

# Azure Conditional Access policies
az rest --method get \
  --uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies' \
  > azure-conditional-access.json

# Create evidence bundle
tar -czf mfa-evidence-$(date +%Y%m%d).tar.gz \
  *-policies.yaml *-policies.json *-conditional-access.json
```

## Troubleshooting

### MFA Challenge Not Appearing

```bash
# GCP: Verify 2FA is enabled
gcloud auth list
gcloud organizations get-iam-policy ORG_ID | grep -A5 condition

# AWS: Check MFA device registration
aws iam list-mfa-devices --user-name USERNAME

# Azure: Verify user MFA registration
az ad user show --id USER_ID --query "strongAuthenticationDetail"
```

### Session Timeout Issues

```bash
# Check token expiration
gcloud auth print-access-token --format=json | jq '.token_expiry'

# AWS session info
aws sts get-caller-identity
aws sts get-session-token --duration-seconds 900

# Refresh Azure token
az account get-access-token --query "expiresOn"
```

### Break-Glass Access Failures

```bash
# Verify emergency credentials exist
vault kv get secret/emergency/k8s-admin

# Check KMS encryption
gcloud kms keys list --location=global --keyring=emergency

# Verify emergency IAM bindings
gcloud projects get-iam-policy PROJECT_ID | grep emergency
```

## Related Documentation

- [Encryption in Transit](encryption-in-transit.md)
- [Production Checklist](production-checklist.md)
- [Incident Response](incident-response.md)
- [GCP Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
- [AWS IAM Roles for Service Accounts](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [Azure AD for AKS](https://docs.microsoft.com/en-us/azure/aks/managed-aad)
