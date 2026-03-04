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

### [shuffle-bot](./packages/shuffle-bot)
Slack 채널에서 셔플/룰렛을 실행할 수 있는 봇

- ✅ `/shuffle @사람1 @사람2` 빠른 실행 (모달 없이)
- ✅ `/shuffle 2 @사람1 @사람2 @사람3` 숫자로 룰렛
- ✅ `/shuffle #채널` 채널 멤버 대상 실행
- ✅ 모달을 통한 상세 설정 (유저그룹, 제외 인원 등)
- ✅ 결과 메시지에 커스텀 제목 지원
- ✅ AWS Lambda 서버리스 아키텍처

### [ai-prompts](./packages/ai-prompts)
팀 공용 AI 프롬프트 (Commands & Skills) 저장소

- ✅ 팀 공용 슬래시 커맨드/스킬 공유
- ✅ Claude 세션 시작 시 자동 업데이트
- ✅ sparse-checkout으로 ai-prompts만 설치 (전체 레포 X)

```bash
curl -fsSL https://raw.githubusercontent.com/SAZO-KR/sazo-toolkit/main/packages/ai-prompts/install.sh | bash
```

## 🏗️ Slack 앱 구조

이 저장소의 Slack 봇들은 **두 가지 유형**의 앱으로 운영됩니다:

### 독립 앱 (전용 아이콘/이름이 필요한 경우)

| 앱 | 패키지 | 설명 |
|---|---|---|
| 🎋 대나무숲 | bamboo-forest | 익명 메시지 봇 (전용 아이콘 필요) |
| 🤖 번역봇 | translate-bot | 자동 번역 봇 (전용 아이콘 필요) |

### 범용 유틸리티 앱 (Sazo Toolkit)

조직 내에서 범용적으로 필요한 유틸리티들을 하나의 앱에 모아 운영합니다.

| 커맨드 | 패키지 | 설명 |
|---|---|---|
| `/shuffle` | shuffle-bot | 셔플/룰렛 |

> 새로운 유틸리티를 추가할 때는 이 앱에 커맨드/기능을 추가하고, Lambda는 별도로 배포합니다.
> 모든 유틸리티가 하나의 Slack 앱(Bot Token, Signing Secret)을 공유하므로, Secrets Manager에 하나의 시크릿만 관리하면 됩니다.

## 🔧 Slack 신규 앱 만들기 (범용 유틸리티 앱 기준)

### Step 1. 앱 생성

1. [api.slack.com/apps](https://api.slack.com/apps) 접속
2. **Create New App** → **From scratch** 선택
3. App Name: `Sazo Toolkit` (또는 원하는 이름)
4. Workspace: 설치할 워크스페이스 선택
5. **Create App** 클릭

### Step 2. Bot Token Scopes 설정

**OAuth & Permissions** 페이지 → **Scopes** 섹션 → **Bot Token Scopes**에 추가:

| Scope | 용도 |
|---|---|
| `commands` | 슬래시 커맨드 (`/shuffle` 등) |
| `chat:write` | 결과 메시지 전송 |
| `chat:write.public` | 공개 채널에 봇 초대 없이 전송 |
| `channels:read` | 공개 채널 멤버 목록 조회 |
| `groups:read` | 비공개 채널 멤버 목록 조회 |
| `usergroups:read` | 유저그룹 목록/멤버 조회 |
| `users:read` | 유저 이름 캐시 (제외 목록 표시용) |

> 새 유틸리티 추가 시 필요한 스코프가 있다면 여기에 추가하고 앱을 재설치해야 합니다.

### Step 3. 워크스페이스에 설치

1. **OAuth & Permissions** 페이지 → **Install to Workspace** 클릭
2. 권한 허용
3. 설치 완료 후 **Bot User OAuth Token** (`xoxb-...`) 복사 → 메모해둡니다

### Step 4. Signing Secret 확인

1. **Basic Information** 페이지 → **App Credentials** 섹션
2. **Signing Secret** → **Show** 클릭 → 복사 → 메모해둡니다

### Step 5. AWS Secrets Manager에 저장

```bash
aws secretsmanager create-secret \
  --name sazo-toolkit/slack \
  --description "Sazo Toolkit Slack App credentials" \
  --secret-string '{
    "SLACK_BOT_TOKEN": "xoxb-...",
    "SLACK_SIGNING_SECRET": "..."
  }'
```

> 이 시크릿을 여러 Lambda 함수에서 공유할 수 있습니다.

### Step 6. Interactivity 활성화

1. **Interactivity & Shortcuts** 페이지
2. **Interactivity** → **On** 토글
3. **Request URL**: 해당 기능의 Lambda Function URL 입력
4. **Save Changes**

> ⚠️ 하나의 앱에 Interactivity URL은 하나만 설정 가능합니다.
> 여러 Lambda를 사용할 경우, API Gateway 등으로 라우팅하거나 하나의 Lambda에서 분기 처리가 필요할 수 있습니다.
> 현재는 각 커맨드가 독립 Lambda이므로, 커맨드별로 Slash Command URL은 개별 설정하되 Interactivity URL은 해당 기능의 Lambda를 지정합니다.

### Step 7. Slash Command 등록

1. **Slash Commands** 페이지 → **Create New Command**
2. 설정:
   - **Command**: `/shuffle`
   - **Request URL**: shuffle-bot Lambda Function URL
   - **Short Description**: 셔플/룰렛 실행
3. **Save**

### Step 8. Lambda 배포

각 패키지의 README에 있는 배포 가이드를 따릅니다.
Lambda 환경변수에서 `SECRET_NAME`을 공유 시크릿(`sazo-toolkit/slack`)으로 지정합니다.

```bash
aws lambda create-function \
  --function-name shuffle-bot \
  --runtime provided.al2 \
  --handler bootstrap \
  --role arn:aws:iam::${AWS_ACCOUNT_ID}:role/shuffle-bot-lambda-role \
  --zip-file fileb://packages/shuffle-bot/function.zip \
  --timeout 10 \
  --memory-size 128 \
  --environment "Variables={SECRET_NAME=sazo-toolkit/slack}"
```

### 새 유틸리티 추가 시 체크리스트

1. `packages/`에 새 패키지 생성
2. 필요한 Bot Token Scope 추가 → 앱 재설치
3. Slash Command 추가 (커맨드 URL = 새 Lambda Function URL)
4. Interactivity URL 라우팅 검토
5. Lambda 배포 (`SECRET_NAME=sazo-toolkit/slack` 공유)
6. 이 README의 범용 유틸리티 앱 테이블에 항목 추가

## 📝 기여 가이드

새로운 도구를 추가할 때는 `packages/` 디렉토리에 별도 패키지로 추가하고 해당 README를 작성해주세요.
