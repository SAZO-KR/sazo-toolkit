#!/bin/bash
# Claude Code sleep-guard watchdog — stale 마커 정리 + pmset 상태 동기화.
#
# 호출:
#   watchdog.sh sync    1회 동기화 (launchd 주기 실행 or 훅에서 호출)
#
# 동작:
#   1) /tmp/claude-awake-$USER/* 중 mtime이 STALE_SECS를 초과한 마커 제거
#      (interrupt 시 Stop 훅이 불리지 않는 케이스 안전망)
#   2) 남은 마커 수와 현재 SleepDisabled 값이 다를 때만 `sudo -n pmset -a
#      disablesleep 0|1` 호출 (NOPASSWD sudoers 엔트리 필요 — setup.sh가 설치).
#      현재 값은 sudo 없는 `pmset -g`에서 읽어 0/non-0 경계를 넘을 때만 sudo 호출.
#
# 사용자별 state 캐시는 두지 않음 — pmset -a는 시스템 전역이라 cross-user
# short-circuit 버그를 유발한다. `pmset -g`의 SleepDisabled는 시스템 권위값이라
# 어느 사용자의 watchdog이 호출해도 동일한 값을 본다.
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

# launchd PATH는 제한적이라 (/usr/bin:/bin:/usr/sbin:/sbin) 절대 경로로 호출.
# sudo NOPASSWD sudoers 엔트리도 /usr/bin/pmset 절대 경로에 바인딩되므로 직접 호출
# 경로와 일치시켜 일관성 확보. 테스트는 PMSET_BIN을 stub 경로로 override.
PMSET_BIN="${PMSET_BIN:-/usr/bin/pmset}"

# 멀티유저 환경 권한 충돌 방지 — /tmp 공용 경로를 사용자별로 분리.
# $USER가 비어 있으면(일부 launchd 컨텍스트) UID로 폴백.
USER_SUFFIX="${USER:-$(id -u)}"
AWAKE_DIR="/tmp/claude-awake-${USER_SUFFIX}"
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
    # stale lock 감지 (30초 초과). read_mtime과 동일하게 OS별 분기.
    local lock_mtime now age
    if [ "$(uname -s)" = "Darwin" ]; then
        lock_mtime="$(stat -f %m "$LOCK_DIR" 2>/dev/null)"
    else
        lock_mtime="$(stat -c %Y "$LOCK_DIR" 2>/dev/null)"
    fi
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

# BSD(macOS)와 GNU(Linux/CI) stat은 `-f`/`-c` 의미가 달라 `||` chain으로 섞으면
# 한쪽 성공 stdout이 다른 쪽 출력과 concat될 위험이 있음. OS별로 분기해 명확히
# 호출하고, 최종 값은 반드시 숫자 검증.
read_mtime() {
    local m=""
    if [ "$(uname -s)" = "Darwin" ]; then
        m="$(stat -f %m "$1" 2>/dev/null)"
    else
        m="$(stat -c %Y "$1" 2>/dev/null)"
    fi
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

# 노이즈 감소: launchd가 ~10초 주기로 watchdog을 호출하므로 매 sync마다 sudo를
# spawn하면 macOS Sequoia가 background-activity notification을 띄우거나 unified
# log에 sudo의 "Too many groups requested" 같은 Default-level 경고가 누적된다.
# `pmset -g`는 sudo 없이 시스템 전역 SleepDisabled 값을 출력하므로(authoritative
# read), 현재 값과 desired_state가 같으면 sudo 호출을 skip — 활성 마커 수가
# 0/non-0 경계를 넘는 시점에만 sudo가 호출된다.
#
# per-user cache를 쓰지 않는 이유는 그대로 유효: 여기서 읽는 SleepDisabled는
# 시스템 전역 pmset의 권위값이므로 user A가 설정한 상태를 user B의 watchdog도
# 정확히 본다. cross-user short-circuit 버그가 발생하지 않는다.
#
# `pmset -g`에서 SleepDisabled 라인이 누락되면 시스템 기본값(0 = sleep 허용)으로
# 간주. 일부 환경/버전에서 값이 0일 때 라인이 생략될 수 있어 방어적으로 처리.
desired=0
[ "$active_count" -gt 0 ] && desired=1

current=$("$PMSET_BIN" -g 2>/dev/null \
    | awk '/^[[:space:]]*SleepDisabled/ {print $NF; found=1; exit} END {if (!found) print "0"}')
case "$current" in
    0|1) ;;
    *) current=0 ;;
esac

# desired는 위에서 0/1로만 설정되므로 분기 없이 그대로 전달.
if [ "$current" != "$desired" ]; then
    sudo -n "$PMSET_BIN" -a disablesleep "$desired" >/dev/null 2>&1 || true
fi

exit 0
