# Bamboo Forest 🎋

Slack 채널에서 익명으로 메시지를 게시할 수 있는 대나무숲 봇입니다.

## ✨ 주요 기능

- 🎭 **익명 메시지 게시**: `/bamboo` 커맨드로 어디서나 익명 메시지 작성
- 💬 **익명 스레드**: 게시된 메시지에 익명으로 답글 달기
- 🏷️ **선택적 닉네임**: "3년차 개발자", "신입사원" 등 익명 닉네임 설정 가능
- ✅ **게시 전 확인**: 수정/삭제 불가 확인 체크박스로 실수 방지
- ⚡ **AWS Lambda 서버리스 아키텍처**
- 📋 **카테고리 선택**: 건의사항, 질문, 칭찬, 고민, 기타 카테고리 분류
- 🚨 **긴급도 설정**: 긴급, 보통, 여유 중 선택하여 중요도 표시
- 👍 **이모지 반응**: 공감, 비공감, 응원, 힘내 반응 및 Google Sheets 자동 기록
- ✅ **처리 완료 버튼**: 관리자나 당사자가 메시지 처리 상태 표시 가능
- 👤 **사용자 멘션**: 특정 사용자에게 메시지를 전달하고 알림 전송 가능

## 🔧 동작 원리

1. 사용자가 `/bamboo` 커맨드 실행
2. 메시지 입력 모달 표시 (메시지, 카테고리, 긴급도, 닉네임, 멘션 대상, 확인 체크박스)
3. 확인 체크박스 선택 후 제출
4. 지정된 채널에 익명 메시지 게시
5. "익명 답글 달기" 버튼으로 스레드에 익명 답글 가능

## 📋 요구사항

### AWS
- AWS Lambda
- AWS Secrets Manager
- IAM 권한 (Lambda 실행 역할, Secrets Manager 접근)

### Slack
- Slack App 생성
- Bot Token (`xoxb-...`)
- Signing Secret
- Slash Command 설정 (`/bamboo`)
- Interactivity 활성화

### Google Cloud Platform (선택)
- Google Sheets API 활성화
- 서비스 계정 JSON 키
- Note: 이모지 반응 추적 기능 사용 시 필요

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
cd packages/bamboo-forest

# Linux용 바이너리 빌드 (Lambda 환경)
GOOS=linux GOARCH=amd64 go build -o bootstrap main.go

# ZIP 파일 생성
zip function.zip bootstrap
```

### 3. AWS Secrets Manager 설정

```bash
# 시크릿 생성
aws secretsmanager create-secret \
  --name bamboo-forest/slack \
  --description "Bamboo Forest Slack Bot credentials" \
  --secret-string '{
    "SLACK_BOT_TOKEN": "xoxb-your-token-here",
    "SLACK_SIGNING_SECRET": "your-signing-secret-here",
    "GOOGLE_CLOUD_PROJECT_ID": "your-gcp-project-id",
    "GOOGLE_CREDS": {"type":"service_account",...},
    "SHEETS_ID": "your-google-sheets-id"
  }'
```

또는 AWS 콘솔에서 직접 생성:
```json
{
  "SLACK_BOT_TOKEN": "xoxb-...",
  "SLACK_SIGNING_SECRET": "...",
  "GOOGLE_CLOUD_PROJECT_ID": "your-gcp-project-id",
  "GOOGLE_CREDS": "{\"type\":\"service_account\",...}",
  "SHEETS_ID": "your-google-sheets-id"
}
```

> **Note**: Google Sheets 연동이 필요 없다면 GCP 관련 항목은 생략 가능합니다.

### 4. IAM 역할 생성

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
  --role-name bamboo-forest-lambda-role \
  --assume-role-policy-document file://trust-policy.json

# 기본 Lambda 실행 정책 연결
aws iam attach-role-policy \
  --role-name bamboo-forest-lambda-role \
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
      "Resource": "arn:aws:secretsmanager:*:*:secret:bamboo-forest/*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name bamboo-forest-lambda-role \
  --policy-name SecretsManagerAccess \
  --policy-document file://secrets-policy.json

# 정리
rm trust-policy.json secrets-policy.json
```

### 5. Lambda 함수 생성

```bash
# 계정 ID 확인
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Lambda 함수 생성
aws lambda create-function \
  --function-name bamboo-forest \
  --runtime provided.al2 \
  --handler bootstrap \
  --role arn:aws:iam::${AWS_ACCOUNT_ID}:role/bamboo-forest-lambda-role \
  --zip-file fileb://function.zip \
  --timeout 10 \
  --memory-size 128 \
  --environment "Variables={SECRET_NAME=bamboo-forest/slack}"

# Function URL 생성 (인증 없음 - Slack에서 직접 호출)
aws lambda create-function-url-config \
  --function-name bamboo-forest \
  --auth-type NONE

# Function URL에 대한 퍼블릭 접근 허용
aws lambda add-permission \
  --function-name bamboo-forest \
  --statement-id FunctionURLAllowPublicAccess \
  --action lambda:InvokeFunctionUrl \
  --principal "*" \
  --function-url-auth-type NONE
```

### 6. Function URL 확인

```bash
# Function URL 확인
aws lambda get-function-url-config \
  --function-name bamboo-forest \
  --query 'FunctionUrl' \
  --output text
```

출력 예시: `https://xxxxxxxxxx.lambda-url.ap-northeast-2.on.aws/`

### 7. 코드 업데이트 (재배포)

```bash
# 다시 빌드
GOOS=linux GOARCH=amd64 go build -o bootstrap main.go
zip function.zip bootstrap

# Lambda 함수 업데이트
aws lambda update-function-code \
  --function-name bamboo-forest \
  --zip-file fileb://function.zip
```

### 8. Slack App 설정

1. **Slash Commands** 페이지
   - Command: `/bamboo`
   - Request URL: Lambda Function URL
   - Short Description: 익명 메시지 게시

2. **Interactivity & Shortcuts** 페이지
   - Interactivity: On
   - Request URL: Lambda Function URL (Slash Command와 동일)

3. **OAuth & Permissions**
   - Bot Token Scopes:
     - `commands`
     - `chat:write`
     - `chat:write.public` (봇이 초대되지 않은 채널에도 게시)
     - `users:read` (사용자 멘션 기능)

4. Workspace에 앱 설치

### 5. 채널 설정

`main.go`의 `TargetChannelID` 상수를 대상 채널 ID로 변경:

```go
const TargetChannelID = "C09SQ9N05MZ" // 여기에 실제 채널 ID 입력
```

## 💻 로컬 개발

```bash
# 환경 변수 설정
export SLACK_BOT_TOKEN="xoxb-..."
export SLACK_SIGNING_SECRET="..."

# (선택) Google Sheets 연동
export GOOGLE_CLOUD_PROJECT_ID="your-project-id"
export GOOGLE_CREDS='{"type":"service_account",...}'
export SHEETS_ID="your-sheets-id"

# 실행
go run main.go
```

**참고**: 로컬 개발 시 ngrok 등을 사용하여 Slack에서 접근 가능한 URL을 만들어야 합니다.

## 📱 사용 방법

### 익명 메시지 게시
1. 아무 채널에서나 `/bamboo` 입력
2. 모달에서 메시지 작성
3. 카테고리 선택
4. 긴급도 선택
5. (선택) 닉네임 입력
6. (선택) 멘션 대상 지정
7. "수정/삭제 불가" 체크박스 선택
8. "게시하기" 클릭

### 익명 답글 달기
1. 게시된 익명 메시지 하단의 "💬 익명 답글 달기" 버튼 클릭
2. 답글 작성
3. (선택) 닉네임 입력
4. (선택) 멘션 대상 지정
5. 확인 체크박스 선택
6. "답글 달기" 클릭

### 이모지 반응
- 게시된 메시지 하단의 반응 버튼(👍, 👎, 🤗, 💪)으로 공감 표시
- 한 사람당 이모지당 1회만 가능 (중복 방지 해시 사용)
- 반응 데이터는 설정된 Google Sheets에 자동으로 기록됩니다

### 처리 완료
- 메시지 하단의 "✅ 처리 완료" 버튼 클릭 시 처리 상태 표시
- 버튼 클릭 시 헤더에 처리한 사용자 정보가 추가되며, "처리 완료" 버튼은 사라집니다

## ⚠️ 주의사항

- 게시된 메시지는 **수정하거나 삭제할 수 없습니다**
- 타인을 비방하거나 불쾌감을 주는 내용은 삼가주세요
- 관리자가 Slack 관리 도구를 통해 메시지를 삭제할 수 있습니다

## 📝 라이선스

MIT

## 👨‍💻 개발자

[@hakunlee](https://github.com/hakunlee)
