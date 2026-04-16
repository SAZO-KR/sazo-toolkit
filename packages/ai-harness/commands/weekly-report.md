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
| GitHub | `gh api user --jq .login` + `gh api /orgs/SAZO-KR --jq .login` | login 반환 + 조직 접근 확인 | `{GH_USER}` ← 반환된 login |

**Notion 사용자 조회 순서:** Gmail `{MY_EMAIL}` → 없으면 `git config user.email` → 둘 다 없으면 Notion 건너뜀.
이를 위해 Notion probe는 이메일을 확보한 뒤 실행합니다. 나머지 MCP probe 4개(Slack, Linear, Gmail, Calendar)와 Git 확인은 병렬로 호출합니다.

**연결 실패한 서비스**는 사용자에게 알리고, 해당 서비스를 건너뛴 채 진행합니다.
**모든 MCP 서비스가 실패하면** Git만으로 코드 변경 보고서를 생성합니다.

### 도구 권한 영구 등록

**CRITICAL: probe 호출 전에** 모든 도구 권한을 등록해야 승인 팝업이 뜨지 않습니다.

사용자에게 한 번 물어봅니다:

> "주간 보고서에 필요한 모든 도구 권한(MCP 읽기 + Bash + 파일)을 영구 등록하시겠습니까? (다음 세션부터 승인 팝업 없이 실행됩니다)"

**사용자가 승인하면** probe **이전에** 아래 스크립트를 실행합니다:

```bash
SETTINGS="$HOME/.claude/settings.json"

if [ ! -f "$SETTINGS" ]; then
  mkdir -p "$(dirname "$SETTINGS")"
  echo '{}' > "$SETTINGS"
fi

# 모든 도구를 무조건 등록 (연결 여부 무관)
TOOLS='[
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
  "mcp__claude_ai_Notion__fetch",
  "Bash(git *)", "Bash(gh *)", "Bash(gh auth *)", "Bash(gh api *)",
  "Bash(gh search *)", "Bash(gh pr *)", "Bash(gh repo *)",
  "Bash(date*)", "Bash(jq *)", "Bash(jq\t*)",
  "Bash(cat *)", "Bash(python3 *)", "Bash(mktemp*)", "Bash(mv *)",
  "Bash(grep *)", "Bash(sed *)", "Bash(head *)", "Bash(echo *)",
  "Bash(DOW=*)", "Bash(LAST_FRIDAY=*)",
  "Bash(GH_USER=*)", "Bash(GH_ORG=*)", "Bash(PR_COUNT=*)",
  "Bash(REPO=*)", "Bash(NUM=*)",
  "Bash(SETTINGS=*)", "Bash(TOOLS=*)", "Bash(TMP=*)",
  "Read", "Write", "Edit"
]'

TMP=$(mktemp)
jq --argjson tools "$TOOLS" '.permissions.allow = ((.permissions.allow // []) + ($tools - (.permissions.allow // [])))' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
```

등록 후 **새 세션을 시작해야 반영**됩니다. 최초 1회만 필요하며, 이후 실행부터는 팝업 없이 전체 커맨드가 수행됩니다.

**사용자가 거부하면** 권한 등록을 건너뛰고 매번 수동 승인으로 진행합니다.

**이 셋업은 도구 권한이 모두 등록되어 있으면 건너뜁니다.**

**이 셋업은 도구 권한이 모두 등록되면 건너뜁니다.**
판단 기준: 연결 성공한 서비스의 도구가 `settings.json`의 `permissions.allow`에 **모두** 포함되어 있으면 셋업 완료. 일부라도 누락된 도구가 있으면 (새 서비스 연결 등) 누락분만 추가 등록합니다 (사용자에게 재확인).

### gh CLI 선결 조건 (GitHub 전역 수집의 필수 조건)

Git 수집은 로컬 repo 범위가 아니라 **SAZO-KR 조직 전체**를 대상으로 합니다 (`gh search` 기반).
아래 3가지를 순서대로 확인하고, 실패한 항목은 **사용자에게 명시적으로 안내**한 후 재실행 대기합니다.

```bash
# 1) gh 설치 확인
if ! command -v gh >/dev/null 2>&1; then
  echo "❌ gh CLI 미설치. 다음 명령으로 설치 후 재실행하세요:"
  echo "   brew install gh"
  exit 1
fi

# 2) gh 인증 확인
if ! gh auth status >/dev/null 2>&1; then
  echo "❌ gh 인증 필요. 다음 명령으로 로그인 후 재실행하세요:"
  echo "   gh auth login   # GitHub.com, HTTPS, 웹 브라우저 인증 권장"
  echo "   (프롬프트에서 '!gh auth login'로 세션 내 실행 가능)"
  exit 1
fi

# 3) SAZO-KR 조직 접근 확인 (SSO SAML 승인 필요할 수 있음)
if ! gh api /orgs/SAZO-KR >/dev/null 2>&1; then
  echo "❌ SAZO-KR 조직 접근 실패. 가능한 원인/해결:"
  echo "   (a) 조직 멤버가 아님 — 관리자에게 초대 요청"
  echo "   (b) SSO 미승인 — https://github.com/settings/tokens 에서 토큰에 'Configure SSO' → SAZO-KR Authorize"
  echo "   (c) scope 부족 — gh auth refresh -s read:org,repo"
  exit 1
fi

GH_USER=$(gh api user --jq .login)
GH_ORG="SAZO-KR"
echo "✅ GitHub: $GH_USER @ $GH_ORG"
```

**셋 중 하나라도 실패하면** Git 수집 전체를 건너뛰지 말고 **사용자에게 구성 안내 후 재실행을 요청**합니다. (주간 보고서의 핵심 데이터가 GitHub이므로 생략 불가)

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

**CRITICAL: 각 소스에서 URL/링크를 반드시 함께 수집합니다.** 최종 보고서에서 항목을 클릭하면 원본을 볼 수 있도록 하기 위함입니다.

| 소스 | 수집할 링크 |
|---|---|
| GitHub | `gh search` 결과의 `url` 필드를 그대로 사용 (commit/PR 모두 포함). 추가로 `repository.nameWithOwner`로 repo 맥락 |
| Linear | 이슈 `identifier` + `url` 필드 |
| Slack | 메시지 `permalink` 필드 |
| Gmail | 메시지 `id` → `https://mail.google.com/mail/u/0/#inbox/{id}` |
| Notion | 페이지 `url` 필드 |
| Calendar | 이벤트 `htmlLink` 필드 |

### 2-1. GitHub 활동 (필수) — SAZO-KR 조직 전역

**CRITICAL: 로컬 repo가 아니라 `gh search`로 SAZO-KR 조직의 모든 repo를 대상으로 수집합니다.**
현재 작업 디렉토리가 어디든, 내가 참여한 모든 repo의 활동이 포함됩니다.

```bash
# 사전 변수 (Step 0에서 확보)
# GH_USER=<본인 login>
# GH_ORG="SAZO-KR"

# 1) 지난주 본인 커밋 (모든 SAZO-KR repo)
gh search commits \
  --author=@me \
  --author-date=">=$LAST_FRIDAY" \
  --owner="$GH_ORG" \
  --sort=author-date --order=desc \
  --limit 100 \
  --json sha,commit,repository,url \
  > /tmp/weekly-commits.json

# 2) 지난주 생성한 PR (description = 비즈니스 맥락의 주 소스)
gh search prs \
  --author=@me \
  --created=">=$LAST_FRIDAY" \
  --owner="$GH_ORG" \
  --limit 100 \
  --json number,title,body,state,createdAt,updatedAt,url,repository \
  > /tmp/weekly-prs-created.json

# 3) 지난주 업데이트된 PR (이전 생성 + 이번 주 머지/코멘트 포함)
gh search prs \
  --author=@me \
  --updated=">=$LAST_FRIDAY" \
  --owner="$GH_ORG" \
  --limit 100 \
  --json number,title,body,state,createdAt,updatedAt,url,repository \
  > /tmp/weekly-prs-updated.json

# 4) 두 PR 목록을 merge (중복 제거)
jq -s '.[0] + .[1] | unique_by(.url)' /tmp/weekly-prs-created.json /tmp/weekly-prs-updated.json \
  > /tmp/weekly-prs.json

# 5) (선택) 상위 PR의 diff stat — Agent A에 부피 부담 줄 수 있으니 많을 때는 건너뜀
# PR 10건 이하일 때만 stat 보강
PR_COUNT=$(jq 'length' /tmp/weekly-prs.json)
if [ "$PR_COUNT" -le 10 ]; then
  jq -r '.[] | [.repository.nameWithOwner, .number] | @tsv' /tmp/weekly-prs.json \
  | while IFS=$'\t' read -r REPO NUM; do
      gh api "/repos/$REPO/pulls/$NUM" --jq '{repo: "'"$REPO"'", number: '"$NUM"', additions, deletions, changed_files}'
    done \
  | jq -s '.' > /tmp/weekly-pr-stats.json
fi
```

**검증:**
- `/tmp/weekly-commits.json`, `/tmp/weekly-prs.json`의 `length`가 0이면 지난주 GitHub 활동이 없는 것.
- 양쪽 모두 0이면 사용자에게 확인 (기간/조직/권한 문제 가능성).

**링크:** `gh search`가 반환하는 객체에 이미 `url`과 `repository.url` / `repository.nameWithOwner`가 포함되어 있어 수동 조립 불필요. Agent A 입력 시 그대로 전달.

**Repo별 그룹화:** 데이터는 여러 repo에 걸쳐 있으므로, Agent A 프롬프트에서 `repository.nameWithOwner`로 묶어 서술하도록 지시합니다.

**제약:**
- GitHub Search API는 결과 최대 1000건 / rate limit 30 req/min. 주간 범위면 사실상 제약 없음.
- `gh search`는 default branch 외 커밋도 포함 — 머지 여부와 무관하게 "내가 한 작업" 전체를 포착.
- Private repo는 SSO 승인된 토큰에 한해 검색됨 (Step 0에서 선검증).

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

**입력 데이터:** `gh search` 결과 (commits JSON + PRs JSON + 선택적 PR stat JSON) + Linear 이슈 목록
**주의:** 여러 SAZO-KR repo에 걸친 데이터입니다. 각 항목의 `repository.nameWithOwner`를 확인하고, 동일 repo 내 관련 작업끼리 묶어 서술합니다. repo명이 명확한 맥락(예: `translate-bot`, `sazo-toolkit`)을 제공하면 서술에 포함합니다.

**프롬프트:**

```
당신은 주간 개발 활동을 비즈니스 관점에서 해석하는 에이전트입니다.
단순히 "무엇을 했는지" 나열하지 말고, "왜 중요한지, 누구에게 영향을 미치는지"를 고찰하여 작성하세요.

대상 독자는 프로덕트 조직원(개발 배경 있음)입니다. 기술 용어 병기 OK.

## 데이터
{`/tmp/weekly-commits.json` + `/tmp/weekly-prs.json` + (있으면) `/tmp/weekly-pr-stats.json` + Linear 이슈 데이터를 여기에 삽입}

각 커밋/PR 객체의 `repository.nameWithOwner`로 repo를 식별할 수 있습니다. 링크는 객체의 `url` 필드를 그대로 사용하세요.

## 작성 원칙
1. **비즈니스 임팩트 우선** — "N+1 쿼리 제거"가 아니라 "상품 동기화 속도가 개선되어 판매자 대기 시간 단축 (N+1 쿼리 제거)"
2. **So What 테스트** — 각 항목을 쓴 후 "그래서 뭐?"라고 자문. 대답이 안 되면 임팩트를 보강하거나 제외
3. **관련 있는 변경은 하나의 스토리로 묶기** — 커밋 3개가 같은 기능이면 하나의 항목으로 통합 (repo가 다르더라도 같은 목적이면 묶어도 됨)
4. **Repo 맥락 명시** — 서로 다른 서비스/도구 작업은 repo 힌트를 포함 (예: `sazo-toolkit/ai-harness`, `translate-bot`)
5. **팀 전체가 알면 좋을 맥락 포함** — "이 변경으로 인해 앞으로 X가 가능해졌다" 또는 "Y 문제가 해소되었다"
6. **최종 상태만** — 중간 시행착오, 되돌림은 생략
7. **Linear 이슈 병합** — PR에 반영된 이슈는 코드 변경과 병합. 미반영 이슈(논의 중, 기획)는 "🔜 진행 중" 섹션으로

## 필터링
**포함:** 비즈니스 영향이 있는 변경 (기능, 성능, 안정성, 연동, 버그픽스)
**축소:** 내부 정리(타입, 린트, 테스트, 의존성) → 많으면 "내부 코드 품질 개선" 1줄로 묶기

## 출력 형식

섹션 헤딩 + bullet 구조로 가독성 최우선. 카테고리별 이모지 헤딩으로 시각적 구분.

```
**✨ 신기능**
- 임팩트 설명 (기술 배경) — [PR #N](URL)

**🔧 리팩토링**
- 임팩트 설명 — [PR #N](URL)

**🔜 진행 중**
- [항목] — 다음 주 계속 ([PROJ-N](URL))
```

이모지: 🔐보안 ⚡성능 🏷️카테고리 🤖AI/번역 📦상품 🔔알림 🐛버그 ✨신기능 🔧리팩토링 🔄동기화 🔍검색 🌍배송 🔜진행중

**CRITICAL 링크 규칙:**
- 모든 항목에 관련 PR, Linear 이슈 중 대표 1~2개의 **클릭 가능한 마크다운 링크** 필수
- 형식: `[PR #N](https://github.com/OWNER/REPO/pull/N)` 또는 `[PROJ-N](https://linear.app/TEAM/issue/PROJ-N)`
- `PR #587` (plain text) ← **금지**. 반드시 `[PR #587](URL)` 형태여야 함
- 데이터의 `url` 필드(`gh search` 결과)와 Linear issue URL을 그대로 링크로 사용 — 수동 조립 금지

## 나쁜 예 vs 좋은 예
❌ "상품 모델 단순화 — PR #572, PR #573" — 링크가 plain text, 클릭 불가
✅ "상품 모델 단순화로 동기화 안정성 향상 — 외부 플랫폼 의존 필드를 독립 구조로 분리 ([PR #572](https://github.com/.../pull/572), [PR #573](https://github.com/.../pull/573))"

❌ "번역 재동기화 추가" — 링크 자체가 없음
✅ "번역 변경 시 자동 재동기화 — 번역 해시를 체크섬에 포함 ([INTG-89](https://linear.app/.../INTG-89))"

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

## 출력 형식

섹션 헤딩으로 구분. 가독성 최우선.

```
**💬 주요 논의/의사결정**
- [주제]: 결정 내용 또는 합의사항 — [스레드](permalink)

**📧 외부 커뮤니케이션** (내용이 있을 때만)
- [대상]: 목적과 결과 — [메일](URL)
```

**CRITICAL 링크 규칙:**
- 모든 항목에 원본 Slack permalink 또는 Gmail 링크를 **클릭 가능한 마크다운 링크** 필수
- 형식: `[스레드](https://sazo-kr.slack.com/archives/...)` 또는 `[메일](https://mail.google.com/...)`
- `— 스레드` (plain text) ← **금지**. 반드시 `[스레드](permalink_URL)` 형태여야 함
- Slack 검색 결과의 `permalink` 필드에서 실제 URL을 추출하여 사용

## 나쁜 예 vs 좋은 예
❌ "ES 비용 대응 결정 — 스레드" — 링크가 plain text, 클릭 불가
✅ "ES 비용 대응: 통합 DB 작업으로 해결하기로 결론 ([스레드](https://sazo-kr.slack.com/archives/C.../p...))"

❌ "팀장님과 DM 5건" — 상대만 있고 내용 없음
✅ "Q2 로드맵 우선순위 조정: 번역 품질 개선을 앞으로 당기기로 결정 ([스레드](https://sazo-kr.slack.com/archives/C.../p...))"

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
5. **참조만 한 기존 문서는 제외** — 본인이 해당 기간에 새로 작성하거나 실질적으로 내용을 추가한 문서만 포함. 단순 열람·댓글·참조는 보고 가치 없음
6. **팀에게 공유할 가치** 기준으로 필터링 — 개인 메모성 문서는 제외
7. **Notion 데이터가 참조 위주뿐이면 📝 섹션 자체를 생략** — "작성 문서 없음"도 쓰지 않음

## 출력 형식

섹션 헤딩으로 구분. 가독성 최우선.

```
**📅 주요 회의**
- [회의명](htmlLink): 핵심 안건/결정사항
- 정기 회의 N회 (스탠드업, 위클리 등)

**📝 작성 문서** (내용이 있을 때만)
- [문서 제목](notion_url): 목적과 대상
```

**CRITICAL 링크 규칙:**
- 회의: Calendar `htmlLink`로 **클릭 가능한 마크다운 링크** 필수. 형식: `[회의명](htmlLink)`
- 문서: Notion 페이지 `url`로 문서 제목을 링크화. 형식: `[문서 제목](notion_url)`
- 링크 없는 plain text 출력 금지

## 나쁜 예 vs 좋은 예
❌ "제품 회의 참석" — 회의 이름만, 링크 없음
✅ "[제품 회의](https://calendar.google.com/...): eBay 카테고리 매핑 자동화 범위를 1차 100개 카테고리로 확정"

❌ "API 가이드 작성" — 목적/대상 불명, 링크 없음
✅ "[파트너사 연동 API 가이드](https://notion.so/...): Rakuten 상품 등록 API 초안, 개발팀 리뷰용"

회의나 문서가 없으면 해당 섹션을 생략합니다.
최대 7개 항목. Notion에 바로 복사할 수 있는 포맷만 출력합니다.
```

## Step 4: 최종 보고서 조합

3개 에이전트의 응답을 취합하여 **팀 주간보고 템플릿 형식**으로 조합합니다.

1. **교차 소스 중복 제거** — 같은 작업이 Git + Linear + Slack에 걸쳐 있으면 가장 풍부한 설명으로 병합
2. **섹션 구조 유지** — 에이전트별 결과를 섹션 헤딩 + `---` 구분선으로 시각적으로 분리. 개발 → 논의 → 회의/문서 순서
3. **한 줄 하이라이트** — `> 💡` blockquote로 보고서 최상단에 배치
4. **링크 보존** — 중복 제거로 항목을 병합할 때, 각 소스의 링크는 모두 유지

**출력 형식:** 가독성 최우선. 섹션 헤딩 + 이모지 + 구분선으로 시각적 구조를 유지합니다.

```markdown
## 📊 금주 작업 사항

> 💡 **하이라이트**: [가장 중요한 1~2가지 한 줄 요약]

[Agent A — 개발 활동: 카테고리별 이모지 헤딩 + bullet]

---

[Agent B — 논의/의사결정 (내용이 있을 때만)]

---

[Agent C — 회의/문서 (내용이 있을 때만)]

---

## 🔜 차주 작업 사항

[Linear 기반 자동 생성 또는 사용자 직접 작성]
```

## Step 5: 차주 작업 사항

금주 작업 사항을 먼저 사용자에게 보여준 뒤, 차주 작업 사항 작성 방식을 물어봅니다:

> "차주 작업 사항을 Linear 이슈 기반으로 자동 작성할까요, 아니면 직접 작성하시겠습니까?"

### 사용자가 "자동"을 선택한 경우

Linear에서 다음 조건에 해당하는 이슈를 조회합니다:

```
# 1. 진행 중이지만 미완료 (In Progress)
list_issues(assignee: "me", status: "In Progress")

# 2. Due date가 차주 중인 이슈
list_issues(assignee: "me", dueDate: { gte: "$NEXT_MONDAY", lte: "$NEXT_FRIDAY" })

# 3. Todo 상태인 이슈
list_issues(assignee: "me", status: "Todo")
```

```bash
# 차주 날짜 계산
NEXT_MONDAY=$(date -v+monday +%Y-%m-%d 2>/dev/null || date -d "next monday" +%Y-%m-%d)
NEXT_FRIDAY=$(date -v+friday +%Y-%m-%d 2>/dev/null || date -d "next friday" +%Y-%m-%d)
```

조회된 이슈를 **금주 작업 사항과 동일한 방식**으로 정리합니다:
- 비즈니스 임팩트 중심 서술
- 관련 이슈는 하나의 스토리로 묶기
- 각 항목에 Linear 이슈 링크 첨부: `[PROJ-N](URL)`
- flat bullet list 형식

### 사용자가 "직접"을 선택한 경우

차주 작업 사항을 비워두고 사용자가 채울 수 있도록 placeholder를 남깁니다:

```markdown
- 차주 작업 사항
    - (직접 작성)
```

## Step 6: 파일 저장 및 사용자에게 제시

보고서를 마크다운 파일로 저장합니다. 링크가 클릭 가능하려면 파일로 열어야 합니다.

```bash
# 프로젝트 루트에 저장 (날짜 기반 파일명)
REPORT_FILE="weekly-report-${LAST_FRIDAY}-${TODAY}.md"
```

1. 보고서를 `$REPORT_FILE`에 Write 도구로 저장
2. 터미널에 요약(하이라이트 + 파일 경로)만 출력:
   ```
   ✅ 주간 보고서 생성 완료: $REPORT_FILE
   💡 하이라이트: [한 줄 요약]
   📎 링크 포함 전체 보고서 → $REPORT_FILE 을 열어주세요.
   ```
3. "수정이 필요한 부분이 있으면 말씀해주세요" 로 마무리

## 주의사항

- **연결 안 된 서비스는 조용히 건너뜀** — 에러 메시지 남발하지 않기
- **Notion 호환 포맷 필수** — 복사해서 바로 붙여넣기 가능하도록
- **한국어로 작성** — 모든 카테고리명, 설명
- **서브에이전트는 요약만 리턴** — raw 데이터를 그대로 출력하지 않음
- **중복 제거** — 같은 작업이 Git + Linear + Slack에 걸쳐 있으면 하나로 병합
- **GitHub 분석 범위** — SAZO-KR 조직의 모든 repo를 `gh search`로 전역 수집 (작업 디렉토리 무관, 여러 repo 별도 실행 불필요)
- **실행 시간대** — 금요일 오후나 주말에 실행하면 해당 주 기준으로 자동 계산
