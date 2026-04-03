---
description: 주간 업무 보고서 생성 — 코드, 이슈, 메일, 슬랙, 캘린더, 문서 전체 취합
---

## Your Task

지난 한 주간의 **전체 업무 활동**을 수집하고 요약하여 Notion 호환 마크다운으로 출력합니다.

**CRITICAL: 모든 출력은 한국어로 작성합니다.**

## Step 0: 셋업 확인

### MCP 서비스 연결 확인

아래 6개 서비스에 대해 probe 호출로 연결 상태를 확인합니다. **반드시 병렬로 호출합니다.**
각 probe의 반환 값에서 사용자 ID를 추출하여 이후 단계에서 사용합니다.

| 서비스 | Probe 호출 | 성공 기준 | 저장할 값 |
|--------|-----------|----------|----------|
| Slack | `slack_read_user_profile()` (파라미터 없이) | user ID 반환 | `{MY_SLACK_ID}` ← 반환된 user_id |
| Linear | `get_authenticated_user()` | user 정보 반환 | `{MY_LINEAR_ID}` ← 반환된 id |
| Gmail | `gmail_get_profile()` | 이메일 주소 반환 | `{MY_EMAIL}` ← 반환된 emailAddress |
| Google Calendar | `gcal_list_calendars()` | 캘린더 목록 반환 | (ID 불필요) |
| Notion | `search(query: "test", query_type: "user", filters: {})` | 에러 없이 응답 | `{MY_NOTION_ID}` ← 본인 user_id |
| Git | `git log --oneline -1` | 커밋 해시 반환 | (ID 불필요) |

**연결 실패한 서비스**는 사용자에게 알리고, 해당 서비스를 건너뛴 채 진행합니다.
**모든 MCP 서비스가 실패하면** Git만으로 코드 변경 보고서를 생성합니다.

### MCP 도구 권한 영구 허용

연결 확인이 끝나면 사용자에게 한 번 물어봅니다:

> "연결된 서비스들의 읽기 권한을 영구적으로 허용하시겠습니까? (매 실행마다 승인 팝업이 뜨지 않게 됩니다)"

**사용자가 승인하면** `~/.claude/settings.json`의 `permissions.allow` 배열에 아래 항목을 추가합니다.
이미 존재하는 항목은 건너뜁니다.

```json
[
  "mcp__claude_ai_Slack__slack_search_public_and_private",
  "mcp__claude_ai_Slack__slack_read_thread",
  "mcp__claude_ai_Slack__slack_read_channel",
  "mcp__claude_ai_Slack__slack_read_user_profile",
  "mcp__claude_ai_Linear__list_issues",
  "mcp__claude_ai_Linear__get_issue",
  "mcp__claude_ai_Linear__get_authenticated_user",
  "mcp__claude_ai_Linear__get_project",
  "mcp__claude_ai_Gmail__gmail_search_messages",
  "mcp__claude_ai_Gmail__gmail_read_message",
  "mcp__claude_ai_Gmail__gmail_get_profile",
  "mcp__claude_ai_Google_Calendar__gcal_list_events",
  "mcp__claude_ai_Google_Calendar__gcal_list_calendars",
  "mcp__claude_ai_Notion__search",
  "mcp__claude_ai_Notion__fetch"
]
```

설정 파일 수정은 `jq`를 사용합니다:

```bash
SETTINGS="$HOME/.claude/settings.json"

# 설정 파일이 없으면 생성
if [ ! -f "$SETTINGS" ]; then
  mkdir -p "$(dirname "$SETTINGS")"
  echo '{}' > "$SETTINGS"
fi

TOOLS='["mcp__claude_ai_Slack__slack_search_public_and_private","mcp__claude_ai_Slack__slack_read_thread","mcp__claude_ai_Slack__slack_read_channel","mcp__claude_ai_Slack__slack_read_user_profile","mcp__claude_ai_Linear__list_issues","mcp__claude_ai_Linear__get_issue","mcp__claude_ai_Linear__get_authenticated_user","mcp__claude_ai_Linear__get_project","mcp__claude_ai_Gmail__gmail_search_messages","mcp__claude_ai_Gmail__gmail_read_message","mcp__claude_ai_Gmail__gmail_get_profile","mcp__claude_ai_Google_Calendar__gcal_list_events","mcp__claude_ai_Google_Calendar__gcal_list_calendars","mcp__claude_ai_Notion__search","mcp__claude_ai_Notion__fetch"]'

TMP=$(mktemp)
jq --argjson tools "$TOOLS" '.permissions.allow = ((.permissions.allow // []) + ($tools - (.permissions.allow // [])))' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
```

**사용자가 거부하면** 권한 등록을 건너뛰고 매번 수동 승인으로 진행합니다.

**이 셋업은 최초 1회만 실행합니다.** 이미 권한이 등록되어 있으면 이 단계를 건너뜁니다.
판단 기준: `settings.json`의 `permissions.allow`에 위 목록의 항목이 **모두** 포함되어 있으면 셋업 완료로 간주합니다. 일부만 있으면 누락된 항목만 추가 등록합니다.

## Step 1: 날짜 범위 계산

```bash
# 지난 금요일 계산 (금요일에 실행하면 지난주 금요일)
DOW=$(date +%u)
if [[ $DOW -ge 5 ]]; then
  DAYS_BACK=$((DOW - 5))
else
  DAYS_BACK=$((DOW + 2))
fi
# 금요일(DAYS_BACK=0)에 실행하면 지난주 금요일(7일 전)을 기준으로 함
if [[ $DAYS_BACK -eq 0 ]]; then
  DAYS_BACK=7
fi
LAST_FRIDAY=$(date -v-${DAYS_BACK}d +%Y-%m-%d 2>/dev/null || date -d "${DAYS_BACK} days ago" +%Y-%m-%d)
TODAY=$(date +%Y-%m-%d)
echo "분석 기간: $LAST_FRIDAY ~ $TODAY"
```

## Step 2: 데이터 수집

**연결 확인된 서비스에 대해서만 수집합니다. 가능한 한 병렬로 호출합니다.**

### 2-1. Git 커밋 (필수)

```bash
git fetch origin main

BASE_COMMIT=$(git log origin/main --since="$LAST_FRIDAY" --reverse --format="%H" | head -1)
if [ -z "$BASE_COMMIT" ]; then
  BASE_COMMIT=$(git log origin/main --until="$LAST_FRIDAY" --format="%H" -1)
fi

# 변경 요약
git log $BASE_COMMIT..origin/main --oneline --no-merges
git diff --stat $BASE_COMMIT..origin/main
git diff $BASE_COMMIT..origin/main
```

### 2-2. Linear 이슈

```
list_issues(assignee: "me", updatedAt: "$LAST_FRIDAY")
```

상태가 변경된 이슈(시작, 완료, 리뷰 등)에 주목합니다.

### 2-3. Google Calendar

```
gcal_list_events(timeMin: "${LAST_FRIDAY}T00:00:00", timeMax: "${TODAY}T23:59:59", timeZone: "Asia/Seoul")
```

### 2-4. Slack 메시지

```
slack_search_public_and_private(query: "from:<@{MY_SLACK_ID}> after:$LAST_FRIDAY", sort: "timestamp", limit: 20)
```

결과가 부족하면 `cursor` 파라미터로 추가 페이지를 요청합니다. 최대 3회까지 페이지네이션합니다.

### 2-5. Gmail 발송 메일

```
gmail_search_messages(q: "from:me after:$LAST_FRIDAY", maxResults: 20)
```

### 2-6. Notion 페이지

```
search(query: "", query_type: "internal", filters: { created_by_user_ids: ["{MY_NOTION_ID}"], created_date_range: { start_date: "$LAST_FRIDAY" } }, page_size: 10, max_highlight_length: 100)
```

## Step 3: 서브에이전트 병렬 요약

수집한 데이터를 **3개의 서브에이전트에게 병렬로** 위임합니다. 각 에이전트에게는 해당 raw 데이터와 아래 프롬프트를 전달합니다.

**CRITICAL: 반드시 Agent 도구를 사용하고, 3개를 동시에 호출합니다.**

### Agent A: 개발 활동 요약

**입력 데이터:** Git 커밋 로그 + diff stat + Linear 이슈 목록

**프롬프트:**

```
당신은 주간 개발 보고서 요약 에이전트입니다.

아래 데이터를 분석하여 한국어로 요약하세요.

## 데이터
{Git 커밋 + diff + Linear 이슈 데이터를 여기에 삽입}

## 요약 규칙
1. 도메인별로 그룹핑 (예: eBay, Joom, 상품, 주문 등)
2. 결과 중심으로 작성 — "무엇이 가능해졌는지/개선됐는지"
3. 비즈니스 용어(기술 용어) 형식. 예: "상품 동기화 속도 개선 (N+1 쿼리 제거)"
4. 항목당 1줄 요약
5. 최종 상태만 기술 (중간 과정 무시)
6. Linear 이슈는 Git 커밋과 겹치는 내용이면 병합하고, 코드에 반영 안 된 이슈(논의 중, 기획 단계)는 별도 섹션으로

## 필터링
**포함:** 새 기능, 비즈니스 로직 변경, 성능/안정성 개선, 외부 연동 변경, 버그 수정, 모니터링 추가, 리팩토링
**1줄 요약으로 축소:** 타입 수정, 린트, 테스트만 추가, 의존성 업데이트, 문서 수정

## 출력 형식 (Notion 호환)
- **[emoji] 카테고리명**
    - 항목 설명

이모지 가이드: 🔐보안 ⚡성능 🏷️카테고리 🎵K-POP 🎛️설정 🤖AI/번역 📦상품 🔔알림 🐛버그 ✨신기능 🔧리팩토링 🔄동기화 🔍검색 🌍배송

최대 10개 항목으로 간결하게 응답하세요 — Notion에 바로 복사할 수 있는 포맷만 출력합니다.
```

### Agent B: 커뮤니케이션 요약

**입력 데이터:** Slack 메시지 + Gmail 발송 메일

**프롬프트:**

```
당신은 주간 커뮤니케이션 요약 에이전트입니다.

아래 데이터를 분석하여 한국어로 요약하세요.

## 데이터
{Slack 메시지 + Gmail 데이터를 여기에 삽입}

## 요약 규칙
1. 업무 관련 논의/의사결정만 추출
2. 잡담, 인사, 단순 확인("넵", "확인했습니다", "ㅋㅋ") 등은 제외
3. 주제별로 그룹핑
4. 핵심 논의 내용과 결론/결정사항 위주로 요약
5. 외부(사외) 커뮤니케이션은 별도로 표시

## 출력 형식 (Notion 호환)
- **💬 주요 논의/의사결정**
    - [주제]: 결정 내용 요약
- **📧 외부 커뮤니케이션**
    - [대상]: 내용 요약

업무와 무관한 메시지만 있다면 "특이사항 없음"으로 응답하세요.
최대 5개 항목으로 간결하게 응답하세요 — Notion에 바로 복사할 수 있는 포맷만 출력합니다.
```

### Agent C: 문서/회의 요약

**입력 데이터:** Notion 페이지 목록 + Google Calendar 일정

**프롬프트:**

```
당신은 주간 문서/회의 요약 에이전트입니다.

아래 데이터를 분석하여 한국어로 요약하세요.

## 데이터
{Notion 페이지 + Calendar 일정 데이터를 여기에 삽입}

## 요약 규칙
1. 회의: 참석한 회의 중 주요 회의만 나열 (정기 스탠드업 등은 "정기 회의 N회" 로 묶기)
2. 문서: 작성한 문서의 제목과 목적을 1줄로 요약
3. Notion 페이지 중 내용이 거의 없는 것(템플릿만 생성한 것)은 제외

## 출력 형식 (Notion 호환)
- **📅 주요 회의**
    - [회의명]: 핵심 안건/결정사항 (있다면)
    - 정기 회의 N회 (스탠드업, 위클리 등)
- **📝 작성 문서**
    - [문서 제목]: 목적/내용 요약

회의나 문서가 없으면 해당 섹션을 생략합니다.
최대 5개 항목으로 간결하게 응답하세요 — Notion에 바로 복사할 수 있는 포맷만 출력합니다.
```

## Step 4: 최종 보고서 조합

3개 에이전트의 응답을 취합하여 아래 순서로 출력합니다:

```
📊 주간 업무 보고 ($LAST_FRIDAY ~ $TODAY)

[Agent A 결과 — 개발 활동]

[Agent B 결과 — 커뮤니케이션 (내용이 있을 때만)]

[Agent C 결과 — 문서/회의 (내용이 있을 때만)]
```

## Step 5: 사용자에게 제시

1. 분석 기간 표시: `$LAST_FRIDAY ~ $TODAY`
2. 위 포맷으로 보고서 출력
3. "수정이 필요한 부분이 있으면 말씀해주세요" 로 마무리

## 주의사항

- **연결 안 된 서비스는 조용히 건너뜀** — 에러 메시지 남발하지 않기
- **Notion 호환 포맷 필수** — 복사해서 바로 붙여넣기 가능하도록
- **한국어로 작성** — 모든 카테고리명, 설명
- **서브에이전트는 요약만 리턴** — raw 데이터를 그대로 출력하지 않음
- **중복 제거** — 같은 작업이 Git + Linear + Slack에 걸쳐 있으면 하나로 병합
- **Git 분석 범위** — 현재 리포지토리만 대상 (여러 레포에서 작업한 경우 각 레포에서 별도 실행 필요)
