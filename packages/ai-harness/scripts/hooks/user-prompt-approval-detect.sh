#!/bin/bash
# user-prompt-approval-detect.sh — UserPromptSubmit hook.
#
# 사용자가 직접 입력한 메시지가 정확한 승인 패턴 (`/approved`만)일 때 nonce 발급.
# `/approved` slash command는 nonce 검증 후에만 approval stage 마킹.
# Claude가 자의적으로 `/approved` 호출해도 nonce 없으면 거부 → "사용자 의사결정"
# 원칙 보장.
#
# 패턴 — 정확히 "/approved" (앞뒤 공백 허용, 다른 텍스트 금지).
# 한국어 자연어 "ok/승인/go" 등은 의도적으로 제외 — Claude가 사용자 메시지 해석
# 오류로 통과시키는 것을 막기 위해 명시적 슬래시 명령만 인정.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/session-state.sh
source "$LIB_DIR/session-state.sh"

if ! workflow_hooks_enabled; then
    exit 0
fi

read_hook_payload

[ -z "${SAZO_SESSION_ID:-}" ] && exit 0

# trim whitespace + 첫 토큰만 검사. "/approved", "/approved 진행", "/approved please"
# 모두 인정. 단 다른 슬래시 명령이 함께 있는 경우는 거부.
trimmed=$(echo "$SAZO_USER_PROMPT" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
first_token="${trimmed%%[[:space:]]*}"

if [ "$first_token" = "/approved" ]; then
    state_init "$SAZO_SESSION_ID" "$SAZO_CWD" "$SAZO_MODEL"
    # 짧은 nonce — UUIDv4 대신 랜덤 hex (의존성 최소화)
    nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    approval_nonce_set "$SAZO_SESSION_ID" "$nonce"
    # /approved 명령이 같은 turn 내에서 실행되면서 nonce 소비.
    # Claude에게 노출 안 함 (stdout 비움).
fi

exit 0
