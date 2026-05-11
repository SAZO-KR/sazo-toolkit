#!/bin/bash
# pre-task-general-purpose-gate.sh — PreToolUse hook (Plan 14).
#
# Opus 세션이 Task(subagent_type="general-purpose")로 위임할 때 soft warn.
# 이유: `general-purpose`는 부모 모델(Opus) inherit → 컨텍스트만 절약, 비용 동일.
# 대부분의 작업은 모델별로 더 저렴한 전용 subagent가 존재.
# 정책: warn-only (block 안 함). 사용자가 그래도 진행하면 그대로 통과.
#
# 정책:
# - Narrow hook (default ON) + Opus 모델만 적용
# - Task tool + subagent_type=="general-purpose" → 1회 warn + 전용 추천 메시지
# - SAZO_SKIP_GENERAL_PURPOSE_GATE=1: 본 hook만 비활성
# - SAZO_DISABLE_NARROW_HOOKS=1: 모든 narrow hook 비활성

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/session-state.sh
source "$LIB_DIR/session-state.sh"

if ! narrow_hooks_enabled || [ "${SAZO_SKIP_GENERAL_PURPOSE_GATE:-0}" = "1" ]; then
    exit 0
fi

read_hook_payload

# session_id 없으면 claude code 외부 호출 — passthrough (pre-exploration-gate와 동일 가드).
if [ -z "${SAZO_SESSION_ID:-}" ]; then
    exit 0
fi

# Opus 세션만 적용 (다른 모델은 general-purpose 사용해도 상속 비용 낮음)
case "${SAZO_MODEL:-${CLAUDE_MODEL:-}}" in
    *opus*) ;;
    *) exit 0 ;;
esac

[ "$SAZO_TOOL_NAME" = "Task" ] || exit 0

subagent_type=$(echo "$SAZO_TOOL_INPUT" | jq -r '.subagent_type // ""' 2>/dev/null)
[ "$subagent_type" = "general-purpose" ] || exit 0

cat >&2 <<'EOF'
[plan-14-warn] Opus 세션이 general-purpose subagent를 호출했습니다.
general-purpose는 부모 모델(Opus)을 inherit해 비용 절감 효과가 없습니다.
전용 subagent 권장 (haiku/sonnet으로 비용 절감):

  • In-repo 탐색: code-searcher (haiku)
  • 외부 docs / OSS: docs-researcher (haiku)
  • Plan 작성/검증: plan-drafter → plan-auditor → plan-critic
  • Plan 실행: plan-executor (sonnet)
  • 코드리뷰: code-reviewer / architect-advisor (sonnet)
  • UI/프론트엔드: ui-engineer (sonnet)
  • 문서 업데이트: doc-writer (haiku)
  • 이미지/스크린샷 분석: image-analyzer (haiku)

CLAUDE.md "0. 에이전트 위임 원칙" 표 참조.
계속 진행하려면 무시 가능 (이 hook은 warn-only). 본 hook만 비활성화:
  SAZO_SKIP_GENERAL_PURPOSE_GATE=1
EOF
exit 0
