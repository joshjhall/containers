#!/bin/bash
# Compare benchmark results with baseline
#
# Usage:
#   ./compare-results.sh baseline.json current.json

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <baseline.json> <current.json>"
    exit 1
fi

BASELINE="$1"
CURRENT="$2"

if [ ! -f "$BASELINE" ]; then
    echo "Error: Baseline file not found: $BASELINE"
    exit 1
fi

if [ ! -f "$CURRENT" ]; then
    echo "Error: Current file not found: $CURRENT"
    exit 1
fi

# Check if jq is available
if ! command -v jq &>/dev/null; then
    echo "Error: jq is required for comparison"
    echo "Install with: apt-get install jq"
    exit 1
fi

echo "Benchmark Comparison"
echo "===================="
echo ""
echo "Baseline: $BASELINE"
echo "Current:  $CURRENT"
echo ""

# Get variants from current results
variants=$(jq -r '.results[].variant' "$CURRENT" 2>/dev/null || echo "")

if [ -z "$variants" ]; then
    echo "Error: Could not parse results from $CURRENT"
    exit 1
fi

printf "%-15s %12s %12s %10s\n" "Variant" "Baseline" "Current" "Change"
printf "%-15s %12s %12s %10s\n" "-------" "--------" "-------" "------"

for variant in $variants; do
    # Get build times
    baseline_time=$(jq -r ".results[] | select(.variant==\"$variant\") | .build_time_seconds" "$BASELINE" 2>/dev/null || echo "0")
    current_time=$(jq -r ".results[] | select(.variant==\"$variant\") | .build_time_seconds" "$CURRENT" 2>/dev/null || echo "0")

    # Calculate change
    if [ "$baseline_time" != "0" ] && [ "$baseline_time" != "null" ]; then
        change=$(echo "scale=1; ($current_time - $baseline_time) * 100 / $baseline_time" | bc)
        if (( $(echo "$change > 0" | bc -l) )); then
            change="+${change}%"
        else
            change="${change}%"
        fi
    else
        change="N/A"
    fi

    printf "%-15s %10.1fs %10.1fs %10s\n" "$variant" "$baseline_time" "$current_time" "$change"
done

echo ""
echo "Image Sizes:"
printf "%-15s %12s %12s %10s\n" "Variant" "Baseline" "Current" "Change"
printf "%-15s %12s %12s %10s\n" "-------" "--------" "-------" "------"

for variant in $variants; do
    baseline_size=$(jq -r ".results[] | select(.variant==\"$variant\") | .image_size_mb" "$BASELINE" 2>/dev/null || echo "0")
    current_size=$(jq -r ".results[] | select(.variant==\"$variant\") | .image_size_mb" "$CURRENT" 2>/dev/null || echo "0")

    if [ "$baseline_size" != "0" ] && [ "$baseline_size" != "null" ]; then
        change=$(echo "scale=1; ($current_size - $baseline_size) * 100 / $baseline_size" | bc)
        if (( $(echo "$change > 0" | bc -l) )); then
            change="+${change}%"
        else
            change="${change}%"
        fi
    else
        change="N/A"
    fi

    printf "%-15s %10.1f MB %10.1f MB %10s\n" "$variant" "$baseline_size" "$current_size" "$change"
done

echo ""

# Summary
echo "Summary:"
total_baseline=$(jq '[.results[].build_time_seconds] | add' "$BASELINE" 2>/dev/null || echo "0")
total_current=$(jq '[.results[].build_time_seconds] | add' "$CURRENT" 2>/dev/null || echo "0")

if [ "$total_baseline" != "0" ] && [ "$total_baseline" != "null" ]; then
    total_change=$(echo "scale=1; ($total_current - $total_baseline) * 100 / $total_baseline" | bc)
    if (( $(echo "$total_change > 0" | bc -l) )); then
        echo "  Total build time change: +${total_change}%"
    else
        echo "  Total build time change: ${total_change}%"
    fi
else
    echo "  Total build time: ${total_current}s"
fi
