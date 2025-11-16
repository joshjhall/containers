# OpenTelemetry Integration Guide

This guide explains how to integrate OpenTelemetry (OTel) for distributed tracing and advanced observability in the container build system.

## Overview

OpenTelemetry provides:

- **Distributed Tracing**: Track build steps across services
- **Trace Context Propagation**: Link related operations
- **Custom Spans**: Instrument build scripts with timing data
- **OTLP Export**: Send traces to Jaeger, Zipkin, or other backends

## Table of Contents

- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Instrumentation](#instrumentation)
- [Backends](#backends)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)

## Quick Start

### 1. Enable OpenTelemetry

Set environment variables:

```bash
export OTEL_ENABLED=true
export OTEL_SERVICE_NAME="container-build"
export OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector:4318"
```

### 2. Install OTel SDK (if needed)

For shell script tracing, install minimal OTLP HTTP exporter:

```bash
# Option 1: Use curl (lightweight, no dependencies)
# This is the default approach - see implementation below

# Option 2: Use Python otel SDK (more features)
pip install opentelemetry-api opentelemetry-sdk opentelemetry-exporter-otlp

# Option 3: Use Node.js SDK (if node available)
npm install @opentelemetry/api @opentelemetry/sdk-node
```

### 3. Instrument Build Scripts

Source the OTel helper library in your scripts:

```bash
# In feature scripts
source /tmp/build-scripts/base/otel-tracing.sh

# Create span for operation
otel_span_start "install-python" "Installing Python 3.13"
# ... do work ...
otel_span_end "install-python" 0  # 0 = success
```

### 4. View Traces

Access your tracing backend:

- **Jaeger UI**: `http://jaeger:16686`
- **Zipkin UI**: `http://zipkin:9411`
- **Grafana Tempo**: Configure in Grafana datasources

## Configuration

### Environment Variables

```bash
# Core Configuration
OTEL_ENABLED=true                              # Enable OpenTelemetry (default: false)
OTEL_SERVICE_NAME="container-build"           # Service name in traces
OTEL_SERVICE_VERSION="4.0.0"                  # Service version

# Exporter Configuration
OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector:4318"  # OTLP HTTP endpoint
OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"              # Protocol (http/protobuf or grpc)
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer token"  # Optional auth headers

# Trace Configuration
OTEL_TRACES_SAMPLER="always_on"                # Sampling: always_on, always_off, traceidratio
OTEL_TRACES_SAMPLER_ARG="1.0"                  # Sample ratio (0.0-1.0)

# Resource Attributes
OTEL_RESOURCE_ATTRIBUTES="deployment.environment=production,host.name=build-server-1"

# Batch Export Settings
OTEL_BSP_MAX_QUEUE_SIZE="2048"                # Max spans in queue
OTEL_BSP_SCHEDULE_DELAY="5000"                # Export interval (ms)
OTEL_BSP_EXPORT_TIMEOUT="30000"               # Export timeout (ms)
```

### Docker Compose Example

```yaml
version: "3.8"

services:
  # OpenTelemetry Collector
  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    command: ["--config=/etc/otel-collector-config.yaml"]
    volumes:
      - ./otel-collector-config.yaml:/etc/otel-collector-config.yaml:ro
    ports:
      - "4317:4317" # OTLP gRPC
      - "4318:4318" # OTLP HTTP
      - "8888:8888" # Metrics

  # Jaeger (Trace Backend)
  jaeger:
    image: jaegertracing/all-in-one:latest
    environment:
      - COLLECTOR_OTLP_ENABLED=true
    ports:
      - "16686:16686" # Jaeger UI
      - "14268:14268" # Collector HTTP

  # Container with OTel enabled
  container:
    build: .
    environment:
      - OTEL_ENABLED=true
      - OTEL_SERVICE_NAME=my-project-build
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
    depends_on:
      - otel-collector
```

### OTel Collector Configuration

Create `otel-collector-config.yaml`:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 10s
    send_batch_size: 1024

  # Add resource attributes
  resource:
    attributes:
      - key: service.namespace
        value: containers
        action: insert

  # Sample traces (optional)
  probabilistic_sampler:
    sampling_percentage: 100 # 100% for development, 10-50% for production

exporters:
  # Export to Jaeger
  otlp/jaeger:
    endpoint: jaeger:4317
    tls:
      insecure: true

  # Export to Grafana Tempo
  otlp/tempo:
    endpoint: tempo:4317
    tls:
      insecure: true

  # Export to file (debugging)
  file:
    path: /tmp/otel-traces.json

  # Logging (debugging)
  logging:
    loglevel: debug

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch, resource]
      exporters: [otlp/jaeger, logging]
```

## Instrumentation

### Shell Script Tracing

Create `lib/base/otel-tracing.sh`:

```bash
#!/bin/bash
# OpenTelemetry tracing for shell scripts

# Check if OTel is enabled
if [ "${OTEL_ENABLED:-false}" != "true" ]; then
    # Provide no-op functions when disabled
    otel_span_start() { :; }
    otel_span_end() { :; }
    otel_add_event() { :; }
    otel_set_attribute() { :; }
    export -f otel_span_start otel_span_end otel_add_event otel_set_attribute
    return 0
fi

# Generate trace and span IDs
otel_generate_trace_id() {
    head /dev/urandom | tr -dc '0-9a-f' | head -c 32
}

otel_generate_span_id() {
    head /dev/urandom | tr -dc '0-9a-f' | head -c 16
}

# Current trace context
export OTEL_TRACE_ID="${OTEL_TRACE_ID:-$(otel_generate_trace_id)}"
declare -gA OTEL_ACTIVE_SPANS

# Start a span
otel_span_start() {
    local span_name="$1"
    local description="${2:-}"

    local span_id
    span_id=$(otel_generate_span_id)
    local start_time
    start_time=$(date +%s%N)  # nanoseconds

    # Store span context
    OTEL_ACTIVE_SPANS[$span_name]="$span_id:$start_time"

    # Set as current span
    export OTEL_CURRENT_SPAN_ID="$span_id"
}

# End a span and export
otel_span_end() {
    local span_name="$1"
    local status_code="${2:-0}"  # 0=success, non-zero=error

    if [ -z "${OTEL_ACTIVE_SPANS[$span_name]:-}" ]; then
        return 1
    fi

    local span_context="${OTEL_ACTIVE_SPANS[$span_name]}"
    local span_id="${span_context%%:*}"
    local start_time="${span_context##*:}"
    local end_time
    end_time=$(date +%s%N)

    # Build OTLP JSON payload
    local payload
    payload=$(cat <<EOF
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        {"key": "service.name", "value": {"stringValue": "${OTEL_SERVICE_NAME:-container-build}"}},
        {"key": "service.version", "value": {"stringValue": "${OTEL_SERVICE_VERSION:-unknown}"}}
      ]
    },
    "scopeSpans": [{
      "scope": {"name": "container-build-instrumentation"},
      "spans": [{
        "traceId": "$OTEL_TRACE_ID",
        "spanId": "$span_id",
        "parentSpanId": "${OTEL_PARENT_SPAN_ID:-}",
        "name": "$span_name",
        "kind": 1,
        "startTimeUnixNano": "$start_time",
        "endTimeUnixNano": "$end_time",
        "status": {
          "code": $([ "$status_code" -eq 0 ] && echo 1 || echo 2)
        }
      }]
    }]
  }]
}
EOF
)

    # Export via OTLP HTTP
    if [ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]; then
        curl -s -X POST \
            -H "Content-Type: application/json" \
            ${OTEL_EXPORTER_OTLP_HEADERS:+-H "$OTEL_EXPORTER_OTLP_HEADERS"} \
            "$OTEL_EXPORTER_OTLP_ENDPOINT/v1/traces" \
            -d "$payload" >/dev/null 2>&1 &
    fi

    # Clean up
    unset "OTEL_ACTIVE_SPANS[$span_name]"
}

# Export functions
export -f otel_span_start otel_span_end
```

### Usage in Feature Scripts

```bash
#!/bin/bash
# lib/features/python-dev.sh

source /tmp/build-scripts/base/otel-tracing.sh

# Start feature span
otel_span_start "install-python-dev" "Installing Python development environment"

# Sub-span for downloading
otel_span_start "download-python" "Downloading Python 3.13"
curl -O https://python.org/ftp/python/3.13.0/Python-3.13.0.tgz
otel_span_end "download-python" $?

# Sub-span for building
otel_span_start "build-python" "Building Python from source"
./configure && make && make install
otel_span_end "build-python" $?

# End feature span
otel_span_end "install-python-dev" 0
```

## Backends

### Jaeger

**Deployment**:

```bash
docker run -d --name jaeger \
  -e COLLECTOR_OTLP_ENABLED=true \
  -p 16686:16686 \
  -p 4317:4317 \
  -p 4318:4318 \
  jaegertracing/all-in-one:latest
```

**Access UI**: http://localhost:16686

**Query Traces**:

```bash
# Find traces for service
curl "http://localhost:16686/api/traces?service=container-build&limit=20"
```

### Grafana Tempo

**Docker Compose**:

```yaml
tempo:
  image: grafana/tempo:latest
  command: ["-config.file=/etc/tempo.yaml"]
  volumes:
    - ./tempo.yaml:/etc/tempo.yaml:ro
    - tempo-data:/var/tempo
  ports:
    - "4317:4317" # OTLP gRPC
    - "3200:3200" # Tempo HTTP

grafana:
  image: grafana/grafana:latest
  environment:
    - GF_FEATURE_TOGGLES_ENABLE=traceqlEditor
  volumes:
    - ./grafana-datasources.yaml:/etc/grafana/provisioning/datasources/datasources.yaml:ro
```

**Tempo Config** (`tempo.yaml`):

```yaml
server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317

storage:
  trace:
    backend: local
    local:
      path: /var/tempo/traces
```

### Zipkin

**Deployment**:

```bash
docker run -d -p 9411:9411 openzipkin/zipkin:latest
```

**Configure OTel Collector**:

```yaml
exporters:
  zipkin:
    endpoint: "http://zipkin:9411/api/v2/spans"
```

## Examples

### Full Stack with Tracing

Create `docker-compose-observability.yml`:

```yaml
version: "3.8"

services:
  # OpenTelemetry Collector
  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    command: ["--config=/etc/otel-config.yaml"]
    volumes:
      - ./examples/observability/otel-collector-config.yaml:/etc/otel-config.yaml:ro
    ports:
      - "4317:4317"
      - "4318:4318"

  # Jaeger
  jaeger:
    image: jaegertracing/all-in-one:latest
    ports:
      - "16686:16686"
      - "14268:14268"

  # Prometheus
  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
    ports:
      - "9090:9090"

  # Grafana
  grafana:
    image: grafana/grafana:latest
    environment:
      - GF_FEATURE_TOGGLES_ENABLE=traceqlEditor
    volumes:
      - ./examples/observability/grafana:/etc/grafana/provisioning/dashboards:ro
    ports:
      - "3000:3000"

  # Container with full observability
  container:
    build:
      context: .
      args:
        - INCLUDE_PYTHON_DEV=true
        - INCLUDE_NODE_DEV=true
    environment:
      # Metrics
      - METRICS_ENABLED=true
      - METRICS_PORT=9090

      # Logging
      - ENABLE_JSON_LOGGING=true

      # Tracing
      - OTEL_ENABLED=true
      - OTEL_SERVICE_NAME=my-project
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
      - OTEL_RESOURCE_ATTRIBUTES=deployment.environment=dev
    ports:
      - "9091:9090"
    depends_on:
      - otel-collector
      - prometheus
```

**Start the stack**:

```bash
docker-compose -f docker-compose-observability.yml up -d
```

**Access UIs**:

- Grafana: http://localhost:3000
- Jaeger: http://localhost:16686
- Prometheus: http://localhost:9090

## Troubleshooting

### No Traces Appearing

1. **Check OTel is enabled**:

   ```bash
   echo $OTEL_ENABLED  # Should be "true"
   ```

2. **Verify collector is reachable**:

   ```bash
   curl http://otel-collector:4318/v1/traces
   # Should return method not allowed (means endpoint exists)
   ```

3. **Check collector logs**:

   ```bash
   docker logs otel-collector | grep -i error
   ```

4. **Test manual span export**:

   ```bash
   curl -X POST http://otel-collector:4318/v1/traces \
     -H "Content-Type: application/json" \
     -d '{"resourceSpans":[{"scopeSpans":[{"spans":[{"traceId":"12345678901234567890123456789012","spanId":"1234567890123456","name":"test"}]}]}]}'
   ```

### Incomplete Traces

- **Missing parent spans**: Check `OTEL_PARENT_SPAN_ID` is set correctly
- **Orphaned spans**: Ensure trace ID propagates across contexts
- **Timing issues**: Verify system clocks are synchronized (NTP)

### Performance Impact

- **Disable in production** if overhead is too high
- **Reduce sampling**: Set `OTEL_TRACES_SAMPLER_ARG=0.1` (10%)
- **Batch exports**: Increase `OTEL_BSP_SCHEDULE_DELAY`
- **Async exports**: Spans are exported in background by default

## Best Practices

1. **Span Granularity**: Create spans for operations > 100ms
2. **Attributes**: Add meaningful attributes (version, feature, etc.)
3. **Error Handling**: Always call `otel_span_end` even on errors
4. **Sampling**: Use 100% in dev, 10-50% in production
5. **Cardinality**: Avoid high-cardinality attributes (timestamps, IDs)

## Additional Resources

- [OpenTelemetry Documentation](https://opentelemetry.io/docs/)
- [OTLP Specification](https://opentelemetry.io/docs/specs/otlp/)
- [Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/)
- [Grafana Tempo](https://grafana.com/docs/tempo/latest/)
- [Jaeger](https://www.jaegertracing.io/docs/latest/)
