#!/usr/bin/env bash
# Pre-commit hook: enforce 'command' prefix on common shell commands.
# Prevents alias interference in interactive shells (grep→rg, cat→bat, etc.).
# Also deduplicates 'command command X' → 'command X'.
# Auto-fixes files in-place. Exit 1 = changes made, exit 0 = clean,
# exit 2 = a file could not be processed (the run stops there).
#
# Fixes are written to a tmpfile beside the original and mv'd over it, so an
# interrupted run never leaves a truncated script (#1439). The mode is copied
# across, so read-only files are fixed and stay read-only (#1440); only a file
# in an unwritable directory exits 2. Symlink operands
# are skipped: git tracks the link, not its target's bytes, and the target
# may lie outside the repo.
#
# Each file is processed by a single awk program (one process per file, not
# ~15 per line — #1424). The awk rules mirror the original grep/sed pipeline
# byte-for-byte; see the comments inside the program for the sed semantics
# each helper reproduces.
set -euo pipefail

# Target commands that are commonly aliased in interactive shells
CMDS="ls|cat|grep|sed|awk|head|tail|find|sort|wc|tr|cut|tee"

# Inline suppression marker — add to any line to skip enforcement
SUPPRESS_MARKER="enforce-command-prefix: off"

# Portable awk (mawk/BWK/gawk): no gensub, no backreferences, [ \t] instead of
# [[:blank:]]. Exits 1 if any line changed, 0 if clean.
read -r -d '' ENFORCE_AWK <<'AWK' || true
# ins(s, re, g): sed 's/(PREFIX)(CMD)(SUFFIX)/\1command \2\3/[g]'. None of the
# prefixes (blanks, |, &&, ||, ;, $( ) contain a lowercase letter, so the
# command name starts at the first [a-z] inside the match. With g, scanning
# resumes after each match, as sed's /g does.
function ins(s, re, g,    out, rs, rl, m, p) {
    out = ""
    while (match(s, re)) {
        rs = RSTART; rl = RLENGTH
        m = substr(s, rs, rl)
        p = match(m, /[a-z]/)
        out = out substr(s, 1, rs - 1) substr(m, 1, p - 1) "command " substr(m, p)
        s = substr(s, rs + rl)
        if (!g) break
    }
    return out s
}

# dedup_once(s): one pass of
#   sed -E 's/(^|[^A-Za-z_-])command[[:blank:]]+command[[:blank:]]/\1command /g'
# The ^ branch can only match at the very start of the line: sed's /g rescans
# the remainder with REG_NOTBOL.
function dedup_once(s,    out, bol, rs, rl) {
    out = ""; bol = 1
    while (1) {
        if (bol && match(s, /^command[ \t]+command[ \t]/)) {
            out = out "command "
            s = substr(s, RLENGTH + 1)
        } else if (match(s, /[^A-Za-z_-]command[ \t]+command[ \t]/)) {
            rs = RSTART; rl = RLENGTH
            out = out substr(s, 1, rs) "command "
            s = substr(s, rs + rl)
        } else {
            break
        }
        bol = 0
    }
    return out s
}

function dedup(s) {
    while (s ~ /(^|[^A-Za-z_-])command[ \t]+command[ \t]/)
        s = dedup_once(s)
    return s
}

# Heredoc delimiter, as sed -nE 's/.*<<-?[[:blank:]]*\\?["']?(IDENT)["']?.*/\1/p'
# extracts it: greedy .* means the LAST '<<' on the line that can start a
# match wins. Returns "" if the line has no heredoc start.
function heredoc_delim(s,    i, t) {
    if (s !~ /<<-?[ \t]*\\?["']?[A-Za-z_]/) return ""
    for (i = length(s) - 1; i >= 1; i--) {
        t = substr(s, i)
        if (t ~ /^<<-?[ \t]*\\?["']?[A-Za-z_]/) {
            t = substr(t, 3)
            sub(/^-/, "", t)
            sub(/^[ \t]*/, "", t)
            sub(/^\\/, "", t)
            sub(/^["']/, "", t)
            match(t, /^[A-Za-z_][A-Za-z_0-9]*/)
            return substr(t, 1, RLENGTH)
        }
    }
    return ""
}

BEGIN {
    C = "(" cmds ")"
    B = "[ \t]"
    r_start = "^" B "*" C B;        r_start_eol = "^" B "*" C "$"
    r_pipe = "[|]" B "*" C B;       r_pipe_eol = "[|]" B "*" C "$"
    r_list = "(&&|[|][|]|;)" B "*" C B
    r_list_eol = "(&&|[|][|]|;)" B "*" C "$"
    r_subst = "[$][(]" B "*" C B;   r_subst_eol = "[$][(]" B "*" C "$"
    in_heredoc = 0; changed = 0
}

{
    line = $0

    # --- Heredoc state machine ---
    if (in_heredoc) {
        # End delimiter (may have leading blanks for <<-)
        if (line ~ ("^[ \t]*" delim "$")) { in_heredoc = 0; delim = "" }
        print line
        next
    }

    # Heredoc start is detected before the skips below, so a heredoc opened
    # on a comment or alias line still suppresses its body.
    d = heredoc_delim(line)
    if (d != "") { delim = d; in_heredoc = 1 }

    # --- Skip lines that should not be modified ---
    if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*alias[ \t]/ || index(line, marker)) {
        print line
        next
    }

    # --- Apply fixes (same order as the original sed pipeline) ---
    new = dedup(line)
    new = ins(new, r_start, 0);  new = ins(new, r_start_eol, 0)
    new = ins(new, r_pipe, 1);   new = ins(new, r_pipe_eol, 1)
    new = ins(new, r_list, 1);   new = ins(new, r_list_eol, 1)
    new = ins(new, r_subst, 1);  new = ins(new, r_subst_eol, 1)
    new = dedup(new)

    if (new != line) changed = 1
    print new
}

END { exit changed }
AWK

fixed=0

# Remove an in-flight tmpfile if the run is interrupted. The deliberate
# keep-the-tmpfile exits clear it first.
tmpfile=""
trap '[ -z "$tmpfile" ] || /usr/bin/rm -f "$tmpfile"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# keep_and_fail FILE: report that FILE could not be replaced and exit 2,
# leaving the tmpfile (the only copy of the fixed content) in place.
keep_and_fail() {
    printf 'enforce-command-prefix: could not write %s; fixed content kept at %s\n' \
        "$1" "$tmpfile" >&2
    tmpfile=""
    exit 2
}

for file in "$@"; do
    [ -f "$file" ] || continue
    [ -L "$file" ] && continue

    # Keep awk from reading an operand like 'a=b.sh' as a variable assignment,
    # and mktemp/chmod/mv from reading '-x.sh' as an option.
    case "$file" in
        /*) path="$file" ;;
        *) path="./$file" ;;
    esac

    # An unwritable directory is the one place a fix cannot land; without the
    # explicit exit 2, set -e would exit with mktemp's 1, which means "fixed".
    tmpfile=$(/usr/bin/mktemp "${path}.enforce.XXXXXX") || {
        printf 'enforce-command-prefix: could not create a tmpfile beside %s\n' "$file" >&2
        exit 2
    }
    rc=0
    /usr/bin/awk -v cmds="$CMDS" -v marker="$SUPPRESS_MARKER" \
        "$ENFORCE_AWK" "$path" >"$tmpfile" || rc=$?

    case "$rc" in
        0)
            /usr/bin/rm -f "$tmpfile"
            tmpfile=""
            ;;
        1)
            # Copy the mode onto the 0600 tmpfile, then mv it over the
            # original: rename is atomic, so an interrupt leaves either the
            # old file or the new one, never a truncated one (#1439). The
            # mode comes from GNU `stat -c` or BSD `stat -f` (no GNU-only
            # `chmod --reference`, #1429); if neither works, stop rather than
            # ship a 0600 script. The owner becomes the hook runner and hard
            # links are split, which is fine for tracked scripts.
            mode=$(command stat -c '%a' "$path" 2>/dev/null ||
                command stat -f '%Lp' "$path" 2>/dev/null) || mode=""
            # GNU %a drops leading zeros (mode 044 prints "44"), so accept
            # any non-empty run of octal digits.
            case "$mode" in
                '' | *[!0-7]*)
                    printf 'enforce-command-prefix: could not read the mode of %s; left unchanged\n' \
                        "$file" >&2
                    exit 2
                    ;;
            esac
            # Rename needs write access to the directory, not the file, so a
            # read-only (e.g. 444/555) file is fixed too and keeps its mode
            # (#1440).
            command chmod "$mode" "$tmpfile" || keep_and_fail "$file"
            command mv -f "$tmpfile" "$path" || keep_and_fail "$file"
            tmpfile=""
            printf 'Fixed: %s\n' "$file"
            fixed=1
            ;;
        *)
            /usr/bin/rm -f "$tmpfile"
            tmpfile=""
            printf 'enforce-command-prefix: awk failed (exit %s) on %s\n' "$rc" "$file" >&2
            exit 2
            ;;
    esac
done

exit "$fixed"
