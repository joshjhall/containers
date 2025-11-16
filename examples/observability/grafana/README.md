# Grafana Dashboards

Pre-built Grafana dashboards for monitoring container build and runtime metrics.

## Available Dashboards

### 1. Container Build Overview

**File**: `container-build-overview.json`

Visualizes build-time metrics collected during feature installations.

**Panels**:

- **Features Installed**: Total number of features successfully installed
- **Total Build Errors**: Aggregate error count across all features
- **Total Build Warnings**: Aggregate warning count across all features
- **Build Status by Feature**: Table showing each feature's build status and duration
- **Build Duration by Feature**: Bar chart of build times
- **Errors and Warnings by Feature**: Time series of errors/warnings per feature

**Use Cases**:

- Identify slow-building features
- Track build error trends over time
- Monitor build quality (warnings/errors)
- Compare build performance across container rebuilds

### 2. Container Runtime Health

**File**: `container-runtime-health.json`

Monitors container health and resource usage in real-time.

**Panels**:

- **Health Status**: Current container health (Healthy/Unhealthy)
- **Container Uptime**: Time since container start
- **Health Status Over Time**: Health trend visualization
- **Healthcheck Duration**: Time taken for health checks
- **Disk Usage by Path**: Disk space used by key directories (cache, workspace, logs)

**Use Cases**:

- Monitor container health in production
- Detect container restarts (uptime drops)
- Track resource usage trends
- Alert on unhealthy containers

## Installation

### Import into Grafana

1. **Via UI**:

   ```text
   Grafana → Dashboards → New → Import → Upload JSON file
   ```

2. **Via API**:

   ```bash
   curl -X POST http://grafana:3000/api/dashboards/db \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer $GRAFANA_API_KEY" \
     -d @container-build-overview.json
   ```

3. **Via Provisioning** (Recommended for automation):

   Create `grafana-provisioning.yaml`:

   ```yaml
   apiVersion: 1
   providers:
     - name: Container Observability
       orgId: 1
       folder: Containers
       type: file
       disableDeletion: false
       updateIntervalSeconds: 10
       options:
         path: /etc/grafana/provisioning/dashboards
   ```

   Mount dashboard files to `/etc/grafana/provisioning/dashboards/`:

   ```yaml
   volumes:
     - ./examples/observability/grafana:/etc/grafana/provisioning/dashboards:ro
   ```

## Prerequisites

### 1. Prometheus Data Source

Dashboards require a Prometheus data source configured in Grafana:

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
```

### 2. Metrics Exporter Running

Ensure the container is exposing metrics:

```bash
# Start metrics exporter in container
metrics-exporter.sh --server --port 9090

# Or as file-based (for node exporter to collect)
metrics-exporter.sh --file /var/metrics/prometheus.txt
```

### 3. Prometheus Scraping

Configure Prometheus to scrape container metrics:

```yaml
scrape_configs:
  - job_name: "containers"
    static_configs:
      - targets: ["container:9090"]
        labels:
          environment: "production"
          project: "myproject"
```

## Customization

### Variables

Both dashboards support the `$datasource` variable for multi-datasource setups.

### Refresh Interval

Default: 30 seconds. Change via dashboard settings or URL parameter:

```text
http://grafana:3000/d/container-build-overview?refresh=10s
```

### Time Range

- **Build Overview**: Default 6 hours (build metrics are mostly static)
- **Runtime Health**: Default 1 hour (runtime metrics change frequently)

### Thresholds

Modify panel thresholds to match your SLOs:

```json
{
  "thresholds": {
    "mode": "absolute",
    "steps": [
      { "color": "green", "value": null },
      { "color": "yellow", "value": 5 },
      { "color": "red", "value": 10 }
    ]
  }
}
```

## Kubernetes Integration

### ServiceMonitor (Prometheus Operator)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: container-metrics
spec:
  selector:
    matchLabels:
      app: devcontainer
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
```

### Pod Annotations

Dashboards work with Prometheus annotation-based discovery:

```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9090"
    prometheus.io/path: "/metrics"
```

## Troubleshooting

### No Data in Dashboards

1. **Check Prometheus target**:

   ```text
   Prometheus → Status → Targets
   Verify container target is UP
   ```

2. **Verify metrics exporter**:

   ```bash
   # Inside container
   curl http://localhost:9090/metrics

   # Should return Prometheus-format metrics
   ```

3. **Check Grafana datasource**:

   ```text
   Grafana → Configuration → Data Sources → Prometheus
   Test connection should succeed
   ```

### Missing Metrics

- **Build metrics**: Only appear after features are installed (requires build logs)
- **Runtime metrics**: Require healthcheck and metrics exporter to be running
- **Disk metrics**: Require `df` and `du` commands available

### Dashboard Errors

**"No data" panels**:

- Verify metric names match those in `metrics-exporter.sh`
- Check Prometheus scrape interval matches dashboard refresh rate

**"Template variable error"**:

- Ensure Prometheus datasource is named correctly
- Or edit dashboard JSON to match your datasource name

## Examples

### Full Stack Deployment

Docker Compose example with Grafana + Prometheus:

```yaml
version: "3.8"

services:
  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    ports:
      - "9090:9090"

  grafana:
    image: grafana/grafana:latest
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - ./grafana-datasources.yml:/etc/grafana/provisioning/datasources/datasources.yml:ro
      - ./examples/observability/grafana:/etc/grafana/provisioning/dashboards:ro
      - ./grafana-provisioning.yml:/etc/grafana/provisioning/dashboards/dashboards.yml:ro
      - grafana-data:/var/lib/grafana
    ports:
      - "3000:3000"
    depends_on:
      - prometheus

  container:
    build: .
    environment:
      - METRICS_ENABLED=true
      - METRICS_PORT=9090
    ports:
      - "9091:9090"
    depends_on:
      - prometheus

volumes:
  prometheus-data:
  grafana-data:
```

### Alerting Integration

Link dashboards to Prometheus alerts:

```yaml
# In dashboard JSON, add annotation
{
  "annotations": {
    "list": [
      {
        "datasource": "Prometheus",
        "enable": true,
        "expr": "ALERTS{alertname=\"ContainerBuildFailed\"}",
        "iconColor": "red",
        "name": "Build Failures",
        "step": "60s",
        "tagKeys": "feature",
        "titleFormat": "Build Failed",
        "type": "tags"
      }
    ]
  }
}
```

## Additional Resources

- [Grafana Documentation](https://grafana.com/docs/)
- [Prometheus Metrics](../../docs/observability-design.md)
- [Alerting Rules](../prometheus/alerts.yml)
- [Runbooks](../../../docs/observability/runbooks/)
