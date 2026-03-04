#!/bin/bash

# Claude Code Stop Hook
# Shows notification when Claude finishes responding

PROJECT=$(echo "$CLAUDE_PROJECT_DIR" | sed "s/\.worktrees.*//" | xargs basename)
BRANCH=$(git -C "$CLAUDE_PROJECT_DIR" branch --show-current 2>/dev/null || echo "no-git")

osascript -e "display notification \"응답 완료\" with title \"$PROJECT ($BRANCH)\" sound name \"Glass\""
