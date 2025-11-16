#!/bin/bash
# Generate GitHub release notes from CHANGELOG
set -euo pipefail

VERSION="${1:-}"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 VERSION"
    exit 1
fi

# Get the directory where this script is located
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$BIN_DIR")"
CHANGELOG="$PROJECT_ROOT/CHANGELOG.md"

if [ ! -f "$CHANGELOG" ]; then
    echo "CHANGELOG.md not found"
    exit 1
fi

# Extract the section for this version
# Look for ## [VERSION] and capture until next ## or end of file
awk -v version="$VERSION" '
    /^## \['"$VERSION"'\]/ { found=1; next }
    found && /^## \[/ { exit }
    found { print }
' "$CHANGELOG" | sed '1{/^$/d}' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'

# If no content found, provide default message
if [ "${PIPESTATUS[0]}" -ne 0 ] || [ -z "$(awk -v version="$VERSION" '/^## \['"$VERSION"'\]/ { found=1; next } found && /^## \[/ { exit } found { print }' "$CHANGELOG")" ]; then
    command cat <<EOF
## Release v$VERSION

See [CHANGELOG.md](https://github.com/joshjhall/containers/blob/v$VERSION/CHANGELOG.md) for complete details.

### Container Images

All container variants are available at:
\`ghcr.io/joshjhall/containers:<variant>\`

Supported variants: minimal, python, python-dev, node, node-dev, rust, rust-dev, ruby, ruby-dev, golang, golang-dev, java, java-dev, r, r-dev, mojo, and many more.
EOF
fi
