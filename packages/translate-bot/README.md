# Translate Bot 🤖

Slack 채널에서 한국어와 일본어를 자동으로 번역해주는 봇입니다.

## ✨ 주요 기능

- 🇰🇷 **한국어 → 일본어** 자동 번역
- 🇯🇵 **일본어 → 한국어** 자동 번역
- 🧵 스레드로 자동 회신
- 📝 긴 텍스트도 안전하게 분할 번역 (UTF-8 문자 경계 처리)
- 🔇 **번역 토글**: `!tt` 명령어로 스레드별 번역 ON/OFF 전환
- 🔄 **반복 정규화**: 반복 문자를 자동 정리하여 번역 품질 향상 (4자 이상 반복 → 3자로 축소)
- 💱 **통화·표현 보호**: 원↔ウォン, 엔↔円, ㅋㅋㅋ↔www 자동 변환
- ⚡ AWS Lambda 기반 서버리스 아키텍처

## 🛠️ 기술 스택

- **언어**: Go 1.x
- **클라우드**: AWS Lambda (Function URL)
- **번역 API**: Google Cloud Translation API (Advanced LLM model)
- **메시징**: Slack Events API
- **인증**: AWS Secrets Manager

## 📋 요구사항

### AWS
- AWS Lambda
- AWS Secrets Manager
- IAM 권한 (Lambda 실행 역할, Secrets Manager 접근)

### Google Cloud Platform
- Google Cloud Translation API 활성화
- 서비스 계정 JSON 키

### Slack
- Slack App 생성
- Bot Token (`xoxb-...`)
- Signing Secret
- Event Subscriptions 활성화
  - `message.channels` 또는 `message.groups` 스코프

## 🚀 배포 방법

### 1. 사전 준비

```bash
# AWS CLI 설치 확인
aws --version

# AWS 자격 증명 설정 (아직 안했다면)
aws configure
```

### 2. 빌드

```bash
cd packages/translate-bot

# Linux용 바이너리 빌드 (Lambda 환경)
GOOS=linux GOARCH=amd64 go build -o bootstrap main.go

# ZIP 파일 생성
zip function.zip bootstrap
```

### 3. GCP 서비스 계정 준비

1. [Google Cloud Console](https://console.cloud.google.com/)에서 프로젝트 생성/선택
2. **APIs & Services > Enable APIs** 에서 `Cloud Translation API` 활성화
3. **IAM & Admin > Service Accounts** 에서 서비스 계정 생성
4. **Keys** 탭에서 JSON 키 생성 및 다운로드
5. JSON 키 내용을 한 줄로 변환 (줄바꿈 제거):

```bash
# JSON 파일을 한 줄로 변환
cat your-service-account.json | jq -c '.'
```

### 4. AWS Secrets Manager 설정

```bash
# 시크릿 생성 (GCP JSON은 이스케이프 필요)
aws secretsmanager create-secret \
  --name translate-bot/config \
  --description "Translate Bot configuration" \
  --secret-string '{
    "SLACK_BOT_TOKEN": "xoxb-your-token-here",
    "SLACK_SIGNING_SECRET": "your-signing-secret-here",
    "GOOGLE_CLOUD_PROJECT_ID": "your-gcp-project-id",
    "GOOGLE_TRANSLATE_API_LOCATION": "global",
    "GOOGLE_CREDS": {"type":"service_account","project_id":"...전체 서비스 계정 JSON..."}
  }'
```

**참고**: `GOOGLE_CREDS`는 JSON 객체 형태로 직접 넣거나, 문자열로 이스케이프하여 넣을 수 있습니다.

AWS 콘솔에서 직접 생성할 경우:
```json
{
  "SLACK_BOT_TOKEN": "xoxb-...",
  "SLACK_SIGNING_SECRET": "...",
  "GOOGLE_CLOUD_PROJECT_ID": "your-project-id",
  "GOOGLE_TRANSLATE_API_LOCATION": "global",
  "GOOGLE_CREDS": {"type":"service_account","project_id":"..."}
}
```

### 5. IAM 역할 생성

```bash
# Lambda 실행 역할 신뢰 정책 파일 생성
cat > trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# IAM 역할 생성
aws iam create-role \
  --role-name translate-bot-lambda-role \
  --assume-role-policy-document file://trust-policy.json

# 기본 Lambda 실행 정책 연결
aws iam attach-role-policy \
  --role-name translate-bot-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# Secrets Manager 접근 정책 생성
cat > secrets-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "arn:aws:secretsmanager:*:*:secret:translate-bot/*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name translate-bot-lambda-role \
  --policy-name SecretsManagerAccess \
  --policy-document file://secrets-policy.json

# 정리
rm trust-policy.json secrets-policy.json
```

### 6. Lambda 함수 생성

```bash
# 계정 ID 확인
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Lambda 함수 생성
aws lambda create-function \
  --function-name translate-bot \
  --runtime provided.al2 \
  --handler bootstrap \
  --role arn:aws:iam::${AWS_ACCOUNT_ID}:role/translate-bot-lambda-role \
  --zip-file fileb://function.zip \
  --timeout 15 \
  --memory-size 128 \
  --environment "Variables={SECRET_NAME=translate-bot/config}"

# Function URL 생성 (인증 없음 - Slack에서 직접 호출)
aws lambda create-function-url-config \
  --function-name translate-bot \
  --auth-type NONE

# Function URL에 대한 퍼블릭 접근 허용
aws lambda add-permission \
  --function-name translate-bot \
  --statement-id FunctionURLAllowPublicAccess \
  --action lambda:InvokeFunctionUrl \
  --principal "*" \
  --function-url-auth-type NONE
```

### 7. Function URL 확인

```bash
# Function URL 확인
aws lambda get-function-url-config \
  --function-name translate-bot \
  --query 'FunctionUrl' \
  --output text
```

출력 예시: `https://xxxxxxxxxx.lambda-url.ap-northeast-2.on.aws/`

### 8. 코드 업데이트 (재배포)

```bash
# 다시 빌드
GOOS=linux GOARCH=amd64 go build -o bootstrap main.go
zip function.zip bootstrap

# Lambda 함수 업데이트
aws lambda update-function-code \
  --function-name translate-bot \
  --zip-file fileb://function.zip
```

### 9. Slack App 설정

1. **Event Subscriptions** 페이지
   - Request URL: Lambda Function URL
   - Subscribe to bot events:
     - `message.channels` (공개 채널)
     - `message.groups` (비공개 채널)

2. **OAuth & Permissions**
   - Bot Token Scopes:
     - `chat:write`
     - `channels:history` (또는 `groups:history`)

3. Workspace에 앱 설치

## 📱 사용 방법

### 번역 토글 (`!tt`)

스레드에서 `!tt`를 입력하면 해당 스레드의 번역을 ON/OFF 할 수 있습니다.

- **번역 OFF**: 봇이 `no_translate` 이모지를 추가하고 해당 스레드의 번역을 중단합니다
- **번역 ON**: `no_translate` 이모지를 제거하고 번역을 재개합니다

> 봇이 자동으로 번역하지 않아야 할 스레드 (예: 코드 논의, 특정 언어로만 진행되는 대화)에서 유용합니다.

## 💻 로컬 개발

```bash
# 환경 변수 설정
export SLACK_BOT_TOKEN="xoxb-..."
export SLACK_SIGNING_SECRET="..."
export GOOGLE_CLOUD_PROJECT_ID="your-project-id"
export GOOGLE_TRANSLATE_API_LOCATION="global"
export GOOGLE_CREDS='{"type":"service_account",...}'

# 실행
go run main.go
```

**참고**: 로컬 개발 시에는 `SECRET_NAME` 환경 변수를 설정하지 않으면 환경 변수에서 직접 로드됩니다.

## 🔧 동작 원리

1. Slack에서 메시지 이벤트 발생
2. Lambda Function URL로 POST 요청
3. Slack 서명 검증
4. 메시지에서 한국어/일본어 감지
   - 한국어만 포함 → 일본어로 번역
   - 일본어만 포함 → 한국어로 번역
   - 둘 다 포함 또는 둘 다 없음 → 건너뛰기
5. Google Cloud Translation API로 번역
6. 원본 메시지의 스레드에 번역 결과 게시

## 📝 라이선스

MIT

## 👨‍💻 개발자

[@hakunlee](https://github.com/hakunlee)
