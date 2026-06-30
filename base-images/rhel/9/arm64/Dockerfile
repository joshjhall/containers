# syntax=docker/dockerfile:1.7
# base-rhel-9-arm64 — minimal hardened base image for v5 evidence runs.
#
# This image is the install target for per-tool CI runs (issue
# joshjhall/containers-db#1). It ships:
#   - UBI 9 minimal (Red Hat Universal Base Image), linux/arm64
#   - Non-root user `runner` (UID/GID 1000)
#   - /etc/shells restricted to bash; service users → nologin
#   - Passwordless sudo OFF (production-safe default)
#   - cosign-signed + SBOM-attested when published
#
# It does NOT ship language toolchains, package managers beyond microdnf, or
# any dev-container ergonomics. Tools are installed at evidence-run time
# via `luggage install` (issue #405).
#
# bash is NOT installed deliberately: UBI 9 ships bash 5.1 by default, which
# already satisfies lib/base/os-validation.sh's bash >= 5.0 requirement, the
# #!/usr/bin/env bash hardening.sh shebang, and the /etc/shells→bash invariant.
# (Contrast alpine, which ships only busybox ash and had to `apk add bash`.)
#
# See base-images/README.md for spec, hardening invariants, and the
# v4-to-v5 migration story.

# Pinned to ubi9/ubi-minimal:9.5 (no ARG indirection) so hadolint can verify
# the tag at lint time. 9.5 is the highest floating minor tag published on
# registry.access.redhat.com (there is no bare `:9` tag there); a floating
# minor still rolls forward to the latest patch within 9.5, keeping the
# Trivy CRITICAL/HIGH gate current without freezing on a stale build. Bump the
# minor here when Red Hat publishes 9.6+. For digest-pinned reproducibility,
# edit this line in a feature branch.
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.5

ARG USERNAME=runner
ARG USER_UID=1000
ARG USER_GID=${USER_UID}
ARG RESTRICT_SHELLS=true
ARG PRODUCTION_MODE=true
ARG ENABLE_PASSWORDLESS_SUDO=false

# Minimal package set: ca-certificates for TLS, shadow-utils for groupadd/
# useradd/usermod (NOT in ubi-minimal), sudo for the user policy. nologin is
# NOT installed (it lives in util-linux-core, absent from ubi-minimal) —
# harden_service_users falls back to /usr/bin/false (coreutils, always
# present), an equally valid deny-login shell, so no extra package is needed.
# bash is deliberately omitted — UBI 9 ships bash 5.1, satisfying the
# os-validation bash>=5.0 guard and the hardening.sh shebang for free. Anything
# else is a
# tool the evidence run is supposed to install — keeping it out of this layer
# preserves the "tool under test is the only major variable" invariant.
#
# `microdnf upgrade` runs against the preinstalled set so a fresh build picks
# up Red Hat security advisories without waiting for an upstream image refresh
# (Trivy gate parity with the debian pilot's `apt-get upgrade`). DL3040 (clean
# after install) and DL3041 (version-pin / no upgrade) are intentionally
# ignored — a base image is itself a security boundary, so it tracks the
# distro's current security state rather than freezing package versions.
# hadolint ignore=DL3040,DL3041
RUN microdnf upgrade -y \
 && microdnf install -y ca-certificates shadow-utils sudo \
 && microdnf clean all \
 && rm -rf /var/cache/yum /var/cache/dnf

COPY hardening.sh /tmp/hardening.sh
RUN chmod +x /tmp/hardening.sh \
 && RESTRICT_SHELLS=${RESTRICT_SHELLS} \
    PRODUCTION_MODE=${PRODUCTION_MODE} \
    ENABLE_PASSWORDLESS_SUDO=${ENABLE_PASSWORDLESS_SUDO} \
    /tmp/hardening.sh "${USERNAME}" "${USER_UID}" "${USER_GID}" \
 && rm /tmp/hardening.sh

# OCI image annotations — these populate `docker inspect` and the registry
# UI so containers-db#1 evidence rows stay traceable.
LABEL org.opencontainers.image.title="containers/base-rhel-9-arm64" \
      org.opencontainers.image.description="Minimal hardened rhel-9 arm64 base image for v5 evidence runs" \
      org.opencontainers.image.source="https://github.com/joshjhall/containers" \
      org.opencontainers.image.licenses="MIT OR Apache-2.0" \
      org.opencontainers.image.vendor="joshjhall" \
      org.opencontainers.image.documentation="https://github.com/joshjhall/containers/blob/main/base-images/README.md" \
      io.containers.base-image.distro="rhel" \
      io.containers.base-image.distro-version="9" \
      io.containers.base-image.arch="arm64"

USER ${USERNAME}
WORKDIR /home/${USERNAME}

CMD ["/bin/bash"]
