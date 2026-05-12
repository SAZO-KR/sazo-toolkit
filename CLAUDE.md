# CLAUDE.md

팀 생산성 도구 모노레포. 각 패키지는 독립적인 기술 스택을 사용한다.

## 프로젝트 구조

```
packages/
├── ai-harness/      # AI 에이전트 설정 하네스 (Bash)
├── claude-notify/   # Claude 완료 알림 (Bash)
├── translate-bot/   # 번역 봇 (Go + AWS Lambda)
├── bamboo-forest/   # 익명 게시판 봇 (Go + AWS Lambda)
└── shuffle-bot/     # 셔플/룰렛 봇 (Go + AWS Lambda)
```

## 🔄 CI 커맨드

이 프로젝트는 패키지별로 독립 빌드/테스트한다. 통합 CI 커맨드는 없다.

| 패키지                                                | 검증 방법                                                          |
| ----------------------------------------------------- | ------------------------------------------------------------------ |
| ai-harness                                            | `bash -n scripts/auto-update.sh && bash -n install.sh && bash -n scripts/setup-rtk.sh && bash -n scripts/awake/awake.sh && bash -n scripts/sazo-workflow.sh && bash scripts/tests/setup-rtk.smoke.sh && bash scripts/tests/awake.smoke.sh && bash scripts/tests/sleep-guard-cleanup.smoke.sh && bash scripts/tests/workflow-hooks.smoke.sh && bash scripts/tests/footer-parser.smoke.sh && bash scripts/tests/verdict-nonce.smoke.sh && bash scripts/tests/verdict-aggregation.smoke.sh && bash scripts/tests/state-truncate.smoke.sh && bash scripts/tests/verdict-flow.smoke.sh && bash scripts/tests/ci-invalidate.smoke.sh && bash scripts/tests/workflow-cli.smoke.sh && bash scripts/tests/phase1-default.smoke.sh && bash scripts/tests/general-purpose-gate.smoke.sh && bash scripts/tests/approval-immediate.smoke.sh && bash scripts/tests/slash-detect.smoke.sh && bash scripts/tests/session-end-metrics.smoke.sh && bash scripts/tests/task-output-audit.smoke.sh && bash scripts/tests/auto-skip-block.smoke.sh && bash scripts/tests/approval-bypass.smoke.sh && bash scripts/tests/worktree-gate.smoke.sh && bash scripts/tests/pr-merge-gate.smoke.sh && bash scripts/tests/register-stale-dedup.smoke.sh && bash scripts/tests/bot-review-label.smoke.sh && bash scripts/tests/skip-streak.smoke.sh` |
| Go 패키지 (translate-bot, bamboo-forest, shuffle-bot) | `cd packages/{name} && go build ./...`                             |
| 셸 스크립트 (claude-notify)                           | `bash -n scripts/*.sh`                                             |

## 패키지별 규칙

### ai-harness (팀 공유 AI 설정)

- `commands/`, `skills/`, `agents/` → `~/.claude/`에 심볼릭 링크됨
- `_TEMPLATE*` 파일은 link 대상에서 제외됨
- `install.sh` 수정 시 → 반드시 새 환경에서 테스트 (기존 설치 깨뜨리지 않는지)
- `scripts/auto-update.sh` → SessionStart 훅으로 실행됨. 비대화형이어야 함.
- **스킬 권한 선언 필수**: 스킬이 기본 allow 리스트에 없는 bash 명령(`date`, `sleep`, `echo`, `seq` 등)을 사용하면, 해당 스킬 디렉토리에 `permissions.json`을 두어 declare한다. `install.sh`와 `auto-update.sh`가 자동으로 `~/.claude/settings.json`의 `permissions.allow`에 union한다. 상세는 `packages/ai-harness/README.md` 참조.

### Go 패키지 (Slack 봇)

- AWS Lambda 배포 대상
- `GOOS=linux GOARCH=amd64 go build` 로 크로스 컴파일
- 시크릿: AWS Secrets Manager (`sazo-toolkit/slack`)
- 환경변수: `SECRET_NAME` 으로 시크릿 이름 지정

## 커밋 규칙

- `feat(패키지명): 설명` — 기능 추가
- `fix(패키지명): 설명` — 버그 수정
- `docs(패키지명): 설명` — 문서만 수정
