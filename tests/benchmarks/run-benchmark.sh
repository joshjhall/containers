#!/bin/bash
# Performance Benchmark Runner
#
# Benchmarks container builds and collects metrics:
# - Build time
# - Image size
# - Layer count
# - Cache effectiveness
#
# Usage:
#   ./run-benchmark.sh                    # Run all benchmarks
#   ./run-benchmark.sh minimal            # Run specific variant
#   ./run-benchmark.sh --json             # Output as JSON
#   ./run-benchmark.sh --compare FILE     # Compare with baseline

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
OUTPUT_FORMAT="text"
COMPARE_FILE=""
SPECIFIC_VARIANT=""
NO_CACHE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)
            OUTPUT_FORMAT="json"
            shift
            ;;
        --compare)
            COMPARE_FILE="$2"
            shift 2
            ;;
        --no-cache)
            NO_CACHE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS] [VARIANT]"
            echo ""
            echo "Options:"
            echo "  --json           Output results as JSON"
            echo "  --compare FILE   Compare results with baseline file"
            echo "  --no-cache       Build without Docker cache"
            echo ""
            echo "Variants:"
            echo "  minimal          Base container only"
            echo "  python-dev       Python development environment"
            echo "  node-dev         Node.js development environment"
            echo "  full             Full polyglot environment"
            exit 0
            ;;
        *)
            SPECIFIC_VARIANT="$1"
            shift
            ;;
    esac
done

# Create results directory
mkdir -p "$RESULTS_DIR"

# Timestamp for this run
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_FILE="$RESULTS_DIR/benchmark-$TIMESTAMP.json"

# Get system info
get_system_info() {
    local cpus memory_gb docker_ver
    cpus=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
    memory_gb=$(free -g 2>/dev/null | awk '/Mem:/{print $2}')
    docker_ver=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')

    # Validate all numeric values
    if [ -z "$cpus" ] || ! [[ "$cpus" =~ ^[0-9]+$ ]]; then
        cpus=1
    fi
    if [ -z "$memory_gb" ] || ! [[ "$memory_gb" =~ ^[0-9]+$ ]]; then
        memory_gb=0
    fi
    if [ -z "$docker_ver" ]; then
        docker_ver="unknown"
    fi

    echo "{"
    echo "  \"hostname\": \"$(hostname)\","
    echo "  \"os\": \"$(uname -s)\","
    echo "  \"arch\": \"$(uname -m)\","
    echo "  \"docker_version\": \"$docker_ver\","
    echo "  \"cpus\": $cpus,"
    echo "  \"memory_gb\": $memory_gb"
    echo "}"
}

# Build a variant and collect metrics
benchmark_variant() {
    local name="$1"
    local build_args="$2"
    local image_tag="benchmark-$name:$TIMESTAMP"

    echo "Benchmarking: $name"

    local cache_flag=""
    if [ "$NO_CACHE" = "true" ]; then
        cache_flag="--no-cache"
    fi

    # Measure build time
    local start_time
    start_time=$(date +%s.%N)

    # Build the image
    local build_output
    local build_failed=false
    # shellcheck disable=SC2086  # Word splitting intentional for build_args
    build_output=$(docker build \
        -f "$PROJECT_ROOT/Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=benchmark \
        $build_args \
        $cache_flag \
        -t "$image_tag" \
        "$PROJECT_ROOT" 2>&1) || {
        echo "  Build failed!"
        build_failed=true
    }

    local end_time
    end_time=$(date +%s.%N)

    # Initialize all metrics with defaults
    local build_time="0"
    local image_size="0"
    local image_size_mb="0"
    local layer_count="0"
    local cached_steps=0
    local total_steps=0
    local cache_rate="0"

    # Only collect metrics if build succeeded
    if [ "$build_failed" = "false" ]; then
        # Use awk instead of bc for reliable numeric output
        # Validate inputs are numeric before calculation
        build_time=$(awk "BEGIN {printf \"%.2f\", $end_time - $start_time}" 2>/dev/null)
        # Ensure we have a valid number (not empty, not containing letters)
        if [ -z "$build_time" ] || ! [[ "$build_time" =~ ^[0-9.]+$ ]]; then
            build_time="0"
        fi

        # Get image size
        image_size=$(docker image inspect "$image_tag" --format '{{.Size}}' 2>/dev/null || echo "0")
        # Validate image_size is numeric
        if [ -z "$image_size" ] || ! [[ "$image_size" =~ ^[0-9]+$ ]]; then
            image_size="0"
        fi
        image_size_mb=$(awk "BEGIN {printf \"%.2f\", $image_size / 1048576}" 2>/dev/null)
        if [ -z "$image_size_mb" ] || ! [[ "$image_size_mb" =~ ^[0-9.]+$ ]]; then
            image_size_mb="0"
        fi

        # Get layer count (strip whitespace from wc output)
        layer_count=$(docker image history "$image_tag" --quiet 2>/dev/null | wc -l | tr -d ' ')
        # Validate layer_count is numeric
        if [ -z "$layer_count" ] || ! [[ "$layer_count" =~ ^[0-9]+$ ]]; then
            layer_count="0"
        fi

        # Check cache utilization
        total_steps=$(echo "$build_output" | grep -c "^#[0-9]" || echo 0)
        cached_steps=$(echo "$build_output" | grep -c "CACHED" || echo 0)
        # Validate step counts are numeric
        if [ -z "$total_steps" ] || ! [[ "$total_steps" =~ ^[0-9]+$ ]]; then
            total_steps=0
        fi
        if [ -z "$cached_steps" ] || ! [[ "$cached_steps" =~ ^[0-9]+$ ]]; then
            cached_steps=0
        fi
        if [ "$total_steps" -gt 0 ]; then
            cache_rate=$(awk "BEGIN {printf \"%.2f\", $cached_steps * 100 / $total_steps}" 2>/dev/null)
            if [ -z "$cache_rate" ] || ! [[ "$cache_rate" =~ ^[0-9.]+$ ]]; then
                cache_rate="0"
            fi
        fi
    fi

    # Output results
    if [ "$OUTPUT_FORMAT" = "json" ]; then
        echo "{"
        echo "  \"variant\": \"$name\","
        echo "  \"build_time_seconds\": $build_time,"
        echo "  \"image_size_bytes\": $image_size,"
        echo "  \"image_size_mb\": $image_size_mb,"
        echo "  \"layer_count\": $layer_count,"
        echo "  \"cache_hit_rate\": $cache_rate,"
        echo "  \"cached_steps\": $cached_steps,"
        echo "  \"total_steps\": $total_steps"
        echo "}"
    else
        printf "  Build time:     %.2fs\n" "$build_time"
        printf "  Image size:     %.2f MB\n" "$image_size_mb"
        printf "  Layers:         %d\n" "$layer_count"
        printf "  Cache hit rate: %.1f%% (%d/%d steps)\n" "$cache_rate" "$cached_steps" "$total_steps"
    fi

    # Clean up
    docker rmi "$image_tag" >/dev/null 2>&1 || true
}

# Define benchmark variants
declare -A VARIANTS=(
    ["minimal"]=""
    ["python-dev"]="--build-arg INCLUDE_PYTHON_DEV=true"
    ["node-dev"]="--build-arg INCLUDE_NODE_DEV=true"
    ["golang-dev"]="--build-arg INCLUDE_GOLANG_DEV=true"
    ["full"]="--build-arg INCLUDE_PYTHON_DEV=true --build-arg INCLUDE_NODE_DEV=true --build-arg INCLUDE_DEV_TOOLS=true --build-arg INCLUDE_DOCKER=true"
)

# Main execution
main() {
    if [ "$OUTPUT_FORMAT" = "json" ]; then
        echo "{"
        echo "  \"timestamp\": \"$TIMESTAMP\","
        echo "  \"system\": $(get_system_info),"
        echo "  \"results\": ["
    else
        echo "Container Build Benchmarks"
        echo "=========================="
        echo "Timestamp: $TIMESTAMP"
        echo ""
    fi

    local first=true

    if [ -n "$SPECIFIC_VARIANT" ]; then
        # Run specific variant
        if [ -z "${VARIANTS[$SPECIFIC_VARIANT]:-}" ] && [ "$SPECIFIC_VARIANT" != "minimal" ]; then
            echo "Unknown variant: $SPECIFIC_VARIANT"
            echo "Available: ${!VARIANTS[*]}"
            exit 1
        fi
        benchmark_variant "$SPECIFIC_VARIANT" "${VARIANTS[$SPECIFIC_VARIANT]:-}"
    else
        # Run all variants
        for variant in minimal python-dev node-dev golang-dev full; do
            if [ "$OUTPUT_FORMAT" = "json" ]; then
                [ "$first" = "false" ] && echo ","
                first=false
            fi
            benchmark_variant "$variant" "${VARIANTS[$variant]:-}"
            [ "$OUTPUT_FORMAT" = "text" ] && echo ""
        done
    fi

    if [ "$OUTPUT_FORMAT" = "json" ]; then
        echo "  ]"
        echo "}"
    fi

    # Compare with baseline if requested
    if [ -n "$COMPARE_FILE" ] && [ -f "$COMPARE_FILE" ]; then
        echo ""
        echo "Comparison with baseline:"
        "$SCRIPT_DIR/compare-results.sh" "$COMPARE_FILE" "$RESULTS_FILE"
    fi
}

main "$@"
