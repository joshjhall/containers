# GCP Cloud Storage Immutable Configuration for Audit Logs
#
# Description:
#   Terraform configuration for creating GCS bucket with retention policy
#   and bucket lock for tamper-proof audit log storage.
#
# Compliance Coverage:
#   - SOC 2 CC6.1: Logical and physical access controls
#   - ISO 27001 A.12.4.2: Protection of log information
#   - HIPAA 164.312(b): Audit controls with 6-year retention
#   - PCI DSS 10.5: Secure audit trails
#   - FedRAMP AU-9: Protection of audit information
#   - GDPR Art. 5(1)(e): Storage limitation
#
# Usage:
#   terraform init
#   terraform plan -var="project_id=my-project" -var="environment=production"
#   terraform apply

terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

# Variables
variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "region" {
  description = "GCP region for bucket"
  type        = string
  default     = "us-central1"
}

variable "retention_days" {
  description = "Retention period in days (2190 = 6 years for HIPAA)"
  type        = number
  default     = 2190
}

variable "lock_retention" {
  description = "Lock retention policy (cannot be shortened once locked)"
  type        = bool
  default     = true
}

variable "enable_versioning" {
  description = "Enable object versioning"
  type        = bool
  default     = true
}

# Random suffix for globally unique bucket name
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Primary audit log bucket with retention policy
resource "google_storage_bucket" "audit_logs" {
  name          = "${var.project_id}-audit-logs-${var.environment}-${random_id.bucket_suffix.hex}"
  project       = var.project_id
  location      = var.region
  storage_class = "STANDARD"

  # Prevent accidental deletion
  force_destroy = false

  # Enable uniform bucket-level access (recommended)
  uniform_bucket_level_access = true

  # Retention policy - objects cannot be deleted until retention period expires
  retention_policy {
    retention_period = var.retention_days * 86400 # Convert days to seconds
    is_locked        = var.lock_retention
  }

  # Versioning for additional protection
  versioning {
    enabled = var.enable_versioning
  }

  # Encryption with customer-managed key
  encryption {
    default_kms_key_name = google_kms_crypto_key.audit_log_key.id
  }

  # Lifecycle rules for cost optimization
  lifecycle_rule {
    condition {
      age = 90 # days
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  lifecycle_rule {
    condition {
      age = 365 # days
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  lifecycle_rule {
    condition {
      age = 730 # days
    }
    action {
      type          = "SetStorageClass"
      storage_class = "ARCHIVE"
    }
  }

  # Logging configuration
  logging {
    log_bucket        = google_storage_bucket.access_logs.name
    log_object_prefix = "audit-logs/"
  }

  labels = {
    environment        = var.environment
    compliance         = "soc2-hipaa-pci-gdpr"
    data-classification = "sensitive"
    retention-days     = tostring(var.retention_days)
  }
}

# Access log bucket
resource "google_storage_bucket" "access_logs" {
  name          = "${var.project_id}-audit-access-logs-${var.environment}-${random_id.bucket_suffix.hex}"
  project       = var.project_id
  location      = var.region
  storage_class = "STANDARD"

  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    environment = var.environment
    purpose     = "access-logging"
  }
}

# KMS keyring for audit log encryption
resource "google_kms_key_ring" "audit_logs" {
  name     = "audit-logs-${var.environment}"
  project  = var.project_id
  location = var.region
}

# KMS key for audit log encryption
resource "google_kms_crypto_key" "audit_log_key" {
  name            = "audit-log-key"
  key_ring        = google_kms_key_ring.audit_logs.id
  rotation_period = "7776000s" # 90 days

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
  }

  labels = {
    purpose = "audit-log-encryption"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Grant Cloud Storage service account access to KMS key
resource "google_kms_crypto_key_iam_binding" "storage_encrypter" {
  crypto_key_id = google_kms_crypto_key.audit_log_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"

  members = [
    "serviceAccount:service-${data.google_project.project.number}@gs-project-accounts.iam.gserviceaccount.com",
  ]
}

# Get project information
data "google_project" "project" {
  project_id = var.project_id
}

# Service account for writing audit logs
resource "google_service_account" "audit_log_writer" {
  account_id   = "audit-log-writer-${var.environment}"
  display_name = "Audit Log Writer"
  project      = var.project_id
}

# IAM binding for audit log writer
resource "google_storage_bucket_iam_member" "writer" {
  bucket = google_storage_bucket.audit_logs.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.audit_log_writer.email}"
}

# Service account for reading audit logs (compliance team)
resource "google_service_account" "audit_log_reader" {
  account_id   = "audit-log-reader-${var.environment}"
  display_name = "Audit Log Reader"
  project      = var.project_id
}

# IAM binding for audit log reader
resource "google_storage_bucket_iam_member" "reader" {
  bucket = google_storage_bucket.audit_logs.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.audit_log_reader.email}"
}

# Deny public access
resource "google_storage_bucket_iam_member" "deny_public" {
  bucket = google_storage_bucket.audit_logs.name
  role   = "roles/storage.legacyBucketReader"
  member = "allUsers"

  # This will fail if someone tries to add public access
  lifecycle {
    precondition {
      condition     = false
      error_message = "Public access is not allowed on audit log bucket"
    }
  }
}

# Monitoring alert for unauthorized access
resource "google_monitoring_alert_policy" "unauthorized_access" {
  display_name = "Audit Log Unauthorized Access - ${var.environment}"
  project      = var.project_id

  conditions {
    display_name = "Unauthorized access attempts"
    condition_threshold {
      filter          = "resource.type=\"gcs_bucket\" AND resource.labels.bucket_name=\"${google_storage_bucket.audit_logs.name}\" AND protoPayload.status.code>=400"
      duration        = "60s"
      comparison      = "COMPARISON_GT"
      threshold_value = 5

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_COUNT"
      }
    }
  }

  combiner = "OR"

  notification_channels = [google_monitoring_notification_channel.email.name]

  alert_strategy {
    auto_close = "1800s"
  }
}

# Notification channel for alerts
resource "google_monitoring_notification_channel" "email" {
  display_name = "Audit Log Alerts"
  project      = var.project_id
  type         = "email"

  labels = {
    email_address = "security-team@example.com"
  }
}

# Outputs
output "bucket_name" {
  description = "Audit log bucket name"
  value       = google_storage_bucket.audit_logs.name
}

output "bucket_url" {
  description = "Audit log bucket URL"
  value       = google_storage_bucket.audit_logs.url
}

output "kms_key_id" {
  description = "KMS key ID for audit log encryption"
  value       = google_kms_crypto_key.audit_log_key.id
}

output "writer_service_account" {
  description = "Service account email for writing audit logs"
  value       = google_service_account.audit_log_writer.email
}

output "reader_service_account" {
  description = "Service account email for reading audit logs"
  value       = google_service_account.audit_log_reader.email
}

output "retention_policy" {
  description = "Retention policy details"
  value = {
    days      = var.retention_days
    is_locked = var.lock_retention
  }
}
