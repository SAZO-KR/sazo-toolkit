---
description: 주간 업무 보고서 생성 — 코드, 이슈, 메일, 슬랙, 캘린더, 문서 전체 취합
---

## Your Task

지난 한 주간의 **전체 업무 활동**을 수집하고 요약하여 Notion 호환 마크다운으로 출력합니다.

**CRITICAL: 모든 출력은 한국어로 작성합니다.**

## Step 0: 셋업 확인

### MCP 서비스 연결 확인

아래 6개 서비스에 대해 probe 호출로 연결 상태를 확인합니다. **가능한 한 병렬로 호출합니다.**
각 probe의 반환 값에서 사용자 ID를 추출하여 이후 단계에서 사용합니다.

| 서비스 | Probe 호출 | 성공 기준 | 저장할 값 |
|--------|-----------|----------|----------|
| Slack | `slack_read_user_profile()` (파라미터 없이) | user ID 반환 | `{MY_SLACK_ID}` ← 반환된 user_id |
| Linear | `get_authenticated_user()` | user 정보 반환 | `{MY_LINEAR_ID}` ← 반환된 id |
| Gmail | `gmail_get_profile()` | 이메일 주소 반환 | `{MY_EMAIL}` ← 반환된 emailAddress |
| Google Calendar | `gcal_list_calendars()` | 캘린더 목록 반환 | (ID 불필요) |
| Notion | `search(query: "{이메일}", query_type: "user", filters: {})` | 본인 유저 반환 | `{MY_NOTION_ID}` ← 반환된 user_id |
| Git | `git log --oneline -1` | 커밋 해시 반환 | (ID 불필요) |

**Notion 사용자 조회 순서:** Gmail `{MY_EMAIL}` → 없으면 `git config user.email` → 둘 다 없으면 Notion 건너뜀.
이를 위해 Notion probe는 이메일을 확보한 뒤 실행합니다. 나머지 MCP probe 4개(Slack, Linear, Gmail, Calendar)와 Git 확인은 병렬로 호출합니다.

**연결 실패한 서비스**는 사용자에게 알리고, 해당 서비스를 건너뛴 채 진행합니다.
**모든 MCP 서비스가 실패하면** Git만으로 코드 변경 보고서를 생성합니다.

### MCP 도구 권한 영구 허용

연결 확인이 끝나면 사용자에게 한 번 물어봅니다:

> "연결된 서비스들의 읽기 권한을 영구적으로 허용하시겠습니까? (매 실행마다 승인 팝업이 뜨지 않게 됩니다)"

**사용자가 승인하면** `~/.claude/settings.json`의 `permissions.allow` 배열에 **연결 성공한 서비스의 도구만** 추가합니다.
이미 존재하는 항목은 건너뜁니다.

서비스별 도구 목록:

| 서비스 | 도구 |
|--------|------|
| Slack | `mcp__claude_ai_Slack__slack_search_public_and_private`, `mcp__claude_ai_Slack__slack_read_thread`, `mcp__claude_ai_Slack__slack_read_channel`, `mcp__claude_ai_Slack__slack_read_user_profile` |
| Linear | `mcp__claude_ai_Linear__list_issues`, `mcp__claude_ai_Linear__get_issue`, `mcp__claude_ai_Linear__get_authenticated_user`, `mcp__claude_ai_Linear__get_project` |
| Gmail | `mcp__claude_ai_Gmail__gmail_search_messages`, `mcp__claude_ai_Gmail__gmail_read_message`, `mcp__claude_ai_Gmail__gmail_get_profile` |
| Google Calendar | `mcp__claude_ai_Google_Calendar__gcal_list_events`, `mcp__claude_ai_Google_Calendar__gcal_list_calendars` |
| Notion | `mcp__claude_ai_Notion__search`, `mcp__claude_ai_Notion__fetch` |

**CRITICAL: probe가 실패한 서비스의 도구는 등록하지 않습니다.**

설정 파일 수정은 `jq`를 사용합니다. 연결 성공한 서비스의 도구만으로 TOOLS 배열을 동적으로 구성합니다:

```bash
SETTINGS="$HOME/.claude/settings.json"

# 설정 파일이 없으면 생성
if [ ! -f "$SETTINGS" ]; then
  mkdir -p "$(dirname "$SETTINGS")"
  echo '{}' > "$SETTINGS"
fi

# TOOLS 배열을 연결 성공한 서비스의 도구만으로 동적 구성
# CRITICAL: 아래는 의사코드입니다. probe가 성공한 서비스만 해당 블록을 실행하세요.
TOOLS='[]'
if [ "$SLACK_CONNECTED" = true ]; then
  TOOLS=$(echo "$TOOLS" | jq '. + ["mcp__claude_ai_Slack__slack_search_public_and_private","mcp__claude_ai_Slack__slack_read_thread","mcp__claude_ai_Slack__slack_read_channel","mcp__claude_ai_Slack__slack_read_user_profile"]')
fi
if [ "$LINEAR_CONNECTED" = true ]; then
  TOOLS=$(echo "$TOOLS" | jq '. + ["mcp__claude_ai_Linear__list_issues","mcp__claude_ai_Linear__get_issue","mcp__claude_ai_Linear__get_authenticated_user","mcp__claude_ai_Linear__get_project"]')
fi
if [ "$GMAIL_CONNECTED" = true ]; then
  TOOLS=$(echo "$TOOLS" | jq '. + ["mcp__claude_ai_Gmail__gmail_search_messages","mcp__claude_ai_Gmail__gmail_read_message","mcp__claude_ai_Gmail__gmail_get_profile"]')
fi
if [ "$CALENDAR_CONNECTED" = true ]; then
  TOOLS=$(echo "$TOOLS" | jq '. + ["mcp__claude_ai_Google_Calendar__gcal_list_events","mcp__claude_ai_Google_Calendar__gcal_list_calendars"]')
fi
if [ "$NOTION_CONNECTED" = true ]; then
  TOOLS=$(echo "$TOOLS" | jq '. + ["mcp__claude_ai_Notion__search","mcp__claude_ai_Notion__fetch"]')
fi

TMP=$(mktemp)
jq --argjson tools "$TOOLS" '.permissions.allow = ((.permissions.allow // []) + ($tools - (.permissions.allow // [])))' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
```

**사용자가 거부하면** 권한 등록을 건너뛰고 매번 수동 승인으로 진행합니다.

**이 셋업은 도구 권한이 모두 등록되면 건너뜁니다.**
판단 기준: 연결 성공한 서비스의 도구가 `settings.json`의 `permissions.allow`에 **모두** 포함되어 있으면 셋업 완료. 일부라도 누락된 도구가 있으면 (새 서비스 연결 등) 누락분만 추가 등록합니다 (사용자에게 재확인).

## Step 1: 날짜 범위 계산

```bash
# 가장 최근 금요일 계산 (한 주간의 시작점)
DOW=$(date +%u)  # 1=Mon ... 7=Sun
if [[ $DOW -le 4 ]]; then
  # 월~목: 지난주 금요일
  DAYS_BACK=$((DOW + 2))
elif [[ $DOW -eq 5 ]]; then
  # 금요일: 지난주 금요일 (7일 전)
  DAYS_BACK=7
else
  # 토(6)/일(7): 이번 주 금요일 (가장 최근)
  DAYS_BACK=$((DOW - 5))
fi
LAST_FRIDAY=$(date -v-${DAYS_BACK}d +%Y-%m-%d 2>/dev/null || date -d "${DAYS_BACK} days ago" +%Y-%m-%d)
TODAY=$(date +%Y-%m-%d)
NOW_ISO=$(date +%Y-%m-%dT%H:%M:%S)
echo "분석 기간: $LAST_FRIDAY ~ $TODAY ($NOW_ISO)"
```

## Step 2: 데이터 수집

**연결 확인된 서비스에 대해서만 수집합니다. 가능한 한 병렬로 호출합니다.**

### 2-1. Git 커밋 (필수)

```bash
git fetch origin main

# 본인 커밋만 조회 (--author=email로 정확한 필터링)
GIT_AUTHOR=$(git config user.email)
if [ -z "$GIT_AUTHOR" ]; then
  echo "ERROR: git user.email이 설정되지 않았습니다."
  # Claude: 이 에러가 발생하면 사용자에게 'git config --global user.email' 설정을 요청하고 Git 수집 전체를 건너뛰세요.
else
  git log origin/main --since="$LAST_FRIDAY" --author="$GIT_AUTHOR" --oneline --no-merges

  # 본인 커밋의 변경 내용만 추출 (팀원 커밋 제외)
  git log origin/main --since="$LAST_FRIDAY" --author="$GIT_AUTHOR" --no-merges --stat
  git log origin/main --since="$LAST_FRIDAY" --author="$GIT_AUTHOR" --no-merges -p | head -3000
fi
```

**참고:** `git log -p`는 author 필터가 적용된 커밋의 diff만 출력하므로 팀원 변경이 섞이지 않습니다. `head -3000`으로 컨텍스트 초과를 방지합니다. 기간 내 본인 커밋이 없으면 출력이 비어있으며, 이 경우 건너뜁니다.

### 2-2. Linear 이슈

```
list_issues(assignee: "me", updatedAt: "$LAST_FRIDAY")
```

상태가 변경된 이슈(시작, 완료, 리뷰 등)에 주목합니다.

### 2-3. Google Calendar

```
gcal_list_events(timeMin: "${LAST_FRIDAY}T00:00:00", timeMax: "${NOW_ISO}", timeZone: "Asia/Seoul")
```

`${NOW_ISO}`는 현재 시각의 RFC3339 형식 (예: `2026-04-03T14:30:00`). 아직 시작하지 않은 미래 일정은 제외합니다.

### 2-4. Slack 메시지

```
slack_search_public_and_private(query: "from:<@{MY_SLACK_ID}> after:$LAST_FRIDAY", sort: "timestamp", limit: 20)
```

결과가 부족하면 `cursor` 파라미터로 추가 페이지를 요청합니다. 최대 3회까지 페이지네이션합니다.

### 2-5. Gmail 발송 메일

```
gmail_search_messages(q: "from:me after:$LAST_FRIDAY", maxResults: 20)
```

결과에 `nextPageToken`이 포함되어 있으면 추가 페이지를 요청합니다. 최대 3회까지 페이지네이션합니다.

### 2-6. Notion 페이지

```
search(query: "", query_type: "internal", filters: { created_by_user_ids: ["{MY_NOTION_ID}"], created_date_range: { start_date: "$LAST_FRIDAY" } }, page_size: 25, max_highlight_length: 100)
```

## Step 3: 서브에이전트 병렬 요약

수집한 데이터를 **3개의 서브에이전트에게 병렬로** 위임합니다. 각 에이전트에게는 해당 raw 데이터와 아래 프롬프트를 전달합니다.

**CRITICAL: 반드시 Agent 도구를 사용하고, 3개를 동시에 호출합니다.**

### Agent A: 개발 활동 요약

**입력 데이터:** Git 커밋 로그 + diff stat + Linear 이슈 목록

**프롬프트:**

```
당신은 주간 개발 활동을 비즈니스 관점에서 해석하는 에이전트입니다.
단순히 "무엇을 했는지" 나열하지 말고, "왜 중요한지, 누구에게 영향을 미치는지"를 고찰하여 작성하세요.

대상 독자는 프로덕트 조직원(개발 배경 있음)입니다. 기술 용어 병기 OK.

## 데이터
{Git 커밋 + diff + Linear 이슈 데이터를 여기에 삽입}

## 작성 원칙
1. **비즈니스 임팩트 우선** — "N+1 쿼리 제거"가 아니라 "상품 동기화 속도가 개선되어 판매자 대기 시간 단축 (N+1 쿼리 제거)"
2. **So What 테스트** — 각 항목을 쓴 후 "그래서 뭐?"라고 자문. 대답이 안 되면 임팩트를 보강하거나 제외
3. **관련 있는 변경은 하나의 스토리로 묶기** — 커밋 3개가 같은 기능이면 하나의 항목으로 통합
4. **팀 전체가 알면 좋을 맥락 포함** — "이 변경으로 인해 앞으로 X가 가능해졌다" 또는 "Y 문제가 해소되었다"
5. **최종 상태만** — 중간 시행착오, 되돌림은 생략
6. **Linear 이슈 병합** — Git에 반영된 이슈는 코드 변경과 병합. 미반영 이슈(논의 중, 기획)는 "🔜 진행 중" 섹션으로

## 필터링
**포함:** 비즈니스 영향이 있는 변경 (기능, 성능, 안정성, 연동, 버그픽스)
**축소:** 내부 정리(타입, 린트, 테스트, 의존성) → 많으면 "내부 코드 품질 개선" 1줄로 묶기

## 출력 형식 (Notion 호환)
- **[emoji] 카테고리명**
    - 항목: 임팩트 설명 (기술 배경)

이모지: 🔐보안 ⚡성능 🏷️카테고리 🎵K-POP 🎛️설정 🤖AI/번역 📦상품 🔔알림 🐛버그 ✨신기능 🔧리팩토링 🔄동기화 🔍검색 🌍배송 🔜진행중

## 나쁜 예 vs 좋은 예
❌ "externalProducts 필드 제거" — 코드 레벨, 임팩트 없음
✅ "상품 모델 단순화로 동기화 안정성 향상 — 외부 플랫폼 의존 필드를 독립 구조로 분리하여 데이터 불일치 위험 제거"

❌ "checksum 계산에 translationHash 추가" — 무엇을 했는지만
✅ "번역 변경 시 자동 재동기화 — 번역 해시를 체크섬에 포함하여 번역 수정이 즉시 반영"

최대 10개 항목. Notion에 바로 복사할 수 있는 포맷만 출력합니다.
```

### Agent B: 커뮤니케이션 요약

**입력 데이터:** Slack 메시지 + Gmail 발송 메일

**프롬프트:**

```
당신은 주간 커뮤니케이션에서 팀에게 유의미한 논의와 결정사항을 추출하는 에이전트입니다.
단순 메시지 나열이 아니라, "어떤 주제에 대해 어떤 결론이 났는지" 또는 "어떤 방향이 정해졌는지"를 중심으로 정리하세요.

## 데이터
{Slack 메시지 + Gmail 데이터를 여기에 삽입}

## 작성 원칙
1. **의사결정과 합의 중심** — "A와 B를 논의했다"가 아니라 "A 방식으로 진행하기로 결정"
2. **잡담/인사/단순 확인은 완전히 제외** — "넵", "확인", "ㅋㅋ", 이모지만 있는 메시지 등
3. **맥락을 보강** — 메시지만으로는 알 수 없는 배경이 스레드에 있다면 포함
4. **외부 커뮤니케이션은 상대방과 목적을 명시** — "Joom 담당자에게 배송 정책 변경 문의"
5. **팀원이 몰랐을 수 있는 정보 우선** — 공개 채널 공지보다는 DM/소규모 채널에서 나온 결정이 더 가치 있음

## 출력 형식 (Notion 호환)
- **💬 주요 논의/의사결정**
    - [주제]: 결정 내용 또는 합의사항
- **📧 외부 커뮤니케이션**
    - [대상]: 목적과 결과

## 나쁜 예 vs 좋은 예
❌ "Joom 관련 슬랙 메시지 3건" — 내용 없는 집계
✅ "Joom 배송비 정책 변경: 무게 기반에서 부피 기반으로 전환하기로 합의 (4/1 슬랙 논의)"

❌ "팀장님과 DM 5건" — 상대만 있고 내용 없음
✅ "Q2 로드맵 우선순위 조정: 번역 품질 개선을 상품 확장보다 앞으로 당기기로 결정"

업무와 무관한 메시지만 있다면 "특이사항 없음"으로 응답하세요.
최대 7개 항목. Notion에 바로 복사할 수 있는 포맷만 출력합니다.
```

### Agent C: 문서/회의 요약

**입력 데이터:** Notion 페이지 목록 + Google Calendar 일정

**프롬프트:**

```
당신은 주간 회의/문서 활동에서 팀에게 공유할 가치가 있는 내용을 추출하는 에이전트입니다.
회의 목록을 나열하는 것이 아니라, "이번 주에 어떤 논의가 있었고 어떤 방향이 잡혔는지"를 전달하세요.

## 데이터
{Notion 페이지 + Calendar 일정 데이터를 여기에 삽입}

## 작성 원칙
1. **회의는 결과/결정사항 중심** — 회의 이름만 나열하지 말고, 핵심 안건이나 결정된 사항을 포함
2. **정기 회의는 묶기** — 데일리 스탠드업, 위클리 등 반복 회의는 "정기 회의 N회" 1줄로. 단, 특별한 안건이 있었으면 별도 언급
3. **문서는 목적과 대상을 명시** — "API 가이드 작성"이 아니라 "파트너사 연동을 위한 API 가이드 초안 작성"
4. **템플릿만 생성한 Notion 페이지는 제외** — 내용이 거의 없는 것은 skip
5. **팀에게 공유할 가치** 기준으로 필터링 — 개인 메모성 문서는 제외

## 출력 형식 (Notion 호환)
- **📅 주요 회의**
    - [회의명]: 핵심 안건/결정사항
    - 정기 회의 N회 (스탠드업, 위클리 등)
- **📝 작성 문서**
    - [문서 제목]: 목적과 대상

## 나쁜 예 vs 좋은 예
❌ "제품 회의 참석" — 회의 이름만, 내용 없음
✅ "제품 회의: eBay 카테고리 매핑 자동화 범위를 1차 100개 카테고리로 확정"

❌ "API 가이드 작성" — 목적/대상 불명
✅ "파트너사(Rakuten) 연동을 위한 상품 등록 API 가이드 초안 작성"

회의나 문서가 없으면 해당 섹션을 생략합니다.
최대 7개 항목. Notion에 바로 복사할 수 있는 포맷만 출력합니다.
```

## Step 4: 최종 보고서 조합

3개 에이전트의 응답을 취합합니다. **단순 이어붙이기가 아니라:**

1. **교차 소스 중복 제거** — 같은 작업이 Git + Linear + Slack에 걸쳐 있으면 가장 풍부한 설명으로 병합
2. **비즈니스 스토리 재구성** — 개별 항목을 "이번 주 핵심 성과"와 "진행 중인 과제"로 재배치
3. **한 줄 하이라이트** — 보고서 최상단에 이번 주 가장 임팩트 있는 1~2가지를 한 줄로 요약

```
📊 주간 업무 보고 ($LAST_FRIDAY ~ $TODAY)

> 💡 이번 주 하이라이트: [가장 중요한 1~2가지 한 줄 요약]

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
