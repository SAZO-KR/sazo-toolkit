#!/bin/bash
#
# stop-summary.sh — Claude Code "Stop" hook
#
# Reads the hook payload (JSON) from stdin. When the just-finished turn did real
# work, emits a `{"decision":"block","reason":...}` so the main Claude writes a
# concise turn summary + surfaces any decisions needed next. The summary is
# produced from Claude's existing context (no extra reads/tokens).
#
# Loop guard: when `stop_hook_active` is true, this Stop is itself the result of
# our previous block (Claude just wrote the summary) — exit 0 so it can stop.
#
# Safe defaults everywhere: any missing input / no jq / parse error => exit 0
# (let Claude stop normally, never wedge the session).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INPUT="$(cat)"

# jq is how we read the payload and emit valid JSON. Absent jq => inert.
command -v jq >/dev/null 2>&1 || exit 0

# Loop guard: don't re-block the summary turn.
STOP_ACTIVE="$(jq -r '.stop_hook_active // false' <<< "$INPUT" 2>/dev/null)"
[ "$STOP_ACTIVE" = "true" ] && exit 0

TRANSCRIPT="$(jq -r '.transcript_path // empty' <<< "$INPUT" 2>/dev/null)"
[ -n "$TRANSCRIPT" ] || exit 0

# Gate: only summarize turns that actually did work.
bash "$SCRIPT_DIR/gate.sh" "$TRANSCRIPT" || exit 0

REASON="$(cat <<'EOF'
이번 턴 작업이 끝났습니다. 아래 형식으로 **간결하게** 정리하세요. 이 요약은 이후 대화 컨텍스트에 남으니 장황하게 쓰지 마세요.

### 🔄 이번 턴 요약
- 이번 턴에 한 일을 3~5개 불릿으로. 가능하면 `파일:라인` 포함.

### 🔀 결정 필요
다음 진행을 위해 사람의 의사결정이 필요한 지점이 있을 때만 이 섹션을 쓰세요. 각 결정마다:
- **<결정 주제>** — *왜 필요한지 한 줄*
- 가능한 안들을 장단점과 함께 (표 또는 불릿). 추천이 있으면 명시.

의사결정이 필요 없으면 이 섹션을 통째로 생략하고 "결정 필요 없음" 한 줄만 쓰세요.

### ▶ 다음 단계
(선택) 바로 이어질 작업이 명확하면 체크박스로 1~3개.
EOF
)"

jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
exit 0
