# Audit Logging Configuration

This directory contains log shipping configurations for container audit logs,
supporting compliance requirements for SOC 2, HIPAA, PCI DSS, GDPR, and FedRAMP.

## Compliance Coverage

| Framework    | Requirement                   | Implementation                   |
| ------------ | ----------------------------- | -------------------------------- |
| SOC 2 CC7.2  | Security event monitoring     | Structured JSON logging          |
| ISO 27001    | A.12.4 Logging and monitoring | Centralized log collection       |
| HIPAA        | 164.312(b) Audit controls     | 6-year retention, immutable logs |
| PCI DSS 10.2 | Audit trail events            | Event categorization             |
| GDPR Art. 30 | Records of processing         | Data access logging              |
| FedRAMP AU-2 | Audit events                  | Comprehensive event capture      |
| NIST 800-53  | AU-2 Event logging            | Security event categories        |

## Files

### Log Shipping Configurations

| File                   | Description                             |
| ---------------------- | --------------------------------------- |
| fluentd-config.conf    | Fluentd/Fluent Bit configuration        |
| cloudwatch-config.json | AWS CloudWatch Logs agent configuration |
| promtail-config.yaml   | Grafana Loki (Promtail) configuration   |

### Immutable Storage Configurations

| File                       | Description                                          |
| -------------------------- | ---------------------------------------------------- |
| aws-s3-immutable.yaml      | AWS S3 with Object Lock (CloudFormation)             |
| gcp-storage-immutable.tf   | GCP Cloud Storage with retention (Terraform)         |
| cloudflare-r2-immutable.tf | Cloudflare R2 with Worker access control (Terraform) |

## Retention Policies by Framework

Different compliance frameworks have different retention requirements:

| Framework | Minimum Retention | Notes                               |
| --------- | ----------------- | ----------------------------------- |
| SOC 2     | 12 months         | Common audit period                 |
| HIPAA     | 6 years           | Longest requirement, use as default |
| PCI DSS   | 1 year            | 3 months immediately available      |
| GDPR      | As needed         | Data minimization principle applies |
| FedRAMP   | 3 years           | Federal records requirements        |
| SOX       | 7 years           | Financial records                   |

**Recommendation**: Use 6-year retention (HIPAA) as default to satisfy all
frameworks.

## Quick Start

### Enable Audit Logging

Build your container with audit logging enabled:

```bash
docker build -t myapp:secure \
  --build-arg ENABLE_AUDIT_LOGGING=true \
  --build-arg ENABLE_JSON_LOGGING=true \
  --build-arg PRODUCTION_MODE=true \
  -f containers/Dockerfile .
```

### Use Audit Functions in Your Application

```bash
# Source the audit logger
source /opt/container-runtime/audit-logger.sh

# Log authentication events
audit_auth "login" "admin" "success" '{"ip":"10.0.0.1","mfa":true}'

# Log authorization decisions
audit_authz "/api/users" "read" "admin" "granted" "admin role"

# Log data access (for sensitive data tracking)
audit_data_access "pii" "read" "service" 100 "user lookup"

# Log configuration changes
audit_config "database" "modified" "admin" "old_value" "new_value"

# Log security events
audit_security "anomaly" "high" "Unusual login pattern" '{"attempts":50}'

# Log compliance checks
audit_compliance "hipaa" "164.312(b)" "compliant" '{"control":"audit_logging"}'
```

## Log Shipping Setup

### Fluentd

1. Install Fluentd with required plugins:

```bash
gem install fluent-plugin-elasticsearch
gem install fluent-plugin-s3
```

1. Copy and customize configuration:

```bash
cp fluentd-config.conf /etc/fluentd/fluent.conf

# Set environment variables
export ELASTICSEARCH_HOST=elasticsearch.example.com
export AUDIT_LOGS_BUCKET=my-audit-logs
export AWS_REGION=us-east-1
```

1. Create Elasticsearch template for ILM:

```json
{
  "index_patterns": ["audit-logs-*"],
  "settings": {
    "index.lifecycle.name": "audit-logs-policy",
    "index.lifecycle.rollover_alias": "audit-logs",
    "number_of_shards": 2,
    "number_of_replicas": 1
  }
}
```

### AWS CloudWatch

1. Install CloudWatch agent:

```bash
wget https://s3.amazonaws.com/amazoncloudwatch-agent/debian/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i amazon-cloudwatch-agent.deb
```

1. Apply configuration:

```bash
cp cloudwatch-config.json /opt/aws/amazon-cloudwatch-agent/etc/

# Start agent
amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/cloudwatch-config.json -s
```

1. Create log group with retention:

```bash
aws logs create-log-group --log-group-name /containers/audit-logs
aws logs put-retention-policy --log-group-name /containers/audit-logs --retention-in-days 2190
```

### Grafana Loki

1. Install Promtail:

```bash
curl -O -L "https://github.com/grafana/loki/releases/latest/download/promtail-linux-amd64.zip"
unzip promtail-linux-amd64.zip
mv promtail-linux-amd64 /usr/local/bin/promtail
```

1. Apply configuration:

```bash
cp promtail-config.yaml /etc/promtail/config.yaml

# Set environment variables
export LOKI_URL=https://loki.example.com
export ENVIRONMENT=production
```

1. Configure Loki retention:

```yaml
# loki-config.yaml
compactor:
  retention_enabled: true
  retention_delete_delay: 2h
  compaction_interval: 10m

limits_config:
  retention_period: 52560h # 6 years
```

## Event Categories

The audit logger uses these categories for compliance mapping:

| Category       | Code   | PCI DSS | SOC 2 | HIPAA         |
| -------------- | ------ | ------- | ----- | ------------- |
| authentication | AUTH   | 10.2.4  | CC6.1 | 164.312(d)    |
| authorization  | AUTHZ  | 10.2.1  | CC6.1 | 164.312(a)(1) |
| data_access    | DATA   | 10.2.1  | CC6.7 | 164.312(b)    |
| configuration  | CONFIG | 10.2.7  | CC7.1 | 164.312(c)(1) |
| system         | SYS    | 10.2.6  | CC7.2 | 164.312(b)    |
| network        | NET    | 10.2.4  | CC6.6 | 164.312(e)    |
| file           | FILE   | 10.2.7  | CC6.1 | 164.312(c)(2) |
| process        | PROC   | 10.2.7  | CC7.2 | 164.312(b)    |
| security       | SEC    | 10.6    | CC7.3 | 164.308(a)(6) |
| compliance     | COMP   | 12.10   | CC4.1 | 164.308(a)(8) |

## Log Format

Audit logs are written in JSON format with these fields:

```json
{
  "@timestamp": "2024-01-15T10:30:45.123Z",
  "event_id": "550e8400-e29b-41d4-a716-446655440000",
  "category": "authentication",
  "category_code": "AUTH",
  "level": "info",
  "message": "Authentication event: login",
  "pid": 1234,
  "hostname": "container-abc123",
  "container_id": "abc123def456",
  "container_name": "myapp",
  "action": "login",
  "user": "admin",
  "result": "success",
  "details": {
    "ip": "10.0.0.1",
    "mfa": true
  }
}
```

## Immutable Storage

For tamper-proof audit logs, deploy one of the provided infrastructure
configurations:

### AWS S3 with Object Lock

Deploy the CloudFormation stack:

```bash
# Deploy with default 6-year HIPAA retention
aws cloudformation create-stack \
  --stack-name audit-logs-production \
  --template-body file://aws-s3-immutable.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=production \
    ParameterKey=RetentionMode,ParameterValue=COMPLIANCE \
    ParameterKey=RetentionDays,ParameterValue=2190 \
  --capabilities CAPABILITY_NAMED_IAM

# Get outputs
aws cloudformation describe-stacks --stack-name audit-logs-production --query 'Stacks[0].Outputs'
```

Features:

- S3 Object Lock in COMPLIANCE mode (cannot be overridden)
- KMS encryption with automatic key rotation
- Lifecycle rules: Standard -> IA (90d) -> Glacier (365d) -> Deep Archive (730d)
- Bucket policy denying deletions and unencrypted uploads
- CloudWatch alarms for unauthorized access

### GCP Cloud Storage with Retention Policy

Deploy with Terraform:

```bash
cd examples/observability/audit-logging

# Initialize and deploy
terraform init
terraform plan \
  -var="project_id=my-gcp-project" \
  -var="environment=production" \
  -var="retention_days=2190" \
  -var="lock_retention=true"

terraform apply
```

Features:

- Locked retention policy (cannot be shortened once enabled)
- Customer-managed KMS encryption with 90-day rotation
- Lifecycle rules: Standard -> Nearline (90d) -> Coldline (365d) -> Archive
  (730d)
- Service accounts for writers and readers with least privilege
- Monitoring alerts for unauthorized access

### Cloudflare R2 with Worker Access Control

Deploy with Terraform:

```bash
export CLOUDFLARE_API_TOKEN="your-api-token"

terraform init
terraform plan \
  -var="account_id=your-account-id" \
  -var="environment=production" \
  -var="retention_days=2190"

terraform apply
```

Features:

- Worker gateway that blocks DELETE and overwrite operations
- Automatic access logging for audit trail
- Health monitoring with scheduled checks
- S3-compatible API for easy integration
- Custom domain support

Upload logs via Worker gateway:

```bash
curl -X PUT "https://audit-log-gateway-production.YOUR_ACCOUNT.workers.dev/audit-logs/$(date +%Y/%m/%d)/event.json" \
  -H "Content-Type: application/json" \
  -d '{"event": "login", "user": "admin"}'
```

### Quick CLI Commands

For simple setups without infrastructure-as-code:

```bash
# AWS S3
aws s3api put-object-lock-configuration \
  --bucket audit-logs-bucket \
  --object-lock-configuration '{
    "ObjectLockEnabled": "Enabled",
    "Rule": {
      "DefaultRetention": {
        "Mode": "COMPLIANCE",
        "Years": 6
      }
    }
  }'

# GCP Cloud Storage
gcloud storage buckets update gs://audit-logs-bucket \
  --retention-period=6y \
  --lock-retention-period
```

### Comparison

| Feature             | AWS S3        | GCP Storage      | Cloudflare R2     |
| ------------------- | ------------- | ---------------- | ----------------- |
| Object Lock         | Native        | Retention policy | Worker-enforced   |
| Encryption          | KMS           | CMEK             | At-rest default   |
| Lifecycle rules     | Yes           | Yes              | Manual            |
| Egress costs        | Yes           | Yes              | No                |
| Global distribution | Multi-region  | Dual-region      | Global by default |
| Compliance certs    | SOC/HIPAA/PCI | SOC/HIPAA/PCI    | SOC 2             |

## Alerting

Configure alerts for high-priority audit events:

### Elasticsearch Watcher

```json
{
  "trigger": {
    "schedule": { "interval": "1m" }
  },
  "input": {
    "search": {
      "request": {
        "indices": ["audit-logs-*"],
        "body": {
          "query": {
            "bool": {
              "must": [
                { "range": { "@timestamp": { "gte": "now-1m" } } },
                { "terms": { "level": ["critical", "error"] } }
              ]
            }
          }
        }
      }
    }
  },
  "condition": {
    "compare": { "ctx.payload.hits.total.value": { "gt": 0 } }
  },
  "actions": {
    "notify": {
      "webhook": {
        "url": "https://alerts.example.com/webhook"
      }
    }
  }
}
```

### Loki Alert Rules

```yaml
groups:
  - name: audit-alerts
    rules:
      - alert: CriticalSecurityEvent
        expr: |
          count_over_time({job="container-audit",level="critical"}[5m]) > 0
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: Critical security event detected
```

## Verification

Verify audit logging is working correctly:

```bash
# Check if audit log file exists and has entries
ls -la /var/log/audit/container-audit.log

# View recent audit events
tail -f /var/log/audit/container-audit.log | jq

# Verify log integrity (if rotation with checksums enabled)
source /opt/container-runtime/audit-logger.sh
audit_verify_integrity

# Test an audit event
audit_log "system" "info" "Test event" '{"test":true}'
```

## Related Documentation

- [Observability Overview](../../docs/observability/README.md)
- [JSON Logging](../../../lib/observability/json-logging.sh)
- [Audit Alerts](../../../lib/observability/audit-alerts.yaml)
- [Production Checklist](../../../docs/compliance/production-checklist.md)
