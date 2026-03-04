# Claude Notify

Claude CLI 알림 훅 설치 스크립트 (macOS)

## 기능

- **Stop hook**: 작업 완료 시 "응답 완료" 알림
- **Notification hook**: 입력 대기 시 "입력 대기 중" 알림 (idle_prompt 제외)
- 프로젝트 이름 및 Git 브랜치 표시
- Git worktree 지원

## 요구사항

- macOS
- jq (`brew install jq`)

## 설치

```bash
./install-claude-notify.sh
```

스크립트가 `~/.claude/hooks/`에 복사되고 `~/.claude/settings.json`에 훅이 등록됩니다.

## 파일 구조

```
claude-notify/
├── scripts/
│   ├── stop-hook.sh          # Stop 훅 스크립트
│   └── notification-hook.sh  # Notification 훅 스크립트
├── install-claude-notify.sh  # 설치 스크립트
└── README.md
```

## 제거

```bash
# 훅 설정 제거
jq 'del(.hooks.Stop) | del(.hooks.Notification)' ~/.claude/settings.json > tmp.json && mv tmp.json ~/.claude/settings.json

# 스크립트 파일 제거
rm -rf ~/.claude/hooks/
```

## 제한사항

- Notification hook은 60초 후에만 발동 (Claude Code 제한)
- `idle_prompt` 타입은 무시됨 (60초 타임아웃으로 인한 불필요한 알림 방지)
