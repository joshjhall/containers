#!/usr/bin/env bash
# check-patterns-coverage.sh — Coverage report for patterns.sh vs contract.md
#
# Parses all check-* domain contract.md and patterns.sh files to report
# what percentage of each domain's categories are covered by deterministic
# pre-scan (patterns.sh) vs requiring LLM analysis.
#
# Usage: check-patterns-coverage.sh [OPTIONS]
# Options:
#   --json    Output results in JSON format
#   --help    Show this help message
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$BIN_DIR")"
SKILLS_DIR="${PROJECT_ROOT}/lib/features/templates/claude/skills"

OUTPUT_FORMAT="text"

while [[ $# -gt 0 ]]; do
    case $1 in
        --json)
            OUTPUT_FORMAT="json"
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Analyze patterns.sh coverage against contract.md categories"
            echo ""
            echo "Options:"
            echo "  --json    Output results in JSON format"
            echo "  --help    Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# --- Parse contract.md categories ---
# Returns: slug|method (one per line)
# Handles two table formats:
#   Format A: | Category | Certainty | Method | Confidence |
#   Format B: | Slug | Certainty Expectation | Severity Range |
parse_contract_categories() {
    local contract="$1"
    if [[ ! -f "$contract" ]]; then
        return
    fi

    local in_table=false
    local format=""

    while IFS= read -r line; do
        # Detect table header to determine format
        if [[ "$line" =~ ^[[:space:]]*\|.*Method ]]; then
            format="A"
            in_table=true
            continue
        elif [[ "$line" =~ ^[[:space:]]*\|.*Certainty\ Expectation ]]; then
            format="B"
            in_table=true
            continue
        fi

        # Skip separator lines
        if [[ "$line" =~ ^[[:space:]]*\|[[:space:]-]+\|[[:space:]-]+\| ]]; then
            continue
        fi

        # End of table
        if $in_table && [[ ! "$line" =~ ^[[:space:]]*\| ]]; then
            in_table=false
            continue
        fi

        if ! $in_table; then
            continue
        fi

        # Extract category slug (backtick-quoted in first column)
        local slug
        slug=$(/usr/bin/printf '%s' "$line" | /usr/bin/sed -n 's/^[[:space:]]*|[[:space:]]*`\([a-z][-a-z]*\)`.*/\1/p')
        if [[ -z "$slug" ]]; then
            continue
        fi

        # Extract method
        local method="unknown"
        if [[ "$format" == "A" ]]; then
            # Format A: method is in the third column
            method=$(/usr/bin/printf '%s' "$line" | /usr/bin/awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); print $4}')
        elif [[ "$format" == "B" ]]; then
            # Format B: method from parenthetical in second column
            local certainty_col
            certainty_col=$(/usr/bin/printf '%s' "$line" | /usr/bin/awk -F'|' '{print $3}')
            if /usr/bin/printf '%s' "$certainty_col" | /usr/bin/grep -qi 'pre-scan'; then
                method="deterministic"
            elif /usr/bin/printf '%s' "$certainty_col" | /usr/bin/grep -qi 'deterministic'; then
                method="deterministic"
            elif /usr/bin/printf '%s' "$certainty_col" | /usr/bin/grep -qi 'pattern match'; then
                method="deterministic"
            elif /usr/bin/printf '%s' "$certainty_col" | /usr/bin/grep -qi 'file missing'; then
                method="deterministic"
            elif /usr/bin/printf '%s' "$certainty_col" | /usr/bin/grep -qi 'heuristic'; then
                method="heuristic"
            elif /usr/bin/printf '%s' "$certainty_col" | /usr/bin/grep -qi 'LLM'; then
                method="llm"
            fi

            # Some entries have dual: "HIGH (pre-scan) or MEDIUM (LLM)"
            # Use the highest-capability method (pre-scan wins)
            if /usr/bin/printf '%s' "$certainty_col" | /usr/bin/grep -qi 'pre-scan\|deterministic\|pattern match\|file missing'; then
                method="deterministic"
            fi
        fi

        /usr/bin/printf '%s|%s\n' "$slug" "$method"
    done < "$contract"
}

# --- Check if a category is implemented in patterns.sh ---
# Returns 0 (true) if the category slug appears as a quoted string in the file
is_category_in_patterns() {
    local patterns="$1"
    local slug="$2"
    if [[ ! -f "$patterns" ]]; then
        return 1
    fi
    /usr/bin/grep -qF "\"${slug}\"" "$patterns" 2>/dev/null
}

# --- Main ---

# Collect all check-* domains
domains=()
for dir in "${SKILLS_DIR}"/check-*/; do
    if [[ -d "$dir" ]]; then
        domains+=("$(/usr/bin/basename "$dir")")
    fi
done

# Process each domain
declare -A domain_total
declare -A domain_covered
declare -A domain_det
declare -A domain_heur
declare -A domain_llm
declare -A domain_details  # JSON array for --json mode

total_categories=0
total_covered=0
total_det=0
total_heur=0
total_llm=0

for domain in "${domains[@]}"; do
    contract="${SKILLS_DIR}/${domain}/contract.md"
    patterns="${SKILLS_DIR}/${domain}/patterns.sh"

    # Parse contract categories
    contract_cats=$(parse_contract_categories "$contract")

    # Count per domain
    det_count=0
    heur_count=0
    llm_count=0
    covered_count=0
    cat_count=0
    details_json="["

    while IFS='|' read -r slug method; do
        [[ -z "$slug" ]] && continue
        cat_count=$((cat_count + 1))

        # Check if patterns.sh covers this category
        local_covered="false"
        if is_category_in_patterns "$patterns" "$slug"; then
            local_covered="true"
            covered_count=$((covered_count + 1))
        fi

        # Classify method
        case "$method" in
            deterministic) det_count=$((det_count + 1)) ;;
            heuristic)     heur_count=$((heur_count + 1)) ;;
            llm)           llm_count=$((llm_count + 1)) ;;
            *)             det_count=$((det_count + 1)) ;;  # default to deterministic
        esac

        # Build detail line
        if [[ "$details_json" != "[" ]]; then
            details_json="${details_json},"
        fi
        details_json="${details_json}{\"slug\":\"${slug}\",\"method\":\"${method}\",\"covered\":${local_covered}}"
    done <<< "$contract_cats"

    details_json="${details_json}]"

    domain_total[$domain]=$cat_count
    domain_covered[$domain]=$covered_count
    domain_det[$domain]=$det_count
    domain_heur[$domain]=$heur_count
    domain_llm[$domain]=$llm_count
    domain_details[$domain]=$details_json

    total_categories=$((total_categories + cat_count))
    total_covered=$((total_covered + covered_count))
    total_det=$((total_det + det_count))
    total_heur=$((total_heur + heur_count))
    total_llm=$((total_llm + llm_count))
done

# --- Output ---

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    /usr/bin/printf '{\n  "domains": {\n'
    first=true
    for domain in "${domains[@]}"; do
        if ! $first; then
            /usr/bin/printf ',\n'
        fi
        first=false
        total=${domain_total[$domain]}
        covered=${domain_covered[$domain]}
        pct=0
        if [[ $total -gt 0 ]]; then
            pct=$((covered * 100 / total))
        fi
        /usr/bin/printf '    "%s": {\n' "$domain"
        /usr/bin/printf '      "total": %d,\n' "$total"
        /usr/bin/printf '      "covered": %d,\n' "$covered"
        /usr/bin/printf '      "coverage_pct": %d,\n' "$pct"
        /usr/bin/printf '      "deterministic": %d,\n' "${domain_det[$domain]}"
        /usr/bin/printf '      "heuristic": %d,\n' "${domain_heur[$domain]}"
        /usr/bin/printf '      "llm": %d,\n' "${domain_llm[$domain]}"
        /usr/bin/printf '      "categories": %s\n' "${domain_details[$domain]}"
        /usr/bin/printf '    }'
    done
    total_pct=0
    if [[ $total_categories -gt 0 ]]; then
        total_pct=$((total_covered * 100 / total_categories))
    fi
    /usr/bin/printf '\n  },\n'
    /usr/bin/printf '  "summary": {\n'
    /usr/bin/printf '    "total_categories": %d,\n' "$total_categories"
    /usr/bin/printf '    "total_covered": %d,\n' "$total_covered"
    /usr/bin/printf '    "coverage_pct": %d,\n' "$total_pct"
    /usr/bin/printf '    "deterministic": %d,\n' "$total_det"
    /usr/bin/printf '    "heuristic": %d,\n' "$total_heur"
    /usr/bin/printf '    "llm": %d\n' "$total_llm"
    /usr/bin/printf '  }\n}\n'
else
    # Text table output
    /usr/bin/printf '%-28s  %s  %s  %s  %s\n' "Domain" "Coverage" "Det." "Heur" "LLM"
    /usr/bin/printf '%-28s  %s  %s  %s  %s\n' "---" "---" "---" "---" "---"

    for domain in "${domains[@]}"; do
        total=${domain_total[$domain]}
        covered=${domain_covered[$domain]}
        pct=0
        if [[ $total -gt 0 ]]; then
            pct=$((covered * 100 / total))
        fi
        /usr/bin/printf '%-28s  %d/%d %3d%%  %4d  %4d  %3d\n' \
            "$domain" "$covered" "$total" "$pct" \
            "${domain_det[$domain]}" "${domain_heur[$domain]}" "${domain_llm[$domain]}"
    done

    /usr/bin/printf '\n'
    total_pct=0
    if [[ $total_categories -gt 0 ]]; then
        total_pct=$((total_covered * 100 / total_categories))
    fi
    /usr/bin/printf 'TOTAL: %d/%d (%d%%) deterministic coverage\n' \
        "$total_covered" "$total_categories" "$total_pct"
    /usr/bin/printf '  Deterministic categories: %d\n' "$total_det"
    /usr/bin/printf '  Heuristic categories:     %d\n' "$total_heur"
    /usr/bin/printf '  LLM-only categories:      %d\n' "$total_llm"

    # Show uncovered categories
    uncovered=""
    for domain in "${domains[@]}"; do
        contract="${SKILLS_DIR}/${domain}/contract.md"
        patterns="${SKILLS_DIR}/${domain}/patterns.sh"
        contract_cats=$(parse_contract_categories "$contract")

        while IFS='|' read -r slug method; do
            [[ -z "$slug" ]] && continue
            if ! is_category_in_patterns "$patterns" "$slug"; then
                reason="inherently LLM"
                if [[ "$method" == "deterministic" ]]; then
                    reason="deterministic-possible"
                elif [[ "$method" == "heuristic" ]]; then
                    reason="heuristic"
                fi
                uncovered="${uncovered}\n  ${domain}: ${slug} (${reason})"
            fi
        done <<< "$contract_cats"
    done

    if [[ -n "$uncovered" ]]; then
        /usr/bin/printf '\nUncovered categories:%b\n' "$uncovered"
    fi
fi
