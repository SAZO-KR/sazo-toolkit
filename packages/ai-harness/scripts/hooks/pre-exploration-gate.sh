#!/bin/bash
# pre-exploration-gate.sh — PreToolUse hook.
#
# Opus 세션에서 메인 루프가 직접 grep/rg/find 탐색하는 것을 차단한다.
# CLAUDE.md "0. 에이전트 위임 원칙" → "Opus급 에이전트의 직접 탐색 금지".
# 탐색은 code-searcher/docs-researcher subagent(haiku)에 위임해야 한다.
#
# 정책:
# - Narrow hook (Plan 06부터 default ON) + Opus 모델만 적용
# - Grep tool + Glob tool + Bash `grep|egrep|fgrep|git grep|rg|ag|fd|xargs grep|find -name` → 카운트
# - 1-2회는 soft 경고, 3회부터 block
# - SAZO_ALLOW_GREP_ONCE=1: 1회 override
# - SAZO_SKIP_EXPLORE_GATE=1: 본 hook만 비활성
# - SAZO_DISABLE_NARROW_HOOKS=1: 모든 narrow hook 비활성
# - explore_count는 Task subagent 호출 시 PostToolUse hook이 decay 처리

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/session-state.sh
source "$LIB_DIR/session-state.sh"

if ! narrow_hooks_enabled || [ "${SAZO_SKIP_EXPLORE_GATE:-0}" = "1" ]; then
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
# Plan 14: Glob도 메인 직접 탐색의 일부 (475건/10일). code-searcher 위임 대상.
is_exploration=0
if [ "$SAZO_TOOL_NAME" = "Grep" ] || [ "$SAZO_TOOL_NAME" = "Glob" ]; then
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

# 1회 override. env는 session 내내 유지되는 문제 있어 state 파일에 consumption
# 기록 — 사용 후 같은 env 값으로 재호출하면 거부 (Codex V9 P2 one-shot).
# 다시 override하려면 /skip 경로나 전체 hook 비활성 env 사용.
if [ "${SAZO_ALLOW_GREP_ONCE:-0}" = "1" ]; then
    ONCE_USED=$(state_get "$SAZO_SESSION_ID" '.grep_once_consumed' 2>/dev/null)
    if [ -z "$ONCE_USED" ] || [ "$ONCE_USED" = "null" ] || [ "$ONCE_USED" = "0" ]; then
        state_set_json "$SAZO_SESSION_ID" ".grep_once_consumed" "true"
        exit 0
    fi
    cat >&2 <<EOF
[explore-gate] SAZO_ALLOW_GREP_ONCE 이미 이번 세션에서 사용됨 — one-shot 소진.
계속 우회하려면 SAZO_SKIP_EXPLORE_GATE=1 (세션 비활성) 고려.
EOF
    # 소진됐으므로 normal gate flow로 진행 (exit 하지 않음) — 아래 counter 로직 적용.
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
