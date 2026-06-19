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
[ -n "$INPUT" ] || exit 0

# jq is how we read the payload and emit valid JSON. Absent jq => inert.
command -v jq >/dev/null 2>&1 || exit 0

# Loop guard: don't re-block the summary turn.
STOP_ACTIVE="$(jq -r '.stop_hook_active // false' <<< "$INPUT" 2>/dev/null)"
[ "$STOP_ACTIVE" = "true" ] && exit 0

TRANSCRIPT="$(jq -r '.transcript_path // empty' <<< "$INPUT" 2>/dev/null)"
[ -n "$TRANSCRIPT" ] || exit 0

# transcript_path may be home-relative (e.g. ~/.claude/projects/...). Bash does
# not expand a leading ~ stored in a variable, so normalize it before use.
case "$TRANSCRIPT" in
    "~")   TRANSCRIPT="$HOME" ;;
    "~/"*) TRANSCRIPT="$HOME/${TRANSCRIPT#"~/"}" ;;
esac

# Gate: only summarize turns that actually did work.
bash "$SCRIPT_DIR/gate.sh" "$TRANSCRIPT" || exit 0

REASON="$(cat <<'EOF'
이번 턴 작업 종료. 아래 3블록으로 **간결히** 정리(컨텍스트에 남으니 장황 금지). 해당 없는 블록은 생략.

🔄 이번 턴 요약 — 한 일 3~5개 불릿, 가능하면 `파일:라인`.
🔀 결정 필요 — 사람 판단이 필요할 때만. 결정마다 숫자 번호(1, 2, …)를 매기고 한 줄로 왜 필요한지. 안이 여럿이면 표로, 각 행 맨 앞에 숫자 번호(1, 2, …)를 붙여 사용자가 번호로 소통하게. 추천 안 명시. 없으면 "결정 필요 없음" 한 줄.
▶ 다음 단계 — 바로 이어질 작업이 명확할 때만 숫자 번호로 1~3개.
EOF
)"

jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
exit 0
