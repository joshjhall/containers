# shellcheck disable=SC2164
# ----------------------------------------------------------------------------
# Cloudflare Tools Configuration and Helpers
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
# Wrangler Aliases - Cloudflare Workers CLI shortcuts
# ----------------------------------------------------------------------------
alias wr='wrangler'
alias wrd='wrangler dev'
alias wrp='wrangler publish'         # Deprecated, use deploy
alias wrdeploy='wrangler deploy'
alias wrlogs='wrangler tail'
alias wrlogin='wrangler login'
alias wrwhoami='wrangler whoami'

# ----------------------------------------------------------------------------
# Cloudflared Aliases - Tunnel management shortcuts
# ----------------------------------------------------------------------------
alias cft='cloudflared tunnel'
alias cftlist='cloudflared tunnel list'
alias cftrun='cloudflared tunnel run'
alias cftcreate='cloudflared tunnel create'
alias cftdelete='cloudflared tunnel delete'
alias cftroute='cloudflared tunnel route'

# ----------------------------------------------------------------------------
# wrangler-init - Initialize a new Workers project
#
# Arguments:
#   $1 - Project name (default: my-worker)
#   $2 - Template name (optional)
#
# Examples:
#   wrangler-init my-api
#   wrangler-init my-site "https://github.com/cloudflare/worker-template"
# ----------------------------------------------------------------------------
wrangler-init() {
    local project_name="${1:-my-worker}"
    local template="${2:-}"

    if [ -n "$template" ]; then
        wrangler init "$project_name" --template "$template"
    else
        wrangler init "$project_name"
    fi
    cd "$project_name"
}

# ----------------------------------------------------------------------------
# wrangler-deploy - Deploy current project to Cloudflare Workers
#
# Requires:
#   wrangler.toml in current directory
# ----------------------------------------------------------------------------
wrangler-deploy() {
    if [ ! -f wrangler.toml ]; then
        echo "Error: No wrangler.toml found in current directory"
        return 1
    fi
    wrangler deploy
}

# ----------------------------------------------------------------------------
# tunnel-quick - Start a quick public tunnel to localhost
#
# Arguments:
#   $1 - Port number (default: 8080)
#
# Example:
#   tunnel-quick 3000  # Expose localhost:3000 to the internet
# ----------------------------------------------------------------------------
tunnel-quick() {
    local port="${1:-8080}"
    echo "Starting Cloudflare tunnel on port $port..."
    cloudflared tunnel --url "http://localhost:$port"
}

tunnel-create() {
    if [ -z "$1" ]; then
        echo "Usage: tunnel-create <tunnel-name>"
        return 1
    fi
    cloudflared tunnel create "$1"
    echo "Don't forget to create a config file and route DNS!"
}

# Helper to test Workers locally
worker-test() {
    if [ ! -f wrangler.toml ]; then
        echo "Error: No wrangler.toml found in current directory"
        return 1
    fi
    echo "Starting local development server..."
    wrangler dev --local
}

# Auto-completion for wrangler (removed - wrangler doesn't support completions command)


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
