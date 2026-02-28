#!/usr/bin/env bash
# Pre-commit hook: enforce 'command' prefix on common shell commands.
# Prevents alias interference in interactive shells (grep→rg, cat→bat, etc.).
# Also deduplicates 'command command X' → 'command X'.
# Auto-fixes files in-place. Exit 1 = changes made, exit 0 = clean.
set -euo pipefail

# Target commands that are commonly aliased in interactive shells
CMDS="ls|cat|grep|sed|awk|head|tail|find|sort|wc|tr|cut|tee"

# Inline suppression marker — add to any line to skip enforcement
SUPPRESS_MARKER="enforce-command-prefix: off"

fixed=0

for file in "$@"; do
    [ -f "$file" ] || continue

    tmpfile=$(/usr/bin/mktemp "${file}.enforce.XXXXXX")
    changed=0
    in_heredoc=0
    heredoc_delim=""

    while IFS= read -r line || [ -n "$line" ]; do
        # --- Heredoc state machine ---
        if [ "$in_heredoc" -eq 1 ]; then
            # Check for heredoc end delimiter (may have leading tabs for <<-)
            if printf '%s\n' "$line" | /usr/bin/grep -qxE "[[:blank:]]*${heredoc_delim}"; then
                in_heredoc=0
                heredoc_delim=""
            fi
            printf '%s\n' "$line"
            continue
        fi

        # Detect heredoc start: <<[-]?['"]?DELIM['"]?
        # Capture the delimiter, stripping optional quotes and backslash
        if printf '%s\n' "$line" | /usr/bin/grep -qE '<<-?[[:blank:]]*\\?["'"'"']?[A-Za-z_][A-Za-z_0-9]*["'"'"']?'; then
            heredoc_delim=$(printf '%s\n' "$line" | /usr/bin/sed -nE "s/.*<<-?[[:blank:]]*\\\\?[\"']?([A-Za-z_][A-Za-z_0-9]*)[\"']?.*/\1/p" | /usr/bin/head -n1)
            if [ -n "$heredoc_delim" ]; then
                in_heredoc=1
            fi
        fi

        # --- Skip lines that should not be modified ---
        # Skip comment lines (leading whitespace + #)
        if printf '%s\n' "$line" | /usr/bin/grep -qE '^[[:blank:]]*#'; then
            printf '%s\n' "$line"
            continue
        fi

        # Skip alias definitions
        if printf '%s\n' "$line" | /usr/bin/grep -qE '^[[:blank:]]*alias[[:blank:]]'; then
            printf '%s\n' "$line"
            continue
        fi

        # Skip lines with inline suppression marker
        case "$line" in
            *"$SUPPRESS_MARKER"*) printf '%s\n' "$line"; continue ;;
        esac

        # --- Apply fixes ---
        newline="$line"

        # 1. Deduplicate: 'command command ' → 'command '
        #    Handle multiple levels (command command command → command)
        while printf '%s\n' "$newline" | /usr/bin/grep -qE '(^|[^A-Za-z_-])command[[:blank:]]+command[[:blank:]]'; do
            newline=$(printf '%s\n' "$newline" | /usr/bin/sed -E 's/(^|[^A-Za-z_-])command[[:blank:]]+command[[:blank:]]/\1command /g')
        done

        # 2. Start of line: bare command at beginning (after optional whitespace)
        newline=$(printf '%s\n' "$newline" | /usr/bin/sed -E "s/^([[:blank:]]*)(${CMDS})([[:blank:]])/\1command \2\3/")
        # Also handle command at end of line (e.g., standalone 'ls')
        newline=$(printf '%s\n' "$newline" | /usr/bin/sed -E "s/^([[:blank:]]*)(${CMDS})$/\1command \2/")

        # 3. After pipe: | cmd
        newline=$(printf '%s\n' "$newline" | /usr/bin/sed -E "s/(\|[[:blank:]]*)(${CMDS})([[:blank:]])/\1command \2\3/g")
        newline=$(printf '%s\n' "$newline" | /usr/bin/sed -E "s/(\|[[:blank:]]*)(${CMDS})$/\1command \2/g")

        # 4. After && || ;
        newline=$(printf '%s\n' "$newline" | /usr/bin/sed -E "s/((&&|\|\||;)[[:blank:]]*)(${CMDS})([[:blank:]])/\1command \3\4/g")
        newline=$(printf '%s\n' "$newline" | /usr/bin/sed -E "s/((&&|\|\||;)[[:blank:]]*)(${CMDS})$/\1command \3/g")

        # 5. After $(: subshell command substitution
        newline=$(printf '%s\n' "$newline" | /usr/bin/sed -E "s/(\\\$\([[:blank:]]*)(${CMDS})([[:blank:]])/\1command \2\3/g")
        newline=$(printf '%s\n' "$newline" | /usr/bin/sed -E "s/(\\\$\([[:blank:]]*)(${CMDS})$/\1command \2/g")

        # 6. Clean up any 'command command' we may have introduced
        while printf '%s\n' "$newline" | /usr/bin/grep -qE '(^|[^A-Za-z_-])command[[:blank:]]+command[[:blank:]]'; do
            newline=$(printf '%s\n' "$newline" | /usr/bin/sed -E 's/(^|[^A-Za-z_-])command[[:blank:]]+command[[:blank:]]/\1command /g')
        done

        if [ "$newline" != "$line" ]; then
            changed=1
        fi

        printf '%s\n' "$newline"
    done < "$file" > "$tmpfile"

    if [ "$changed" -eq 1 ]; then
        chmod --reference="$file" "$tmpfile" 2>/dev/null || true
        /usr/bin/mv "$tmpfile" "$file"
        printf 'Fixed: %s\n' "$file"
        fixed=1
    else
        /usr/bin/rm -f "$tmpfile"
    fi
done

exit "$fixed"
