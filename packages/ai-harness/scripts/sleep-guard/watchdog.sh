#!/bin/bash
# Claude Code sleep-guard watchdog — stale 마커 정리 + pmset 상태 동기화.
#
# 호출:
#   watchdog.sh sync    1회 동기화 (launchd 주기 실행 or 훅에서 호출)
#
# 동작:
#   1) /tmp/claude-awake-$USER/* 중 mtime이 STALE_SECS를 초과한 마커 제거
#      (interrupt 시 Stop 훅이 불리지 않는 케이스 안전망)
#   2) 남은 마커 수에 따라 `sudo -n pmset -a disablesleep 0|1` 호출
#      (NOPASSWD sudoers 엔트리 필요 — setup.sh가 설치)
#
# 상태 파일 /tmp/claude-awake-$USER.pmset-state — 현재 적용된 on/off 캐시.
# pmset 호출 최소화 (매 틱마다 호출하지 않음).
#
# STALE_SECS 기본 900초(15분):
#   - 단일 tool이 15분 넘게 실행되는 동안 중간 tool 경계(heartbeat)가 없으면
#     마커가 stale 판정되어 pmset off → sleep 가능. 긴 빌드가 많은 환경이면
#     `launchd.plist.template`의 EnvironmentVariables 블록에 값을 넣어 override할 것.
#     (쉘 프로파일의 env는 launchd 주기 실행 경로에 상속되지 않음. 훅 실행은
#     Claude Code 세션 env를 상속하므로 쉘 설정이 부분적으로 적용되지만, 두 경로 간
#     일관성을 위해 plist를 권위값으로 사용 권장.)

set -u

MODE="${1:-}"
[ "$MODE" = "sync" ] || exit 0

# 멀티유저 환경 권한 충돌 방지 — /tmp 공용 경로를 사용자별로 분리.
# $USER가 비어 있으면(일부 launchd 컨텍스트) UID로 폴백.
USER_SUFFIX="${USER:-$(id -u)}"
AWAKE_DIR="/tmp/claude-awake-${USER_SUFFIX}"
STATE_FILE="/tmp/claude-awake-${USER_SUFFIX}.pmset-state"
LOCK_DIR="/tmp/claude-awake-${USER_SUFFIX}.lock.d"
STALE_SECS="${CLAUDE_AWAKE_STALE_SECS:-900}"

mkdir -p "$AWAKE_DIR" 2>/dev/null || true

# 동시 실행 방지 — mkdir atomicity 기반 락 (macOS에 flock이 기본 없음).
# 락 획득 실패 시 조용히 종료: 다른 인스턴스가 처리 중이거나, stale 락이
# 30초 이상 남아 있으면 강제 해제.
acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        return 0
    fi
    # stale lock 감지 (30초 초과). GNU stat 비호환 출력은 숫자 검증으로 방어.
    local lock_mtime now age
    lock_mtime="$(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)"
    case "$lock_mtime" in
        ''|*[!0-9]*) lock_mtime=0 ;;
    esac
    now="$(date +%s)"
    age=$(( now - lock_mtime ))
    if [ "$age" -gt 30 ]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
        mkdir "$LOCK_DIR" 2>/dev/null && return 0
    fi
    return 1
}
acquire_lock || exit 0
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

now="$(date +%s)"

# GNU stat에서 `stat -f`가 filesystem 옵션으로 해석되어 비숫자 출력을
# 돌려줄 수 있음. arithmetic 에러 방지를 위해 반드시 숫자 검증.
read_mtime() {
    local m
    m="$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0)"
    case "$m" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$m" ;;
    esac
}

# stale 마커 제거 — 본인 소유 디렉토리만. 다른 사용자의 마커는 각자의 watchdog이
# 정리해야 하므로 건드리지 않는다 (권한도 없음).
if [ -d "$AWAKE_DIR" ]; then
    for f in "$AWAKE_DIR"/*; do
        [ -e "$f" ] || continue
        mtime="$(read_mtime "$f")"
        age=$(( now - mtime ))
        if [ "$age" -gt "$STALE_SECS" ]; then
            rm -f "$f"
        fi
    done
fi

# 활성 마커 수 — `pmset -a disablesleep`은 시스템 전역이므로 모든 사용자의
# 활성 세션을 합산해야 한다. 다만 다른 사용자의 stale 마커는 우리가 지울 수
# 없으므로 (권한) active 판정 시 mtime으로 제외: 자신/타인 무관하게 STALE_SECS
# 이내 heartbeat가 있는 마커만 active로 센다. 이러지 않으면 다른 사용자가
# 로그아웃/크래시 후 stale 마커가 남아 있어 pmset=1이 기계 전역에 stuck.
active_count=0
for dir in /tmp/claude-awake-*; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*; do
        [ -e "$f" ] || continue
        mtime="$(read_mtime "$f")"
        age=$(( now - mtime ))
        [ "$age" -le "$STALE_SECS" ] && active_count=$((active_count + 1))
    done
done

current_state="off"
[ -f "$STATE_FILE" ] && current_state="$(cat "$STATE_FILE" 2>/dev/null || echo off)"

desired_state="off"
[ "$active_count" -gt 0 ] && desired_state="on"

if [ "$desired_state" = "$current_state" ]; then
    exit 0
fi

# pmset 실행 — NOPASSWD가 없으면 실패해도 조용히 넘어감 (state 파일 안 씀 → 재시도 유지)
if [ "$desired_state" = "on" ]; then
    if sudo -n /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1; then
        echo "on" > "$STATE_FILE"
    fi
else
    if sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
        echo "off" > "$STATE_FILE"
    fi
fi

exit 0
