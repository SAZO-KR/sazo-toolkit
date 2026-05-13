# CLAUDE.md

팀 생산성 도구 모노레포. 각 패키지는 독립적인 기술 스택을 사용한다.

## 프로젝트 구조

```
packages/
├── ai-harness/      # AI 에이전트/스킬/커맨드 (archived)
├── translate-bot/   # 번역 봇 (Go + AWS Lambda)
├── bamboo-forest/   # 익명 게시판 봇 (Go + AWS Lambda)
└── shuffle-bot/     # 셔플/룰렛 봇 (Go + AWS Lambda)
```

## 🔄 CI 커맨드

이 프로젝트는 패키지별로 독립 빌드/테스트한다. 통합 CI 커맨드는 없다.

| 패키지                                                | 검증 방법                                                          |
| ----------------------------------------------------- | ------------------------------------------------------------------ |
| ai-harness                                            | `bash -n packages/ai-harness/uninstall.sh` |
| Go 패키지 (translate-bot, bamboo-forest, shuffle-bot) | `cd packages/{name} && go build ./...`                             |

## 패키지별 규칙

### ai-harness (archived)

- Hook/workflow 시스템 폐기됨. Agent 정의, 스킬, 커맨드만 보존.
- 기존 설치 제거: `curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-harness/uninstall.sh | bash`

### Go 패키지 (Slack 봇)

- AWS Lambda 배포 대상
- `GOOS=linux GOARCH=amd64 go build` 로 크로스 컴파일
- 시크릿: AWS Secrets Manager (`sazo-toolkit/slack`)
- 환경변수: `SECRET_NAME` 으로 시크릿 이름 지정

## 커밋 규칙

- `feat(패키지명): 설명` — 기능 추가
- `fix(패키지명): 설명` — 버그 수정
- `docs(패키지명): 설명` — 문서만 수정
