#!/usr/bin/env bash
# Output formatting for version check results
#
# Part of the version checking system (see bin/check-versions.sh).
# Contains functions for rendering results in text and JSON formats.
#
# Exit codes (both formats):
#   0  every tool checked and current
#   1  one or more tools outdated
#   3  one or more tools UNCHECKED — registered in check-versions.sh but with
#      no checker case in main()'s dispatch. Takes precedence over 1: an
#      unchecked tool never reaches "outdated", so it would otherwise stall at
#      its pin forever with nothing downstream noticing (#991, cf. #781).
#   A tool whose latest is "check manually" is a deliberate manual status and
#   does not count as unchecked.

CHECK_EXIT_OUTDATED=1
CHECK_EXIT_UNCHECKED=3

# is_unchecked STATUS LATEST — true for a tool no checker ever ran against.
is_unchecked() {
    [ "$1" = "unchecked" ] && [ "$2" != "check manually" ]
}

# check_exit_code OUTDATED UNCHECKED — the process exit code for these counts.
check_exit_code() {
    if [ "$2" -gt 0 ]; then
        echo "$CHECK_EXIT_UNCHECKED"
    elif [ "$1" -gt 0 ]; then
        echo "$CHECK_EXIT_OUTDATED"
    else
        echo 0
    fi
}

# Print results in JSON format
print_json_results() {
    local outdated=0
    local current=0
    local errors=0
    local manual=0
    local unchecked=0
    local unchecked_tools=()

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
        if is_unchecked "$status" "$latest"; then
            unchecked=$((unchecked + 1))
            unchecked_tools+=("$tool")
        fi

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
    echo "    \"manual_check\": $manual,"
    echo "    \"unchecked\": $unchecked"
    echo "  },"
    # Tool names are simple identifiers from add_tool, so plain quoting is safe.
    local names="" t
    for t in "${unchecked_tools[@]}"; do
        names+="${names:+,}\"$t\""
    done
    echo "  \"unchecked_tools\": [$names],"
    local rc
    rc=$(check_exit_code "$outdated" "$unchecked")
    echo "  \"exit_code\": $rc"
    echo "}"
    return "$rc"
}

# Print results in text table format
print_results() {
    if [ "$OUTPUT_FORMAT" = "json" ]; then
        local rc=0
        print_json_results || rc=$?
        exit "$rc"
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
    local unchecked=0
    local unchecked_tools=()

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
                    status_color="${RED}✗ unchecked${NC}"
                fi
                ;;
        esac

        if is_unchecked "$status" "${LATEST_VERSIONS[$i]}"; then
            unchecked=$((unchecked + 1))
            unchecked_tools+=("$tool")
        fi

        printf "%-20s %-15s %-15s %-20s %b\n" "$tool" "$cur_ver" "$lat_ver" "$file" "$status_color"
    done

    echo ""
    echo -e "${BLUE}Summary:${NC}"
    echo -e "  Current: ${GREEN}$current${NC}"
    echo -e "  Outdated: ${YELLOW}$outdated${NC}"
    echo -e "  Errors: ${RED}$errors${NC}"
    echo -e "  Manual Check: ${BLUE}$manual${NC}"
    echo -e "  Unchecked: ${RED}$unchecked${NC}"

    if [ $outdated -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Note: $outdated tool(s) have newer versions available${NC}"
    fi
    if [ $unchecked -gt 0 ]; then
        echo ""
        echo -e "${RED}Error: $unchecked tool(s) have no checker case in bin/check-versions.sh: ${unchecked_tools[*]}${NC}"
        echo -e "${RED}       They will stay at their current pins until a case is added (#991).${NC}"
    fi

    local rc
    rc=$(check_exit_code "$outdated" "$unchecked")
    [ "$rc" -eq 0 ] || exit "$rc"
}
