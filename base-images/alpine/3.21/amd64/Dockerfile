# syntax=docker/dockerfile:1.7
# base-alpine-3.21-amd64 — minimal hardened base image for v5 evidence runs.
#
# This image is the install target for per-tool CI runs (issue
# joshjhall/containers-db#1). It ships:
#   - Alpine 3.21, linux/amd64
#   - Non-root user `runner` (UID/GID 1000)
#   - /etc/shells restricted to bash; service users → nologin
#   - Passwordless sudo OFF (production-safe default)
#   - cosign-signed + SBOM-attested when published
#
# It does NOT ship language toolchains, package managers beyond apk, or
# any dev-container ergonomics. Tools are installed at evidence-run time
# via `luggage install` (issue #405).
#
# bash is installed deliberately: Alpine ships only busybox ash by default,
# but lib/base/os-validation.sh hard-requires bash >= 5.0, the #!/usr/bin/env
# bash hardening.sh shebang needs an interpreter, and the /etc/shells→bash
# invariant must hold literally. Alpine 3.21's bash package is 5.2.
#
# See base-images/README.md for spec, hardening invariants, and the
# v4-to-v5 migration story.

# Pinned to alpine:3.21 explicitly (no ARG indirection) so hadolint can
# verify the tag at lint time. If a future build needs a digest-pinned
# base for reproducibility experiments, edit this line in a feature branch.
FROM alpine:3.21

ARG USERNAME=runner
ARG USER_UID=1000
ARG USER_GID=${USER_UID}
ARG RESTRICT_SHELLS=true
ARG PRODUCTION_MODE=true
ARG ENABLE_PASSWORDLESS_SUDO=false

# Minimal package set: ca-certificates for TLS, bash for the hardening lib +
# os-validation bash>=5.0 guard, shadow for usermod, sudo for the user policy.
# Anything else is a tool the evidence run is supposed to install — keeping it
# out of this layer preserves the "tool under test is the only major variable"
# invariant.
#
# `apk upgrade` runs against `alpine:3.21`'s preinstalled set so a fresh build
# picks up Alpine security advisories without waiting for an upstream image
# refresh (Trivy gate parity with the debian pilot's `apt-get upgrade`).
# DL3018 normally wants version-pinned apk packages, but a base image is itself
# a security boundary — it tracks the distro's current security state rather
# than freezing package versions.
# hadolint ignore=DL3018
RUN apk upgrade --no-cache \
 && apk add --no-cache \
        ca-certificates \
        bash \
        shadow \
        sudo

COPY hardening.sh /tmp/hardening.sh
RUN chmod +x /tmp/hardening.sh \
 && RESTRICT_SHELLS=${RESTRICT_SHELLS} \
    PRODUCTION_MODE=${PRODUCTION_MODE} \
    ENABLE_PASSWORDLESS_SUDO=${ENABLE_PASSWORDLESS_SUDO} \
    /tmp/hardening.sh "${USERNAME}" "${USER_UID}" "${USER_GID}" \
 && rm /tmp/hardening.sh

# OCI image annotations — these populate `docker inspect` and the registry
# UI so containers-db#1 evidence rows stay traceable.
LABEL org.opencontainers.image.title="containers/base-alpine-3.21-amd64" \
      org.opencontainers.image.description="Minimal hardened alpine-3.21 amd64 base image for v5 evidence runs" \
      org.opencontainers.image.source="https://github.com/joshjhall/containers" \
      org.opencontainers.image.licenses="MIT OR Apache-2.0" \
      org.opencontainers.image.vendor="joshjhall" \
      org.opencontainers.image.documentation="https://github.com/joshjhall/containers/blob/main/base-images/README.md" \
      io.containers.base-image.distro="alpine" \
      io.containers.base-image.distro-version="3.21" \
      io.containers.base-image.arch="amd64"

USER ${USERNAME}
WORKDIR /home/${USERNAME}

CMD ["/bin/bash"]
