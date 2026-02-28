# ----------------------------------------------------------------------------
# Cron Aliases and Functions
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi

# ----------------------------------------------------------------------------
# Cron Aliases
# ----------------------------------------------------------------------------

# List user's crontab
alias cron-list='crontab -l 2>/dev/null || echo "No crontab for current user"'

# Edit user's crontab
alias cron-edit='crontab -e'

# List system cron jobs
alias cron-system='ls -la /etc/cron.d/ 2>/dev/null'

# Show cron daemon status
alias cron-status='pgrep -x cron > /dev/null && echo "cron: running" || echo "cron: not running"'

# ----------------------------------------------------------------------------
# cron-logs - View recent cron log entries
#
# Arguments:
#   $1 - Number of lines to show (default: 20)
# ----------------------------------------------------------------------------
cron-logs() {
    local lines="${1:-20}"
    if [ -f /var/log/syslog ]; then
        command grep -i cron /var/log/syslog | tail -n "$lines"
    elif [ -f /var/log/cron.log ]; then
        tail -n "$lines" /var/log/cron.log
    else
        echo "No cron logs found"
        echo "Try: journalctl -u cron (if using systemd)"
    fi
}

# Note: We leave set +u and set +e in place for interactive shells
