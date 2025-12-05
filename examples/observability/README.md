# Container Observability

Complete observability stack for monitoring, tracing, and logging container builds and runtime.

## Overview

This observability implementation provides:

- **Metrics**: Prometheus metrics for build and runtime monitoring
- **Logging**: Structured JSON logging with correlation IDs
- **Tracing**: OpenTelemetry distributed tracing
- **Dashboards**: Pre-built Grafana visualizations
- **Alerting**: Prometheus alerts with runbooks
- **Full Stack**: Ready-to-use Docker Compose deployment

## Quick Start

### 1. Start the Observability Stack

```bash
# From repository root
docker-compose -f examples/observability/docker-compose.yml up -d
```

### 2. Access the UIs

- **Grafana**: `http://localhost:3000` (admin/admin)
- **Prometheus**: `http://localhost:9090`
- **Jaeger**: `http://localhost:16686`

### 3. Enable Observability in Your Container

```bash
# Build with observability enabled
docker build \
  --build-arg PROJECT_NAME=myproject \
  --build-arg INCLUDE_PYTHON_DEV=true \
  -t myproject:obs \
  .

# Run with observability configured
docker run -d \
  -e METRICS_ENABLED=true \
  -e METRICS_PORT=9090 \
  -e ENABLE_JSON_LOGGING=true \
  -e OTEL_ENABLED=true \
  -e OTEL_SERVICE_NAME=myproject \
  -e OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \
  --name myproject \
  myproject:obs
```

### 4. View Metrics and Traces

1. **Grafana Dashboards**:

   - Navigate to Dashboards → Container Build Overview
   - Navigate to Dashboards → Container Runtime Health

1. **Prometheus Metrics**:

   - Visit `http://localhost:9090`
   - Query: `container_build_duration_seconds`

1. **Jaeger Traces**:

   - Visit `http://localhost:16686`
   - Search for service: `myproject`

## Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                       Container                             │
│                                                             │
│  ┌─────────────────┐    ┌──────────────────┐              │
│  │ Build Process   │───▶│ JSON Logs        │──────┐       │
│  │ (Features)      │    │ (/var/log/...)   │      │       │
│  └─────────────────┘    └──────────────────┘      │       │
│                                                     │       │
│  ┌─────────────────┐    ┌──────────────────┐      │       │
│  │ Metrics         │───▶│ Prometheus       │      │       │
│  │ Exporter :9090  │    │ Endpoint         │      │       │
│  └─────────────────┘    └──────────────────┘      │       │
│                                │                   │       │
│  ┌─────────────────┐           │                   │       │
│  │ OpenTelemetry   │───────────┼───────────────────┘       │
│  │ Traces          │           │                           │
│  └─────────────────┘           │                           │
└─────────────────────────────────┼───────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────┐
│                    Observability Stack                      │
│                                                             │
│  ┌────────────┐   ┌───────────┐   ┌──────────────┐        │
│  │Prometheus  │──▶│  Grafana  │◀──│    Jaeger    │        │
│  │  :9090     │   │   :3000   │   │    :16686    │        │
│  └────────────┘   └───────────┘   └──────────────┘        │
│       │                                    │                │
│       │           ┌──────────────┐         │                │
│       └──────────▶│ OTel         │◀────────┘                │
│                   │ Collector    │                          │
│                   │ :4318        │                          │
│                   └──────────────┘                          │
└─────────────────────────────────────────────────────────────┘
```

## Components

### Metrics Exporter

**Location**: `lib/runtime/metrics-exporter.sh`

Exposes Prometheus metrics on port 9090:

```bash
# Start metrics server
metrics-exporter.sh --server --port 9090

# Write to file
metrics-exporter.sh --file /var/metrics/prometheus.txt

# Print to stdout
metrics-exporter.sh
```

**Metrics Exposed**:

- `container_build_duration_seconds` - Build time per feature
- `container_build_errors_total` - Build errors per feature
- `container_healthcheck_status` - Current health (1=healthy, 0=unhealthy)
- `container_uptime_seconds` - Container uptime
- `container_disk_usage_bytes` - Disk usage by path

### JSON Logging

**Location**: `lib/base/json-logging.sh`

Structured logging with correlation IDs:

```bash
# Enable in container
export ENABLE_JSON_LOGGING=true

# Logs written to
/var/log/container-build/json/*.jsonl
```

**Log Format**:

```json
{
  "timestamp": "2025-11-16T20:00:00.123Z",
  "level": "INFO",
  "correlation_id": "build-1731783600-abc123",
  "feature": "python-dev",
  "message": "Installing Python 3.13",
  "metadata": {
    "duration_seconds": 145,
    "status": "success"
  }
}
```

### Grafana Dashboards

**Location**: `examples/observability/grafana/`

Two pre-built dashboards:

1. **Container Build Overview** - Build metrics and status
1. **Container Runtime Health** - Health and resource usage

Import via Grafana UI or provisioning (see `grafana-dashboards.yml`).

### Prometheus Alerts

**Location**: `examples/observability/prometheus/alerts.yml`

12+ alert rules across 4 categories:

- **Build Alerts**: Failed builds, slow builds
- **Runtime Alerts**: Unhealthy containers, restarts
- **Resource Alerts**: Disk usage, cache size
- **Metrics Alerts**: Stale/missing metrics

### Runbooks

**Location**: `docs/observability/runbooks/`

Operational guides for responding to alerts:

- `README.md` - Runbook overview
- `container-unhealthy.md` - Critical health failures
- `build-failed.md` - Build error diagnosis

Each runbook includes:

- Impact assessment
- Diagnosis steps
- Resolution procedures
- Prevention measures
- Escalation criteria

### OpenTelemetry

**Location**: `docs/observability/opentelemetry-integration.md`

Distributed tracing integration:

- Shell script instrumentation
- Span creation and export
- Backend configuration (Jaeger, Tempo, Zipkin)
- Performance tuning

## Configuration

### Environment Variables

**Metrics**:

```bash
METRICS_ENABLED=true                 # Enable metrics exporter
METRICS_PORT=9090                    # Port for Prometheus scraping
METRICS_REFRESH_INTERVAL=15          # Metrics refresh interval (seconds)
```

**Logging**:

```bash
ENABLE_JSON_LOGGING=true             # Enable JSON logging
BUILD_LOG_DIR=/var/log/container-build  # Log directory
```

**Tracing**:

```bash
OTEL_ENABLED=true                    # Enable OpenTelemetry
OTEL_SERVICE_NAME=my-service         # Service name in traces
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318  # OTLP endpoint
OTEL_TRACES_SAMPLER=always_on        # Sampling strategy
```

### Docker Compose

See `docker-compose.yml` for full stack configuration.

### Kubernetes

Example deployment with observability:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myproject
spec:
  template:
    metadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: myproject
          image: myproject:latest
          env:
            - name: METRICS_ENABLED
              value: "true"
            - name: ENABLE_JSON_LOGGING
              value: "true"
            - name: OTEL_ENABLED
              value: "true"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector:4318"
          ports:
            - containerPort: 9090
              name: metrics
```

## Usage Examples

### Example 1: Monitor Build Metrics

```bash
# Build container
docker build -t test:latest .

# Start metrics exporter
docker run -d -p 9091:9090 test:latest

# Query metrics
curl http://localhost:9091/metrics | grep container_build

# Output:
# container_build_duration_seconds{feature="python-dev",status="success"} 145.3
# container_build_errors_total{feature="python-dev"} 0
# container_build_warnings_total{feature="python-dev"} 2
```

### Example 2: Analyze JSON Logs

```bash
# Enable JSON logging
docker run -d \
  -e ENABLE_JSON_LOGGING=true \
  -v $(pwd)/logs:/var/log/container-build \
  test:latest

# Query logs with jq
cat logs/json/build-summary.jsonl | jq -r 'select(.errors > 0)'

# Output:
# {
#   "timestamp": "2025-11-16T20:00:00Z",
#   "feature": "rust-dev",
#   "errors": 1,
#   "status": "failed"
# }
```

### Example 3: Distributed Tracing

```bash
# Start observability stack
docker-compose up -d

# Run container with tracing
docker run -d \
  -e OTEL_ENABLED=true \
  -e OTEL_SERVICE_NAME=test \
  -e OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \
  --network observability_default \
  test:latest

# View traces in Jaeger
# http://localhost:16686 → Search for service "test"
```

## Troubleshooting

### No Metrics in Prometheus

1. Check metrics endpoint:

   ```bash
   docker exec <container> curl http://localhost:9090/metrics
   ```

1. Verify Prometheus scraping:

   ```bash
   # Check targets
   curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets'
   ```

1. Check container logs:

   ```bash
   docker logs <container> | grep -i metric
   ```

### Dashboards Show No Data

1. Verify Prometheus datasource in Grafana:

   - Settings → Data Sources → Prometheus
   - Click "Test" button

1. Check metrics are being scraped:

   - Prometheus UI → Status → Targets

1. Verify time range in Grafana matches data availability

### Traces Not Appearing in Jaeger

1. Check OTel Collector:

   ```bash
   docker logs otel-collector | grep -i error
   ```

1. Verify OTLP endpoint is reachable:

   ```bash
   curl http://localhost:4318/v1/traces
   # Should return "method not allowed" (endpoint exists)
   ```

1. Check trace export from container:

   ```bash
   docker logs <container> | grep -i otel
   ```

## Performance Considerations

- **Metrics**: Minimal overhead (~1% CPU, 10MB RAM)
- **JSON Logging**: ~5% overhead for dual logging (text + JSON)
- **Tracing**: ~2-5% overhead depending on sampling rate

**Optimization**:

- Reduce sampling in production: `OTEL_TRACES_SAMPLER_ARG=0.1` (10%)
- Increase metrics interval: `METRICS_REFRESH_INTERVAL=60`
- Disable JSON logging if not needed: `ENABLE_JSON_LOGGING=false`

## Production Deployment

### Checklist

- [ ] Configure Prometheus retention (default: 15 days)
- [ ] Set up Alertmanager for notifications
- [ ] Configure Grafana authentication (LDAP/OAuth)
- [ ] Enable TLS for all endpoints
- [ ] Set appropriate sampling rates for tracing
- [ ] Configure log rotation and retention
- [ ] Test alert firing and runbook procedures
- [ ] Set up backup for Grafana dashboards

### High Availability

For production, deploy with redundancy:

- **Prometheus**: Use Thanos or Cortex for HA
- **Grafana**: Deploy multiple replicas behind load balancer
- **Jaeger**: Use Cassandra or Elasticsearch backend
- **OTel Collector**: Deploy collector per node/zone

## Additional Resources

- [Design Document](../../docs/observability-design.md)
- [OpenTelemetry Integration](../../docs/observability/opentelemetry-integration.md)
- [Alert Runbooks](../../docs/observability/runbooks/)
- [Grafana Dashboard Guide](./grafana/README.md)
- [Prometheus Alerts](./prometheus/alerts.yml)

## Support

For issues or questions:

1. Check [Troubleshooting Guide](../../docs/troubleshooting.md)
1. Review [Alert Runbooks](../../docs/observability/runbooks/)
1. Open an issue in the repository
