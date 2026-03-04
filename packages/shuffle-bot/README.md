# Shuffle Bot 🎲

Slack 채널에서 셔플/룰렛을 실행할 수 있는 봇입니다.

## ✨ 주요 기능

- 🎲 **셔플**: 대상 인원을 랜덤으로 섞어 전체 순서를 보여줍니다
- 🎰 **룰렛**: 지정한 인원 수만큼 당첨자를 뽑습니다
- 📢 **채널 멤버** 대상으로 실행
- 👥 **유저그룹** 대상으로 실행
- ✋ **직접 선택**한 사람들 대상으로 실행
- 🚫 채널/그룹 모드에서 특정 사람 **제외** 가능
- ⚡ AWS Lambda 서버리스 아키텍처

## 🔧 동작 원리

1. 사용자가 `/shuffle` 커맨드 실행
2. 기본: 현재 채널 멤버가 자동으로 대상이 됨 (별도 선택 불필요)
3. 모달에서 필요 시 유저그룹/직접 선택으로 변경 가능
4. 제외 인원, 모드(셔플/룰렛) 설정
5. "실행!" 클릭 → 결과 메시지를 채널에 공개 전송

## 📋 요구사항

### AWS
- AWS Lambda
- AWS Secrets Manager
- IAM 권한 (Lambda 실행 역할, Secrets Manager 접근)

### Slack
- Slack App 생성
- Bot Token (`xoxb-...`)
- Signing Secret
- Slash Command 설정 (`/shuffle`)
- Interactivity 활성화

### Bot Token Scopes
- `commands` — `/shuffle` 슬래시 커맨드
- `chat:write` — 결과 메시지 전송
- `chat:write.public` — 공개 채널에 봇 초대 없이 전송
- `channels:read` — 공개 채널 멤버 조회
- `groups:read` — 비공개 채널 멤버 조회
- `usergroups:read` — 유저그룹 목록/멤버 조회
- `users:read` — 유저 이름 캐시 (제외 목록 표시용)

## 🚀 배포 방법

### 1. 빌드

```bash
cd packages/shuffle-bot

# Linux용 바이너리 빌드 (Lambda 환경)
GOOS=linux GOARCH=amd64 go build -o bootstrap main.go

# ZIP 파일 생성
zip function.zip bootstrap
```

### 2. AWS Secrets Manager 설정

범용 유틸리티 앱(Sazo Toolkit)의 공유 시크릿을 사용합니다.
이미 생성되어 있다면 이 단계는 건너뛰세요.

```bash
aws secretsmanager create-secret \
  --name sazo-toolkit/slack \
  --description "Sazo Toolkit Slack App credentials" \
  --secret-string '{
    "SLACK_BOT_TOKEN": "xoxb-your-token-here",
    "SLACK_SIGNING_SECRET": "your-signing-secret-here"
  }'
```

### 3. IAM 역할 생성

```bash
# Lambda 실행 역할 신뢰 정책
cat > trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name shuffle-bot-lambda-role \
  --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy \
  --role-name shuffle-bot-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# Secrets Manager 접근 정책
cat > secrets-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": "arn:aws:secretsmanager:*:*:secret:sazo-toolkit/*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name shuffle-bot-lambda-role \
  --policy-name SecretsManagerAccess \
  --policy-document file://secrets-policy.json

rm trust-policy.json secrets-policy.json
```

### 4. Lambda 함수 생성

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws lambda create-function \
  --function-name shuffle-bot \
  --runtime provided.al2 \
  --handler bootstrap \
  --role arn:aws:iam::${AWS_ACCOUNT_ID}:role/shuffle-bot-lambda-role \
  --zip-file fileb://function.zip \
  --timeout 10 \
  --memory-size 128 \
  --environment "Variables={SECRET_NAME=sazo-toolkit/slack}"

aws lambda create-function-url-config \
  --function-name shuffle-bot \
  --auth-type NONE

aws lambda add-permission \
  --function-name shuffle-bot \
  --statement-id FunctionURLAllowPublicAccess \
  --action lambda:InvokeFunctionUrl \
  --principal "*" \
  --function-url-auth-type NONE
```

### 5. Function URL 확인

```bash
aws lambda get-function-url-config \
  --function-name shuffle-bot \
  --query 'FunctionUrl' \
  --output text
```

### 6. 코드 업데이트 (재배포)

```bash
GOOS=linux GOARCH=amd64 go build -o bootstrap main.go
zip function.zip bootstrap

aws lambda update-function-code \
  --function-name shuffle-bot \
  --zip-file fileb://function.zip
```

### 7. Slack App 설정

1. **Slash Commands** 페이지
   - Command: `/shuffle`
   - Request URL: Lambda Function URL
   - Short Description: 셔플/룰렛 실행

2. **Interactivity & Shortcuts** 페이지
   - Interactivity: On
   - Request URL: Lambda Function URL (Slash Command와 동일)

3. **OAuth & Permissions**
   - Bot Token Scopes: `commands`, `chat:write`, `chat:write.public`, `channels:read`, `groups:read`, `usergroups:read`, `users:read`

4. Workspace에 앱 설치

## 💻 로컬 개발

```bash
export SLACK_BOT_TOKEN="xoxb-..."
export SLACK_SIGNING_SECRET="..."

go run main.go
```

## 📱 사용 방법

### 빠른 실행 (Quick Command)

모달 없이 바로 실행할 수 있습니다.

```
# 셔플
/shuffle @A @B @C
/shuffle @here                    (이 채널 멤버)

# 룰렛 (N명 추첨) — 숫자를 붙이면 룰렛
/shuffle 2 @A @B @C
/shuffle 1 @here

# 제외 — -- 뒤에 멘션하면 제외
/shuffle @here -- @제외할사람

# 제목 — 멘션 앞에 텍스트를 붙이면 결과 제목
/shuffle 점심당번 @A @B @C
/shuffle 리뷰어 2 @here

# 사용법
/shuffle help
```

### 상세 설정 (모달)

인자 없이 `/shuffle` 만 입력하면 모달이 열립니다.

1. 기본: 이 채널 멤버가 대상 (자동 선택, 멤버 수 표시)
2. 필요 시 유저그룹 또는 직접 선택으로 변경
3. 제외할 사람 선택 (100명 이하일 때 표시)
4. 모드 선택 (🎲 셔플 / 🎰 룰렛)
5. 룰렛인 경우 뽑을 인원 수 입력 (대상보다 크면 에러)
6. 제목 입력 (선택사항)
7. "실행!" 클릭 → 결과가 채널에 공개 메시지로 전송됨

## 📝 라이선스

MIT
