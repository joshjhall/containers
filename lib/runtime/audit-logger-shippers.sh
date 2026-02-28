#!/usr/bin/env bash
# Audit Logger - Log Shipping Support
#
# Provides configuration generators for log shipping backends.
# Part of the audit logging system (see audit-logger.sh).
#
# Usage:
#   source /opt/container-runtime/audit-logger.sh  # Sources this automatically
#   get_fluentd_config > /etc/fluentd/conf.d/audit.conf

# Prevent multiple sourcing
if [ -n "${_AUDIT_LOGGER_SHIPPERS_LOADED:-}" ]; then
    return 0
fi
_AUDIT_LOGGER_SHIPPERS_LOADED=1

# ============================================================================
# Log Shipping Support
# ============================================================================

# Get log shipper configuration for different backends
get_fluentd_config() {
    cat << 'EOF'
<source>
  @type tail
  path /var/log/audit/container-audit.log
  pos_file /var/log/audit/container-audit.log.pos
  tag container.audit
  <parse>
    @type json
    time_key @timestamp
    time_format %Y-%m-%dT%H:%M:%S.%NZ
  </parse>
</source>

<match container.audit>
  @type forward
  <server>
    host ${FLUENTD_HOST}
    port ${FLUENTD_PORT}
  </server>
  <buffer>
    @type file
    path /var/log/fluentd-buffer
    flush_interval 5s
  </buffer>
</match>
EOF
}

# Get CloudWatch Logs agent configuration
get_cloudwatch_config() {
    cat << 'EOF'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/audit/container-audit.log",
            "log_group_name": "${CLOUDWATCH_LOG_GROUP}",
            "log_stream_name": "${CLOUDWATCH_LOG_STREAM}",
            "timestamp_format": "%Y-%m-%dT%H:%M:%S.%fZ",
            "multi_line_start_pattern": "^{"
          }
        ]
      }
    }
  }
}
EOF
}

# Get Grafana Loki configuration (Promtail)
get_loki_config() {
    cat << 'EOF'
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: ${LOKI_URL}/loki/api/v1/push

scrape_configs:
  - job_name: container_audit
    static_configs:
      - targets:
          - localhost
        labels:
          job: container-audit
          __path__: /var/log/audit/container-audit.log
    pipeline_stages:
      - json:
          expressions:
            level: level
            category: category
            event_id: event_id
      - labels:
          level:
          category:
EOF
}
