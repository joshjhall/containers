#!/usr/bin/env bash
# Output formatting for version check results
#
# Part of the version checking system (see bin/check-versions.sh).
# Contains functions for rendering results in text and JSON formats.

# Print results in JSON format
print_json_results() {
    local outdated=0
    local current=0
    local errors=0
    local manual=0

    # Build JSON array
    echo "{"
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"tools\": ["

    for i in "${!TOOLS[@]}"; do
        local tool="${TOOLS[$i]}"
        local cur_ver="${CURRENT_VERSIONS[$i]}"
        local latest="${LATEST_VERSIONS[$i]}"
        local status="${VERSION_STATUS[$i]}"
        local file="${VERSION_FILES[$i]}"

        # Update counters
        case "$status" in
            outdated) outdated=$((outdated + 1)) ;;
            current) current=$((current + 1)) ;;
            error) errors=$((errors + 1)) ;;
            manual) manual=$((manual + 1)) ;;
        esac

        # Print JSON object for this tool
        echo -n "    {"
        echo -n "\"tool\":\"$tool\","
        echo -n "\"current\":\"$cur_ver\","
        echo -n "\"latest\":\"$latest\","
        echo -n "\"file\":\"$file\","
        echo -n "\"status\":\"$status\""
        echo -n "}"

        # Add comma if not last item
        if [ "$i" -lt $((${#TOOLS[@]} - 1)) ]; then
            echo ","
        else
            echo ""
        fi
    done

    echo "  ],"
    echo "  \"summary\": {"
    echo "    \"total\": ${#TOOLS[@]},"
    echo "    \"current\": $current,"
    echo "    \"outdated\": $outdated,"
    echo "    \"errors\": $errors,"
    echo "    \"manual_check\": $manual"
    echo "  },"
    echo "  \"exit_code\": $([ $outdated -gt 0 ] && echo 1 || echo 0)"
    echo "}"
}

# Print results in text table format
print_results() {
    if [ "$OUTPUT_FORMAT" = "json" ]; then
        print_json_results
        return
    fi

    echo ""
    echo -e "${BLUE}=== Version Check Results ===${NC}"
    echo ""

    printf "%-20s %-15s %-15s %-20s %s\n" "Tool" "Current" "Latest" "File" "Status"
    printf "%-20s %-15s %-15s %-20s %s\n" "----" "-------" "------" "----" "------"

    local outdated=0
    local current=0
    local errors=0
    local manual=0

    for i in "${!TOOLS[@]}"; do
        local tool="${TOOLS[$i]}"
        local cur_ver="${CURRENT_VERSIONS[$i]}"
        local lat_ver="${LATEST_VERSIONS[$i]:-unknown}"
        local file="${VERSION_FILES[$i]}"
        local status="${VERSION_STATUS[$i]}"

        local status_color=""
        case "$status" in
            current)
                status_color="${GREEN}✓ current${NC}"
                current=$((current + 1))
                ;;
            outdated)
                status_color="${YELLOW}⚠ outdated${NC}"
                outdated=$((outdated + 1))
                ;;
            error)
                status_color="${RED}✗ error${NC}"
                errors=$((errors + 1))
                ;;
            *)
                if [ "$lat_ver" = "check manually" ]; then
                    status_color="${BLUE}ℹ manual${NC}"
                    manual=$((manual + 1))
                else
                    status_color="unchecked"
                fi
                ;;
        esac

        printf "%-20s %-15s %-15s %-20s %b\n" "$tool" "$cur_ver" "$lat_ver" "$file" "$status_color"
    done

    echo ""
    echo -e "${BLUE}Summary:${NC}"
    echo -e "  Current: ${GREEN}$current${NC}"
    echo -e "  Outdated: ${YELLOW}$outdated${NC}"
    echo -e "  Errors: ${RED}$errors${NC}"
    echo -e "  Manual Check: ${BLUE}$manual${NC}"

    if [ $outdated -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Note: $outdated tool(s) have newer versions available${NC}"
        exit 1
    fi
}
