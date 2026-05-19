#!/bin/bash

# awake — macOS closed-lid 실행 유지용 pmset wrapper.

set -u

HELPER_BIN="${AWAKE_HELPER_BIN-/usr/local/libexec/sazo-ai-harness/awake-helper}"
SUDO_BIN="${AWAKE_SUDO_BIN-sudo}"
STATE_DIR="${AWAKE_STATE_DIR-$HOME/.config/sazo-ai-harness}"
STATE_FILE="$STATE_DIR/awake.state"
LEGACY_PID_FILE="$STATE_DIR/awake.pid"
LEGACY_EXPIRES_FILE="$STATE_DIR/awake.expires"
DEFAULT_DURATION="2h"
MAX_DURATION_SECS=86400
PMSET_BIN="${AWAKE_PMSET_BIN-/usr/bin/pmset}"
PS_BIN="${AWAKE_PS_BIN-/bin/ps}"
KILL_BIN="${AWAKE_KILL_BIN-kill}"

usage() {
    cat <<EOF
Usage: awake <command> [args]

Commands:
  on [duration]    Keep running with lid closed (default: $DEFAULT_DURATION)
  off              Restore previous sleep setting
  status           Show current awake state
  extend <dur>     Add to remaining time
  reset            Force disablesleep 0 and clear awake state

Duration: 30s / 5m / 2h / 1h30m / 90 (plain int = seconds)
EOF
}

err() { echo "$@" >&2; }

read_legacy_pid() {
    local pid
    [ -f "$LEGACY_PID_FILE" ] || return 1
    pid="$(cat "$LEGACY_PID_FILE" 2>/dev/null || true)"
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$pid"
}

clean_legacy_state() {
    local legacy_pid legacy_comm

    if legacy_pid="$(read_legacy_pid 2>/dev/null)"; then
        legacy_comm="$($PS_BIN -p "$legacy_pid" -o comm= 2>/dev/null || true)"
        case "$legacy_comm" in
            *caffeinate*)
                "$KILL_BIN" "$legacy_pid" 2>/dev/null || true
                ;;
        esac
    fi

    rm -f "$LEGACY_PID_FILE" "$LEGACY_EXPIRES_FILE"
}

clean_state() {
    rm -f "$STATE_FILE"
}

write_state() {
    local token="$1"
    local expires_epoch="$2"
    local tmp

    mkdir -p "$STATE_DIR"
    tmp="$(mktemp "$STATE_DIR/awake.state.tmp.XXXXXX")" || return 1
    cat > "$tmp" <<EOF
version=1
token=$token
expires_epoch=$expires_epoch
helper_bin=$HELPER_BIN
EOF
    mv "$tmp" "$STATE_FILE"
}

read_state_value() {
    local key="$1"
    local file="${2:-$STATE_FILE}"
    local line value

    [ -f "$file" ] || return 1

    while IFS= read -r line; do
        case "$line" in
            "$key"=*)
                value="${line#*=}"
                printf '%s\n' "$value"
                return 0
                ;;
        esac
    done < "$file"
    return 1
}

now_epoch() {
    date +%s
}

platform_name() {
    printf '%s\n' "${AWAKE_UNAME-$(uname -s)}"
}

generate_token() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
        return 0
    fi
    printf 'awake-%s-%s-%s\n' "$(now_epoch)" "$$" "${RANDOM:-0}"
}

parse_duration() {
    local rest="$1" total=0 num unit
    [ -z "$rest" ] && return 1
    if [[ "$rest" =~ ^[0-9]+$ ]]; then
        [ "$rest" -gt 0 ] || return 1
        [ "$rest" -le "$MAX_DURATION_SECS" ] || return 1
        echo "$rest"
        return 0
    fi
    while [ -n "$rest" ]; do
        if [[ "$rest" =~ ^([0-9]+)([smh])(.*)$ ]]; then
            num="${BASH_REMATCH[1]}"
            unit="${BASH_REMATCH[2]}"
            rest="${BASH_REMATCH[3]}"
            case "$unit" in
                s) total=$((total + num)) ;;
                m) total=$((total + num * 60)) ;;
                h) total=$((total + num * 3600)) ;;
            esac
        else
            return 1
        fi
    done
    [ "$total" -gt 0 ] || return 1
    [ "$total" -le "$MAX_DURATION_SECS" ] || return 1
    echo "$total"
}

require_darwin() {
    if [ "$(platform_name)" != "Darwin" ]; then
        err "awake is only supported on macOS"
        return 1
    fi
}

run_helper() {
    local command="$1"
    shift

    if [ ! -x "$HELPER_BIN" ]; then
        err "awake helper not installed: $HELPER_BIN"
        err "Reinstall ai-harness and enable awake helper setup."
        return 1
    fi

    if [ -n "$SUDO_BIN" ]; then
        "$SUDO_BIN" "$HELPER_BIN" "$command" "$@"
    else
        "$HELPER_BIN" "$command" "$@"
    fi
}

helper_active_state() {
    local status_output
    status_output="$(run_helper status 2>/dev/null || true)"
    case "$status_output" in
        *$'\n'active=1|active=1|active=1$'\n'*) printf '1\n'; return 0 ;;
        *$'\n'active=0|active=0|active=0$'\n'*) printf '0\n'; return 0 ;;
    esac
    return 1
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

cmd_on() {
    local dur="${1:-$DEFAULT_DURATION}"
    local secs token expires_epoch

    require_darwin || return 1
    clean_legacy_state

    if ! secs="$(parse_duration "$dur")"; then
        err "Invalid duration: $dur"
        return 2
    fi

    token="$(generate_token)"
    expires_epoch=$(( $(now_epoch) + secs ))

    if ! run_helper start "$secs" "$token" "$expires_epoch"; then
        err "Failed to enable closed-lid awake mode"
        return 1
    fi

    write_state "$token" "$expires_epoch" || {
        run_helper restore "$token" >/dev/null 2>&1 || true
        clean_state
        err "Failed to write awake state"
        return 1
    }

    echo "awake on (${secs}s)"
}

cmd_off() {
    local token expires_epoch now helper_active

    require_darwin || return 1
    clean_legacy_state

    if ! token="$(read_state_value token)"; then
        clean_state
        echo "awake: not running"
        return 0
    fi

    expires_epoch="$(read_state_value expires_epoch 2>/dev/null || true)"
    case "$expires_epoch" in
        ''|*[!0-9]*) expires_epoch=0 ;;
    esac
    now="$(now_epoch)"

    if ! run_helper restore "$token"; then
        if [ "$expires_epoch" -gt 0 ] && [ "$expires_epoch" -le "$now" ]; then
            helper_active="$(helper_active_state 2>/dev/null || true)"
            if [ "$helper_active" = "0" ]; then
                clean_state
                echo "awake: off"
                return 0
            fi
        fi
        err "Failed to restore previous sleep setting"
        err "If state looks stuck, run 'awake reset'."
        return 1
    fi

    clean_state
    echo "awake off"
}

cmd_status() {
    local token expires_epoch now remain pmset_value helper_active

    clean_legacy_state
    now="$(now_epoch)"
    token="$(read_state_value token 2>/dev/null || true)"
    expires_epoch="$(read_state_value expires_epoch 2>/dev/null || true)"
    pmset_value="$(read_pmset_disablesleep 2>/dev/null || true)"

    if [ -n "$token" ] && [ -n "$expires_epoch" ] && [[ "$expires_epoch" =~ ^[0-9]+$ ]]; then
        remain=$(( expires_epoch - now ))
        [ "$remain" -lt 0 ] && remain=0

        if [ "$remain" -eq 0 ]; then
            helper_active="$(helper_active_state 2>/dev/null || true)"
            if [ "$helper_active" = "0" ]; then
                clean_state
                echo "awake: off"
                return 0
            fi
        fi

        echo "awake: on (${remain}s remaining${pmset_value:+, SleepDisabled=$pmset_value})"
        return 0
    fi

    if [ "$pmset_value" = "1" ]; then
        echo "awake: unmanaged (SleepDisabled=1)"
        return 0
    fi

    clean_state
    echo "awake: off"
}

cmd_extend() {
    local dur="${1:-}"
    local add token expires_epoch now remain new_secs new_token new_expires_epoch

    require_darwin || return 1
    clean_legacy_state

    if [ -z "$dur" ]; then
        err "Usage: awake extend <duration>"
        return 2
    fi
    if ! add="$(parse_duration "$dur")"; then
        err "Invalid duration: $dur"
        return 2
    fi
    if ! token="$(read_state_value token)"; then
        err "awake not running — use 'awake on' first"
        return 1
    fi
    expires_epoch="$(read_state_value expires_epoch)"
    case "$expires_epoch" in
        ''|*[!0-9]*) expires_epoch=0 ;;
    esac

    now="$(now_epoch)"
    remain=$(( expires_epoch - now ))
    [ "$remain" -lt 0 ] && remain=0
    new_secs=$(( remain + add ))
    if [ "$new_secs" -gt "$MAX_DURATION_SECS" ]; then
        echo "awake: extend clamped to max ${MAX_DURATION_SECS}s (24h)" >&2
        new_secs=$MAX_DURATION_SECS
    fi

    new_token="$(generate_token)"
    new_expires_epoch=$(( now + new_secs ))

    if ! run_helper start "$new_secs" "$new_token" "$new_expires_epoch"; then
        err "Failed to extend awake session"
        return 1
    fi

    write_state "$new_token" "$new_expires_epoch" || {
        run_helper restore "$new_token" >/dev/null 2>&1 || true
        clean_state
        err "Failed to write awake state"
        return 1
    }

    echo "awake extended (${new_secs}s remaining)"
}

cmd_reset() {
    require_darwin || return 1
    clean_legacy_state

    if ! run_helper reset; then
        err "Failed to force awake reset"
        return 1
    fi

    clean_state
    echo "awake reset"
}

case "${1:-}" in
    on)      shift; cmd_on "$@" ;;
    off)     shift; cmd_off "$@" ;;
    status)  shift; cmd_status "$@" ;;
    extend)  shift; cmd_extend "$@" ;;
    reset)   shift; cmd_reset "$@" ;;
    __parse) shift; parse_duration "${1:-}" ;;
    -h|--help|help) usage ;;
    "")     usage; exit 2 ;;
    *)       err "Unknown command: $1"; usage; exit 2 ;;
esac
