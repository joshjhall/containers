# SLO Tracking for Container Observability

Service Level Objectives (SLOs) define reliability targets for the container
platform. This directory contains Prometheus recording rules and alerts that
implement multi-window, multi-burn-rate alerting based on the
[Google SRE book](https://sre.google/sre-book/alerting-on-slos/) pattern.

## Defined SLOs

| SLO                    | Target   | Error Budget (30d) | Metric                                   |
| ---------------------- | -------- | ------------------ | ---------------------------------------- |
| Container Availability | 99.9%    | 43.2 min           | `container_healthcheck_status`           |
| Build Success Rate     | 99.5%    | 3.6 hours          | `container_build_errors_total`           |
| Healthcheck Latency    | 99% < 5s | 7.2 hours          | `container_healthcheck_duration_seconds` |

## Concepts

### Service Level Indicators (SLIs)

SLIs are the metrics that measure service behavior. Recording rules in
`slo-rules.yml` pre-compute SLI ratios over multiple time windows (5m, 30m,
1h, 6h, 1d, 3d) for efficient querying and alerting.

### Error Budgets

Each SLO has an error budget: the amount of allowed unreliability over a
rolling 30-day window. For example, a 99.9% availability target allows
43.2 minutes of downtime per month.

The `error_budget:*:remaining` recording rules track how much budget is left
as a ratio from 1.0 (full) to 0.0 (exhausted) and below (over budget).

### Multi-Window, Multi-Burn-Rate Alerts

Instead of alerting on instantaneous SLI violations, burn rate alerts measure
how fast the error budget is being consumed:

| Burn Rate | Short Window | Long Window | Budget Consumed | Action           |
| --------- | ------------ | ----------- | --------------- | ---------------- |
| 14.4x     | 5m           | 1h          | 2% in 1 hour    | Page (critical)  |
| 6x        | 30m          | 6h          | 5% in 6 hours   | Page (critical)  |
| 1x        | 6h           | 3d          | 10% in 3 days   | Ticket (warning) |

Both windows must fire simultaneously to reduce false positives. The short
window detects the current issue; the long window confirms it is sustained.

## Setup

1. Add the rules file to your Prometheus configuration:

   ```yaml
   rule_files:
     - "/etc/prometheus/alerts.yml"
     - "/etc/prometheus/slo-rules.yml"
   ```

1. Mount the file in your docker-compose or Kubernetes deployment:

   ```yaml
   volumes:
     - ./slo/slo-rules.yml:/etc/prometheus/slo-rules.yml:ro
   ```

1. Customize SLO targets by editing the threshold values in `slo-rules.yml`:

   - `0.001` = 1 - 0.999 (99.9% availability target)
   - `0.005` = 1 - 0.995 (99.5% build success target)

## Grafana Dashboard Queries

Track error budget consumption over time:

```promql
# Availability error budget remaining (%)
error_budget:container_availability:remaining * 100

# Build success error budget remaining (%)
error_budget:build_success:remaining * 100

# Current availability over 1 hour
sli:container_availability:ratio_rate1h

# Current build success over 1 hour
sli:build_success:ratio_rate1h
```

## Adjusting Targets

To change an SLO target, update the corresponding threshold in the burn rate
alert expressions. For example, to change availability from 99.9% to 99.95%:

- Replace `0.001` with `0.0005` in all `slo: container-availability` alerts
- Update the `error_budget:container_availability:remaining` formula denominator
