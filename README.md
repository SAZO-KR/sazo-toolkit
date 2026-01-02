# Sazo Toolkit

팀 생산성 향상을 위한 도구 모음 저장소

## 📦 패키지

### [claude-notify](./packages/claude-notify)
Claude CLI 응답 완료 시 macOS 알림을 보내주는 훅 설치 스크립트

- ✅ 응답 완료 시 자동 알림
- ✅ Git 브랜치 정보 포함
- ✅ Worktree 환경 지원

### [translate-bot](./packages/translate-bot)
Slack 채널에서 한국어와 일본어를 자동으로 번역해주는 봇

- ✅ 한국어 ↔ 일본어 자동 번역
- ✅ 스레드로 자동 회신
- ✅ AWS Lambda 서버리스 아키텍처
- ✅ Google Cloud Translation API (LLM 모델) 사용

### [bamboo-forest](./packages/bamboo-forest)
Slack 채널에서 익명으로 메시지를 게시할 수 있는 대나무숲 봇

- ✅ `/bamboo` 커맨드로 익명 메시지 게시
- ✅ 익명 스레드 답글 기능
- ✅ 선택적 닉네임 설정
- ✅ AWS Lambda 서버리스 아키텍처

## 📝 기여 가이드

새로운 도구를 추가할 때는 `packages/` 디렉토리에 별도 패키지로 추가하고 해당 README를 작성해주세요.
