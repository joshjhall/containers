#!/bin/bash
# System packages for the Node.js feature
#
# Description:
#   The apt packages node.sh needs before it can download, verify, and run a
#   Node.js release tarball. A function rather than an inline call so the unit
#   suite can run it against a stub apt_install and assert what is requested,
#   instead of grepping node.sh (#985).
#
# Usage:
#   source /tmp/build-scripts/features/lib/node/system-deps.sh
#   install_node_system_deps
#
# Requirements:
#   - apt_install (lib/base/apt-utils.sh)

# install_node_system_deps - apt-install node.sh's build/runtime prerequisites
install_node_system_deps() {
    # libatomic1: newer Node.js binaries (26.x on arm64, #983) link
    # libatomic.so.1, which the slim base image does not ship; without it
    # `node` exits 127.
    apt_install \
        curl \
        ca-certificates \
        xz-utils \
        libatomic1
}
