# Metrics Reference

All Prometheus metrics exposed by the container metrics exporter
(`lib/runtime/metrics-exporter.sh`). Metrics are served on the HTTP endpoint
or written to a file for collection.

## Build Metrics

Extracted from build logs at `$BUILD_LOG_DIR/master-summary.log`.

| Metric                               | Type    | Labels              | Description                                                       |
| ------------------------------------ | ------- | ------------------- | ----------------------------------------------------------------- |
| `container_build_duration_seconds`   | gauge   | `feature`, `status` | Time taken to build a feature. `status` is `success` or `failed`. |
| `container_build_errors_total`       | counter | `feature`           | Error count for a single feature build.                           |
| `container_build_warnings_total`     | counter | `feature`           | Warning count for a single feature build.                         |
| `container_features_installed`       | gauge   | -                   | Total number of features installed.                               |
| `container_build_errors_total_all`   | counter | -                   | Total errors across all features.                                 |
| `container_build_warnings_total_all` | counter | -                   | Total warnings across all features.                               |

## Runtime Metrics

Collected live from the running container.

| Metric                                   | Type  | Labels | Description                                                                                           |
| ---------------------------------------- | ----- | ------ | ----------------------------------------------------------------------------------------------------- |
| `container_uptime_seconds`               | gauge | -      | Seconds since container start.                                                                        |
| `container_healthcheck_status`           | gauge | -      | Current health: `1` = healthy, `0` = unhealthy. Only present when `healthcheck` command is available. |
| `container_healthcheck_duration_seconds` | gauge | -      | Seconds taken for the last healthcheck.                                                               |

## Resource Metrics

Disk usage for key directories. Requires `df` and `du` to be available.

| Metric                       | Type  | Labels | Description                                                                                           |
| ---------------------------- | ----- | ------ | ----------------------------------------------------------------------------------------------------- |
| `container_disk_usage_bytes` | gauge | `path` | Bytes used by a directory. Reported for `/cache`, `/workspace`, and `$BUILD_LOG_DIR` when they exist. |

## JSON Log Metrics

Extracted from `$BUILD_LOG_DIR/json/build-summary.jsonl` when `jq` is
available. These duplicate build metrics with a separate metric name to
distinguish the source.

| Metric                                  | Type  | Labels              | Description                    |
| --------------------------------------- | ----- | ------------------- | ------------------------------ |
| `container_build_json_duration_seconds` | gauge | `feature`, `status` | Build duration from JSON logs. |

## Internal Metrics

| Metric                                       | Type  | Labels | Description                                    |
| -------------------------------------------- | ----- | ------ | ---------------------------------------------- |
| `container_metrics_scrape_timestamp_seconds` | gauge | -      | Unix timestamp of the last metrics collection. |

## Configuration

| Variable                   | Default                    | Description                                               |
| -------------------------- | -------------------------- | --------------------------------------------------------- |
| `METRICS_ENABLED`          | `false`                    | Set to `true` to enable the metrics endpoint at runtime.  |
| `METRICS_PORT`             | `9090`                     | Port for the HTTP metrics server.                         |
| `METRICS_REFRESH_INTERVAL` | `15`                       | Seconds between metric refreshes (server and file modes). |
| `METRICS_FILE`             | (empty)                    | When set, write metrics to this file instead of HTTP.     |
| `BUILD_LOG_DIR`            | `/var/log/container-build` | Directory containing build logs to parse.                 |

## Running the Exporter

```bash
# HTTP server mode (for Prometheus scraping)
metrics-exporter.sh --server --port 9090

# File mode (write metrics for node_exporter textfile collector)
metrics-exporter.sh --file /var/metrics/prometheus.txt

# Stdout (for testing)
metrics-exporter.sh
```

The HTTP server requires `socat` or `nc` (netcat). If neither is available, the
exporter falls back to file mode automatically.

## Prometheus Scrape Configuration

```yaml
scrape_configs:
  - job_name: "containers"
    scrape_interval: 30s
    static_configs:
      - targets: ["container:9090"]
        labels:
          environment: "production"
          project: "myproject"
```

For Kubernetes, use annotations or a ServiceMonitor:

```yaml
# Pod annotations
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9090"
    prometheus.io/path: "/metrics"
```

See the [Grafana Dashboard Guide](../../examples/observability/grafana/README.md)
for connecting these metrics to dashboards.
