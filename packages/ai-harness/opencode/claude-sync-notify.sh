#!/bin/bash
result=$(claude-sync 2>&1)
echo "$result"

if echo "$result" | grep -qi "expired\|failed\|error\|locked\|cannot\|not found"; then
  osascript -e 'display notification "Claude 토큰이 만료되었습니다. 터미널에서 claude login을 실행하세요." with title "OpenCode Auth" sound name "Blow"'
fi
