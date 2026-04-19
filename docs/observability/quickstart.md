# Observability Quickstart

Get container observability running in about 5 minutes. This guide walks
through enabling metrics and structured logging, launching the monitoring
stack, and verifying everything works.

## Prerequisites

- Docker and Docker Compose
- A built container image (see [main README](../../README.md))

## 1. Enable Metrics and Logging

Set these environment variables when running your container:

```bash
# Prometheus metrics on port 9090
METRICS_ENABLED=true
METRICS_PORT=9090

# Structured JSON logging
ENABLE_JSON_LOGGING=true
```

In a docker-compose file:

```yaml
services:
  mycontainer:
    build:
      context: .
      dockerfile: containers/Dockerfile
      args:
        - PROJECT_NAME=myproject
        - INCLUDE_PYTHON_DEV=true
    init: true
    environment:
      - METRICS_ENABLED=true
      - METRICS_PORT=9090
      - ENABLE_JSON_LOGGING=true
    ports:
      - "9091:9090" # Metrics endpoint
```

## 2. Start the Observability Stack

The repository ships a full stack configuration with Prometheus, Grafana, and
Jaeger:

```bash
cd examples/observability
docker compose up -d
```

This starts:

| Service    | URL                      | Credentials |
| ---------- | ------------------------ | ----------- |
| Grafana    | `http://localhost:3000`  | admin/admin |
| Prometheus | `http://localhost:9090`  | -           |
| Jaeger     | `http://localhost:16686` | -           |

## 3. Verify Metrics in Prometheus

1. Open `http://localhost:9090/targets`
1. Confirm your container target shows **UP**
1. Run a test query: `container_uptime_seconds`

If the target is not listed, check that Prometheus is configured to scrape your
container. Edit `examples/observability/prometheus.yml`:

```yaml
scrape_configs:
  - job_name: "containers"
    static_configs:
      - targets: ["host.docker.internal:9091"]
```

## 4. Verify Dashboards in Grafana

1. Open `http://localhost:3000` (login: admin/admin)
1. Go to **Dashboards** in the left sidebar
1. Open **Container Build Overview** — shows build durations, errors, warnings
1. Open **Container Runtime Health** — shows uptime, health status, disk usage

The dashboards are auto-provisioned from the JSON files in
`examples/observability/grafana/`.

## 5. Verify JSON Logs

Inside your running container:

```bash
# Check that JSON log files exist
ls /var/log/container-build/json/

# Validate a log file is valid JSONL
cat /var/log/container-build/json/build-summary.jsonl | jq '.'

# Check correlation IDs are present
cat /var/log/container-build/json/build-summary.jsonl | jq '.correlation_id'
```

## Smoke Test Checklist

After first setup, verify each component:

- [ ] Observability stack starts without errors (`docker compose up`)
- [ ] Prometheus targets page shows container as UP
- [ ] Query `container_uptime_seconds` returns data in Prometheus
- [ ] Grafana dashboards load without "No data" errors
- [ ] JSON logs under `/var/log/container-build/json/` parse as valid JSON
- [ ] Build summary JSONL contains correlation IDs
- [ ] (Optional) Jaeger UI shows traces if OTel is configured

## Configuration Reference

| Variable                   | Default                    | Description                            |
| -------------------------- | -------------------------- | -------------------------------------- |
| `METRICS_ENABLED`          | `false`                    | Enable the Prometheus metrics endpoint |
| `METRICS_PORT`             | `9090`                     | Port for the metrics HTTP server       |
| `METRICS_REFRESH_INTERVAL` | `15`                       | Seconds between metric refreshes       |
| `ENABLE_JSON_LOGGING`      | `false`                    | Enable structured JSON log output      |
| `BUILD_LOG_DIR`            | `/var/log/container-build` | Base directory for logs                |

## Next Steps

- **[Metrics Reference](metrics-reference.md)** - Full list of exposed metrics
- **[Structured Logging Reference](structured-logging-reference.md)** - JSON
  field descriptions and event types
- **[OpenTelemetry Integration](opentelemetry-integration.md)** - Add
  distributed tracing
- **[Grafana Dashboard Guide](../../examples/observability/grafana/README.md)** -
  Dashboard customization and Kubernetes integration
- **[Alerting Runbooks](runbooks/)** - Respond to fired alerts
