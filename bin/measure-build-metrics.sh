#!/usr/bin/env bash
# Measure Build Metrics - Track image size and build time
#
# Description:
#   Measures Docker image size and build time for container variants.
#   Can save baseline metrics and compare against them to detect regressions.
#
# Usage:
#   ./measure-build-metrics.sh [OPTIONS] <variant>
#
# Options:
#   --save-baseline      Save measurements as baseline for future comparisons
#   --compare           Compare against baseline and fail if regression detected
#   --threshold-size MB  Size regression threshold in MB (default: 100)
#   --threshold-time PCT Time regression threshold as percentage (default: 20)
#   --json              Output as JSON
#   --help              Show this help message
#
# Examples:
#   # Measure minimal variant
#   ./measure-build-metrics.sh minimal
#
#   # Save baseline for python-dev variant
#   ./measure-build-metrics.sh --save-baseline python-dev
#
#   # Compare against baseline and fail if regression
#   ./measure-build-metrics.sh --compare python-dev
#
# Exit Codes:
#   0 - Success (no regressions if --compare used)
#   1 - Error or regression detected
#   2 - Usage error
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Metrics directory
METRICS_DIR="$PROJECT_ROOT/metrics"
BASELINE_DIR="$METRICS_DIR/baselines"

# Default thresholds
SIZE_THRESHOLD_MB=100  # MB increase triggers regression
TIME_THRESHOLD_PCT=20  # Percentage increase triggers regression

# Flags
SAVE_BASELINE=false
COMPARE_BASELINE=false
OUTPUT_JSON=false

# ============================================================================
# Helper Functions
# ============================================================================

show_help() {
    head -n 30 "$0" | grep '^#' | command sed 's/^# \?//'
}

error() {
    echo "ERROR: $*" >&2
    exit 1
}

usage_error() {
    echo "ERROR: $*" >&2
    echo
    show_help
    exit 2
}

# Convert bytes to human-readable format
bytes_to_human() {
    local bytes="$1"
    local mb
    mb=$(awk "BEGIN {printf \"%.2f\", $bytes / 1024 / 1024}")
    echo "${mb}MB"
}

# Get current timestamp
timestamp() {
    date +%Y-%m-%d_%H:%M:%S
}

# ============================================================================
# Measurement Functions
# ============================================================================

# Measure image size in bytes
measure_image_size() {
    local image_name="$1"

    if ! docker image inspect "$image_name" >/dev/null 2>&1; then
        error "Image not found: $image_name"
    fi

    # Get size in bytes
    docker image inspect "$image_name" --format='{{.Size}}'
}

# Measure build time in seconds
measure_build_time() {
    local variant="$1"
    local build_args="$2"

    local start_time
    local end_time
    local duration

    start_time=$(date +%s)

    # Build the image
    # Note: This is a simplified example - actual builds may need more configuration
    # shellcheck disable=SC2086  # build_args intentionally word-splits to multiple args
    if ! docker build \
        -f "$PROJECT_ROOT/Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test \
        $build_args \
        -t "test:$variant" \
        "$PROJECT_ROOT" >/dev/null 2>&1; then
        error "Build failed for variant: $variant"
    fi

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    echo "$duration"
}

# Get build arguments for a variant
get_build_args_for_variant() {
    local variant="$1"
    local args=""

    case "$variant" in
        minimal)
            # No additional args
            ;;
        python-dev)
            args="--build-arg INCLUDE_PYTHON=true --build-arg INCLUDE_PYTHON_DEV=true"
            ;;
        node-dev)
            args="--build-arg INCLUDE_NODE=true --build-arg INCLUDE_NODE_DEV=true"
            ;;
        rust-golang)
            args="--build-arg INCLUDE_RUST=true --build-arg INCLUDE_GOLANG=true"
            ;;
        cloud-ops)
            args="--build-arg INCLUDE_DOCKER=true --build-arg INCLUDE_KUBERNETES=true --build-arg INCLUDE_TERRAFORM=true --build-arg INCLUDE_AWS=true"
            ;;
        polyglot)
            args="--build-arg INCLUDE_PYTHON=true --build-arg INCLUDE_NODE=true --build-arg INCLUDE_RUST=true --build-arg INCLUDE_GOLANG=true"
            ;;
        *)
            error "Unknown variant: $variant"
            ;;
    esac

    echo "$args"
}

# ============================================================================
# Baseline Functions
# ============================================================================

# Save baseline metrics
save_baseline() {
    local variant="$1"
    local size_bytes="$2"
    local build_time="$3"

    mkdir -p "$BASELINE_DIR"

    local baseline_file="$BASELINE_DIR/${variant}.json"

    command cat > "$baseline_file" << EOF
{
  "variant": "$variant",
  "timestamp": "$(timestamp)",
  "size_bytes": $size_bytes,
  "size_human": "$(bytes_to_human "$size_bytes")",
  "build_time_seconds": $build_time
}
EOF

    echo "Baseline saved: $baseline_file"
}

# Load baseline metrics
load_baseline() {
    local variant="$1"
    local baseline_file="$BASELINE_DIR/${variant}.json"

    if [ ! -f "$baseline_file" ]; then
        error "No baseline found for variant: $variant (run with --save-baseline first)"
    fi

    command cat "$baseline_file"
}

# Compare current metrics against baseline
compare_against_baseline() {
    local variant="$1"
    local current_size="$2"
    local current_time="$3"

    local baseline
    baseline=$(load_baseline "$variant")

    local baseline_size
    local baseline_time
    baseline_size=$(echo "$baseline" | grep -o '"size_bytes": [0-9]*' | awk '{print $2}')
    baseline_time=$(echo "$baseline" | grep -o '"build_time_seconds": [0-9]*' | awk '{print $2}')

    # Calculate differences
    local size_diff_bytes=$((current_size - baseline_size))
    local size_diff_mb
    size_diff_mb=$(awk "BEGIN {printf \"%.2f\", $size_diff_bytes / 1024 / 1024}")

    local time_diff_seconds=$((current_time - baseline_time))
    local time_diff_pct
    if [ "$baseline_time" -gt 0 ]; then
        time_diff_pct=$(awk "BEGIN {printf \"%.2f\", ($time_diff_seconds * 100.0) / $baseline_time}")
    else
        time_diff_pct="0.00"
    fi

    # Check for regressions
    local regression=false
    local regression_reasons=()

    # Size regression check
    if [ "$size_diff_bytes" -gt 0 ]; then
        local size_diff_mb_abs
        size_diff_mb_abs=${size_diff_mb#-}  # Remove negative sign if present
        if awk "BEGIN {exit !($size_diff_mb_abs > $SIZE_THRESHOLD_MB)}"; then
            regression=true
            regression_reasons+=("Image size increased by ${size_diff_mb}MB (threshold: ${SIZE_THRESHOLD_MB}MB)")
        fi
    fi

    # Time regression check
    if [ "$time_diff_seconds" -gt 0 ]; then
        local time_diff_pct_abs
        time_diff_pct_abs=${time_diff_pct#-}
        if awk "BEGIN {exit !($time_diff_pct_abs > $TIME_THRESHOLD_PCT)}"; then
            regression=true
            regression_reasons+=("Build time increased by ${time_diff_pct}% (threshold: ${TIME_THRESHOLD_PCT}%)")
        fi
    fi

    # Output results
    echo "=== Baseline Comparison for $variant ==="
    echo
    echo "Image Size:"
    echo "  Baseline:  $(bytes_to_human "$baseline_size")"
    echo "  Current:   $(bytes_to_human "$current_size")"
    echo "  Change:    ${size_diff_mb}MB"
    echo
    echo "Build Time:"
    echo "  Baseline:  ${baseline_time}s"
    echo "  Current:   ${current_time}s"
    echo "  Change:    ${time_diff_seconds}s (${time_diff_pct}%)"
    echo

    if [ "$regression" = true ]; then
        echo "⚠️  REGRESSION DETECTED:"
        for reason in "${regression_reasons[@]}"; do
            echo "  - $reason"
        done
        return 1
    else
        echo "✅ No regressions detected"
        return 0
    fi
}

# ============================================================================
# Output Functions
# ============================================================================

# Output metrics as JSON
output_json() {
    local variant="$1"
    local size_bytes="$2"
    local build_time="$3"

    command cat << EOF
{
  "variant": "$variant",
  "timestamp": "$(timestamp)",
  "size_bytes": $size_bytes,
  "size_human": "$(bytes_to_human "$size_bytes")",
  "build_time_seconds": $build_time
}
EOF
}

# Output metrics as human-readable text
output_text() {
    local variant="$1"
    local size_bytes="$2"
    local build_time="$3"

    echo "=== Build Metrics for $variant ==="
    echo "  Image Size:  $(bytes_to_human "$size_bytes") ($size_bytes bytes)"
    echo "  Build Time:  ${build_time}s"
    echo "  Timestamp:   $(timestamp)"
}

# ============================================================================
# Main Logic
# ============================================================================

# Parse arguments
variant=""
while [ $# -gt 0 ]; do
    case "$1" in
        --save-baseline)
            SAVE_BASELINE=true
            shift
            ;;
        --compare)
            COMPARE_BASELINE=true
            shift
            ;;
        --threshold-size)
            SIZE_THRESHOLD_MB="$2"
            shift 2
            ;;
        --threshold-time)
            TIME_THRESHOLD_PCT="$2"
            shift 2
            ;;
        --json)
            OUTPUT_JSON=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        -*)
            usage_error "Unknown option: $1"
            ;;
        *)
            if [ -n "$variant" ]; then
                usage_error "Multiple variants specified"
            fi
            variant="$1"
            shift
            ;;
    esac
done

# Validate arguments
if [ -z "$variant" ]; then
    usage_error "No variant specified"
fi

# Create metrics directory
mkdir -p "$METRICS_DIR"

# Get build arguments for variant
build_args=$(get_build_args_for_variant "$variant")

# Measure metrics
image_name="test:$variant"

# Check if image exists, if not build it
if ! docker image inspect "$image_name" >/dev/null 2>&1; then
    echo "Image not found, building $variant..." >&2
    build_time=$(measure_build_time "$variant" "$build_args")
else
    echo "Image already exists, measuring size only..." >&2
    build_time=0
fi

image_size=$(measure_image_size "$image_name")

# Save baseline if requested
if [ "$SAVE_BASELINE" = true ]; then
    save_baseline "$variant" "$image_size" "$build_time"
fi

# Compare against baseline if requested
if [ "$COMPARE_BASELINE" = true ]; then
    if ! compare_against_baseline "$variant" "$image_size" "$build_time"; then
        exit 1
    fi
fi

# Output metrics
if [ "$OUTPUT_JSON" = true ]; then
    output_json "$variant" "$image_size" "$build_time"
else
    output_text "$variant" "$image_size" "$build_time"
fi
