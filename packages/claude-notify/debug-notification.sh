#!/bin/bash

# Debug script to capture Notification hook payload
# Usage: Set this as your Notification hook command, then trigger both scenarios

LOG_FILE="/tmp/claude-notification-debug.log"

# Read stdin (JSON payload)
PAYLOAD=$(cat)

# Log timestamp and payload
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
echo "PAYLOAD:" >> "$LOG_FILE"
echo "$PAYLOAD" | jq '.' >> "$LOG_FILE" 2>/dev/null || echo "$PAYLOAD" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Also log environment variables that might be relevant
echo "ENV VARS:" >> "$LOG_FILE"
env | grep -E "^CLAUDE_" >> "$LOG_FILE" 2>/dev/null
echo "" >> "$LOG_FILE"
echo "---" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Still show the notification so you know it triggered
PROJECT=$(echo "$CLAUDE_PROJECT_DIR" | sed "s/\.worktrees.*//" | xargs basename)
BRANCH=$(git -C "$CLAUDE_PROJECT_DIR" branch --show-current 2>/dev/null || echo "no-git")
osascript -e "display notification \"[DEBUG] 입력 대기 중\" with title \"$PROJECT ($BRANCH)\" sound name \"Glass\""
