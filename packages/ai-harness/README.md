# AI Harness (Archived)

> **이 패키지의 hook/workflow 시스템은 폐기되었습니다.**
> Agent 정의, 스킬, 커맨드(awake, weekly-report)만 보존됩니다.

## 기존 설치 제거

```bash
curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-harness/uninstall.sh | bash
```

제거 대상:
- `~/.config/sazo-ai-harness/` (설치 디렉토리)
- `~/.claude/{commands,skills,agents}/` 내 sazo-ai-harness 심볼릭 링크
- `~/.claude/settings.json` 내 hook 항목
- `~/.claude/CLAUDE.md` 내 managed block
- `~/.local/bin/{awake,sazo-workflow,claude-sync-notify.sh}`
- `~/.claude/session-state/`, 로그 파일
- LaunchAgent (claude-sync)

OpenCode 플러그인/모델 설정, RTK, claude-sync는 별도 관리이므로 보존됩니다.

## 보존된 콘텐츠

### Agents

| 에이전트 | 역할 |
|---|---|
| `code-searcher` | in-repo 코드 검색 |
| `docs-researcher` | 외부 docs/OSS 리서치 |
| `image-analyzer` | 스크린샷/다이어그램 분석 |
| `plan-drafter` | 실행 플랜 초안 |
| `plan-auditor` | 플랜 gap 분석 |
| `plan-critic` | 플랜 최종 게이트 |
| `plan-executor` | 승인된 플랜 실행 |
| `ui-engineer` | 프론트엔드/UI 구현 |
| `code-reviewer` | diff 기반 코드리뷰 |
| `architect-advisor` | 아키텍처/설계 판단 |
| `doc-writer` | 기술 문서 작성 |

### Skills

| 스킬 | 용도 |
|---|---|
| `develop` | TDD + Tidy First 워크플로우 |
| `plan` | 3단계 플랜 파이프라인 |
| `review` | 독립 코드리뷰 |
| `isolate` | Worktree 격리 |
| `finish` | PR 생성 워크플로우 |
| `debug` | 디버깅 방법론 |
| `document` | 기술 문서 작성 |
| `automated-code-review-cycle` | 봇 리뷰 피드백 루프 |

### Commands

| 커맨드 | 설명 |
|---|---|
| `/weekly-report` | 주간 업무 보고서 생성 |
| `/awake` | macOS sleep 차단 CLI |
