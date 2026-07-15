#!/usr/bin/env bash
set -euo pipefail
#
# entrypoint.sh - container entrypoint for the Bluesound Vault -> TrueNAS
# mover.
#
# Responsibilities:
#   1. Apply env defaults and require the TRUENAS_SMB_PASSWORD secret.
#   2. Generate the rclone SMB remotes config from env on every start.
#   3. Start the status web UI in the background.
#   4. Run the mover pass loop in the foreground (PID 1's main job).

# --- 1. env defaults (harmless redundancy with the Dockerfile ENV, needed
#        for standalone `docker run` / non-image invocations) ---------------
: "${VAULT_HOST:=192.168.0.20}"
: "${VAULT_STATUS_PORT:=2000}"
: "${VAULT_API_PORT:=11000}"
: "${TRUENAS_HOST:=192.168.0.200}"
: "${TRUENAS_SMB_USER:=smb}"
: "${SMB_SHARE:=shared}"
: "${SRC_SUBPATH:=Music}"
: "${DST_SUBPATH:=Music}"
: "${POLL_INTERVAL:=60}"
: "${IDLE_CONFIRMATIONS:=2}"
: "${WEB_PORT:=8080}"
: "${STATE_DIR:=/state}"
: "${LOG_DIR:=/log}"
: "${RCLONE_CONFIG:=/state/rclone.conf}"

# TRUENAS_SMB_PASSWORD has no default - it is a required secret.
if [[ -z "${TRUENAS_SMB_PASSWORD:-}" ]]; then
    echo "ERROR: TRUENAS_SMB_PASSWORD is not set. Refusing to start." >&2
    exit 1
fi

mkdir -p "${STATE_DIR}" "${LOG_DIR}"

# --- 2. generate the rclone config (overwritten on every start, idempotent) -
obscured="$(rclone obscure "${TRUENAS_SMB_PASSWORD}")"

cat > "${RCLONE_CONFIG}" <<EOF
[vault]
type = smb
host = ${VAULT_HOST}
user = guest

[truenas]
type = smb
host = ${TRUENAS_HOST}
user = ${TRUENAS_SMB_USER}
pass = ${obscured}
EOF

chmod 600 "${RCLONE_CONFIG}"
echo "Generated rclone config at ${RCLONE_CONFIG} (remotes: vault, truenas)"

export RCLONE_CONFIG

# --- 3. status web UI, background ------------------------------------------
python3 /app/web/server.py &
web_pid=$!

cleanup() {
    echo "Shutting down: stopping web UI (pid ${web_pid})"
    kill "${web_pid}" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# --- 4. mover pass loop, foreground -----------------------------------------
# `|| true` keeps the loop alive under `set -e` if a pass fails or the lock
# is already held (a previous pass still running).
while true; do
    flock -n "${STATE_DIR}/mover.lock" /app/bin/mover.sh || true
    sleep "${POLL_INTERVAL}"
done
