#!/bin/bash
echo "=== Go Installation Status ==="
if command -v go &> /dev/null; then
    go version
    echo "Go binary: $(which go)"
    echo "GOROOT: ${GOROOT:-/usr/local/go}"
    echo "GOPATH: ${GOPATH:-/cache/go}"
    echo "GOCACHE: ${GOCACHE:-/cache/go-build}"
    echo "GOMODCACHE: ${GOMODCACHE:-/cache/go-mod}"
else
    echo "✗ Go is not installed"
fi
