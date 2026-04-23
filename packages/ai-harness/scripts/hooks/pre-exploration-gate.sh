#!/bin/bash
# pre-exploration-gate.sh — PreToolUse hook.
#
# Opus 세션에서 메인 루프가 직접 grep/rg/find 탐색하는 것을 차단한다.
# CLAUDE.md "0. 에이전트 위임 원칙" → "Opus급 에이전트의 직접 탐색 금지".
# 탐색은 code-searcher/docs-researcher subagent(haiku)에 위임해야 한다.
#
# 정책:
# - Opt-in (SAZO_WORKFLOW_HOOKS_ENABLED=1) + Opus 모델만 적용
# - Grep tool + Bash `grep|egrep|fgrep|git grep|rg|ag|fd|xargs grep|find -name` → 카운트
# - 1-2회는 soft 경고, 3회부터 block
# - SAZO_ALLOW_GREP_ONCE=1: 1회 override
# - SAZO_SKIP_EXPLORE_GATE=1: 전체 비활성
# - explore_count는 Task subagent 호출 시 PostToolUse hook이 decay 처리

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/session-state.sh
source "$LIB_DIR/session-state.sh"

if ! workflow_hooks_enabled || [ "${SAZO_SKIP_EXPLORE_GATE:-0}" = "1" ]; then
    exit 0
fi

read_hook_payload

if [ -z "${SAZO_SESSION_ID:-}" ]; then
    exit 0
fi

# Opus 세션만 적용
case "${SAZO_MODEL:-${CLAUDE_MODEL:-}}" in
    *opus*) ;;
    *) exit 0 ;;
esac

# 탐색 tool 판별 (word-boundary)
is_exploration=0
if [ "$SAZO_TOOL_NAME" = "Grep" ]; then
    is_exploration=1
elif [ "$SAZO_TOOL_NAME" = "Bash" ]; then
    cmd=$(echo "$SAZO_TOOL_INPUT" | jq -r '.command // ""')
    # grep family (word-bounded), git grep, xargs grep, rg, ag, fd
    if echo "$cmd" | grep -qE '(\b|^)(grep|egrep|fgrep|rg|ag|fd)\b'; then
        is_exploration=1
    elif echo "$cmd" | grep -qE '\bgit[[:space:]]+grep\b'; then
        is_exploration=1
    elif echo "$cmd" | grep -qE '\bfind\b[[:space:]]+[^|]*-name'; then
        is_exploration=1
    elif echo "$cmd" | grep -qE '\bls\b[[:space:]]+-[a-zA-Z]*R'; then
        is_exploration=1
    fi
fi

[ "$is_exploration" = "0" ] && exit 0

state_init "$SAZO_SESSION_ID" "$SAZO_CWD" "$SAZO_MODEL"

# 1회 override — 카운트도 증가시키지 않음 (env가 지속될 수 있어 무한 카운트 방지)
if [ "${SAZO_ALLOW_GREP_ONCE:-0}" = "1" ]; then
    exit 0
fi

state_increment "$SAZO_SESSION_ID" ".explore_count"
count=$(state_get "$SAZO_SESSION_ID" ".explore_count")
count=${count:-0}

if [ "$count" -le 2 ]; then
    cat >&2 <<EOF
[explore-gate] Opus 직접 탐색 ${count}회. code-searcher/docs-researcher subagent 위임 권장.
  - in-repo 검색: Task(subagent_type="code-searcher")
  - 외부 docs:   Task(subagent_type="docs-researcher")
3회부터 block. 단건 필요 시: SAZO_ALLOW_GREP_ONCE=1
EOF
    exit 0
fi

cat >&2 <<EOF
[explore-gate] Opus 직접 탐색 ${count}회 — 차단.
code-searcher/docs-researcher subagent로 위임 필수.

  Task(subagent_type="code-searcher", description="...", prompt="...")
  Task(subagent_type="docs-researcher", description="...", prompt="...")

Override:
  - 단건: SAZO_ALLOW_GREP_ONCE=1
  - 세션 비활성: SAZO_SKIP_EXPLORE_GATE=1
EOF
exit 2
