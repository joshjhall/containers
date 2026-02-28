# Observability Design

> **Status**: Partially implemented. Core components (JSON logging, metrics
> exporter, dashboards, alerting) exist. OpenTelemetry integration remains a
> design proposal.

## Overview

This document outlines the observability architecture for the container build system,
providing metrics, structured logging, and monitoring capabilities for production deployments.

## Goals

1. **Metrics**: Expose Prometheus-compatible metrics for monitoring container health and
   performance
1. **Structured Logging**: Provide JSON-formatted logs with correlation IDs for log
   aggregation
1. **Tracing**: Enable OpenTelemetry integration for distributed tracing
1. **Dashboards**: Pre-built Grafana dashboards for common monitoring scenarios
1. **Alerting**: Prometheus alerting rules for common issues
1. **Runbooks**: Documentation for responding to alerts

## Architecture

### Components

```text
┌─────────────────────────────────────────────────────────────┐
│                       Container                             │
│                                                             │
│  ┌─────────────────┐    ┌──────────────────┐              │
│  │ Application     │───▶│ Structured       │              │
│  │ Code            │    │ Logging          │              │
│  └─────────────────┘    │ (JSON + Text)    │              │
│                         └──────────────────┘              │
│                                │                           │
│  ┌─────────────────┐           ▼                           │
│  │ Metrics         │    ┌──────────────────┐              │
│  │ Exporter        │───▶│ Log Files        │              │
│  │ (Port 9090)     │    │ /var/log/        │              │
│  └─────────────────┘    └──────────────────┘              │
│         │                                                   │
│         │               ┌──────────────────┐              │
│         │               │ Healthcheck      │              │
│         │               │ (Existing)       │              │
│         │               └──────────────────┘              │
└─────────│───────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────┐
│                    Monitoring Stack                         │
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐   │
│  │ Prometheus  │───▶│  Grafana    │    │ OpenTelemetry│   │
│  │ (Scraper)   │    │ (Dashboards)│    │  Collector   │   │
│  └─────────────┘    └─────────────┘    └─────────────┘   │
│         │                                       │          │
│         ▼                                       ▼          │
│  ┌─────────────┐                        ┌─────────────┐   │
│  │ Alertmanager│                        │ OTLP Backend│   │
│  └─────────────┘                        │ (Jaeger,etc)│   │
│                                         └─────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Detailed Design

### 1. Structured Logging

**Enhancement to `lib/base/logging.sh`**

Add JSON logging capability while maintaining backward compatibility with existing text logs.

#### Features

- **Dual Output**: Text logs (existing) + JSON logs (new)
- **Correlation IDs**: Track related log entries across build process
- **Structured Fields**: Consistent field names for parsing
- **Log Levels**: DEBUG, INFO, WARN, ERROR, FATAL
- **Context**: Feature name, version, build stage, duration

#### JSON Log Format

```json
{
  "timestamp": "2025-11-16T19:30:45.123Z",
  "level": "INFO",
  "correlation_id": "build-abc123-xyz789",
  "feature": "python-dev",
  "version": "3.13.1",
  "stage": "install",
  "message": "Installing Python dependencies",
  "duration_ms": 1234,
  "command_count": 5,
  "error_count": 0,
  "warning_count": 2,
  "metadata": {
    "platform": "debian:trixie",
    "build_arg_include_python_dev": "true"
  }
}
```

#### Implementation Strategy

1. Add `log_json()` function to logging.sh
1. Environment variable `ENABLE_JSON_LOGGING=true` to opt-in
1. JSON logs written to `/var/log/container-build/json/`
1. Maintain all existing text logging functions
1. Add correlation ID tracking through build process

### 2. Metrics Exporter

**New Runtime Script: `lib/runtime/metrics-exporter.sh`**

Expose Prometheus-compatible metrics on port 9090 (configurable).

#### Metrics Categories

**Build Metrics** (from build logs):

```text
# HELP container_build_duration_seconds Time taken to build container features
# TYPE container_build_duration_seconds gauge
container_build_duration_seconds{feature="python-dev",status="success"} 145.3

# HELP container_build_errors_total Total errors during container build
# TYPE container_build_errors_total counter
container_build_errors_total{feature="python-dev"} 0

# HELP container_build_warnings_total Total warnings during container build
# TYPE container_build_warnings_total counter
container_build_warnings_total{feature="python-dev"} 2

# HELP container_features_installed Total number of features installed
# TYPE container_features_installed gauge
container_features_installed 8
```

**Runtime Metrics**:

```text
# HELP container_uptime_seconds Container uptime in seconds
# TYPE container_uptime_seconds gauge
container_uptime_seconds 3600

# HELP container_healthcheck_status Current health status (1=healthy, 0=unhealthy)
# TYPE container_healthcheck_status gauge
container_healthcheck_status 1

# HELP container_healthcheck_duration_seconds Time taken for last healthcheck
# TYPE container_healthcheck_duration_seconds gauge
container_healthcheck_duration_seconds 0.234
```

**Resource Metrics** (if available):

```text
# HELP container_disk_usage_bytes Disk space used by container directories
# TYPE container_disk_usage_bytes gauge
container_disk_usage_bytes{path="/cache"} 1234567890
container_disk_usage_bytes{path="/workspace"} 9876543210
```

#### Implementation

- Lightweight HTTP server (using `nc` or `socat` if available, fallback to file)
- Metrics collected from:
  - Build log summaries (`/var/log/container-build/master-summary.log`)
  - Healthcheck results
  - System information (`df`, `uptime`, etc.)
- Runs as background process or on-demand via endpoint

### 3. Grafana Dashboards

**Location: `examples/observability/grafana/`**

Pre-built dashboard templates for common scenarios.

#### Dashboards

1. **Container Build Overview**

   - Build durations by feature
   - Error/warning trends
   - Feature installation status
   - Build success rate

1. **Container Runtime Health**

   - Uptime
   - Healthcheck status over time
   - Resource usage (disk, if available)
   - Container restart count

1. **Multi-Container Fleet**

   - Aggregate metrics across multiple containers
   - Feature distribution
   - Health status by container
   - Error hotspots

### 4. Alerting Rules

**Location: `examples/observability/prometheus/`**

Prometheus alerting rules for common issues.

#### Example Alerts

```yaml
groups:
  - name: container_build
    interval: 30s
    rules:
      - alert: ContainerBuildFailed
        expr: container_build_errors_total > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Container build has errors"
          description: "{{ $labels.feature }} has {{ $value }} errors"

      - alert: ContainerUnhealthy
        expr: container_healthcheck_status == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Container is unhealthy"
          description: "Container healthcheck failing"

      - alert: ContainerBuildSlow
        expr: container_build_duration_seconds > 600
        for: 1m
        labels:
          severity: info
        annotations:
          summary: "Container build is slow"
          description: "{{ $labels.feature }} took {{ $value }}s to build"
```

### 5. Runbooks

**Location: `docs/observability/runbooks/`**

Detailed runbooks for responding to alerts.

#### Runbook Structure

Each runbook includes:

- **Alert Name**: Clear identification
- **Severity**: Critical, Warning, Info
- **Description**: What the alert means
- **Impact**: User/system impact
- **Diagnosis**: How to investigate
- **Resolution**: Steps to fix
- **Prevention**: How to prevent recurrence

### 6. OpenTelemetry Integration

**Location: `docs/observability/opentelemetry-integration.md`**

Guide for integrating OpenTelemetry for distributed tracing.

**Features:**

- OTLP exporter configuration
- Trace context propagation
- Span creation for build stages
- Integration with Jaeger, Zipkin, or other backends
- Environment variable configuration

## Implementation Phases

### Phase 1: Core Metrics — DONE

1. ✅ Design document (this file)
1. ✅ Metrics exporter script (`lib/runtime/metrics-exporter.sh`)
1. ✅ Basic Prometheus metrics
1. ✅ Metrics endpoint at runtime

### Phase 2: Structured Logging — DONE

1. ✅ JSON logging support (`lib/base/json-logging.sh`)
1. ✅ Correlation ID tracking
1. ✅ Log aggregation examples

### Phase 3: Dashboards & Alerts — DONE

1. ✅ Grafana dashboard templates (`examples/observability/`)
1. ✅ Prometheus alerting rules
1. ✅ Runbooks for each alert

### Phase 4: OpenTelemetry — NOT STARTED

1. Write OpenTelemetry integration guide
1. Create OTLP exporter examples
1. Document trace context propagation
1. Provide example configurations

### Phase 5: Testing & Documentation — NOT STARTED

1. Add unit tests for metrics exporter
1. Add integration tests for monitoring stack
1. Update main documentation
1. Create quickstart guide

## Configuration

### Environment Variables

```bash
# Enable JSON logging (default: false)
ENABLE_JSON_LOGGING=true

# Metrics exporter configuration
METRICS_ENABLED=true
METRICS_PORT=9090
METRICS_REFRESH_INTERVAL=15

# OpenTelemetry configuration
OTEL_ENABLED=true
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
OTEL_SERVICE_NAME=container-build
```

### Build Arguments

```dockerfile
# Enable metrics at build time (collect build metrics)
ARG ENABLE_BUILD_METRICS=true

# Enable observability features
ARG INCLUDE_OBSERVABILITY=false
```

## Integration Points

### Existing Systems

1. **Logging System** (`lib/base/logging.sh`)

   - Extend with JSON output
   - Add correlation ID support
   - Maintain backward compatibility

1. **Healthcheck** (`lib/runtime/healthcheck`)

   - Export health status as metric
   - Add health history tracking

1. **Build System** (Dockerfile)

   - Collect build metrics during feature installation
   - Store metrics for later export

### New Systems

1. **Metrics Exporter** (new)

   - Runtime script for metric collection
   - HTTP endpoint for Prometheus

1. **Log Aggregation** (external)

   - Fluentd/Fluent Bit configuration
   - Loki configuration
   - Elasticsearch configuration

## Security Considerations

1. **Metrics Endpoint**

   - No authentication by default (internal network only)
   - Optional basic auth configuration
   - Network policy restrictions (Kubernetes)

1. **Log Data**

   - No secrets in logs (already enforced)
   - Structured logging makes redaction easier
   - Correlation IDs don't leak sensitive data

1. **Resource Usage**

   - Metrics collection is lightweight
   - JSON logging has minimal overhead
   - Configurable refresh intervals

## Testing Strategy

1. **Unit Tests**

   - Test JSON log formatting
   - Test metrics calculation
   - Test correlation ID generation

1. **Integration Tests**

   - Test with Prometheus scraper
   - Test with Grafana
   - Test log aggregation
   - Test alert firing

1. **Performance Tests**

   - Measure logging overhead
   - Measure metrics collection overhead
   - Ensure minimal impact on build time

## Documentation Deliverables

1. ✅ This design document
1. ⬜ Observability quickstart guide
1. ⬜ OpenTelemetry integration guide
1. ⬜ Metrics reference documentation
1. ⬜ Structured logging reference
1. ⬜ Grafana dashboard guide
1. ✅ Alerting runbooks (per-alert)

## Success Criteria

- ✅ Prometheus can scrape metrics from container
- ✅ Grafana can display build and runtime metrics
- ✅ JSON logs can be aggregated and searched
- ✅ Alerts fire correctly for common issues
- ✅ Runbooks are clear and actionable
- ⬜ OpenTelemetry integration is documented
- ✅ Zero impact on existing text logging
- ⬜ Minimal performance overhead (\<5% build time increase) — not yet verified

## Future Enhancements

1. **Advanced Metrics**

   - Cache hit rates
   - Network usage during build
   - CPU/memory usage per feature

1. **Anomaly Detection**

   - ML-based anomaly detection
   - Automatic performance regression detection

1. **Cost Tracking**

   - Track build costs (time = money)
   - Resource utilization optimization

1. **Service Mesh Integration**

   - Istio/Linkerd metrics
   - Automatic trace propagation

## References

- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Dashboards](https://grafana.com/docs/grafana/latest/dashboards/)
- [OpenTelemetry Specification](https://opentelemetry.io/docs/)
- [Prometheus Alerting Rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
