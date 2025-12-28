# Claude Notify

Claude CLI 알림 훅 설치 스크립트 (macOS)

## 기능

- **Stop hook**: 작업 완료 시 "응답 완료" 알림
- **Notification hook**: 60초 이상 입력 대기 시 "입력 대기 중" 알림
- 프로젝트 이름 및 Git 브랜치 표시
- Git worktree 지원

## 요구사항

- macOS
- jq (`brew install jq`)

## 설치

```bash
./install-claude-notify.sh
```

## 제거

```bash
jq 'del(.hooks.Stop) | del(.hooks.Notification)' ~/.claude/settings.json > tmp.json && mv tmp.json ~/.claude/settings.json
```

## 제한사항

- Notification hook은 60초 후에만 발동 (Claude Code 제한)
