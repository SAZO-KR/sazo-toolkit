# AI Harness

Agent 정의, 스킬, 커맨드, 그리고 개별 도구를 설치합니다.

## 설치

### 전체 설치 (인터랙티브 메뉴)

```bash
curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-harness/install.sh | bash
```

### 개별 도구 설치

```bash
# awake만 설치
curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-harness/install.sh | bash -s -- --tools awake

# 비대화형으로 전체 설치
curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-harness/install.sh | bash -s -- --yes
```

### 설치 내용

- `~/.claude/{commands,skills,agents}/` 에 심볼릭 링크 생성
- 선택한 도구의 개별 인스톨러 실행
- OpenCode 설치 시 `~/.config/opencode/commands/` 에도 링크 생성

## 제거

```bash
# 전체 제거
curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-harness/uninstall.sh | bash

# 개별 도구 제거
bash ~/.config/sazo-ai-harness/packages/ai-harness/tools/awake/uninstall.sh
```

## 사용 가능한 도구

| 도구 | 설명 | 플랫폼 | sudo 필요 |
|---|---|---|---|
| `awake` | macOS 닫힌 뚜껑 실행 유지 CLI | darwin | 선택 |

## 도구 구조

각 도구는 `tools/<name>/` 아래에 자기완결형 패키지로 구성됩니다:

```
tools/<name>/
├── tool.sh          # 매니페스트 (이름, 버전, 플랫폼)
├── install.sh       # 개별 인스톨러
├── uninstall.sh     # 개별 제거기
├── scripts/         # 도구 스크립트
├── commands/        # 커맨드 정의
└── tests/           # 스모크 테스트
```

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
| `/awake` | macOS closed-lid 실행 유지 CLI |