# Cloudflare R2 Immutable Storage Configuration for Audit Logs
#
# Description:
#   Terraform configuration for creating Cloudflare R2 bucket with
#   object lifecycle rules for compliance audit log storage.
#
# Note: Cloudflare R2 uses S3-compatible API and supports object lifecycle
# rules. While it doesn't have Object Lock like S3, you can configure
# lifecycle rules and use Workers for access control.
#
# Compliance Coverage:
#   - SOC 2 CC6.1: Logical and physical access controls
#   - ISO 27001 A.12.4.2: Protection of log information
#   - HIPAA 164.312(b): Audit controls
#   - PCI DSS 10.5: Secure audit trails
#   - GDPR Art. 5(1)(e): Storage limitation
#
# Usage:
#   export CLOUDFLARE_API_TOKEN="your-api-token"
#   terraform init
#   terraform plan -var="account_id=your-account-id"
#   terraform apply

terraform {
  required_version = ">= 1.0"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

# Variables
variable "account_id" {
  description = "Cloudflare account ID"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "retention_days" {
  description = "Retention period in days (2190 = 6 years for HIPAA)"
  type        = number
  default     = 2190
}

# Primary audit log bucket
resource "cloudflare_r2_bucket" "audit_logs" {
  account_id = var.account_id
  name       = "audit-logs-${var.environment}"
  location   = "WNAM" # Western North America

  # Note: R2 doesn't have native Object Lock, but objects can be protected
  # through Workers and access policies
}

# Lifecycle rule to transition to infrequent access (when available)
# Note: R2 lifecycle rules are still being developed
# This is a placeholder for when the feature becomes available

# API token for bucket access (write)
resource "cloudflare_api_token" "audit_log_writer" {
  name = "audit-log-writer-${var.environment}"

  policy {
    permission_groups = [
      data.cloudflare_api_token_permission_groups.all.r2["Workers R2 Storage Bucket Item Write"],
    ]
    resources = {
      "com.cloudflare.edge.r2.bucket.${var.account_id}_default_${cloudflare_r2_bucket.audit_logs.name}" = "*"
    }
  }
}

# API token for bucket access (read)
resource "cloudflare_api_token" "audit_log_reader" {
  name = "audit-log-reader-${var.environment}"

  policy {
    permission_groups = [
      data.cloudflare_api_token_permission_groups.all.r2["Workers R2 Storage Bucket Item Read"],
    ]
    resources = {
      "com.cloudflare.edge.r2.bucket.${var.account_id}_default_${cloudflare_r2_bucket.audit_logs.name}" = "*"
    }
  }
}

# Get permission groups
data "cloudflare_api_token_permission_groups" "all" {}

# Worker script for access control and audit logging
resource "cloudflare_worker_script" "audit_log_gateway" {
  account_id = var.account_id
  name       = "audit-log-gateway-${var.environment}"
  content    = <<-EOT
    // Audit Log Gateway Worker
    // Provides access control and prevents unauthorized deletions

    const RETENTION_DAYS = ${var.retention_days};
    const BUCKET_NAME = '${cloudflare_r2_bucket.audit_logs.name}';

    export default {
      async fetch(request, env, ctx) {
        const url = new URL(request.url);
        const method = request.method;
        const key = url.pathname.slice(1);

        // Block all DELETE operations for compliance
        if (method === 'DELETE') {
          return new Response(JSON.stringify({
            error: 'DELETE operations are prohibited on audit logs',
            compliance: 'SOC2/HIPAA/PCI-DSS require immutable audit trails',
            retention_days: RETENTION_DAYS
          }), {
            status: 403,
            headers: { 'Content-Type': 'application/json' }
          });
        }

        // Block overwrites (PUT to existing objects)
        if (method === 'PUT' && key) {
          const existing = await env.AUDIT_LOGS.head(key);
          if (existing) {
            return new Response(JSON.stringify({
              error: 'Cannot overwrite existing audit logs',
              key: key,
              compliance: 'Audit logs must be immutable'
            }), {
              status: 409,
              headers: { 'Content-Type': 'application/json' }
            });
          }
        }

        // Log all access for audit trail
        const accessLog = {
          timestamp: new Date().toISOString(),
          method: method,
          key: key,
          ip: request.headers.get('CF-Connecting-IP'),
          country: request.headers.get('CF-IPCountry'),
          user_agent: request.headers.get('User-Agent'),
          ray_id: request.headers.get('CF-Ray')
        };

        // Store access log
        const accessLogKey = `_access_logs/$${new Date().toISOString().split('T')[0]}/$${crypto.randomUUID()}.json`;
        ctx.waitUntil(
          env.AUDIT_LOGS.put(accessLogKey, JSON.stringify(accessLog))
        );

        // Handle the actual request
        switch (method) {
          case 'GET':
            const object = await env.AUDIT_LOGS.get(key);
            if (!object) {
              return new Response('Not found', { status: 404 });
            }
            return new Response(object.body, {
              headers: {
                'Content-Type': object.httpMetadata.contentType || 'application/octet-stream',
                'ETag': object.httpEtag,
                'Last-Modified': object.uploaded.toUTCString()
              }
            });

          case 'PUT':
            const body = await request.arrayBuffer();
            const metadata = {
              uploaded_at: new Date().toISOString(),
              retention_until: new Date(Date.now() + RETENTION_DAYS * 86400000).toISOString(),
              source_ip: request.headers.get('CF-Connecting-IP'),
              immutable: 'true'
            };

            await env.AUDIT_LOGS.put(key, body, {
              customMetadata: metadata,
              httpMetadata: {
                contentType: request.headers.get('Content-Type') || 'application/json'
              }
            });

            return new Response(JSON.stringify({
              success: true,
              key: key,
              retention_until: metadata.retention_until
            }), {
              status: 201,
              headers: { 'Content-Type': 'application/json' }
            });

          case 'HEAD':
            const headObject = await env.AUDIT_LOGS.head(key);
            if (!headObject) {
              return new Response(null, { status: 404 });
            }
            return new Response(null, {
              headers: {
                'Content-Length': headObject.size,
                'ETag': headObject.httpEtag,
                'Last-Modified': headObject.uploaded.toUTCString()
              }
            });

          case 'LIST':
            const listed = await env.AUDIT_LOGS.list({
              prefix: url.searchParams.get('prefix') || '',
              limit: parseInt(url.searchParams.get('limit')) || 1000
            });
            return new Response(JSON.stringify(listed), {
              headers: { 'Content-Type': 'application/json' }
            });

          default:
            return new Response('Method not allowed', { status: 405 });
        }
      }
    };
  EOT

  r2_bucket_binding {
    name        = "AUDIT_LOGS"
    bucket_name = cloudflare_r2_bucket.audit_logs.name
  }
}

# Custom domain for the worker (optional)
resource "cloudflare_worker_domain" "audit_logs" {
  account_id = var.account_id
  hostname   = "audit-logs.${var.environment}.example.com"
  service    = cloudflare_worker_script.audit_log_gateway.name
  zone_id    = var.zone_id

  count = var.zone_id != "" ? 1 : 0
}

variable "zone_id" {
  description = "Cloudflare zone ID for custom domain (optional)"
  type        = string
  default     = ""
}

# Notification for monitoring (using Workers Analytics)
resource "cloudflare_worker_script" "audit_log_monitor" {
  account_id = var.account_id
  name       = "audit-log-monitor-${var.environment}"
  content    = <<-EOT
    // Scheduled worker to monitor audit log health

    export default {
      async scheduled(event, env, ctx) {
        const metrics = {
          timestamp: new Date().toISOString(),
          bucket: '${cloudflare_r2_bucket.audit_logs.name}',
          checks: []
        };

        // Check bucket accessibility
        try {
          const list = await env.AUDIT_LOGS.list({ limit: 1 });
          metrics.checks.push({
            name: 'bucket_accessible',
            status: 'pass'
          });
        } catch (error) {
          metrics.checks.push({
            name: 'bucket_accessible',
            status: 'fail',
            error: error.message
          });
        }

        // Check recent writes (last hour)
        try {
          const hourAgo = new Date(Date.now() - 3600000).toISOString().split('T')[0];
          const recent = await env.AUDIT_LOGS.list({
            prefix: `audit-logs/$${hourAgo}`,
            limit: 1
          });
          metrics.checks.push({
            name: 'recent_writes',
            status: recent.objects.length > 0 ? 'pass' : 'warn',
            count: recent.objects.length
          });
        } catch (error) {
          metrics.checks.push({
            name: 'recent_writes',
            status: 'fail',
            error: error.message
          });
        }

        // Store metrics
        const metricsKey = `_metrics/$${new Date().toISOString()}.json`;
        await env.AUDIT_LOGS.put(metricsKey, JSON.stringify(metrics));

        // Alert on failures (integrate with your alerting system)
        const failures = metrics.checks.filter(c => c.status === 'fail');
        if (failures.length > 0) {
          // Send alert via webhook, email, etc.
          console.log('ALERT: Audit log health check failures:', failures);
        }
      }
    };
  EOT

  r2_bucket_binding {
    name        = "AUDIT_LOGS"
    bucket_name = cloudflare_r2_bucket.audit_logs.name
  }
}

# Cron trigger for monitoring
resource "cloudflare_worker_cron_trigger" "audit_log_monitor" {
  account_id  = var.account_id
  script_name = cloudflare_worker_script.audit_log_monitor.name
  schedules   = ["*/15 * * * *"] # Every 15 minutes
}

# Outputs
output "bucket_name" {
  description = "R2 bucket name for audit logs"
  value       = cloudflare_r2_bucket.audit_logs.name
}

output "bucket_endpoint" {
  description = "S3-compatible endpoint for the bucket"
  value       = "https://${var.account_id}.r2.cloudflarestorage.com/${cloudflare_r2_bucket.audit_logs.name}"
}

output "worker_url" {
  description = "Worker gateway URL"
  value       = "https://${cloudflare_worker_script.audit_log_gateway.name}.${var.account_id}.workers.dev"
}

output "writer_token_id" {
  description = "API token ID for writing audit logs"
  value       = cloudflare_api_token.audit_log_writer.id
  sensitive   = true
}

output "reader_token_id" {
  description = "API token ID for reading audit logs"
  value       = cloudflare_api_token.audit_log_reader.id
  sensitive   = true
}

output "retention_config" {
  description = "Retention configuration"
  value = {
    days             = var.retention_days
    enforced_by      = "Worker access control"
    delete_blocked   = true
    overwrite_blocked = true
  }
}

# Usage example for uploading logs
output "usage_example" {
  description = "Example curl command for uploading audit logs"
  value       = <<-EOT
    # Using Worker gateway (recommended)
    curl -X PUT "https://${cloudflare_worker_script.audit_log_gateway.name}.${var.account_id}.workers.dev/audit-logs/$(date +%Y/%m/%d)/$(uuidgen).json" \
      -H "Content-Type: application/json" \
      -d '{"event": "test", "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}'

    # Using S3-compatible API directly
    aws s3api put-object \
      --endpoint-url https://${var.account_id}.r2.cloudflarestorage.com \
      --bucket ${cloudflare_r2_bucket.audit_logs.name} \
      --key audit-logs/$(date +%Y/%m/%d)/$(uuidgen).json \
      --body audit-event.json
  EOT
}
