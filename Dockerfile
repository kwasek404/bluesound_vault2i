# Bluesound Vault 2i -> TrueNAS mover.
#
# Runs the SMB->SMB rclone mover loop (bin/mover.sh via entrypoint.sh) plus a
# small stdlib Python status web UI (web/server.py). Deployed on TrueNAS
# 25.10.4 as a Custom App (Docker Compose); see docker-compose.yml.

FROM debian:stable-slim

LABEL org.opencontainers.image.source="https://github.com/kwasek404/bluesound_vault2i"
LABEL org.opencontainers.image.description="Moves finished rips from a Bluesound Vault 2i SMB share to a TrueNAS SMB share via rclone, with a status web UI."

# ca-certificates: TLS for rclone downloads / HTTPS remotes (not currently used but cheap to have)
# curl: fetch the rclone .deb + SHA256SUMS at build; HTTP polling of the Vault in mover.sh at runtime
# jq: JSON state read/write in lib.sh
# util-linux: provides flock, used to serialize mover.sh passes
# python3: runs web/server.py (stdlib only, no pip deps)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq \
        util-linux \
        python3 && \
    rm -rf /var/lib/apt/lists/*

# Install rclone from the official Debian package, pinned to an explicit
# version and verified against the upstream SHA256SUMS. Bump RCLONE_PKG_VERSION
# to upgrade. rclone's SMB backend (required by this project) exists only in
# upstream >= 1.61.0, so Debian's apt rclone (1.60.1) cannot be used.
ARG RCLONE_PKG_VERSION=v1.74.4
RUN set -eux; \
    tmp_dir="$(mktemp -d)"; \
    deb="rclone-${RCLONE_PKG_VERSION}-linux-amd64.deb"; \
    curl -fsSL -o "${tmp_dir}/${deb}" "https://downloads.rclone.org/${RCLONE_PKG_VERSION}/${deb}"; \
    curl -fsSL -o "${tmp_dir}/SHA256SUMS" "https://downloads.rclone.org/${RCLONE_PKG_VERSION}/SHA256SUMS"; \
    (cd "${tmp_dir}" && grep " ${deb}\$" SHA256SUMS | sha256sum -c -); \
    apt-get update; \
    apt-get install -y --no-install-recommends "${tmp_dir}/${deb}"; \
    rm -rf "${tmp_dir}" /var/lib/apt/lists/*; \
    rclone version

WORKDIR /app

COPY bin/ /app/bin/
COPY web/ /app/web/
COPY entrypoint.sh /app/entrypoint.sh

RUN chmod +x /app/bin/*.sh /app/entrypoint.sh

# Standalone-run defaults; normally bind-mounted over by the Compose deployment.
RUN mkdir -p /state /log

ENV VAULT_HOST=192.168.0.20 \
    VAULT_STATUS_PORT=2000 \
    VAULT_API_PORT=11000 \
    TRUENAS_HOST=192.168.0.200 \
    TRUENAS_SMB_USER=smb \
    SMB_SHARE=shared \
    SRC_SUBPATH=Music \
    DST_SUBPATH=Music \
    POLL_INTERVAL=60 \
    IDLE_CONFIRMATIONS=2 \
    WEB_PORT=8080 \
    STATE_DIR=/state \
    LOG_DIR=/log \
    RCLONE_CONFIG=/state/rclone.conf

# TRUENAS_SMB_PASSWORD is intentionally NOT set here - it is a required
# secret that must be provided at runtime (see entrypoint.sh and
# docker-compose.yml).

EXPOSE 8080

ENTRYPOINT ["/app/entrypoint.sh"]
