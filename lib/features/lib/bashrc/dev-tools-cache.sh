
# Development tools cache configuration
export DEV_TOOLS_CACHE="/cache/dev-tools"

# mkcert CA root storage
export CAROOT="${DEV_TOOLS_CACHE}/mkcert-ca"

# direnv allow directory
export DIRENV_ALLOW_DIR="${DEV_TOOLS_CACHE}/direnv-allow"

# Claude Code LSP support
# Enables Language Server Protocol integration for better code intelligence
# LSP plugins are configured automatically on first container startup
export ENABLE_LSP_TOOL=1
