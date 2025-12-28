#!/bin/bash

# Claude Code Notification Hook
# - Ignores idle_prompt (60 second timeout)
# - Shows notification for permission_prompt and other types

PAYLOAD=$(cat)
TYPE=$(echo "$PAYLOAD" | jq -r '.notification_type')

# idle_prompt (60초 타임아웃)면 무시
if [ "$TYPE" = "idle_prompt" ]; then
    exit 0
fi

# 나머지 경우만 알림 표시
PROJECT=$(echo "$CLAUDE_PROJECT_DIR" | sed "s/\.worktrees.*//" | xargs basename)
BRANCH=$(git -C "$CLAUDE_PROJECT_DIR" branch --show-current 2>/dev/null || echo "no-git")
osascript -e "display notification \"입력 대기 중\" with title \"$PROJECT ($BRANCH)\" sound name \"Glass\""
