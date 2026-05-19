#!/bin/bash

set -u

PMSET_BIN="${AWAKE_HELPER_PMSET_BIN-/usr/bin/pmset}"
STATE_DIR="${AWAKE_HELPER_STATE_DIR-/var/db/sazo-ai-harness}"
STATE_FILE="$STATE_DIR/awake-root.state"
LOCK_DIR="${AWAKE_HELPER_LOCK_DIR-/var/run/sazo-ai-harness-awake.lock.d}"
SLEEP_BIN="${AWAKE_HELPER_SLEEP_BIN-/bin/sleep}"
SELF_BIN="${AWAKE_HELPER_SELF_BIN-$0}"

err() { echo "$@" >&2; }

now_epoch() {
    date +%s
}

validate_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

validate_token() {
    case "$1" in
        ''|*[!A-Za-z0-9._:-]*) return 1 ;;
        *) return 0 ;;
    esac
}

ensure_dirs() {
    mkdir -p "$STATE_DIR"
}

read_mtime() {
    local target="$1"
    local mtime=""
    if [ "$(uname -s)" = "Darwin" ]; then
        mtime="$(stat -f %m "$target" 2>/dev/null || true)"
    else
        mtime="$(stat -c %Y "$target" 2>/dev/null || true)"
    fi
    case "$mtime" in
        ''|*[!0-9]*) printf '0\n' ;;
        *) printf '%s\n' "$mtime" ;;
    esac
}

acquire_lock() {
    local attempt=0 lock_mtime now age
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        attempt=$((attempt + 1))
        lock_mtime="$(read_mtime "$LOCK_DIR")"
        now="$(now_epoch)"
        age=$(( now - lock_mtime ))
        if [ "$age" -gt 30 ]; then
            rmdir "$LOCK_DIR" 2>/dev/null || true
            if mkdir "$LOCK_DIR" 2>/dev/null; then
                trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
                return 0
            fi
        fi
        [ "$attempt" -ge 50 ] && return 1
        "$SLEEP_BIN" 0.05 2>/dev/null || sleep 1
    done
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
}

read_state_value() {
    local key="$1"
    local line value
    [ -f "$STATE_FILE" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            "$key"=*)
                value="${line#*=}"
                printf '%s\n' "$value"
                return 0
                ;;
        esac
    done < "$STATE_FILE"
    return 1
}

write_state() {
    local token="$1"
    local expires_epoch="$2"
    local original_disablesleep="$3"
    local rollback_pid="$4"
    local started_epoch="$5"
    local tmp

    ensure_dirs
    tmp="$(mktemp "$STATE_DIR/awake-root.state.tmp.XXXXXX")" || return 1
    cat > "$tmp" <<EOF
version=1
token=$token
expires_epoch=$expires_epoch
original_disablesleep=$original_disablesleep
rollback_pid=$rollback_pid
started_epoch=$started_epoch
EOF
    mv "$tmp" "$STATE_FILE"
}

clear_state() {
    rm -f "$STATE_FILE"
}

read_pmset_disablesleep() {
    local line value
    [ -x "$PMSET_BIN" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            *SleepDisabled*)
                value="${line##* }"
                case "$value" in
                    0|1) printf '%s\n' "$value"; return 0 ;;
                esac
                ;;
        esac
    done < <("$PMSET_BIN" -g 2>/dev/null)
    return 1
}

apply_disablesleep() {
    local value="$1"
    case "$value" in
        0|1) ;;
        *) return 1 ;;
    esac
    "$PMSET_BIN" -a disablesleep "$value" >/dev/null 2>&1
}

kill_rollback_pid() {
    local pid="$1"
    validate_uint "$pid" || return 0
    [ "$pid" -gt 0 ] || return 0
    kill "$pid" 2>/dev/null || true
}

spawn_rollback() {
    local token="$1"
    local expires_epoch="$2"
    local now delay

    [ -x "$SLEEP_BIN" ] || return 1
    now="$(now_epoch)"
    delay=$(( expires_epoch - now ))
    [ "$delay" -lt 0 ] && delay=0

    (
        "$SLEEP_BIN" "$delay"
        "$SELF_BIN" rollback "$token" "$expires_epoch"
    ) >/dev/null 2>&1 &
    echo "$!"
}

cmd_start() {
    local secs="$1"
    local token="$2"
    local expires_epoch="$3"
    local original_disablesleep rollback_pid started_epoch existing_original existing_pid had_existing_state=0

    validate_uint "$secs" || return 2
    validate_token "$token" || return 2
    validate_uint "$expires_epoch" || return 2
    acquire_lock || return 1

    if [ -f "$STATE_FILE" ]; then
        had_existing_state=1
        existing_original="$(read_state_value original_disablesleep 2>/dev/null || true)"
        existing_pid="$(read_state_value rollback_pid 2>/dev/null || true)"
        case "$existing_original" in
            0|1) original_disablesleep="$existing_original" ;;
            *) original_disablesleep="$(read_pmset_disablesleep)" || return 1 ;;
        esac
    else
        original_disablesleep="$(read_pmset_disablesleep)" || return 1
    fi

    apply_disablesleep 1 || return 1
    started_epoch="$(now_epoch)"

    if [ "$had_existing_state" -eq 0 ]; then
        if ! write_state "$token" "$expires_epoch" "$original_disablesleep" 0 "$started_epoch"; then
            apply_disablesleep "$original_disablesleep" || true
            clear_state
            return 1
        fi
    fi

    rollback_pid="$(spawn_rollback "$token" "$expires_epoch" 2>/dev/null || true)"
    case "$rollback_pid" in
        ''|*[!0-9]*) rollback_pid=0 ;;
    esac
    if [ "$rollback_pid" -eq 0 ]; then
        if [ "$had_existing_state" -eq 0 ]; then
            apply_disablesleep "$original_disablesleep" || true
            clear_state
        fi
        return 1
    fi
    if ! write_state "$token" "$expires_epoch" "$original_disablesleep" "$rollback_pid" "$started_epoch"; then
        kill_rollback_pid "$rollback_pid"
        if [ "$had_existing_state" -eq 0 ]; then
            apply_disablesleep "$original_disablesleep" || true
            clear_state
        fi
        return 1
    fi
}

cmd_restore() {
    local token="$1"
    local current_token original_disablesleep rollback_pid

    validate_token "$token" || return 2
    acquire_lock || return 1
    [ -f "$STATE_FILE" ] || return 1

    current_token="$(read_state_value token)" || return 1
    [ "$current_token" = "$token" ] || return 1

    original_disablesleep="$(read_state_value original_disablesleep)" || return 1
    apply_disablesleep "$original_disablesleep" || return 1
    clear_state
}

cmd_status() {
    if [ ! -f "$STATE_FILE" ]; then
        echo "active=0"
        return 0
    fi

    cat "$STATE_FILE"
    echo "active=1"
}

cmd_rollback() {
    local token="$1"
    local expires_epoch="$2"
    local current_token original_disablesleep now

    validate_token "$token" || return 2
    validate_uint "$expires_epoch" || return 2
    acquire_lock || return 1
    [ -f "$STATE_FILE" ] || return 0

    current_token="$(read_state_value token 2>/dev/null || true)"
    [ "$current_token" = "$token" ] || return 0

    now="$(now_epoch)"
    if [ "$now" -lt "$expires_epoch" ]; then
        return 0
    fi

    original_disablesleep="$(read_state_value original_disablesleep)" || return 1
    apply_disablesleep "$original_disablesleep" || return 1
    clear_state
}

cmd_reset() {
    acquire_lock || return 1
    apply_disablesleep 0 || return 1
    clear_state
}

case "${1:-}" in
    start)
        [ "$#" -eq 4 ] || exit 2
        shift
        cmd_start "$@"
        ;;
    restore)
        [ "$#" -eq 2 ] || exit 2
        shift
        cmd_restore "$@"
        ;;
    status)
        [ "$#" -eq 1 ] || exit 2
        cmd_status
        ;;
    rollback)
        [ "$#" -eq 3 ] || exit 2
        shift
        cmd_rollback "$@"
        ;;
    reset)
        [ "$#" -eq 1 ] || exit 2
        cmd_reset
        ;;
    *)
        err "Unknown command: ${1:-}"
        exit 2
        ;;
esac
