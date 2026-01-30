#!/bin/bash
# Claude Code MCP Server Installation - DEPRECATED
#
# This feature has been merged into dev-tools.sh as of v4.15.0
#
# MCP servers are now automatically installed when:
# - INCLUDE_DEV_TOOLS=true
# - Node.js is available (INCLUDE_NODE=true or any feature that triggers Node.js)
#
# INCLUDE_MCP_SERVERS is kept for backward compatibility only.
# It still triggers Node.js installation via the Dockerfile conditional,
# but the actual MCP server installation is now handled by dev-tools.sh.
#
# Migration guide:
# - Remove INCLUDE_MCP_SERVERS=true from your build args
# - Use INCLUDE_DEV_TOOLS=true with INCLUDE_NODE=true (or INCLUDE_NODE_DEV=true)
# - MCP servers will be installed automatically

set -euo pipefail

# Source feature utilities
source /tmp/build-scripts/base/feature-header.sh

# ============================================================================
# Feature Start
# ============================================================================
log_feature_start "claude-mcp (DEPRECATED)"

log_warning "============================================================"
log_warning "INCLUDE_MCP_SERVERS is DEPRECATED and will be removed"
log_warning "in a future version."
log_warning ""
log_warning "MCP servers are now installed automatically by dev-tools.sh"
log_warning "when Node.js is available."
log_warning ""
log_warning "To migrate:"
log_warning "  1. Remove INCLUDE_MCP_SERVERS=true from build args"
log_warning "  2. Ensure INCLUDE_DEV_TOOLS=true"
log_warning "  3. Ensure INCLUDE_NODE=true or INCLUDE_NODE_DEV=true"
log_warning "============================================================"

log_feature_end
