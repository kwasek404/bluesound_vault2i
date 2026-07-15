#!/usr/bin/env bash
set -uo pipefail
# mover.sh - one pass of the Vault -> TrueNAS mover job.
#
# Invoked by an external polling loop as:
#   flock -n "$STATE_DIR/mover.lock" bin/mover.sh
# every POLL_INTERVAL seconds. This script performs a single pass and exits;
# it does not loop and does not call flock itself.
#
# NOTE: no `set -e` - `rclone check` exits non-zero when differences exist
# and that must be handled, not abort the script.

VAULT_HOST="${VAULT_HOST:-192.168.0.20}"
VAULT_STATUS_PORT="${VAULT_STATUS_PORT:-2000}"
VAULT_API_PORT="${VAULT_API_PORT:-11000}"
TRUENAS_HOST="${TRUENAS_HOST:-192.168.0.200}"
SMB_SHARE="${SMB_SHARE:-shared}"
SRC_SUBPATH="${SRC_SUBPATH:-Music}"
DST_SUBPATH="${DST_SUBPATH:-Music}"
IDLE_CONFIRMATIONS="${IDLE_CONFIRMATIONS:-2}"
STATE_DIR="${STATE_DIR:-/state}"
LOG_DIR="${LOG_DIR:-/log}"
RCLONE_CONFIG="${RCLONE_CONFIG:-/state/rclone.conf}"
export RCLONE_CONFIG

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

mkdir -p "${STATE_DIR}" "${LOG_DIR}"

log "INFO" "Pass start: vault=${VAULT_HOST} truenas=${TRUENAS_HOST} share=${SMB_SHARE}"

SRC="vault:${SMB_SHARE}/${SRC_SUBPATH}"
DST="truenas:${SMB_SHARE}/${DST_SUBPATH}"

RCLONE_HDD_FLAGS=(--transfers 1 --checkers 1 --multi-thread-streams 1)
RCLONE_RETRY_FLAGS=(--retries 3 --low-level-retries 10 --retries-sleep 30s)
RCLONE_LOG_FLAGS=(--use-json-log --log-file "${LOG_DIR}/rclone.log" --log-level INFO)

# --- 1. previous state -----------------------------------------------------
prev_idle_streak="$(state_read '.idle_streak')"
prev_idle_streak="${prev_idle_streak:-0}"
prev_pending_reindex="$(state_read '.pending_reindex')"
prev_pending_reindex="${prev_pending_reindex:-false}"
prev_last_reindex_at="$(state_read '.last_reindex_at')"

# --- 2. idle check -----------------------------------------------------------
vault_idle="false"
idle_streak=0
if vault_is_idle; then
    vault_idle="true"
    idle_streak=$((prev_idle_streak + 1))
fi

idle_confirmed="false"
if [[ "${idle_streak}" -ge "${IDLE_CONFIRMATIONS}" ]]; then
    idle_confirmed="true"
fi

# --- 3. pending counts (before any transfer) --------------------------------
pending_files="$(count_pending_files)"
pending_albums="$(count_pending_albums)"

# shellcheck disable=SC2034  # consumed by write_state() in lib.sh via caller scope
action=""
copied=0
verified=0
deleted=0
differ=0
missing=0
errors=0
pending_reindex="${prev_pending_reindex}"
last_reindex_at="${prev_last_reindex_at}"

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ "${idle_confirmed}" == "false" ]]; then
    # --- 4. not stably idle yet: never transfer -----------------------------
    log "INFO" "Vault busy or not yet stably idle (streak=${idle_streak}/${IDLE_CONFIRMATIONS}) - skipping transfer"
    action="skipped_busy"
elif [[ "${pending_files}" -eq 0 ]]; then
    # --- 5. idle-confirmed, nothing to move ---------------------------------
    action="idle_empty"
else
    # --- 6. idle-confirmed, transfer pipeline --------------------------------
    log "INFO" "Starting copy: ${SRC} -> ${DST}"
    rclone copy "${RCLONE_EXCLUDES[@]}" "${RCLONE_HDD_FLAGS[@]}" --immutable \
        "${RCLONE_RETRY_FLAGS[@]}" "${RCLONE_LOG_FLAGS[@]}" "${SRC}" "${DST}"
    copy_rc=$?

    if [[ "${copy_rc}" -ne 0 ]]; then
        log "ERROR" "rclone copy failed with exit code ${copy_rc}"
        action="copy_error"
        errors=1
    else
        matched_file="${STATE_DIR}/matched.txt"
        differ_file="${STATE_DIR}/differ.txt"
        missing_file="${STATE_DIR}/missing.txt"
        errors_file="${STATE_DIR}/errors.txt"
        : > "${matched_file}"
        : > "${differ_file}"
        : > "${missing_file}"
        : > "${errors_file}"

        log "INFO" "Starting verification check: ${SRC} -> ${DST}"
        rclone check --download --one-way "${RCLONE_EXCLUDES[@]}" "${RCLONE_HDD_FLAGS[@]}" \
            "${RCLONE_RETRY_FLAGS[@]}" "${RCLONE_LOG_FLAGS[@]}" \
            --match "${matched_file}" --differ "${differ_file}" \
            --missing-on-dst "${missing_file}" --error "${errors_file}" \
            "${SRC}" "${DST}"

        verified="$(wc -l < "${matched_file}")"
        differ="$(wc -l < "${differ_file}")"
        missing="$(wc -l < "${missing_file}")"
        check_errors="$(wc -l < "${errors_file}")"
        copied="${verified}"
        errors="${check_errors}"

        if [[ "${differ}" -gt 0 || "${missing}" -gt 0 || "${check_errors}" -gt 0 ]]; then
            log "WARN" "Verification mismatch: differ=${differ} missing=${missing} errors=${check_errors} - will retry next tick"
            action="verify_mismatch"
        elif [[ "${verified}" -gt 0 ]]; then
            log "INFO" "Deleting ${verified} verified files from vault source"
            rclone delete "${RCLONE_EXCLUDES[@]}" "${RCLONE_HDD_FLAGS[@]}" \
                "${RCLONE_RETRY_FLAGS[@]}" "${RCLONE_LOG_FLAGS[@]}" \
                --files-from "${matched_file}" "${SRC}"
            delete_rc=$?
            if [[ "${delete_rc}" -ne 0 ]]; then
                log "ERROR" "rclone delete failed with exit code ${delete_rc}"
                action="delete_error"
                errors=1
            else
                rclone rmdirs --leave-root "${RCLONE_HDD_FLAGS[@]}" "${RCLONE_LOG_FLAGS[@]}" "${SRC}"
                deleted="${verified}"
                action="moved"
                pending_reindex="true"
            fi
        else
            # Nothing matched but no differences/errors either - unusual,
            # nothing to delete this tick.
            action="verify_empty"
        fi

        # Recompute after the copy attempt so state reflects reality.
        pending_files="$(count_pending_files)"
        pending_albums="$(count_pending_albums)"
    fi
fi

# --- 8. reindex, only once, after a confirmed full drain --------------------
if [[ "${pending_reindex}" == "true" && "${idle_confirmed}" == "true" && "${pending_files}" -eq 0 ]]; then
    if trigger_reindex >/dev/null; then
        last_reindex_at="${now}"
        pending_reindex="false"
        log "INFO" "Triggered Vault reindex"
    else
        log "WARN" "Vault reindex trigger failed - will retry next tick"
    fi
fi

# --- 9. safe-to-power-off evaluation -----------------------------------------
safe="true"
blockers=()
if [[ "${vault_idle}" != "true" ]]; then
    safe="false"
    blockers+=("Trwa rip/enkodowanie na Vault.")
fi
if [[ "${pending_files}" -gt 0 ]]; then
    safe="false"
    blockers+=("Pozostalo ${pending_files} plikow do przeniesienia.")
fi
if [[ "${errors}" -gt 0 ]]; then
    safe="false"
    blockers+=("Wystapil blad ostatniego transferu - sprawdz log.")
fi
if [[ "${pending_reindex}" == "true" ]]; then
    safe="false"
    blockers+=("Oczekuje reindeks biblioteki Vault.")
fi

if [[ "${safe}" == "true" ]]; then
    safe_reason="Wszystko przeniesione i zweryfikowane, Vault bezczynny - mozna wylaczyc sprzet."
else
    safe_reason="${blockers[*]}"
fi

# --- 10. persist state --------------------------------------------------------
updated_at="${now}"
last_run_at="${now}"
last_run_action="${action}"

write_state

log "INFO" "Pass complete: action=${action} pending_files=${pending_files} idle_streak=${idle_streak} safe=${safe}"

exit 0
