# shellcheck shell=bash
#
# lib.sh - shared helpers for the Vault -> TrueNAS mover job.
#
# Sourced by mover.sh. Expects VAULT_HOST, VAULT_STATUS_PORT, VAULT_API_PORT,
# SMB_SHARE, SRC_SUBPATH, STATE_DIR and LOG_DIR to already be set (with
# defaults applied by the caller) before any function below is invoked.

# Paths excluded from every rclone copy/check/delete/lsf call.
RCLONE_EXCLUDES=(--exclude ".DS_Store" --exclude "._*" --exclude ".prmscan" --exclude ".Trashes" --exclude ".Spotlight-*")

# log <level> <msg> - append a timestamped line to LOG_DIR/mover.log and
# print it to stdout.
log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line="${ts} [${level}] ${msg}"
    printf '%s\n' "${line}"
    printf '%s\n' "${line}" >> "${LOG_DIR}/mover.log"
}

# fetch_ripencstat - print the Vault's rip/encode status body, return curl's
# exit code.
fetch_ripencstat() {
    local body
    body="$(curl --silent --show-error --max-time 10 \
        "http://${VAULT_HOST}:${VAULT_STATUS_PORT}/ripencstat?noheader=1")"
    local rc=$?
    printf '%s' "${body}"
    return "${rc}"
}

# vault_is_idle - true (0) only if the Vault reports both no CD inserted and
# no tracks to encode. Any fetch failure is treated as NOT idle (fail-safe).
vault_is_idle() {
    local body
    body="$(fetch_ripencstat)"
    local rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        return 1
    fi
    if [[ "${body}" == *"No CD inserted."* && "${body}" == *"No tracks to encode."* ]]; then
        return 0
    fi
    return 1
}

# count_pending_files - number of files still waiting on the Vault source
# (recursive, excludes junk). Prints 0 on error.
count_pending_files() {
    local n
    n="$(rclone lsf --files-only -R "${RCLONE_EXCLUDES[@]}" "vault:${SMB_SHARE}/${SRC_SUBPATH}" | wc -l)"
    echo "${n:-0}"
}

# count_pending_albums - number of top-level album directories still on the
# Vault source. Prints 0 on error.
count_pending_albums() {
    local n
    n="$(rclone lsf --dirs-only "${RCLONE_EXCLUDES[@]}" "vault:${SMB_SHARE}/${SRC_SUBPATH}" | wc -l)"
    echo "${n:-0}"
}

# trigger_reindex - ask the Vault to reindex its library. Returns curl's
# exit code.
trigger_reindex() {
    curl --fail --silent --show-error --max-time 15 -X POST \
        "http://${VAULT_HOST}:${VAULT_API_PORT}/Reindex" -d 'reindex=1'
}

# state_read <jq-path> - read a value from STATE_DIR/state.json (treated as
# {} if the file is missing). Prints an empty string if the path is
# null/missing.
state_read() {
    local jq_path="$1"
    local file="${STATE_DIR}/state.json"
    local content
    if [[ -f "${file}" ]]; then
        content="$(<"${file}")"
    else
        content="{}"
    fi
    printf '%s' "${content}" | jq -r "(${jq_path}) | if . == null then empty else . end"
}

# write_state - atomically persist STATE_DIR/state.json.
# Reads the following variables from the caller's scope:
#   updated_at, vault_idle, idle_streak, pending_files, pending_albums,
#   last_run_at, last_run_action, copied, verified, deleted, differ,
#   missing, errors, pending_reindex, last_reindex_at, safe, safe_reason
write_state() {
    local tmp_file="${STATE_DIR}/state.json.tmp.$$"
    local last_reindex_json="null"
    if [[ -n "${last_reindex_at}" ]]; then
        last_reindex_json="\"${last_reindex_at}\""
    fi

    # shellcheck disable=SC2154  # vars are set by the caller (mover.sh) per the documented contract
    jq -n \
        --arg updated_at "${updated_at}" \
        --argjson vault_idle "${vault_idle}" \
        --argjson idle_streak "${idle_streak}" \
        --argjson pending_music_files "${pending_files}" \
        --argjson pending_music_albums "${pending_albums}" \
        --arg last_run_at "${last_run_at}" \
        --arg last_run_action "${last_run_action}" \
        --argjson copied "${copied}" \
        --argjson verified "${verified}" \
        --argjson deleted "${deleted}" \
        --argjson differ "${differ}" \
        --argjson missing "${missing}" \
        --argjson errors "${errors}" \
        --argjson pending_reindex "${pending_reindex}" \
        --argjson last_reindex_at "${last_reindex_json}" \
        --argjson safe_to_power_off "${safe}" \
        --arg safe_reason "${safe_reason}" \
        '{
            updated_at: $updated_at,
            vault_idle: $vault_idle,
            idle_streak: $idle_streak,
            pending_music_files: $pending_music_files,
            pending_music_albums: $pending_music_albums,
            last_run: {
                at: $last_run_at,
                action: $last_run_action,
                copied: $copied,
                verified: $verified,
                deleted: $deleted,
                differ: $differ,
                missing: $missing,
                errors: $errors
            },
            pending_reindex: $pending_reindex,
            last_reindex_at: $last_reindex_at,
            safe_to_power_off: $safe_to_power_off,
            safe_reason: $safe_reason
        }' > "${tmp_file}" && mv "${tmp_file}" "${STATE_DIR}/state.json"
}
