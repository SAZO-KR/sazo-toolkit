---
description: workflow stage를 명시적으로 skip 처리. `/skip <stage> <reason>`
allowed-tools: Bash(jq:*), Bash(date:*), Bash(mkdir:*), Bash(cat:*), Bash(mv:*), Bash(printf:*), Bash(rmdir:*), Bash(stat:*), Bash(sleep:*), Bash(shasum:*), Bash(cut:*), Bash(test:*), Bash(echo:*)
argument-hint: <stage> <reason>
---

# /skip — workflow stage skip

## 사용법

```
/skip <stage> <reason>
```

`<stage>`: `worktree`, `research`, `plan`, `review` 중 하나.
`<reason>`: 한 줄 사유 (필수).

`approval`, `ci`는 명시 skip 금지 — 환경변수 override만 가능 (`SAZO_ALLOW_CI_SKIP=1`).

## 동작

!`bash -c '
set -euo pipefail
HARNESS_DIR="${SAZO_HARNESS_DIR:-$HOME/.config/sazo-ai-harness/packages/ai-harness}"
LIB="$HARNESS_DIR/scripts/hooks/lib/session-state.sh"
[ -f "$LIB" ] || { echo "session-state lib 누락: $LIB"; exit 1; }
# shellcheck disable=SC1090
source "$LIB"

ARGS="$ARGUMENTS"
STAGE="${ARGS%% *}"
REASON="${ARGS#* }"
[ -z "$STAGE" ] && { echo "사용법: /skip <stage> <reason>"; exit 1; }
[ "$STAGE" = "$REASON" ] && { echo "reason 누락. 사용법: /skip <stage> <reason>"; exit 1; }

case "$STAGE" in
    worktree|research|plan|review) ;;
    approval|ci) echo "approval/ci skip 금지. 환경변수 override만 허용 (SAZO_ALLOW_CI_SKIP=1)."; exit 1 ;;
    *) echo "알 수 없는 stage: $STAGE (worktree/research/plan/review)"; exit 1 ;;
esac

SID="${CLAUDE_SESSION_ID:-${SAZO_SESSION_ID:-}}"
[ -z "$SID" ] && { echo "session_id 없음 — Claude Code 환경에서만 작동"; exit 1; }

CWD="${CLAUDE_CWD:-$PWD}"
state_init "$SID" "$CWD" "${CLAUDE_MODEL:-unknown}"
stage_mark "$SID" "$STAGE" "skipped" "user" "$REASON" "$CWD"
echo "✓ stage=$STAGE skipped (reason: $REASON)"
'`

## 자율 skip 기준

| Stage | Autonomous skip 가능 |
|---|---|
| worktree | **불가** (사용자 명시만) |
| research | 사용자가 파일/라인 직접 지정, ≤2 파일 |
| plan | ≤5줄 + 단일 파일 + typo/주석/import 정리 |
| approval | **불가** (UserPromptSubmit hook이 nonce 검증) |
| ci | **불가** (env override만) |
| review | 문서/주석만 수정 |

연속 3 stage skip 시 hook이 경고. 의도면 추가 확인 권장.
