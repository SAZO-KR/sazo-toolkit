#!/bin/bash
# awake — macOS sleep 명시적 차단 (caffeinate wrapper).
#
# 사용:
#   awake on [duration]    sleep 차단 시작. duration 없으면 기본 2h.
#                          duration 형식: 30s / 5m / 2h / 1h30m / 90 (초)
#   awake off              차단 해제 (caffeinate 종료).
#   awake status           실행 여부 + 남은 시간.
#   awake extend <dur>     남은 시간에 추가하여 재시작.
#
# 동작:
#   - `caffeinate -dimsu -t SECS` 를 nohup + disown 으로 백그라운드 실행.
#   - PID는 $AWAKE_STATE_DIR/awake.pid, 만료 epoch는 awake.expires.
#   - sudo 불필요. caffeinate 종료 시 sleep 복귀 자동.
#
# Env (테스트):
#   AWAKE_CAFFEINATE_BIN  caffeinate 바이너리 경로 (default /usr/bin/caffeinate)
#   AWAKE_STATE_DIR       PID/expires 저장 경로 (default ~/.config/sazo-ai-harness)

set -u

CAFFEINATE_BIN="${AWAKE_CAFFEINATE_BIN:-/usr/bin/caffeinate}"
STATE_DIR="${AWAKE_STATE_DIR:-$HOME/.config/sazo-ai-harness}"
PID_FILE="$STATE_DIR/awake.pid"
EXPIRES_FILE="$STATE_DIR/awake.expires"
DEFAULT_DURATION="2h"
# 24h cap — 실수로 큰 값 넣어 며칠씩 sleep 차단되는 사고 방지. extend로 늘림.
MAX_DURATION_SECS=86400

usage() {
    cat <<EOF
Usage: awake <command> [args]

Commands:
  on [duration]    Start sleep prevention (default: $DEFAULT_DURATION)
  off              Stop sleep prevention
  status           Show running state + remaining time
  extend <dur>     Add to remaining time

Duration: 30s / 5m / 2h / 1h30m / 90 (plain int = seconds)
EOF
}

err() { echo "$@" >&2; }

# parse_duration "30s" → 30 (stdout). 실패 시 비-zero 종료.
parse_duration() {
    local input="$1" rest="$1" total=0 num unit
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

read_pid() {
    [ -f "$PID_FILE" ] || return 1
    local p; p=$(cat "$PID_FILE" 2>/dev/null || true)
    case "$p" in
        ''|*[!0-9]*) return 1 ;;
    esac
    echo "$p"
}

is_running() {
    local pid
    pid=$(read_pid) || return 1
    kill -0 "$pid" 2>/dev/null
}

clean_state() {
    rm -f "$PID_FILE" "$EXPIRES_FILE"
}

start_caffeinate() {
    # $1 = seconds
    local secs="$1"
    # 사전 검증 — bin이 실행 가능해야 fork 시도. 부재/non-exec 시 fork 후 좀비 PID
    # 기록되는 race 방지. nohup은 exec 실패 후에도 잠시 alive로 보일 수 있음.
    if [ ! -x "$CAFFEINATE_BIN" ]; then
        return 1
    fi
    mkdir -p "$STATE_DIR"
    nohup "$CAFFEINATE_BIN" -dimsu -t "$secs" >/dev/null 2>&1 &
    local pid=$!
    disown "$pid" 2>/dev/null || true
    # liveness 검증 — fork 후 짧은 시점에서 죽었는지 확인 (signal 등). 좀비
    # 윈도우 보강 차원. 50ms × 5 = 250ms 안에 살아있어야 OK.
    local i
    for i in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null && break
        sleep 0.05
    done
    unset i  # bash special var $_와의 혼동 방지 차원에서 정리
    if ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    echo "$pid" > "$PID_FILE"
    echo $(( $(date +%s) + secs )) > "$EXPIRES_FILE"
    echo "$pid"
}

cmd_on() {
    local dur="${1:-$DEFAULT_DURATION}"
    local secs
    if ! secs=$(parse_duration "$dur"); then
        err "Invalid duration: $dur"
        return 2
    fi

    if is_running; then
        local oldpid
        oldpid=$(read_pid)
        echo "Replacing existing awake (pid $oldpid)"
        kill "$oldpid" 2>/dev/null || true
        # 짧게 대기 — 동일 PID 재사용 가능성 회피.
        # `_` 대신 명시적 var 사용: bash $_ (last-arg)와 혼동 회피.
        local wait_i
        for wait_i in 1 2 3 4 5; do
            kill -0 "$oldpid" 2>/dev/null || break
            sleep 0.05
        done
        # 죽은 oldpid 가 PID 파일에 남지 않도록 정리. start_caffeinate 실패 시
        # 파일에 stale pid가 잔존하는 hygiene 문제 방지.
        clean_state
    fi

    local pid
    if ! pid=$(start_caffeinate "$secs"); then
        err "Failed to start caffeinate ($CAFFEINATE_BIN)"
        return 1
    fi
    echo "awake on (pid $pid, ${secs}s)"
}

cmd_off() {
    if ! is_running; then
        clean_state
        echo "awake: not running"
        return 0
    fi
    local pid; pid=$(read_pid)
    kill "$pid" 2>/dev/null || true
    clean_state
    echo "awake off"
}

cmd_status() {
    if ! is_running; then
        clean_state
        echo "awake: off"
        return 0
    fi
    local pid expires now remain
    pid=$(read_pid)
    expires=$(cat "$EXPIRES_FILE" 2>/dev/null || echo 0)
    case "$expires" in
        ''|*[!0-9]*) expires=0 ;;
    esac
    now=$(date +%s)
    remain=$(( expires - now ))
    [ "$remain" -lt 0 ] && remain=0
    echo "awake: on (pid $pid, ${remain}s remaining)"
}

cmd_extend() {
    local dur="${1:-}"
    if [ -z "$dur" ]; then
        err "Usage: awake extend <duration>"
        return 2
    fi
    local add
    if ! add=$(parse_duration "$dur"); then
        err "Invalid duration: $dur"
        return 2
    fi
    if ! is_running; then
        err "awake not running — use 'awake on' first"
        return 1
    fi
    local expires now remain new_secs
    expires=$(cat "$EXPIRES_FILE" 2>/dev/null || echo 0)
    case "$expires" in
        ''|*[!0-9]*) expires=0 ;;
    esac
    now=$(date +%s)
    remain=$(( expires - now ))
    [ "$remain" -lt 0 ] && remain=0
    new_secs=$(( remain + add ))
    # cap clamp — extend가 cmd_on 통해 parse_duration의 cap을 우회하지 못하도록.
    if [ "$new_secs" -gt "$MAX_DURATION_SECS" ]; then
        echo "awake: extend clamped to max ${MAX_DURATION_SECS}s (24h)" >&2
        new_secs=$MAX_DURATION_SECS
    fi
    cmd_on "$new_secs"
}

case "${1:-}" in
    on)      shift; cmd_on "$@" ;;
    off)     shift; cmd_off "$@" ;;
    status)  shift; cmd_status "$@" ;;
    extend)  shift; cmd_extend "$@" ;;
    __parse) shift; parse_duration "${1:-}" ;;  # 테스트용 — 외부 노출 X
    -h|--help|help) usage ;;
    "")      usage; exit 2 ;;
    *)       err "Unknown command: $1"; usage; exit 2 ;;
esac
