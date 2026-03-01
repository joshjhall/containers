# Observability

The container build system includes built-in observability for monitoring
container health, build performance, and runtime behavior. This covers
Prometheus metrics, structured JSON logging, Grafana dashboards, alerting
rules, and OpenTelemetry integration.

## Quick Links

- **[Quickstart Guide](quickstart.md)** - Get observability running in 5
  minutes
- **[Metrics Reference](metrics-reference.md)** - All Prometheus metrics
  exposed by the container
- **[Structured Logging Reference](structured-logging-reference.md)** - JSON
  log format and field descriptions
- **[OpenTelemetry Integration](opentelemetry-integration.md)** - Distributed
  tracing with OTel
- **[Testing Strategy](testing-strategy.md)** - What we test and why
- **[Design Document](../architecture/observability.md)** - Architecture and
  design decisions

## Components

| Component          | Purpose                   | Key Files                                         |
| ------------------ | ------------------------- | ------------------------------------------------- |
| Metrics Exporter   | Prometheus-format metrics | `lib/runtime/metrics-exporter.sh`                 |
| JSON Logging       | Structured build logs     | `lib/base/json-logging.sh`                        |
| Grafana Dashboards | Pre-built visualizations  | `examples/observability/grafana/`                 |
| Alert Rules        | Prometheus alerting       | `examples/observability/prometheus/`              |
| OTel Integration   | Distributed tracing guide | `docs/observability/opentelemetry-integration.md` |
| Runbooks           | Incident response         | `docs/observability/runbooks/`                    |

## I Want To

### Get started quickly

Follow the [Quickstart Guide](quickstart.md) to enable metrics and logging,
start the observability stack, and verify everything works.

### Monitor container health

Enable the metrics exporter (`METRICS_ENABLED=true`) and point Prometheus at
port 9090. See the [Metrics Reference](metrics-reference.md) for available
metrics and the [Grafana dashboard guide](../../examples/observability/grafana/README.md)
for pre-built dashboards.

### Aggregate build logs

Enable JSON logging (`ENABLE_JSON_LOGGING=true`) to produce structured JSONL
logs suitable for Loki, Elasticsearch, or CloudWatch. See the
[Structured Logging Reference](structured-logging-reference.md) for field
descriptions.

### Set up distributed tracing

Follow the [OpenTelemetry Integration](opentelemetry-integration.md) guide to
configure OTLP exporters, trace context propagation, and backend connections.

### Set up alerts

Prometheus alert rules ship in
`examples/observability/prometheus/alerts.yml`. Each alert has a matching
[runbook](runbooks/) with diagnosis and resolution steps.

### Deploy the full stack

The full observability stack (Prometheus, Grafana, Jaeger, OTel Collector) is
defined in `examples/observability/docker-compose.yml`. The
[Quickstart Guide](quickstart.md) walks through launching it.

## Examples

All example configurations live under `examples/observability/`:

```text
examples/observability/
  docker-compose.yml         Full stack (Prometheus + Grafana + Jaeger + OTel)
  prometheus.yml             Prometheus scrape configuration
  prometheus/alerts.yml      Alerting rules
  grafana/                   Dashboard JSON files
  grafana-datasources.yml    Grafana datasource provisioning
  grafana-dashboards.yml     Grafana dashboard provisioning
  audit-logging/             CloudWatch and audit log examples
```

## Related Documentation

- [Architecture: Observability Design](../architecture/observability.md) -
  Design document and implementation phases
- [Grafana Dashboard Guide](../../examples/observability/grafana/README.md) -
  Dashboard details, installation, and customization
- [Environment Variables Reference](../reference/environment-variables.md) -
  All configuration env vars
- [Healthcheck](../healthcheck.md) - Container health monitoring
