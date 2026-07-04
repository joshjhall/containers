#!/bin/bash
# Install the stibbons host CLI from GitHub Release assets.
#
# Detects the host OS + architecture, maps it to the matching release asset
# (built by .github/workflows/release-binaries.yml), downloads and verifies it
# against its .sha256, then installs the `stibbons` binary. Replaces the old
# committed `bin/igor` distribution path (issue #286).
#
# Prerequisites:
#   - curl (or the `gh` CLI) for downloading
#   - tar (unix assets) — zip assets are Windows-only and unpacked by 7z there
#   - sha256sum or shasum for checksum verification
#
# Exit codes:
#   0 - stibbons installed successfully
#   1 - Error (unsupported platform, download/verify failure, missing tools)
#
# Usage:
#   ./install-stibbons.sh                       # latest release -> ~/.local/bin
#   ./install-stibbons.sh --version v4.19.12    # a specific tag
#   ./install-stibbons.sh --dir /usr/local/bin  # custom install dir
#   ./install-stibbons.sh --print-target        # just print the host triple

set -euo pipefail

REPO="joshjhall/containers"
VERSION="latest"
INSTALL_DIR="${HOME}/.local/bin"
PRINT_TARGET_ONLY=false

usage() {
    /usr/bin/cat <<'EOF'
Usage: install-stibbons.sh [OPTIONS]

Options:
  --version <tag>   Release tag to install (default: latest)
  --dir <path>      Install directory (default: ~/.local/bin)
  --repo <owner/repo>  Source repository (default: joshjhall/containers)
  --print-target    Print the detected target triple and exit
  --help            Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --repo)
            REPO="$2"
            shift 2
            ;;
        --print-target)
            PRINT_TARGET_ONLY=true
            shift
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Map `uname` output to the Rust target triple used for the asset name.
detect_target() {
    local os arch
    os=$(/usr/bin/uname -s)
    arch=$(/usr/bin/uname -m)

    case "$os" in
        Linux) os_part="unknown-linux-musl" ;;
        Darwin) os_part="apple-darwin" ;;
        MINGW* | MSYS* | CYGWIN* | Windows_NT) os_part="pc-windows-msvc" ;;
        *)
            echo "Error: unsupported OS: $os" >&2
            return 1
            ;;
    esac

    case "$arch" in
        x86_64 | amd64) arch_part="x86_64" ;;
        aarch64 | arm64) arch_part="aarch64" ;;
        *)
            echo "Error: unsupported architecture: $arch" >&2
            return 1
            ;;
    esac

    echo "${arch_part}-${os_part}"
}

TARGET=$(detect_target)

if [ "$PRINT_TARGET_ONLY" = true ]; then
    echo "$TARGET"
    exit 0
fi

# Windows assets are .zip; every other platform ships a .tar.gz.
case "$TARGET" in
    *windows*) EXT="zip" ;;
    *) EXT="tar.gz" ;;
esac

# Resolve the concrete tag so the asset name (which embeds the numeric
# version, not "latest") can be constructed.
resolve_version() {
    if [ "$VERSION" != "latest" ]; then
        echo "$VERSION"
        return 0
    fi
    if command -v gh >/dev/null 2>&1; then
        gh release view --repo "$REPO" --json tagName --jq '.tagName'
    else
        # Follow the /releases/latest redirect and read the resolved tag.
        /usr/bin/curl -fsSLI -o /dev/null -w '%{url_effective}' \
            "https://github.com/${REPO}/releases/latest" |
            /usr/bin/sed 's#.*/tag/##'
    fi
}

TAG=$(resolve_version)
# The asset name uses the numeric version (tag without a leading "v").
NUM_VERSION="${TAG#v}"
ASSET="stibbons-${NUM_VERSION}-${TARGET}.${EXT}"
BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"

echo "Installing stibbons ${TAG} for ${TARGET}..."

WORKDIR=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$WORKDIR"' EXIT

download() {
    local url="$1" dest="$2"
    /usr/bin/curl -fsSL -o "$dest" "$url"
}

download "${BASE_URL}/${ASSET}" "${WORKDIR}/${ASSET}"
download "${BASE_URL}/${ASSET}.sha256" "${WORKDIR}/${ASSET}.sha256"

# Verify the checksum before unpacking. The .sha256 file records the bare
# asset filename, so verify from inside the work dir.
echo "Verifying checksum..."
(
    cd "$WORKDIR"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c "${ASSET}.sha256"
    else
        shasum -a 256 -c "${ASSET}.sha256"
    fi
)

# Unpack the binary.
case "$EXT" in
    tar.gz) /usr/bin/tar -xzf "${WORKDIR}/${ASSET}" -C "$WORKDIR" ;;
    zip) /usr/bin/unzip -q "${WORKDIR}/${ASSET}" -d "$WORKDIR" ;;
esac

BIN_NAME="stibbons"
[ "$EXT" = "zip" ] && BIN_NAME="stibbons.exe"

/bin/mkdir -p "$INSTALL_DIR"
/usr/bin/install -m 0755 "${WORKDIR}/${BIN_NAME}" "${INSTALL_DIR}/${BIN_NAME}"

echo "Installed ${BIN_NAME} to ${INSTALL_DIR}/${BIN_NAME}"
case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) ;;
    *) echo "Note: ${INSTALL_DIR} is not on your PATH — add it to use 'stibbons' directly." ;;
esac
