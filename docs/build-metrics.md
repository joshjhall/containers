# Build Metrics Tracking

This document describes the build metrics tracking system for monitoring image sizes and build times across container variants.

## Overview

The build metrics system helps you:

- Track Docker image sizes for each variant
- Measure build times for reproducibility
- Detect regressions when images grow unexpectedly
- Save baseline metrics for comparison
- Generate reports in human-readable or JSON format

## Quick Start

### Measure Image Size and Build Time

```bash
# Measure metrics for a variant (builds if needed)
./bin/measure-build-metrics.sh minimal

# Output:
# === Build Metrics for minimal ===
#   Image Size:  450.23MB (471859200 bytes)
#   Build Time:  45s
#   Timestamp:   2025-11-12_01:15:00
```

### Save Baseline for Comparison

```bash
# Measure and save as baseline
./bin/measure-build-metrics.sh --save-baseline python-dev

# Output:
# Image not found, building python-dev...
# Baseline saved: metrics/baselines/python-dev.json
# === Build Metrics for python-dev ===
#   Image Size:  1250.45MB (1310720000 bytes)
#   Build Time:  180s
#   Timestamp:   2025-11-12_01:16:30
```

### Detect Regressions

```bash
# Compare current build against baseline
./bin/measure-build-metrics.sh --compare python-dev

# Output (no regression):
# === Baseline Comparison for python-dev ===
#
# Image Size:
#   Baseline:  1250.45MB
#   Current:   1255.20MB
#   Change:    +4.75MB
#
# Build Time:
#   Baseline:  180s
#   Current:   175s
#   Change:    -5s (-2.78%)
#
# ✅ No regressions detected

# Output (regression detected):
# === Baseline Comparison for python-dev ===
#
# Image Size:
#   Baseline:  1250.45MB
#   Current:   1400.00MB
#   Change:    +149.55MB
#
# Build Time:
#   Baseline:  180s
#   Current:   230s
#   Change:    +50s (+27.78%)
#
# ⚠️  REGRESSION DETECTED:
#   - Image size increased by 149.55MB (threshold: 100MB)
#   - Build time increased by 27.78% (threshold: 20%)
```

## Command-Line Options

### Basic Options

- `<variant>` - Variant to measure (minimal, python-dev, node-dev, rust-golang, cloud-ops, polyglot)
- `--save-baseline` - Save measurements as baseline for future comparisons
- `--compare` - Compare against baseline and fail if regression detected
- `--json` - Output results as JSON instead of human-readable text
- `--help` - Show help message

### Regression Thresholds

- `--threshold-size MB` - Size regression threshold in MB (default: 100)
- `--threshold-time PCT` - Time regression threshold as percentage (default: 20)

## Supported Variants

| Variant | Description | Typical Size |
|---------|-------------|--------------|
| minimal | Base system only | ~450MB |
| python-dev | Python + development tools | ~1.2GB |
| node-dev | Node.js + development tools | ~1.1GB |
| rust-golang | Rust + Go compilers | ~2.0GB |
| cloud-ops | Docker, Kubernetes, Terraform, AWS CLI | ~1.5GB |
| polyglot | Python, Node, Rust, Go | ~2.5GB |

## Usage Examples

### CI/CD Integration

Save baselines after successful releases:

```bash
# In release workflow, save baselines for all variants
for variant in minimal python-dev node-dev rust-golang cloud-ops polyglot; do
    ./bin/measure-build-metrics.sh --save-baseline "$variant"
done
```

Compare in pull request checks:

```bash
# In PR workflow, detect regressions
for variant in minimal python-dev node-dev; do
    if ! ./bin/measure-build-metrics.sh --compare "$variant"; then
        echo "Regression detected in $variant"
        exit 1
    fi
done
```

### Custom Thresholds

For variants with frequent large changes:

```bash
# Allow larger size increases for development variants
./bin/measure-build-metrics.sh \
    --compare \
    --threshold-size 200 \
    --threshold-time 30 \
    python-dev
```

### JSON Output for Automation

```bash
# Get metrics as JSON for processing
./bin/measure-build-metrics.sh --json minimal

# Output:
# {
#   "variant": "minimal",
#   "timestamp": "2025-11-12_01:15:00",
#   "size_bytes": 471859200,
#   "size_human": "450.23MB",
#   "build_time_seconds": 45
# }
```

### Batch Measurement

Measure all variants and save as JSON:

```bash
# Measure all variants
for variant in minimal python-dev node-dev rust-golang cloud-ops polyglot; do
    ./bin/measure-build-metrics.sh --json "$variant" >> metrics/all-variants.json
done
```

## Baseline Management

### Baseline File Format

Baselines are stored as JSON in `metrics/baselines/`:

```json
{
  "variant": "python-dev",
  "timestamp": "2025-11-12_01:16:30",
  "size_bytes": 1310720000,
  "size_human": "1250.45MB",
  "build_time_seconds": 180
}
```

### Updating Baselines

Baselines should be updated:

- After major version releases (e.g., v4.8.0 → v4.9.0)
- When intentional changes increase size (new features, dependencies)
- When optimizations significantly reduce size

```bash
# Update baseline for a specific variant
./bin/measure-build-metrics.sh --save-baseline python-dev

# Commit the updated baseline
git add metrics/baselines/python-dev.json
git commit -m "chore: Update python-dev baseline after adding new tools"
```

### Viewing Baselines

```bash
# View current baseline
cat metrics/baselines/python-dev.json

# View all baselines
ls -lh metrics/baselines/
```

## Regression Detection

### Default Thresholds

- **Size Threshold**: 100MB increase
  - Triggers when image grows by more than 100MB
  - Indicates potential bloat or missing cleanup

- **Time Threshold**: 20% increase
  - Triggers when build time increases by >20%
  - Indicates potential inefficiency or network issues

### Adjusting Thresholds

Thresholds can be adjusted based on variant characteristics:

```bash
# Stricter threshold for minimal variant
./bin/measure-build-metrics.sh \
    --compare \
    --threshold-size 50 \
    --threshold-time 10 \
    minimal

# Looser threshold for large polyglot variant
./bin/measure-build-metrics.sh \
    --compare \
    --threshold-size 200 \
    --threshold-time 30 \
    polyglot
```

## Troubleshooting

### Image Not Found

If the image doesn't exist, the script will attempt to build it:

```
Image not found, building python-dev...
```

To pre-build images:

```bash
docker build -t test:python-dev \
    --build-arg PROJECT_PATH=. \
    --build-arg PROJECT_NAME=test \
    --build-arg INCLUDE_PYTHON=true \
    --build-arg INCLUDE_PYTHON_DEV=true \
    .
```

### No Baseline Found

If comparing without a baseline:

```
ERROR: No baseline found for variant: python-dev (run with --save-baseline first)
```

Solution:

```bash
# Create baseline first
./bin/measure-build-metrics.sh --save-baseline python-dev
```

### Build Failures

If a build fails during measurement:

```
ERROR: Build failed for variant: python-dev
```

Check:
- Docker is running
- Dockerfile is valid
- Build arguments are correct

## Best Practices

### 1. Save Baselines After Releases

Always save baselines after successful releases:

```bash
# After release v4.8.0
for variant in minimal python-dev node-dev; do
    ./bin/measure-build-metrics.sh --save-baseline "$variant"
done
git add metrics/baselines/
git commit -m "chore: Update baselines for v4.8.0"
```

### 2. Check for Regressions in CI

Add regression checks to your CI pipeline:

```yaml
# .github/workflows/ci.yml
- name: Check for build regressions
  run: |
    for variant in minimal python-dev node-dev; do
      ./bin/measure-build-metrics.sh --compare "$variant" || exit 1
    done
```

### 3. Track Metrics Over Time

Save metrics history for trend analysis:

```bash
# Append to metrics history
./bin/measure-build-metrics.sh --json python-dev >> metrics/history/python-dev.jsonl
```

### 4. Document Intentional Increases

When increasing size intentionally, document it:

```bash
# Update baseline with explanation
./bin/measure-build-metrics.sh --save-baseline python-dev
git add metrics/baselines/python-dev.json
git commit -m "chore: Update python-dev baseline

Added NumPy and SciPy (+150MB) for scientific computing support.
See #123 for details."
```

## Integration with Testing

The metrics system integrates with the test framework:

```bash
# Run unit tests for metrics system
./tests/unit/bin/measure-build-metrics.sh

# All tests should pass:
# ✅ Bytes to human-readable conversion
# ✅ Baseline JSON format
# ✅ Regression: Size increase detection
# ✅ Regression: Time increase detection
# (11 tests total)
```

## Exit Codes

- `0` - Success (no regressions if --compare used)
- `1` - Error or regression detected
- `2` - Usage error (invalid arguments)

## Files and Directories

```
metrics/
├── baselines/              # Saved baseline metrics
│   ├── minimal.json
│   ├── python-dev.json
│   ├── node-dev.json
│   ├── rust-golang.json
│   ├── cloud-ops.json
│   └── polyglot.json
└── history/                # Optional: Historical metrics
    └── python-dev.jsonl    # One JSON object per line
```

## Related Documentation

- [Testing Framework](testing-framework.md) - Overall testing approach
- [Production Deployment](production-deployment.md) - Optimizing image sizes
- [Troubleshooting](troubleshooting.md) - Build-time issues
- [Contributing](../CONTRIBUTING.md) - Development guidelines
