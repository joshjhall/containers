# Observability Testing Strategy

## Philosophy

Testing observability is different from testing business logic. Mocking Grafana,
Prometheus, and distributed tracing systems is expensive, fragile, and provides
limited value. Instead, we focus on practical, cost-effective tests that
validate the core functionality.

## What We Test (Cost-Effective)

### 1. JSON Logging ✅

**Test**: Output format and structure **Method**: Unit tests with mock data
**Value**: High - ensures valid JSON, required fields, correlation IDs

```bash
# Test that JSON is valid and contains required fields
cat log.jsonl | jq '.'  # Should parse without error
cat log.jsonl | jq '.correlation_id' # Should exist
```

**CI Cost**: Negligible (pure shell, no external services)

### 2. Metrics Format ✅

**Test**: Prometheus format correctness **Method**: Unit tests parsing mock
build logs **Value**: High - ensures Prometheus can scrape

```bash
# Test metrics format
./metrics-exporter.sh | grep "# HELP"  # Has help text
./metrics-exporter.sh | grep "# TYPE"  # Has type declarations
./metrics-exporter.sh | grep "^container_" # Has metrics
```

**CI Cost**: Negligible (no Prometheus needed)

### 3. Script Execution ✅

**Test**: Scripts don't crash with various inputs **Method**: Run with edge
cases (empty logs, missing files) **Value**: Medium - prevents runtime errors

**CI Cost**: Low (basic shell execution)

### 4. Alert Rules Syntax ✅

**Test**: YAML syntax and Prometheus rule validation **Method**: Use
`promtool check rules` (if available) **Value**: Medium - prevents syntax errors

```bash
# In CI if promtool available
promtool check rules alerts.yml
```

**CI Cost**: Low (static analysis only)

### 5. Dashboard JSON Syntax ✅

**Test**: Valid JSON structure **Method**: Parse with `jq` **Value**: Low - just
syntax checking

```bash
jq '.' dashboard.json > /dev/null
```

**CI Cost**: Negligible

## What We DON'T Test (Too Expensive)

### ❌ Full Prometheus Integration

**Why Skip**: Requires running Prometheus server, configuring scraping, waiting
for data **Alternative**: Manual smoke test when setting up first time

### ❌ Grafana Dashboard Rendering

**Why Skip**: Requires Grafana server, datasource configuration, brittle UI
tests **Alternative**: Manual verification, screenshots in docs

### ❌ Distributed Tracing End-to-End

**Why Skip**: Requires Jaeger/Tempo, complex trace propagation **Alternative**:
Manual testing with example workload

### ❌ Alertmanager Integration

**Why Skip**: Requires Alertmanager, notification channels (Slack, PagerDuty)
**Alternative**: Test alert rule syntax only, manual integration testing

## Recommended Testing Workflow

### During Development

1. Run unit tests: `./tests/unit/observability/test_*.sh`
2. Manual smoke test with stack:
   `docker-compose -f examples/observability/docker-compose.yml up`
3. Verify metrics appear in Prometheus UI
4. Verify dashboards load in Grafana

### In CI

1. ✅ Run unit tests (JSON, metrics format)
2. ✅ Validate YAML syntax (alerts, dashboards)
3. ✅ Check scripts are executable and don't crash
4. ❌ Skip full integration (too slow/expensive)

### First Deployment

1. Deploy observability stack
2. Enable metrics in one container
3. Verify end-to-end: Container → Prometheus → Grafana
4. Test one alert firing
5. Document any issues in runbooks

## Manual Smoke Test Checklist

When setting up observability for the first time:

- [ ] Start observability stack (`docker-compose up`)
- [ ] Build container with metrics enabled
- [ ] Verify Prometheus scrapes metrics (Targets page)
- [ ] Verify dashboards load without errors
- [ ] Trigger an alert condition (e.g., create build error)
- [ ] Verify alert fires in Prometheus
- [ ] Check JSON logs are valid (`jq '.' log.jsonl`)
- [ ] Optional: Send test trace to Jaeger

## Test Coverage Goals

| Component    | Unit Tests         | Integration | Manual          | Priority |
| ------------ | ------------------ | ----------- | --------------- | -------- |
| JSON Logging | ✅ Format, fields  | ❌          | ✅ Smoke test   | High     |
| Metrics      | ✅ Format, parsing | ❌          | ✅ Smoke test   | High     |
| Dashboards   | ✅ Syntax          | ❌          | ✅ First deploy | Medium   |
| Alerts       | ✅ Syntax          | ❌          | ✅ First deploy | Medium   |
| Tracing      | ❌                 | ❌          | ✅ Optional     | Low      |
| Runbooks     | ❌                 | ❌          | ✅ On incidents | Low      |

## Continuous Validation

### Metrics Endpoint Health

Add simple check to existing healthcheck:

```bash
# In healthcheck script
if [ "${METRICS_ENABLED:-false}" = "true" ]; then
    curl -s http://localhost:9090/metrics >/dev/null || return 1
fi
```

### Log Format Validation

Periodically validate JSON logs in production:

```bash
# Cron job or alert
find /var/log/container-build/json -name "*.jsonl" \
    -exec sh -c 'jq "." "$1" >/dev/null 2>&1 || echo "Invalid JSON: $1"' _ {} \;
```

## When Things Break

### Scenario: Prometheus Can't Scrape Metrics

1. Check unit tests pass (format is valid)
2. Check metrics endpoint returns data: `curl localhost:9090/metrics`
3. Check Prometheus config syntax
4. Check network connectivity
5. See runbook: `docs/observability/runbooks/metrics-stale.md`

### Scenario: Grafana Dashboard Broken

1. Check JSON syntax: `jq '.' dashboard.json`
2. Check datasource configured
3. Verify metrics exist in Prometheus
4. Consult Grafana logs

### Scenario: Alerts Not Firing

1. Check rule syntax: `promtool check rules alerts.yml` (if available)
2. Manually trigger condition
3. Check Prometheus Rules page
4. Check Alertmanager (if configured)

## Future Improvements

If observability becomes critical and resources allow:

1. **Add promtool to CI** - Validate Prometheus rules
2. **Add integration test** - One full workflow (build → metrics → alert)
3. **Snapshot testing** - Compare dashboard JSON to known-good state
4. **Chaos testing** - Verify observability survives failures

But for Phase 1: **Focus on format correctness and basic smoke testing**

## Summary

✅ **Do Test**:

- JSON format and required fields
- Prometheus metrics format
- YAML syntax
- Script execution without crashes

❌ **Don't Test**:

- Full Prometheus integration
- Grafana dashboard rendering
- Distributed tracing end-to-end
- External notification systems

**Philosophy**: Test what's cheap and valuable. Defer expensive integration
tests to manual smoke testing. Fix issues as they arise in real usage.
