# syntax=docker/dockerfile:1.7
# base-debian-12-amd64 — minimal hardened base image for v5 evidence runs.
#
# This image is the install target for per-tool CI runs (issue
# joshjhall/containers-db#1). It ships:
#   - Debian 12 (Bookworm) slim, linux/amd64
#   - Non-root user `runner` (UID/GID 1000)
#   - /etc/shells restricted to bash; service users → nologin
#   - Passwordless sudo OFF (production-safe default)
#   - cosign-signed + SBOM-attested when published
#
# It does NOT ship language toolchains, package managers beyond apt, or
# any dev-container ergonomics. Tools are installed at evidence-run time
# via `luggage install` (issue #405).
#
# See base-images/README.md for spec, hardening invariants, and the
# v4-to-v5 migration story.

# Pinned tag is supplied by ARG (default debian:12-slim). hadolint cannot
# see through the ARG indirection, so DL3006 is silenced explicitly here.
# hadolint ignore=DL3006
ARG BASE_IMAGE=debian:12-slim
FROM ${BASE_IMAGE}

ARG USERNAME=runner
ARG USER_UID=1000
ARG USER_GID=${USER_UID}
ARG RESTRICT_SHELLS=true
ARG PRODUCTION_MODE=true
ARG ENABLE_PASSWORDLESS_SUDO=false

ENV DEBIAN_FRONTEND=noninteractive

# Minimal package set: ca-certificates for TLS, sudo for the user policy,
# passwd for nologin lookups, and that's it. Anything else is a tool the
# evidence run is supposed to install — keeping it out of this layer
# preserves the "tool under test is the only major variable" invariant.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        sudo \
        passwd \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

COPY hardening.sh /tmp/hardening.sh
RUN chmod +x /tmp/hardening.sh \
 && RESTRICT_SHELLS=${RESTRICT_SHELLS} \
    PRODUCTION_MODE=${PRODUCTION_MODE} \
    ENABLE_PASSWORDLESS_SUDO=${ENABLE_PASSWORDLESS_SUDO} \
    /tmp/hardening.sh "${USERNAME}" "${USER_UID}" "${USER_GID}" \
 && rm /tmp/hardening.sh

# OCI image annotations — these populate `docker inspect` and the registry
# UI so containers-db#1 evidence rows stay traceable.
LABEL org.opencontainers.image.title="containers/base-debian-12-amd64" \
      org.opencontainers.image.description="Minimal hardened debian-12 amd64 base image for v5 evidence runs" \
      org.opencontainers.image.source="https://github.com/joshjhall/containers" \
      org.opencontainers.image.licenses="MIT OR Apache-2.0" \
      org.opencontainers.image.vendor="joshjhall" \
      org.opencontainers.image.documentation="https://github.com/joshjhall/containers/blob/main/base-images/README.md" \
      io.containers.base-image.distro="debian" \
      io.containers.base-image.distro-version="12" \
      io.containers.base-image.arch="amd64"

USER ${USERNAME}
WORKDIR /home/${USERNAME}

CMD ["/bin/bash"]
