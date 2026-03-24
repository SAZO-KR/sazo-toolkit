#!/bin/bash
CLAUDE_SYNC="${HOME}/.local/bin/claude-sync"
result=$("$CLAUDE_SYNC" 2>&1)
echo "$result"

# Filter out known benign warnings before checking for real errors
filtered=$(echo "$result" | grep -vi "Deprecated opencode-anthropic-auth\|may cause 429 errors\|Remove it with")

if echo "$filtered" | grep -qi "expired\|refresh failed\|auth.*failed\|keychain.*locked\|cannot auto-refresh\|claude CLI not found"; then
  osascript -e 'display notification "Claude 토큰이 만료되었습니다. 터미널에서 claude login을 실행하세요." with title "OpenCode Auth" sound name "Blow"'
fi
