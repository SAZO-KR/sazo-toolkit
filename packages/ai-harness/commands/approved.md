---
description: 사용자가 플랜에 승인 의사를 표시. workflow approval gate 통과 (nonce 검증).
allowed-tools: Bash(jq:*), Bash(date:*), Bash(mkdir:*), Bash(cat:*), Bash(mv:*), Bash(printf:*), Bash(rmdir:*), Bash(stat:*), Bash(sleep:*), Bash(shasum:*), Bash(cut:*), Bash(test:*), Bash(echo:*)
---

# /approved — plan approval marker

## 사용법

```
/approved
```

**사용자 직접 입력 전용**. UserPromptSubmit hook이 사용자가 정확히 `/approved`를 타이핑한 경우에만 nonce를 발급한다. Claude가 자의로 호출하면 nonce 검증 실패 → approval stage 마킹 안 됨.

## 동작

!`bash -c '
set -euo pipefail
HARNESS_DIR="${SAZO_HARNESS_DIR:-$HOME/.config/sazo-ai-harness/packages/ai-harness}"
LIB="$HARNESS_DIR/scripts/hooks/lib/session-state.sh"
[ -f "$LIB" ] || { echo "session-state lib 누락: $LIB"; exit 1; }
# shellcheck disable=SC1090
source "$LIB"

SID="${CLAUDE_SESSION_ID:-${SAZO_SESSION_ID:-}}"
[ -z "$SID" ] && { echo "session_id 없음"; exit 1; }
CWD="${CLAUDE_CWD:-$PWD}"

state_init "$SID" "$CWD" "${CLAUDE_MODEL:-unknown}"

# nonce 조회. UserPromptSubmit hook이 사용자 직접 입력 시에만 발급.
NONCE=$(state_get "$SID" ".approval_nonce" "$CWD")
if [ -z "$NONCE" ]; then
    cat <<EOF
✗ approval nonce 없음. /approved는 사용자 직접 입력만 인정.
Claude 자동 호출 차단 — 사용자가 직접 타이핑해야 함.
EOF
    exit 1
fi

# nonce consume + plan_approved_at 먼저 → stage_mark 마지막
# (validator는 history entry + plan_approved_at 둘 다 요구. 순서 뒤집으면 race window
# 에서 stage_is_passed가 transient false 반환).
approval_nonce_consume "$SID" "$NONCE" "$CWD" || { echo "✗ nonce 검증 실패"; exit 1; }
TS=$(date +%Y-%m-%dT%H:%M:%S%z)
state_set_str "$SID" ".plan_approved_at" "$TS" "$CWD" || { echo "✗ plan_approved_at 기록 실패 (lock timeout 가능). /approved 재입력 시 새 nonce 발급됨."; exit 1; }
stage_mark "$SID" "approval" "completed" "user" "/approved (nonce verified)" "$CWD" || { echo "✗ stage_mark 실패. /approved 재입력 시 새 nonce 발급됨."; exit 1; }
echo "✓ approval stage 통과. 구현 진행 가능."
'`

## 주의

- Claude는 사용자에게 "ok/승인 입력해주세요"가 아니라 "**`/approved` 입력해주세요**"라고 명시 안내해야 함.
- approval은 architecturally **사용자 의사결정** stage. autonomous skip 금지.
