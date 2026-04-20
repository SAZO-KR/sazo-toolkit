#!/bin/bash
# Claude Code 세션 활성 중에만 macOS sleep 방지 — heartbeat 마커 관리.
#
# 모드:
#   heartbeat  UserPromptSubmit / PostToolUse 훅에서 호출 — 마커 touch
#   stop       Stop 훅에서 호출 — 마커 삭제
#
# 마커: /tmp/claude-awake-$USER/{session_id} (mtime = last activity)
# pmset on/off 동기화는 watchdog.sh가 담당.

set -u

MODE="${1:-}"
case "$MODE" in
    heartbeat|stop) ;;
    *) exit 0 ;;
esac

INPUT="$(cat 2>/dev/null || true)"
SESSION_ID=""
if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
    SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
fi
[ -z "$SESSION_ID" ] && SESSION_ID="default"

# session_id 검증 — path traversal 방지 (훅 페이로드가 신뢰 경계라도 방어)
if ! printf '%s' "$SESSION_ID" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
    SESSION_ID="default"
fi

# 멀티유저 환경에서 /tmp 공용 경로가 다른 사용자 소유로 먼저 생성되면 권한
# 충돌이 발생하므로 $USER로 분리. $USER가 비어 있으면 UID로 폴백.
AWAKE_DIR="/tmp/claude-awake-${USER:-$(id -u)}"
MARKER="$AWAKE_DIR/$SESSION_ID"

# watchdog 경로 해석: 훅은 symlink로 설치되므로 $(dirname "$0")는 링크 디렉토리
# (~/.claude/hooks)를 가리킨다. setup.sh가 `sazo-sleep-watchdog.sh` 이름으로
# 심볼릭 링크를 생성하므로 그 경로를 우선 시도. 없으면 symlink target 추적.
HOOKS_DIR="$(dirname "$0")"
WATCHDOG="$HOOKS_DIR/sazo-sleep-watchdog.sh"
if [ ! -e "$WATCHDOG" ]; then
    # 개발/테스트 환경 (심볼릭 링크 없이 직접 실행): 같은 디렉토리의 watchdog.sh
    WATCHDOG="$HOOKS_DIR/watchdog.sh"
fi

# mkdir 실패(권한 충돌: 다른 사용자 소유 파일/디렉토리가 같은 이름으로 선점) 시
# silent fail 하지 않고 stderr에 남겨서 Claude Code 훅 로그로 진단 가능하게 한다.
# 성공 경로는 조용히 통과.
if ! mkdir -p "$AWAKE_DIR" 2>/dev/null; then
    echo "sleep-guard: cannot create $AWAKE_DIR (permission conflict?)" >&2
    exit 0
fi

case "$MODE" in
    heartbeat)
        if ! : > "$MARKER" 2>/dev/null; then
            echo "sleep-guard: cannot write marker $MARKER" >&2
            exit 0
        fi
        ;;
    stop) rm -f "$MARKER" ;;
esac

# watchdog sync를 비동기로 — 훅 지연 방지
if [ -x "$WATCHDOG" ]; then
    "$WATCHDOG" sync >/dev/null 2>&1 &
fi

exit 0
