#!/bin/bash
# Every-boot Docker socket reconcile.
#
# Runs on every container (re)start via /etc/container/startup/ (see
# entrypoint.sh). The entrypoint's sequential-init configure_docker_socket()
# only fires once and — because root always passes its access test — cannot
# repair a socket that Docker Desktop recreated root:root mid-lifetime. This
# thin wrapper re-invokes the durable, self-contained fix-docker-socket command
# so group ownership is reconciled on every boot, restoring `docker` access for
# the non-root user after a Docker Desktop restart without a full rebuild.
#
# See issue #674.

if command -v fix-docker-socket >/dev/null 2>&1; then
    fix-docker-socket || true
fi
