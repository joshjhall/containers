# Structured Logging Reference

The container build system produces structured JSON logs alongside traditional
text logs. JSON logging is implemented in `lib/base/json-logging.sh` and
integrates automatically with the existing logging system.

## Enabling JSON Logging

```bash
export ENABLE_JSON_LOGGING=true
```

When enabled, every feature installation produces a JSONL (one JSON object per
line) log file. Text logging continues to work unchanged.

## JSON Log Format

Each line in a `.jsonl` file is a self-contained JSON object:

```json
{
  "timestamp": "2025-11-16T19:30:45.123Z",
  "level": "INFO",
  "correlation_id": "build-1700164245-a1b2c3",
  "event_type": "command",
  "feature": "python-dev",
  "message": "Installing Python dependencies",
  "metadata": {
    "command_num": 5,
    "exit_code": 0,
    "duration_seconds": 12,
    "success": true
  }
}
```

### Field Descriptions

| Field            | Type   | Description                                                                                           |
| ---------------- | ------ | ----------------------------------------------------------------------------------------------------- |
| `timestamp`      | string | ISO 8601 UTC timestamp with millisecond precision.                                                    |
| `level`          | string | Log level: `DEBUG`, `INFO`, `WARN`, `ERROR`, or `FATAL`.                                              |
| `correlation_id` | string | Unique identifier linking all logs from one build. Format: `build-<unix_timestamp>-<random_6_chars>`. |
| `event_type`     | string | Categorizes the log entry. See [Event Types](#event-types).                                           |
| `feature`        | string | Name of the feature being installed (e.g., `python-dev`).                                             |
| `message`        | string | Human-readable description.                                                                           |
| `metadata`       | object | Event-specific structured data. Fields vary by event type.                                            |

## Event Types

| Event Type      | Level      | When Emitted                  | Metadata Fields                                                         |
| --------------- | ---------- | ----------------------------- | ----------------------------------------------------------------------- |
| `feature_start` | INFO       | Feature installation begins   | `feature`, `version`                                                    |
| `command`       | INFO/ERROR | After each build command runs | `command_num`, `exit_code`, `duration_seconds`, `success`               |
| `error`         | ERROR      | When an error is logged       | `error_count`                                                           |
| `warning`       | WARN       | When a warning is logged      | `warning_count`                                                         |
| `feature_end`   | INFO       | Feature installation finishes | `duration_seconds`, `commands_executed`, `errors`, `warnings`, `status` |

## Correlation ID

Each build generates a single correlation ID shared by all features in that
build. This lets you group all log entries for a single `docker build`
invocation.

- **Format**: `build-<unix_timestamp>-<random_6_chars>`
- **Example**: `build-1700164245-a1b2c3`
- **Lifecycle**: Generated once at the start of the build, exported as
  `BUILD_CORRELATION_ID`, and included in every JSON log entry.
- **Aggregation**: Query `correlation_id = "build-..."` in your log system to
  see all entries from one build.

## Log File Locations

| File                                      | Description                                                                    |
| ----------------------------------------- | ------------------------------------------------------------------------------ |
| `$BUILD_LOG_DIR/json/<feature>.jsonl`     | Per-feature log (e.g., `python-dev.jsonl`)                                     |
| `$BUILD_LOG_DIR/json/build-summary.jsonl` | One-line-per-feature summary with duration, error/warning counts, and status   |
| `$BUILD_LOG_DIR/json/build-metadata.json` | Single JSON object with build-time metadata (base image, platform, build args) |

Default `BUILD_LOG_DIR` is `/var/log/container-build`.

## Configuration

| Variable               | Default                    | Description                                                                   |
| ---------------------- | -------------------------- | ----------------------------------------------------------------------------- |
| `ENABLE_JSON_LOGGING`  | `false`                    | Set to `true` to enable JSON log output.                                      |
| `BUILD_LOG_DIR`        | `/var/log/container-build` | Base directory for all logs. JSON logs are written to `$BUILD_LOG_DIR/json/`. |
| `BUILD_CORRELATION_ID` | (auto-generated)           | Override to use a custom correlation ID.                                      |

## GitHub Actions Build Diagnostics

Independently of JSON logging, the build harness emits CI-aware diagnostics so a
failed feature build is diagnosable from the GitHub UI without scrolling the raw
log (issue #583). These are gated on `GITHUB_ACTIONS=true` and are no-ops
locally.

### Per-feature log groups

`log_feature_start` opens `::group::Install <feature>` and `log_feature_end`
closes it with `::endgroup::`, so the web log view collapses/expands each feature
install independently.

### Failure sentinel and annotation

When a `log_command` aborts the build (a non-zero command under `set -e`), the
`cleanup_on_interrupt` trap in `lib/base/cleanup-handler.sh` fires with the
build-aborting exit code and emits, naming the **feature** and the **exact
command** that failed:

- A greppable **sentinel** line on stderr, always (even outside CI):

  ```text
  >>> BUILD FAILURE: feature='Java Development' command=#7 desc='Installing jdtls' cmd='curl -fsSL …' exit=1
  ```

- The same line appended to `$BUILD_LOG_DIR/build-failure.log` (surfaced first
  by `check-build-logs.sh`).
- Under CI only, a GitHub annotation: `::error title=Build failed in
  <feature>::COMMAND #N '<desc>' failed (exit <code>): <cmd>`.

The trap only fires for a non-zero exit while a feature is the active context, so
a clean install or an interrupt between features is never misreported.
`log_command … || log_warning` call sites are non-fatal and do not trigger it.

> **BuildKit caveat.** GitHub only parses workflow commands (`::error`,
> `::group`) that appear at the **start** of a runner step's stdout line. Output
> emitted *inside* a `docker build` RUN is prefixed by BuildKit (e.g.
> `#12 0.234 …`), so an in-container `::error` will **not** render in the
> Annotations panel — it stays a plain log line. That is why the **sentinel** is
> the primary signal (grep `>>> BUILD FAILURE`), and the workflows additionally
> surface the failing variant/feature from a runner step into the job summary
> (`ci.yml` / `test-pr.yml`, `Surface build failure`). When the v5 `luggage`
> build engine and `igor` runtime emit output directly from a runner step, the
> same `::error` lines will render natively in the Annotations panel.

## Secret Scrubbing

All log messages are passed through `scrub_secrets()` (when available) before
JSON encoding. This prevents secrets from leaking into structured logs. The
scrubbing happens inside `json_escape()`, so it applies to every JSON log path
automatically.

## Log Aggregation

### Loki

Use Promtail to tail the JSONL files:

```yaml
scrape_configs:
  - job_name: container-build
    static_configs:
      - targets: [localhost]
        labels:
          job: container-build
          __path__: /var/log/container-build/json/*.jsonl
    pipeline_stages:
      - json:
          expressions:
            level: level
            feature: feature
            correlation_id: correlation_id
      - labels:
          level:
          feature:
          correlation_id:
```

### Elasticsearch / CloudWatch

The JSONL format is compatible with any log aggregator that accepts JSON. Point
your agent at `/var/log/container-build/json/` and configure it to parse one
JSON object per line. See `examples/observability/audit-logging/` for
CloudWatch-specific examples.

## Build Metadata File

`build-metadata.json` is a single JSON object (not JSONL) written once at the
start of a build:

```json
{
  "correlation_id": "build-1700164245-a1b2c3",
  "timestamp": "2025-11-16T19:30:00.000Z",
  "base_image": "debian:trixie-slim",
  "project_name": "myproject",
  "platform": "Linux",
  "architecture": "x86_64",
  "build_args": {
    "include_python_dev": "true",
    "include_node_dev": "false",
    "include_rust_dev": "false",
    "include_golang_dev": "false",
    "include_java_dev": "false",
    "include_r_dev": "false",
    "include_ruby_dev": "false",
    "include_mojo_dev": "false",
    "include_docker": "false",
    "include_kubernetes": "false",
    "include_terraform": "false",
    "include_dev_tools": "true"
  }
}
```

This is useful for correlating build configuration with build outcomes.
