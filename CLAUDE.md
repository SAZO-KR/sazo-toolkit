# CLAUDE.md

팀 생산성 도구 모노레포. 각 패키지는 독립적인 기술 스택을 사용한다.

## 프로젝트 구조

```
packages/
├── ai-harness/      # AI 에이전트/스킬/커맨드 + 모듈형 인스톨러
├── translate-bot/   # 번역 봇 (Go + AWS Lambda)
├── bamboo-forest/   # 익명 게시판 봇 (Go + AWS Lambda)
└── shuffle-bot/     # 셔플/룰렛 봇 (Go + AWS Lambda)
```

## 🔄 CI 커맨드

이 프로젝트는 패키지별로 독립 빌드/테스트한다. 통합 CI 커맨드는 없다.

| 패키지                                                | 검증 방법                                                          |
| ----------------------------------------------------- | ------------------------------------------------------------------ |
| ai-harness                                            | `bash -n packages/ai-harness/install.sh && bash -n packages/ai-harness/uninstall.sh && bash packages/ai-harness/tests/installer.smoke.sh` |
| Go 패키지 (translate-bot, bamboo-forest, shuffle-bot) | `cd packages/{name} && go build ./...`                             |

## 패키지별 규칙

### ai-harness

- 모듈형 인스톨러 시스템: 각 도구는 `tools/<name>/` 아래 자기완결형 패키지
- 루트 인스톨러: `install.sh` — 인터랙티브 메뉴 + `--tools` CLI 플래그
- 개별 인스톨러: 각 도구는 독립적으로 `curl | bash` 설치 가능
- 수령증(receipt) 기반 제거: `~/.config/sazo-ai-harness/receipts/`로 설치 추적
- 공통 라이브러리: `lib/installer-common.sh` (로깅, 프롬프트, 잠금, 수령증 등)
- 기존 설치 제거: `curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-harness/uninstall.sh | bash`

### Go 패키지 (Slack 봇)

- AWS Lambda 배포 대상
- `GOOS=linux GOARCH=amd64 go build` 로 크로스 컴파일
- 시크릿: AWS Secrets Manager (패키지별 상이)
  - translate-bot: `translate-bot/config`
  - bamboo-forest: `bamboo-forest/slack`
  - shuffle-bot: `sazo-toolkit/slack` (범용 앱 공유)
- 환경변수: `SECRET_NAME` 으로 시크릿 이름 지정

## 커밋 규칙

- `feat(패키지명): 설명` — 기능 추가
- `fix(패키지명): 설명` — 버그 수정
- `docs(패키지명): 설명` — 문서만 수정
