---
name: Automated-Code-Review-Cycle
description: PR에 대해 Codex/Gemini 코드 리뷰를 자동으로 받고, 피드백 수정 → 재리뷰 사이클을 사용자 개입 없이 반복. 활성 리뷰어 전부 통과하면 완료. Gemini 미설정 repo는 Codex만으로 판단.
version: 1.9.0
when_to_use: PR 생성 후 코드 리뷰 사이클을 자동화하고 싶을 때
---

<required>
*CRITICAL* Add the following steps to your Todo list using TodoWrite:

1. Detect target PR (worktree branch → PR, or ask user)
2. Record CYCLE_START_TIME — 이 시각 이후의 quota 코멘트만 인식
3. Determine current state: 미처리 리뷰가 있는지 파악
4. Fetch review feedback and evaluate pass/fail
5. If feedback exists: fix → test → commit → push → reply (with commit hash)
6. Repeat step 4-5 until both reviewers pass or quota exhausted
7. Report final status to user
   </required>

# Automated Code Review Cycle

## Overview

PR에 대해 Codex(및 Gemini가 설정된 경우)의 코드 리뷰를 자동으로 받고, 타당한 피드백은 수정하여 재리뷰를 요청하는 사이클을 사용자 개입 없이 반복합니다. Gemini가 미설정된 repo에서는 Codex만으로 통과 판단합니다.

**Core principle:** Detect PR → Determine state → Fix → Test → Commit → Push → Reply (with commit hash) → Re-review → Repeat until pass.

> **CRITICAL 순서:** 답변(reply)은 반드시 `commit` + `push` **이후에** 게시하고, 답변 본문에 해당 commit의 짧은 hash와 URL을 링크로 포함한다. 답변이 먼저 달리면 GitHub PR discussion의 `commit_id` anchor가 수정 이전 커밋을 가리키게 되어 리뷰어(사람 + 봇 모두)가 "수정 완료" 주장을 검증할 수 없다.

**Announce at start:** "자동 코드 리뷰 사이클을 시작합니다."

## GitHub Review API 구조 (CRITICAL — 반드시 이해)

Codex와 Gemini는 리뷰를 다음 구조로 남깁니다:

```
PR
├── Reviews (gh api repos/.../pulls/NNN/reviews)
│   ├── Review ID: 4055212806 (Codex, submitted_at: ...)
│   │   └── Review Comments (gh api repos/.../pulls/NNN/reviews/4055212806/comments)
│   │       ├── Comment ID: 3032371081 (P1: Seed missing mappings...)
│   │       └── Comment ID: 3032371086 (P2: Return actual count...)
│   ├── Review ID: 4055200000 (Gemini, submitted_at: ...)
│   │   └── Review Comments (...)
│   └── ...
├── PR Comments (gh pr view --comments) ← 일반 코멘트, quota 메시지 등
└── PR Inline Comments (gh api repos/.../pulls/NNN/comments) ← 개별 인라인 코멘트 + 답변
```

**핵심:**

- **리뷰 피드백**: `reviews/{review_id}/comments`에 있음 (review 하위 디스커션)
- **일반 코멘트**: `gh pr view --comments`에 있음 (quota 메시지 등)
- **답변**: `pulls/NNN/comments`에서 `in_reply_to_id`로 답변 여부 확인

**피드백 조회 순서:**

> ⚠️ **CRITICAL: 아래 1, 3번은 반드시 `--paginate` 포함.** 기본 30건만 반환되므로 리뷰/코멘트가 많은 PR에서 최신 데이터가 누락됨.

1. `gh api repos/.../pulls/NNN/reviews --paginate` → 리뷰 목록 (Codex/Gemini별 최신 review ID)
2. `gh api repos/.../pulls/NNN/reviews/{ID}/comments` → 해당 리뷰의 실제 피드백
3. `gh api repos/.../pulls/NNN/comments --paginate` → 전체 인라인 코멘트 (답변 여부 확인용)

## Step 0: Detect Target PR

**자동 감지 순서:**

```bash
# 1. 현재 worktree의 브랜치에서 PR 찾기
PR_NUM=$(gh pr view --json number -q .number 2>/dev/null)

# 2. 실패하면 사용자에게 질문
```

- worktree 브랜치에서 PR을 찾으면 자동 사용
- 찾지 못하면 사용자에게 PR 번호 또는 URL 입력 요청
- 세션에서 마지막으로 생성한 PR이 있으면 "PR #NNN이 맞나요?" 확인

**PR 정보 저장:**

```bash
OWNER=$(gh repo view --json owner -q .owner.login)
REPO=$(gh repo view --json name -q .name)
PR_NUM=<detected>
```

## Step 1: Record Cycle Start Time & Determine State

**CRITICAL: 사이클 시작 시각을 기록한다.**

```bash
CYCLE_START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
```

이 시각은 quota 코멘트 필터링에만 사용. 리뷰 피드백은 "미답변 여부"로 판단.

**현재 상태 파악:**

```bash
# 0. Bot 로그인 정확 매칭 상수 (identity spoofing 가드).
# CRITICAL: Step 1에서 정의해야 한다. 미답변 코멘트가 있어 Step 3로 직접 진입하는
# 경로(상태표 첫 행)에서는 Step 2가 실행되지 않으므로, Step 2에 정의하면 sweep
# block이 빈 문자열로 비교하여 silent pass되는 경로가 생긴다.
CODEX_BOT_LOGIN="chatgpt-codex-connector[bot]"
GEMINI_BOT_LOGIN="gemini-code-assist[bot]"

# 1. 모든 Codex/Gemini 리뷰 ID 수집 — **initial snapshot only**.
# CRITICAL: 이 변수는 cycle start 시점 기준이라 이후 round에서 stale.
#           Step 3-1이 매 라운드 재호출하여 `refresh_review_ids()`로 갱신해야 한다.
#           "Codex가 cycle start 직후 review submit + +1 reaction을 거의 동시에 처리"
#           race를 막는 핵심 — initial snapshot만 신뢰하면 새 review 누락.
# CRITICAL: --paginate 필수! 기본 30건만 반환 → 리뷰 많은 PR에서 누락
# CRITICAL: 최신 리뷰만이 아니라 모든 리뷰를 수집해야 이전 리뷰의 미답변 코멘트를 놓치지 않음
# CRITICAL: bot login 정확 매칭 필수. substring `test("codex|gemini")`은 login에
#           해당 substring을 포함한 임의 사용자(`fake-codex` 등)를 허용해
#           identity spoofing 가능. `GEMINI_ENABLED`는 이 query 결과로 한 번만
#           결정되므로 spoof된 사용자가 fake review를 남기면 Gemini 미설정 repo가
#           활성으로 오판되어 cycle 내내 spurious /gemini review가 발사된다.
# CRITICAL: --paginate + 단일 array-emitting --jq는 페이지마다 분리 array를
#           생성한다. Step 3-1과 동일한 2-stage 패턴(`raw emit → jq -s`)으로 통일.
ALL_CODEX_REVIEW_IDS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews --paginate \
  --jq ".[] | select(.user.login == \"$CODEX_BOT_LOGIN\") | {id, submitted_at}" \
  | jq -s 'sort_by(.submitted_at) | [.[].id]')

ALL_GEMINI_REVIEW_IDS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews --paginate \
  --jq ".[] | select(.user.login == \"$GEMINI_BOT_LOGIN\") | {id, submitted_at}" \
  | jq -s 'sort_by(.submitted_at) | [.[].id]')

# 최신 리뷰 ID (통과 조건 확인용)
LATEST_CODEX_REVIEW=$(echo "$ALL_CODEX_REVIEW_IDS" | jq 'last')
LATEST_GEMINI_REVIEW=$(echo "$ALL_GEMINI_REVIEW_IDS" | jq 'last')

# Gemini 활성 여부 판단 (한 번도 리뷰하지 않았으면 미설정으로 간주)
GEMINI_ENABLED=false
if [ -n "$LATEST_GEMINI_REVIEW" ] && [ "$LATEST_GEMINI_REVIEW" != "null" ]; then
  GEMINI_ENABLED=true
fi

# 2. 전체 미답변 코멘트 수 확인 (모든 리뷰의 코멘트에서)
# → Step 3에서 상세 조회
```

**상태별 진입점:**

| 상태                       | 진입점                                 |
| -------------------------- | -------------------------------------- |
| 미답변 리뷰 코멘트 있음    | → Step 3 (피드백 평가부터)             |
| 리뷰 없음, push 후 대기 중 | → Step 2 (polling)                     |
| 리뷰 없음, trigger 필요    | → push 또는 `/gemini review` 후 Step 2 |

## Step 2: Review Strategy & Polling

**Codex 우선, Gemini fallback:**

| 리뷰어 | Trigger 방법         | 재리뷰 Trigger          | Quota 초기화 |
| ------ | -------------------- | ----------------------- | ------------ |
| Codex  | PR 생성/커밋 시 자동 | 새 커밋 push 시 자동    | ~5시간       |
| Gemini | PR 생성 시 자동      | `/gemini review` 코멘트 | ~24시간      |

> **Gemini 미설정 repo:** Gemini가 한 번도 리뷰하지 않은 PR에서는 `GEMINI_ENABLED=false`. Gemini 관련 polling/trigger/quota 로직을 전부 건너뛴다.

**Polling (push 후):**

```bash
# GitHub 서버 권위 시각(ISO8601 UTC). 로컬 `date`는 runner/dev machine의
# 클록 skew로 reaction `created_at`(서버 시각)과 어긋날 수 있어 승인 false-negative를
# 유발할 수 있다. push 직후 repo.pushed_at을 조회해 server-authoritative cutoff를
# 확보한다.
#
# 한계 (REST에는 PR-head 단위 push 시각이 없음):
# - `repo.pushed_at`은 **repo-wide** 최신 push 시각이라, 내 push 직후 타 브랜치로
#   또 다른 push가 발생하면 cutoff가 그 시각으로 밀린다. 실무적으로는 Codex reaction이
#   push 수십 초 뒤에 도착하므로 수 초의 cutoff 드리프트는 false-negative를 일으키지
#   않지만, 고빈도 모노레포에서는 race 가능. GraphQL `pushedDate`는 deprecated되어
#   신뢰할 수 없음.
# - 검증 + 재시도 + 최종 실패 시 하드-페일로 빈/null cutoff에서 stale 승인이
#   통과하는 경로를 차단한다.
fetch_push_time() {
  local t
  for attempt in 1 2 3; do
    t=$(gh api "repos/$OWNER/$REPO" --jq '.pushed_at' 2>/dev/null)
    if [ -n "$t" ] && [ "$t" != "null" ]; then
      printf '%s' "$t"
      return 0
    fi
    sleep 2
  done
  return 1
}
PUSH_TIME=$(fetch_push_time) || {
  echo "FATAL: Could not obtain server-authoritative PUSH_TIME from repo.pushed_at (3회 재시도 실패)." >&2
  echo "         빈 cutoff로 진행하면 stale 승인이 통과할 수 있어 사이클을 중단한다." >&2
  exit 1
}
NEW_REVIEW_FOUND=false

# `CODEX_BOT_LOGIN` / `GEMINI_BOT_LOGIN`은 Step 1에서 정의됨 (identity spoofing 가드).
# substring 매칭(`test("codex|gemini")`)은 login에 "codex"/"gemini"를 포함한
# 임의 사용자(`fake-codex`, PR author 이름 등)를 허용해 조기 탈출을 유발하므로
# 정확 매칭 상수를 cycle 시작 시점에 한 번만 정의하고 모든 step에서 재사용한다.

# 30초 간격으로 최대 10분 polling
#
# CRITICAL: 본인(PR author) 리뷰 댓글·답변은 "리뷰"가 아니다. `gh api .../reviews`는
# Step 4의 reply 게시(body 없는 review payload)도 카운트하므로 단순 submitted_at
# 필터는 즉시 true가 되어 polling을 조기 종료시킨다. bot 로그인만 **정확 매칭**한다.
for i in $(seq 1 20); do
  sleep 30

  # PUSH_TIME 이후에 제출된 **bot** 리뷰만 확인 (--paginate 필수).
  # `gh api --jq`는 단일 문자열만 받고 `--arg` 지원 안 함 → bash 변수 expansion으로
  # 봇 로그인을 jq 문자열 리터럴에 직접 삽입. bot login에 `[bot]` 브래킷이 있어도
  # jq 문자열 == 비교이므로 정규식 특수문자 이슈 없음.
  # --paginate에서 array/count 연산을 --jq 안에 넣으면 페이지별 count가 여러 줄로
  # 출력되어 `[ "$NEW_REVIEWS" -gt 0 ]` 정수 비교가 깨진다. raw emit → jq -s length.
  NEW_REVIEWS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews --paginate \
    --jq ".[] | select(.submitted_at > \"$PUSH_TIME\" and (.user.login == \"$CODEX_BOT_LOGIN\" or .user.login == \"$GEMINI_BOT_LOGIN\")) | .id" \
    | jq -s 'length')

  # Codex는 리뷰를 submit하지 않고 reaction만 업데이트할 때가 많다. eyes(리뷰 중)
  # 또는 +1(승인) 변화도 "진전 있음"으로 감지해 polling을 조기 종료.
  CODEX_REACTION=$(gh api "repos/$OWNER/$REPO/issues/$PR_NUM/reactions" --paginate \
    --jq '.[] | {content: .content, created_at: .created_at, login: .user.login}' \
    | jq -rs --arg bot "$CODEX_BOT_LOGIN" --arg since "$PUSH_TIME" \
      '[.[] | select(.login == $bot and .created_at > $since)]
       | sort_by(.created_at) | last.content // "none"')

  if [ "$NEW_REVIEWS" -gt "0" ] || [ "$CODEX_REACTION" != "none" ]; then
    NEW_REVIEW_FOUND=true
    break
  fi

  # quota 확인 (CYCLE_START_TIME 이후만)
  check_quota  # see below
done
```

**Quota 감지 (CYCLE_START_TIME 이후만):**

```bash
# CRITICAL: 과거 quota 코멘트는 무시. CYCLE_START_TIME 이후의 PR 코멘트만 확인.
CODEX_QUOTA=$(gh pr view $PR_NUM --comments --json comments \
  --jq "[.comments[] | select(
    .createdAt > \"$CYCLE_START_TIME\" and
    (.body | test(\"reached your.*quota|reached your.*usage limits\"))
  )] | length")

# Gemini quota는 별도 패턴 (Gemini 활성 시에만)
if [ "$GEMINI_ENABLED" = true ]; then
  GEMINI_QUOTA=$(gh pr view $PR_NUM --comments --json comments \
    --jq "[.comments[] | select(
      .createdAt > \"$CYCLE_START_TIME\" and
      (.body | test(\"reached your daily quota limit\"))
    )] | length")
fi
```

Quota 감지 시:

- Codex quota → Gemini 활성 시 fallback (`gh pr comment $PR_NUM --body "/gemini review"`), 미설정 시 사용자에게 알림
- Gemini quota → 사용자에게 알림, 사이클 중단

## Step 3: Fetch & Evaluate Review Feedback

**CRITICAL: 리뷰는 review → review comments 구조로 조회해야 한다.**

### 3-1. 모든 리뷰의 피드백 조회

**CRITICAL: 최신 리뷰만이 아니라 모든 리뷰의 코멘트를 수집해야 한다.** Codex/Gemini가 여러 리뷰를 제출한 경우, 이전 리뷰의 미답변 코멘트가 누락되는 버그를 방지.

**CRITICAL: `ALL_*_REVIEW_IDS`를 매 라운드 재조회한다.** Step 1의 변수는 cycle start 시점 snapshot이라, 사이클 도중 submit된 review를 누락한다. 특히 Codex가 첫 polling 직전에 review submit + reaction 갱신을 거의 동시에 처리하면 +1만 보고 통과 오판하는 race가 발생.

```bash
# ── (a) 매 라운드 review ID 재조회 ── (race 방지)
# CRITICAL: 정확 bot login 매칭 — substring `test("codex|gemini")`은 mid-cycle에
#           login에 substring 포함한 임의 사용자(human reviewer 포함)를 bot 리뷰로
#           오인해 ALL_*_REVIEW_IDS에 끼워넣을 수 있다. 이 refresh가 매 라운드
#           돌아가므로 sweep block과 동일한 exact match로 통일.
# CRITICAL: --paginate + 단일 array-emitting --jq는 페이지마다 분리 array를
#           생성한다. 2-stage 패턴(`.[] | {id, submitted_at}` raw emit → `jq -s`)
#           으로 multi-page 정확 처리.
ALL_CODEX_REVIEW_IDS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews --paginate \
  --jq ".[] | select(.user.login == \"$CODEX_BOT_LOGIN\") | {id, submitted_at}" \
  | jq -s 'sort_by(.submitted_at) | [.[].id]')
ALL_GEMINI_REVIEW_IDS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews --paginate \
  --jq ".[] | select(.user.login == \"$GEMINI_BOT_LOGIN\") | {id, submitted_at}" \
  | jq -s 'sort_by(.submitted_at) | [.[].id]')

# ── (b) 모든 Codex 리뷰의 코멘트를 하나의 배열로 수집 ──
# CRITICAL: reviewer_login 필드 포함 — Step 4에서 decline 답변 시 @멘션에 사용
# CRITICAL: review-comments도 --paginate + 2-stage 패턴 (sweep block과 일관).
CODEX_ALL_COMMENTS='[]'
for REVIEW_ID in $(echo "$ALL_CODEX_REVIEW_IDS" | jq -r '.[]'); do
  COMMENTS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$REVIEW_ID/comments --paginate \
    --jq ".[] | {id, body: .body[0:500], path, line, reviewer_login: .user.login, review_id: $REVIEW_ID}" \
    | jq -s '.')
  CODEX_ALL_COMMENTS=$(echo "$CODEX_ALL_COMMENTS" | jq --argjson c "$COMMENTS" '. + $c')
done

# Gemini도 동일 (활성 시에만)
if [ "$GEMINI_ENABLED" = true ]; then
  GEMINI_ALL_COMMENTS='[]'
  for REVIEW_ID in $(echo "$ALL_GEMINI_REVIEW_IDS" | jq -r '.[]'); do
    COMMENTS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$REVIEW_ID/comments --paginate \
      --jq ".[] | {id, body: .body[0:500], path, line, reviewer_login: .user.login, review_id: $REVIEW_ID}" \
      | jq -s '.')
    GEMINI_ALL_COMMENTS=$(echo "$GEMINI_ALL_COMMENTS" | jq --argjson c "$COMMENTS" '. + $c')
  done
fi
```

### 3-2. 미답변 코멘트만 필터

답변 여부는 전체 PR comments에서 `in_reply_to_id`로 확인:

```bash
# CRITICAL: --paginate 필수! 기본 30건만 반환 → 코멘트 많은 PR에서 최신 답변 누락
REPLIED_IDS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/comments --paginate \
  --jq '.[] | select(.in_reply_to_id != null) | .in_reply_to_id' \
  | jq -s '.')

# 모든 리뷰의 코멘트에서 미답변만 필터
UNANSWERED_CODEX=$(echo "$CODEX_ALL_COMMENTS" \
  | jq --argjson replied "$REPLIED_IDS" \
  '[.[] | select(.id as $cid | ($replied | index($cid)) | not)]')

UNANSWERED_CODEX_COUNT=$(echo "$UNANSWERED_CODEX" | jq 'length')

if [ "$GEMINI_ENABLED" = true ]; then
  UNANSWERED_GEMINI=$(echo "$GEMINI_ALL_COMMENTS" \
    | jq --argjson replied "$REPLIED_IDS" \
    '[.[] | select(.id as $cid | ($replied | index($cid)) | not)]')
  UNANSWERED_GEMINI_COUNT=$(echo "$UNANSWERED_GEMINI" | jq 'length')
else
  UNANSWERED_GEMINI_COUNT=0
fi
```

### 3-3. 통과 조건

| 리뷰어 | 상태 | 판정 근거 |
| ------ | ---- | ---------- |
| Codex  | **approved** (통과) | PR(issue) reactions에 Codex bot의 최신 reaction이 `+1`(👍) |
| Codex  | **reviewing** (리뷰 중) | 최신 reaction이 `eyes`(👀) — polling 계속, stale 카운트 증가 안 함 |
| Codex  | **pending** (반응 없음) | PUSH_TIME 이후 Codex reaction 없음 — stale 대상 |
| Gemini | **passed** | 최신 리뷰에 하위 코멘트(review comments)가 0건 |

> **Codex 승인 스펙 근거:** Codex는 PR(issue)의 `reactions` 엔드포인트(`/repos/{o}/{r}/issues/{n}/reactions`)에 **단일 활성 reaction**으로 상태를 표시한다:
> - 👀 (`content: "eyes"`) — **리뷰 진행 중**. 새 push나 초기 PR 생성 직후 부착.
> - 👍 (`content: "+1"`) — **승인/추가 지적 없음**. 리뷰 완료 후 eyes → +1로 전환.
>
> 즉 fix push 직후 Codex가 re-scan 중이라면 이전 +1이 eyes로 되돌아갔다가 재승인 시 다시 +1로 돌아온다. 단일 시점의 reaction 존재 여부가 아닌 **최신 reaction의 content**를 봐야 현재 상태를 정확히 판정할 수 있다. Codex 공식 안내: "If Codex has suggestions, it will comment; otherwise it will react with 👍."

```bash
# Codex 상태 판정 — PR(issue) reactions의 최신 Codex bot reaction content.
#
# 네 가지 위협을 모두 막는다:
# 1. Stale approval: 이전 라운드의 +1이 새 push 이후에도 남아있어 미검토
#    코드가 통과로 오판됨.
#    → PUSH_TIME 이후의 reaction만 고려. 이전 라운드 +1은 PUSH_TIME 이전이라
#      자동 제외됨.
# 2. Identity spoofing: `test("codex")`는 login에 "codex"를 포함한 임의 사용자
#    (`codex-foo` 등)도 매칭하므로 public repo에서 우회 가능.
#    → 공식 Codex bot login 정확 매칭 (`chatgpt-codex-connector[bot]`).
# 3. 페이지네이션: --paginate는 jq를 페이지마다 독립 실행하므로 복합 연산
#    (sort_by, last 등)이 페이지별로 끊긴다.
#    → 1차 jq는 raw 객체만 emit, 2차 `jq -s`가 전 페이지를 슬럽 후 단일 연산.
# 4. 리뷰 중 false-negative: 이전 설계(단순 `+1 개수 > 0`)는 Codex가 새 push에
#    대해 아직 reviewing(👀) 상태면 approved 아님을 정확히 구분 못 했음. 단순
#    "pending(무반응)"과 "reviewing(활발히 검토)"을 합쳐 stale로 처리해
#    불필요한 Gemini fallback 또는 user escalation이 발생.
#    → 최신 reaction의 content를 읽어 approved/reviewing/pending 3-state 분기.
# CODEX_BOT_LOGIN / GEMINI_BOT_LOGIN은 Step 1에서 이미 정의됨. 여기서 재사용.
# PUSH_TIME은 Step 2에서 `gh api repos/$OWNER/$REPO --jq .pushed_at`으로
# 캡쳐한 서버 권위 시각 (reaction.created_at과 동일한 서버 클록).
CODEX_LATEST=$(gh api "repos/$OWNER/$REPO/issues/$PR_NUM/reactions" --paginate \
  --jq '.[] | {content: .content, created_at: .created_at, login: .user.login}' \
  | jq -rs --arg bot "$CODEX_BOT_LOGIN" --arg since "$PUSH_TIME" \
    '[.[] | select(.login == $bot and .created_at > $since)]
     | sort_by(.created_at) | last.content // "none"')

CODEX_STATE="pending"
case "$CODEX_LATEST" in
  "+1")  CODEX_STATE="approved" ;;
  eyes)  CODEX_STATE="reviewing" ;;
  *)     CODEX_STATE="pending" ;;
esac

CODEX_PASSED=false
if [ "$CODEX_STATE" = "approved" ]; then
  # ── Final sweep guard ──
  # +1 reaction은 review 본문 submit과 별 endpoint라, Codex가 두 작업을
  # 거의 동시에 처리하면 Step 3-1 fetch와 Step 3-3 reaction fetch 사이의 gap에
  # 새 review가 끼어들어 reaction만 보고 통과 오판하는 race가 발생.
  # +1 확정 직전에 reviews + review-comments + replies를 한 번 더 fetch하여
  # 신규 미답변 코멘트가 없는지 최종 확인.
  #
  # 비용: API 추가 호출 (reviews list + reviews별 comments + replies). round당
  # CODEX_STATE=approved일 때 1회만 발생 → 통과 직전에만 비용 발생.
  #
  # CRITICAL: 신규 미답변 발견 시 `CODEX_ALL_COMMENTS` + `UNANSWERED_CODEX` +
  # `UNANSWERED_CODEX_COUNT`까지 모두 덮어써야 Step 6의 `no_unanswered_feedback`
  # 분기가 fresh 데이터를 반영해 Step 4 fix 경로로 정상 진입.
  #
  # CRITICAL: substring match가 아닌 정확한 bot login으로 필터 (identity spoofing 방어,
  #           Step 2/3-3 가드와 일관).
  # CRITICAL: --paginate + 단일 --jq에서 array-emitting 필터(`[.[] | ...]`,
  #           `sort_by`, `last` 등)는 페이지마다 독립 평가되어 multi-page 응답을
  #           multi-array stream으로 만든다. Step 3-3 reaction fetch와 동일한
  #           2-stage 패턴 사용: 1차는 raw 객체/스칼라만 emit, 2차 `jq -s`로
  #           전 페이지를 슬럽 후 단일 연산. 이 방어가 깨지면 sweep이 silent
  #           false-pass로 통과하므로 구조적 정확성이 가장 중요한 곳.
  SWEEP_REVIEW_IDS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews --paginate \
    --jq ".[] | select(.user.login == \"$CODEX_BOT_LOGIN\") | {id, submitted_at}" \
    | jq -s 'sort_by(.submitted_at) | [.[].id]')
  SWEEP_COMMENTS='[]'
  for REVIEW_ID in $(echo "$SWEEP_REVIEW_IDS" | jq -r '.[]'); do
    SC=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$REVIEW_ID/comments --paginate \
      --jq ".[] | {id, body: .body[0:500], path, line, reviewer_login: .user.login, review_id: $REVIEW_ID}" \
      | jq -s '.')
    SWEEP_COMMENTS=$(echo "$SWEEP_COMMENTS" | jq --argjson c "$SC" '. + $c')
  done
  REPLIED_IDS_FRESH=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/comments --paginate \
    --jq '.[] | select(.in_reply_to_id != null) | .in_reply_to_id' \
    | jq -s '.')
  SWEEP_UNANSWERED=$(echo "$SWEEP_COMMENTS" \
    | jq --argjson replied "$REPLIED_IDS_FRESH" \
    '[.[] | select(.id as $cid | ($replied | index($cid)) | not)]')
  SWEEP_UNANSWERED_COUNT=$(echo "$SWEEP_UNANSWERED" | jq 'length')

  if [ "${SWEEP_UNANSWERED_COUNT:-0}" -eq "0" ]; then
    CODEX_PASSED=true
  else
    # Race 감지 — Step 3-1/3-2 결과를 fresh 데이터로 덮어써 Step 6이 fix 경로로
    # 정상 진입하도록.
    CODEX_ALL_COMMENTS="$SWEEP_COMMENTS"
    UNANSWERED_CODEX="$SWEEP_UNANSWERED"
    UNANSWERED_CODEX_COUNT="$SWEEP_UNANSWERED_COUNT"
    echo "Final sweep race 감지: 신규 미답변 코멘트 ${SWEEP_UNANSWERED_COUNT}건. Step 4 fix 경로로 진행." >&2
  fi
fi

# Gemini 통과 확인 (활성 시에만 평가, 미설정 시 자동 통과)
# CRITICAL: Step 3-2에서 정의된 `UNANSWERED_GEMINI_COUNT`를 사용한다.
# 이전 버전은 `GEMINI_COMMENTS`(미정의 변수)를 참조해 `${...:-0}` 기본값으로 항상 0 →
# GEMINI_PASSED=true가 되어 미답변 코멘트가 있어도 통과 판정되는 버그가 있었음.
# 이 변수 오타가 수정되면서 Step 6의 `gemini_stale` / `not GEMINI_PASSED` 분기가
# 비로소 의도대로 동작한다.
if [ "$GEMINI_ENABLED" = true ]; then
  GEMINI_PASSED=false
  if [ "${UNANSWERED_GEMINI_COUNT:-0}" -eq "0" ]; then
    GEMINI_PASSED=true
  fi
else
  GEMINI_PASSED=true  # 미설정 = 자동 통과
fi

# 전체 통과 조건: 활성 리뷰어 전부 통과
ALL_PASSED=false
if [ "$CODEX_PASSED" = true ] && [ "$GEMINI_PASSED" = true ]; then
  ALL_PASSED=true
fi
```

**CODEX_STATE 활용:**
- `approved` → 통과 조건 충족. Step 7로.
- `reviewing` → Codex가 아직 평가 중. Step 6의 stale counter를 증가시키지 말고 polling 계속.
- `pending` → PUSH_TIME 이후 Codex 반응 자체가 없음. 트리거가 실패했거나 Codex가 아직 도달하지 못함. Step 6의 stale counter 대상.

**미답변 피드백이 있으면 → Step 4로.**
**미답변 피드백 0건이면 → 통과 확인 후 Step 7로.**

## Step 4: Fix Feedback → Commit → Push → Reply

Code-Review-Reception 스킬의 프로세스를 따르되, 자동화. **순서 엄수 — 답변은 반드시 push 이후.**

1. **분석**: 각 피드백을 P1/P2/P3으로 분류
2. **판단**: 기술적으로 타당한지 검증 (코드베이스 확인)
   - 타당 → 수정
   - 부당 → decline 답변 (기술적 이유와 함께) — 수정이 없으므로 commit/push 경로는 건너뛰고 바로 Step 4-7 답변으로
   - 이전 라운드와 모순 → decline 답변 (이전 결정 참조)
3. **수정**: blocking → simple → complex 순서로 구현
4. **테스트**: 프로젝트 테스트/린트/빌드 명령 실행 (실패하면 Step 4-3으로 복귀)
5. **커밋**: 수정 내용을 요약한 커밋 메시지
6. **Push**: `git push` — Codex 자동 재리뷰도 이 시점에 트리거됨
7. **답변 게시** (이 순서 필수): 각 코멘트에 `gh api`로 답변. 수정 답변은 **방금 푸시된 commit의 hash를 본문에 링크**. decline 답변은 commit 불필요.

> ⚠️ **답변을 먼저 게시하고 나중에 commit/push하면 안 된다.** GitHub PR discussion은 답변이 달린 시점의 `commit_id`에 anchored되기 때문에, 리뷰어가 "수정 완료" 답변을 열어도 그 시점 branch에는 변경이 없어 검증 불가능하다. 또한 Codex 재리뷰는 push 시각 기준으로 동작하므로 push를 먼저 끝내야 다음 polling이 올바르게 기능한다.

### 답변 멘션 규칙 (CRITICAL)

| 답변 유형               | 멘션 여부              | 이유                                              |
| ----------------------- | ---------------------- | ------------------------------------------------- |
| ✅ 동의 (수정 완료)     | **멘션 없음**          | 리뷰어 재트리거 불필요, 토큰 낭비 방지            |
| 📝 반대 (decline)       | **리뷰어 멘션 필수**   | 리뷰어가 재검토하도록 명시적 트리거               |

- 멘션 형식: `@<reviewer_login>` — bot 계정은 `[bot]` 접미사 제외하고 로그인명만 사용
  - 예: `chatgpt-codex-connector[bot]` → `@chatgpt-codex-connector`
  - 예: `gemini-code-assist[bot]` → `@gemini-code-assist`
- `reviewer_login`은 Step 3-1에서 수집한 코멘트 객체에 포함됨 (`.user.login`).

### 답변 본문 규칙 (CRITICAL)

- **수정 답변**은 첫 줄에 `([` + 짧은 hash + `](commit URL))` 형식으로 commit 링크를 포함한다. 리뷰어/사람이 "이 답변이 참조하는 코드 상태"를 1-클릭으로 확인 가능하도록.
- 여러 commit이 누적됐으면 전부 링크(쉼표 구분)하거나 range URL 하나.
- **decline 답변**은 수정이 없으므로 commit 링크 대신 결정 근거를 파일:줄 참조로 보강.

```bash
# ── Step 4-5/6: 커밋 + push ──
git add <수정 파일들>
git commit -m "fix(<scope>): <요약>"
git push

# CRITICAL: push 직후 CODEX_STATE 강제 reset.
# CODEX_STATE는 Step 3-3에서만 갱신되고 Step 6 stale 판정은 그 이전 라운드 값을
# 참조한다. 이전 라운드에 approved/reviewing이었던 상태가 그대로 유지되면
# 신규 push 후 Codex가 silent stall해도 `codex_progressed=true`로 평가돼
# `codex_stale`이 영원히 false가 되고 manual trigger/fallback 경로에 도달 못 한다.
# push로 새 응답을 기다리는 시점이므로 명시적으로 "pending"으로 reset.
CODEX_STATE="pending"

# push 직후 hash 확보 (여러 커밋을 묶어 push한 경우 PUSH_RANGE 활용).
# REPO_URL은 `gh`가 인식하는 실제 host에서 가져와 GitHub Enterprise 등 비-github.com 호스트에서도 정확한 링크 보장.
COMMIT_HASH=$(git rev-parse --short HEAD)
REPO_URL=$(gh repo view --json url -q .url)
COMMIT_URL="$REPO_URL/pull/$PR_NUM/commits/$COMMIT_HASH"

# ── Step 4-7: 답변 게시 ──

# 동의 (수정 완료) — 멘션 없음, commit hash 링크 필수.
# URL은 따옴표로 감싸 shell globbing 방지 (bash/zsh 공통 동작).
# body에 regex/glob 특수문자가 많으면 HEREDOC 사용 권장 (아래 대안 참조).
gh api "repos/$OWNER/$REPO/pulls/$PR_NUM/comments/$COMMENT_ID/replies" \
  -f body="✅ **수정 완료** ([\`$COMMIT_HASH\`]($COMMIT_URL)) — <설명>"

# decline (반대) — 리뷰어 멘션, commit 링크 불필요.
# reviewer_login은 해당 코멘트 객체의 .reviewer_login 필드.
REVIEWER_HANDLE=$(echo "$REVIEWER_LOGIN" | sed 's/\[bot\]$//')
gh api "repos/$OWNER/$REPO/pulls/$PR_NUM/comments/$COMMENT_ID/replies" \
  -f body="@${REVIEWER_HANDLE} 📝 <기술적 이유와 파일:줄 참조>"

# 대안: body가 복잡해 shell escape가 까다로우면 HEREDOC + --input -.
# `gh api`는 `-f/-F`가 없으면 기본 GET이므로 create-reply 엔드포인트에는 `--method POST` 필수.
gh api --method POST "repos/$OWNER/$REPO/pulls/$PR_NUM/comments/$COMMENT_ID/replies" \
  --input - <<EOF
{"body": "✅ **수정 완료** ([\`$COMMIT_HASH\`]($COMMIT_URL)) — <설명>"}
EOF

# zsh 사용자는 선택적으로 `noglob gh api ...` 래퍼를 써도 됨 (bash에서는 동작 안 함).
```

## Step 5: Quota Check & Gemini Fallback

Step 4-6의 push로 Codex는 이미 자동 재리뷰 경로에 진입. 이 단계는 quota 초과 시 Gemini로 경로 전환을 담당한다.

```bash
# Codex quota 초과 상태면 Gemini fallback (Gemini 활성 시에만)
# CRITICAL: GEMINI_FALLBACK_REQUESTED=true 함께 set. Step 6의 codex_at_max
# fallback과 동일 의미 — cached pass(GEMINI_PASSED=true) 상태에서도 fallback
# 응답을 stale 추적하기 위함. 이 set 누락 시 Gemini가 옛 commit pass + 신규
# request silent no-op일 때 timeout/escalation에 도달 못 함.
if [ "$CODEX_QUOTA_HIT" = true ] && [ "$GEMINI_ENABLED" = true ]; then
  gh pr comment $PR_NUM --body "/gemini review"
  GEMINI_FALLBACK_REQUESTED=true
elif [ "$CODEX_QUOTA_HIT" = true ] && [ "$GEMINI_ENABLED" = false ]; then
  echo "Codex quota 초과, Gemini 미설정 — 사용자에게 알림"
fi
```

## Step 6: Repeat Until Pass

```
ROUND=0
MAX_ROUNDS=10          # 각 라운드 = (리뷰 polling + fix + push + reply) ≈ 4-6회 LLM 호출.
                       # 10 라운드면 최대 ~60회 호출 — 비용 상한. 초과 시 사용자에게 에스컬레이트.
CODEX_STALE_COUNT=0    # Codex가 무반응한 연속 라운드 수 (Gemini와 독립)
GEMINI_STALE_COUNT=0   # Gemini가 무반응한 연속 라운드 수 (Codex와 독립)
MAX_STALE=2            # 이 횟수 도달 시 fallback. 시퀀스: stale=1(수동 트리거) → stale=2(fallback).
                       # CRITICAL: 봇별 카운터로 분리. 단일 STALE_COUNT는 Round A(Gemini stale)
                       # → Round B(Codex stale) 같은 cross-bot 시퀀스에서 누적이 합산되어
                       # 한 봇이 사실상 1라운드만 stale인데 MAX_STALE 도달로 잘못 판정되는
                       # 오염이 발생. effective wait per bot = polling 2회 ≈ 20분.
PREV_CODEX_LATEST_REVIEW=""    # 이전 라운드의 Codex 최신 review ID
PREV_GEMINI_LATEST_REVIEW=""   # 이전 라운드의 Gemini 최신 review ID (활성 시)
CODEX_STATE="pending"   # Step 3-3에서 갱신. Step 6 stale 판정이 Round 1에 Step 3-3
                        # 실행 전에 참조하므로 loop 진입 전 명시적 초기화 필수.
CODEX_FALLBACK_DONE=false  # Codex stale로 인해 Gemini fallback이 한 번이라도 발사됐는지.
                           # 이후 라운드에서 codex_stale을 무시해 매 ~20분마다
                           # spurious @codex review / /gemini review 재발사를 차단.
                           # Codex가 늦게나마 응답해 codex_progressed=true가 되면 reset.
GEMINI_FALLBACK_REQUESTED=false  # Codex fallback으로 `/gemini review`가 발사돼 Gemini
                                 # 응답을 기다리는 상태. cached pass(GEMINI_PASSED=true)
                                 # 상태에서도 신규 review ID 도착 전까지 gemini_stale
                                 # 판정을 활성화 — silent no-op timeout/escalation 가능.
                                 # Gemini 새 review ID 감지 시 reset.
WALL_CLOCK_START=now()   # bash 구현 시 now()는 `$(date +%s)`
WALL_CLOCK_BUDGET=1800   # 30분 — 초과 시 진행 중이라도 사용자 확인 요청

while ROUND < MAX_ROUNDS:
  ROUND++
  log("=== Round $ROUND ===")

  poll_for_reviews()            # Step 2 — push 후 새 리뷰 대기, NEW_REVIEW_FOUND 설정

  check_quota()                 # CYCLE_START_TIME 이후만
  if GEMINI_ENABLED and both_quota_hit:
    notify_user("양쪽 quota 초과. 대기 필요.")
    break
  elif not GEMINI_ENABLED and codex_quota_hit:
    notify_user("Codex quota 초과, Gemini 미설정. 대기 필요.")
    break

  # ── Stale review 감지 (per-bot) ──
  # CODEX_STATE를 먼저 평가해 "활발히 리뷰 중(eyes)"과 "실제 무응답(pending)"을 구분.
  # reviewing 상태는 stale 아님 → polling 계속.
  # pending 상태이거나 최신 review ID가 동일(= bot 진전 없음)일 때만 stale로 인정.
  #
  # NOTE: CODEX_STATE는 Step 3-3에서 갱신된다. 이 stale 판정 시점에는 이전 라운드의
  # 값을 참조한다. 두 layer로 방어:
  # 1) Step 2 polling이 reaction 변화 감지 시 NEW_REVIEW_FOUND=true로 break →
  #    `not NEW_REVIEW_FOUND` 가드.
  # 2) Step 4 push 직후 `CODEX_STATE="pending"` 강제 reset → 이전 라운드의
  #    approved/reviewing이 신규 push silent stall을 가리는 race 방지.
  # CODEX_STATE 참조를 이동하거나 Step 3-3을 stale 판정 앞으로 당기면 이 의존이
  # 깨지므로 주의. push 후 reset이 빠지면 fix push 후 Codex 무응답이 영원히
  # codex_stale=false로 분류돼 manual trigger/fallback에 도달 못 함.
  current_codex_latest = get_latest_codex_review_id()    # 없으면 ""
  current_gemini_latest = get_latest_gemini_review_id()  # 미활성/없으면 ""
  codex_progressed = (CODEX_STATE in {"reviewing", "approved"})
  # CRITICAL: `not CODEX_FALLBACK_DONE` 필수. fallback 후에도 Codex가 무응답이면
  # 매 stale streak마다 @codex review + /gemini review가 영구 재발사된다 (PR에 봇
  # 코멘트 spam). 한 번 fallback한 Codex는 자연 회복(codex_progressed)까지 stale 분류 제외.
  #
  # CRITICAL: review가 한번도 없는 케이스(current_codex_latest == "")도 stale로 인정.
  # Codex는 1차 reviewer이므로 첫 응답이 영영 안 오는 silent stall은 분명한 stale.
  # 이전엔 `current != ""` 가드로 case B를 차단했으나, 그건 "PREV=current=""인 단순
  # 비교를 stale로 오판"하는 트랩만 막으면 됨 — 실제 silent no-review 자체는 정당한
  # stale. ID 비교 분기를 두 케이스로 나눠 정확하게 처리.
  codex_id_static = (current_codex_latest != "" 
                     and current_codex_latest == PREV_CODEX_LATEST_REVIEW)
  codex_no_review = (current_codex_latest == "")
  codex_stale = (not CODEX_FALLBACK_DONE
                 and not codex_progressed
                 and (codex_id_static or codex_no_review))
  # Gemini는 reaction state 머신이 없으므로 "미통과 + 최신 review ID 미변동"으로 stale 추정.
  # 활성이 아니면 stale 아님으로 취급 (Gemini 미설정 repo는 영향 없음).
  # CRITICAL: cached pass(옛 commit) 후 `/gemini review` fallback이 발사된 경우,
  # Gemini가 silent no-op면 review ID 변동 없음. `not GEMINI_PASSED`만 보면
  # cached pass=true가 stale 판정을 영원히 막아 무한 polling. fallback 발사 후
  # 응답을 기다리는 상황을 별도 플래그(`GEMINI_FALLBACK_REQUESTED`)로 추적해
  # cached pass와 무관하게 stale 판정을 진행시킨다 (Gemini 새 review 도착 시 reset).
  gemini_stale = (GEMINI_ENABLED
                  and current_gemini_latest != ""
                  and current_gemini_latest == PREV_GEMINI_LATEST_REVIEW
                  and (not GEMINI_PASSED or GEMINI_FALLBACK_REQUESTED))

  # ── 봇별 카운터 갱신 ──
  # CRITICAL: 봇별 카운터 분리. 한 봇이 progress하면 그 봇의 카운터만 0으로,
  # 다른 봇의 stale streak에는 영향 없음.
  if not NEW_REVIEW_FOUND and codex_stale:
    CODEX_STALE_COUNT++
  else:
    CODEX_STALE_COUNT = 0
    if codex_progressed:
      CODEX_FALLBACK_DONE = false   # Codex 자연 회복 → fallback 락 해제

  if not NEW_REVIEW_FOUND and gemini_stale:
    GEMINI_STALE_COUNT++
  else:
    GEMINI_STALE_COUNT = 0
    # Gemini 새 review ID 도착 = fallback 응답 수신 → 플래그 해제
    if current_gemini_latest != "" and current_gemini_latest != PREV_GEMINI_LATEST_REVIEW:
      GEMINI_FALLBACK_REQUESTED = false

  if codex_stale or gemini_stale:
    log("리뷰어 무응답 (codex=${CODEX_STALE_COUNT}/${MAX_STALE}, gemini=${GEMINI_STALE_COUNT}/${MAX_STALE})")

  # ── stale=1 수동 트리거 (silent-drop 회복 시도) ──
  # polling 1회 ≈ 10분(30s × 20회). 1회 무반응 시 GitHub 측 silent-drop
  # (quota 코멘트도 안 뜨고 멈춘 케이스) 가능성 → 실제 stale인 봇만 재호출.
  # NOTE: dedup은 봇별 ==1 비교 자체로 보장. 카운터는 매 stale 라운드 ++만 되고
  #       stale 아닌 라운드에서 0으로 리셋되므로 한 streak 내 ==1은 정확히 1회만 hit.
  trigger_sent = false
  if CODEX_STALE_COUNT == 1:
    # Codex 공식 manual trigger: PR 코멘트에 `@codex review`.
    gh pr comment $PR_NUM --body "@codex review"
    log("Codex 수동 재트리거 발송 (@codex review)")
    trigger_sent = true
  if GEMINI_STALE_COUNT == 1:
    gh pr comment $PR_NUM --body "/gemini review"
    log("Gemini 수동 재트리거 발송 (/gemini review)")
    trigger_sent = true
  if trigger_sent:
    # CRITICAL: continue 전에 PREV_*_LATEST_REVIEW 갱신 필수.
    # 갱신을 빠뜨리면 다음 라운드에서도 동일 ID로 stale 판정이 즉시 true가 되어
    # 카운터가 race past하며 트리거의 "한 번 더 polling 대기" 의도가 무효화됨.
    PREV_CODEX_LATEST_REVIEW = current_codex_latest
    PREV_GEMINI_LATEST_REVIEW = current_gemini_latest
    continue   # 수동 트리거 후 다음 polling 라운드 대기

  # ── stale ≥ MAX_STALE fallback (per-bot) ──
  # CRITICAL: 봇별 카운터 기반 분기. 수동 트리거 후에도 회복 안 된 봇만 처리.
  # - Codex만 max + Gemini 활성·미stale → Gemini fallback (Codex 자리 메움)
  # - Codex max + Gemini도 max → 양쪽 무응답, fallback 불가, escalate
  # - Gemini만 max → escalate
  # - Codex만 max + Gemini 사용 불가 → escalate
  #
  # CRITICAL: `not GEMINI_PASSED` 가드는 의도적으로 제외.
  # `GEMINI_PASSED`는 "현재 미답변 코멘트가 0건"이라는 사실 기반이지 "이 push에
  # 대해 Gemini가 pass했다"가 아니다 (Step 4 push 후 Gemini는 자동 재리뷰 안 함;
  # `/gemini review` 명시 트리거 필요). 옛 commit에 Gemini가 pass 줬고 신규
  # push 후 Codex가 silent stall한 시나리오에서, `not GEMINI_PASSED=false`가
  # fallback을 막아 user escalate로 빠진다 — 신규 push에 대해 fresh 의견을
  #받을 기회를 잃음. fallback은 stale cached pass에 gate되면 안 됨.
  codex_at_max = (CODEX_STALE_COUNT >= MAX_STALE)
  gemini_at_max = (GEMINI_STALE_COUNT >= MAX_STALE)

  if codex_at_max and gemini_at_max:
    notify_user("Codex + Gemini 모두 ${MAX_STALE}회 연속 무응답. Gemini fallback 불가. 수동 확인 필요.")
    break
  elif codex_at_max:
    if GEMINI_ENABLED and not gemini_stale:
      log("Codex 무응답 지속 → Gemini fallback (신규 push 기준 재리뷰 강제)")
      gh pr comment $PR_NUM --body "/gemini review"
      CODEX_STALE_COUNT = 0
      CODEX_FALLBACK_DONE = true   # 이후 라운드에서 Codex stale 재인식 차단
      GEMINI_FALLBACK_REQUESTED = true  # cached pass와 무관하게 Gemini 응답 추적 활성
      PREV_CODEX_LATEST_REVIEW = current_codex_latest
      PREV_GEMINI_LATEST_REVIEW = current_gemini_latest
      continue
    else:
      notify_user("Codex가 ${MAX_STALE}회 연속 무응답. 수동 확인 필요.")
      break
  elif gemini_at_max:
    notify_user("Gemini가 ${MAX_STALE}회 연속 무응답. 수동 확인 필요.")
    break

  # ── 매 라운드 PREV_* 갱신 ──
  # break/continue로 빠지지 않은 모든 경로(non-stale, 또는 stale이지만 trigger·fallback
  # 양쪽 다 안 걸린 중간 카운터 — MAX_STALE>2 가정)를 커버. detection이 frozen ID로
  # corrupt되는 것을 구조적으로 방어.
  PREV_CODEX_LATEST_REVIEW = current_codex_latest
  PREV_GEMINI_LATEST_REVIEW = current_gemini_latest

  if CODEX_STATE == "reviewing":
    log("Codex 리뷰 진행 중 (👀) — polling 계속")

  fetch_review_feedback()       # Step 3 — review → review comments 구조로 조회
  filter_unanswered()           # in_reply_to_id로 미답변만

  # Plan 08: label-based termination. Exit 3 (changes-requested) falls through
  # to fix_commit_push_reply — same logic as legacy LLM-based pass-condition fail.
  # Infinite oscillation prevented by MAX_ROUNDS=10 bound (no per-round flag needed).

  if no_unanswered_feedback:
    # Plan 08: label-based deterministic termination (Phase 1 = Option C)
    HARNESS="${SAZO_HARNESS_DIR:-$HOME/.config/sazo-ai-harness/packages/ai-harness}"
    REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "WARN: git rev-parse failed; using cwd '$PWD' as REPO_DIR. Repo override (.github/sazo-bot-review.json) may not resolve correctly." >&2
        REPO_DIR="$PWD"
    }
    [ "$ROUND" -eq 1 ] && {
        SETUP_LOG="/tmp/setup-labels-$$.log"
        # CRITICAL: pass --repo-dir so setup-labels.sh merges repo override and creates
        # labels with custom label_prefix values — same as poll-labels.sh does at runtime.
        # Without this, repos with custom prefixes get default labels from setup but the
        # poller waits for custom-prefix labels that don't exist → gh issue edit fails.
        bash "$HARNESS/skills/automated-code-review-cycle/scripts/setup-labels.sh" --repo-dir "$REPO_DIR" >"$SETUP_LOG" 2>&1 || {
            echo "WARN: setup-labels.sh failed (see $SETUP_LOG). Polling may produce false timeout." >&2
        }
    }

    # CRITICAL: write verdict label BEFORE calling poll-labels.sh.
    # Step 4-8 (after fix_commit_push_reply) runs only when there IS unanswered feedback.
    # When no_unanswered_feedback=true (clean review), Step 4-8 is skipped (loop breaks
    # on poll exit 0). The poller needs the approved label to already exist before it
    # starts polling — otherwise it times out waiting for a label that was never written.
    # Apply config-driven prefix (same logic as Step 4-8 below).
    _NUF_HARNESS="${SAZO_HARNESS_DIR:-$HOME/.config/sazo-ai-harness/packages/ai-harness}"
    _NUF_CONFIG="$_NUF_HARNESS/skills/automated-code-review-cycle/config.json"
    if [[ -f "$REPO_DIR/.github/sazo-bot-review.json" ]]; then
      _NUF_MERGED=$(jq -n --slurpfile b "$_NUF_CONFIG" --slurpfile o "$REPO_DIR/.github/sazo-bot-review.json" \
        '$b[0]
         | .active_reviewers = (($b[0].active_reviewers // {}) + ($o[0].active_reviewers // {}))
         | .labels = ($b[0].labels * ($o[0].labels // {}))')
    else
      _NUF_MERGED=$(jq '.' "$_NUF_CONFIG")
    fi
    _NUF_CODEX_PREFIX=$(echo "$_NUF_MERGED" | jq -r '.active_reviewers.codex.label_prefix // "bot-review/codex/"' | sed 's|/$||')
    _NUF_APPROVED_SUFFIX=$(echo "$_NUF_MERGED" | jq -r '.labels.approved.suffix // "approved"')
    _NUF_INPROGRESS_SUFFIX=$(echo "$_NUF_MERGED" | jq -r '.labels.in_progress.suffix // "in-progress"')
    _NUF_CHANGES_SUFFIX=$(echo "$_NUF_MERGED" | jq -r '.labels.changes_requested.suffix // "changes-requested"')
    gh issue edit "$PR_NUM" \
        --add-label "$_NUF_CODEX_PREFIX/$_NUF_APPROVED_SUFFIX" \
        --remove-label "$_NUF_CODEX_PREFIX/$_NUF_INPROGRESS_SUFFIX,$_NUF_CODEX_PREFIX/$_NUF_CHANGES_SUFFIX" 2>/dev/null || true
    # CRITICAL: only write Gemini approved label if Gemini has reviewed the
    # CURRENT push. GEMINI_ENABLED=true means Gemini has reviewed at some point
    # historically, but its last review may predate the current push (stale cached
    # pass). Writing the approved label for a stale Gemini pass lets poll-labels.sh
    # exit 0 immediately even though Gemini never evaluated the latest changes.
    # Guard: check whether any Gemini review was submitted after PUSH_TIME.
    _GEMINI_FRESH=false
    if [ "$GEMINI_ENABLED" = true ]; then
      _GEMINI_LATEST_AT=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews --paginate \
        --jq ".[] | select(.user.login == \"$GEMINI_BOT_LOGIN\") | .submitted_at" \
        2>/dev/null | sort | tail -1)
      if [[ -n "$_GEMINI_LATEST_AT" ]] && [[ "$_GEMINI_LATEST_AT" > "$PUSH_TIME" ]]; then
        _GEMINI_FRESH=true
      fi
    fi
    if [ "$_GEMINI_FRESH" = true ]; then
      _NUF_GEMINI_PREFIX=$(echo "$_NUF_MERGED" | jq -r '.active_reviewers.gemini.label_prefix // "bot-review/gemini/"' | sed 's|/$||')
      gh issue edit "$PR_NUM" \
          --add-label "$_NUF_GEMINI_PREFIX/$_NUF_APPROVED_SUFFIX" \
          --remove-label "$_NUF_GEMINI_PREFIX/$_NUF_INPROGRESS_SUFFIX,$_NUF_GEMINI_PREFIX/$_NUF_CHANGES_SUFFIX" 2>/dev/null || true
    fi

    # CRITICAL: pass --skip-reviewer gemini when:
    # (a) GEMINI_ENABLED=false — Gemini has never reviewed this PR, OR
    # (b) _GEMINI_FRESH=false — Gemini is enabled but hasn't reviewed the current push.
    # In both cases, requiring bot-review/gemini/approved would cause poll-labels.sh
    # to timeout waiting for a label that will never appear.
    # The --skip-reviewer flag excludes the key at runtime without mutating config.
    _SKIP_ARGS=()
    [ "$GEMINI_ENABLED" = false ] && _SKIP_ARGS+=(--skip-reviewer gemini)
    [ "$_GEMINI_FRESH" = false ] && [ "$GEMINI_ENABLED" = true ] && _SKIP_ARGS+=(--skip-reviewer gemini)
    bash "$HARNESS/skills/automated-code-review-cycle/scripts/poll-labels.sh" --pr "$PR_NUM" --repo-dir "$REPO_DIR" "${_SKIP_ARGS[@]+"${_SKIP_ARGS[@]}"}"
    case $? in
      0) ALL_PASSED=true; break ;;
      2) notify_user "Bot review polling timeout (${SAZO_BOT_POLL_MAX_ITER:-60} iterations × ${SAZO_BOT_POLL_INTERVAL:-30}s)"; break ;;
      3) ;; # changes-requested fallthrough — fix_commit_push_reply will run; oscillation bounded by MAX_ROUNDS=10
      4) notify_user "gh CLI 미설치/미인증 — Phase 1 라벨 게이트 비활성. 사용자 수동 LLM 판단 필요."; break ;;
      5) echo "WARN: active reviewers config empty — Phase 1 라벨 게이트 skip. LLM 텍스트 판단 fallback (수동)" >&2
         continue ;;  # skip fix attempt; next round picks up
    esac
    # 통과 조건 미충족 + 새 리뷰 없음 → stale로 처리됨 (위 로직)

  fix_commit_push_reply()       # Step 4 — 수정 → 테스트 → 커밋 → push → 답변(commit hash)

  # Step 4-8: review 결과 라벨 부착 (Plan 08 Phase 1 = Option C)
  # 본문 해석 후 LLM이 REVIEW_STATUS 결정. 그 다음 case가 결정적으로 라벨 부착.

  # CRITICAL: label_prefix는 config.json 및 repo override(.github/sazo-bot-review.json)에서
  # 읽어야 한다. 하드코딩하면 커스텀 prefix를 사용하는 repo에서 poll-labels.sh가 바라보는
  # 라벨과 Step 4-8이 기록하는 라벨이 달라져 gate가 영원히 timeout된다.
  _HARNESS="${SAZO_HARNESS_DIR:-$HOME/.config/sazo-ai-harness/packages/ai-harness}"
  _SKILL_CONFIG="$_HARNESS/skills/automated-code-review-cycle/config.json"
  _REPO_OVERRIDE=""
  _REPO_DIR_4_8=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
  [[ -f "$_REPO_DIR_4_8/.github/sazo-bot-review.json" ]] && _REPO_OVERRIDE="$_REPO_DIR_4_8/.github/sazo-bot-review.json"

  if [[ -n "$_REPO_OVERRIDE" ]]; then
    _MERGED=$(jq -n \
      --slurpfile base "$_SKILL_CONFIG" \
      --slurpfile ovr "$_REPO_OVERRIDE" \
      '$base[0]
       | .active_reviewers = (($base[0].active_reviewers // {}) + ($ovr[0].active_reviewers // {}))
       | .labels = ($base[0].labels * ($ovr[0].labels // {}))')
  else
    _MERGED=$(jq '.' "$_SKILL_CONFIG")
  fi

  CODEX_PREFIX=$(echo "$_MERGED" | jq -r '.active_reviewers.codex.label_prefix // "bot-review/codex/"' | sed 's|/$||')
  GEMINI_PREFIX=$(echo "$_MERGED" | jq -r '.active_reviewers.gemini.label_prefix // "bot-review/gemini/"' | sed 's|/$||')
  # CRITICAL: read suffixes from config to match what poll-labels.sh and setup-labels.sh create.
  # Repos with .labels.*.suffix overrides must write matching label names here.
  _APPROVED_SUFFIX=$(echo "$_MERGED" | jq -r '.labels.approved.suffix // "approved"')
  _INPROGRESS_SUFFIX=$(echo "$_MERGED" | jq -r '.labels.in_progress.suffix // "in-progress"')
  _CHANGES_SUFFIX=$(echo "$_MERGED" | jq -r '.labels.changes_requested.suffix // "changes-requested"')

  # LLM determines status per-reviewer based on review evaluation:
  # - approved: 모든 unanswered 댓글 답변 완료 + decline 0건
  # - changes-requested: decline 있거나 새 fix 요청 진행 중
  # - in-progress: 트리거만 보낸 상태 (응답 대기)

  REVIEW_STATUS_CODEX="approved"  # ← LLM이 평가 후 채움 (approved | changes-requested | in-progress)
  case "$REVIEW_STATUS_CODEX" in
      approved)
          gh issue edit "$PR_NUM" \
              --add-label "$CODEX_PREFIX/$_APPROVED_SUFFIX" \
              --remove-label "$CODEX_PREFIX/$_INPROGRESS_SUFFIX,$CODEX_PREFIX/$_CHANGES_SUFFIX"
          ;;
      changes-requested)
          gh issue edit "$PR_NUM" \
              --add-label "$CODEX_PREFIX/$_CHANGES_SUFFIX" \
              --remove-label "$CODEX_PREFIX/$_INPROGRESS_SUFFIX,$CODEX_PREFIX/$_APPROVED_SUFFIX"
          ;;
      in-progress)
          gh issue edit "$PR_NUM" \
              --add-label "$CODEX_PREFIX/$_INPROGRESS_SUFFIX" \
              --remove-label "$CODEX_PREFIX/$_APPROVED_SUFFIX,$CODEX_PREFIX/$_CHANGES_SUFFIX"
          ;;
  esac

  # Gemini 활성 시 동일 패턴 (REVIEW_STATUS_GEMINI 평가 후 case)
  if [ "$GEMINI_ENABLED" = true ]; then
      REVIEW_STATUS_GEMINI="approved"  # ← LLM 평가
      case "$REVIEW_STATUS_GEMINI" in
          approved) gh issue edit "$PR_NUM" --add-label "$GEMINI_PREFIX/$_APPROVED_SUFFIX" --remove-label "$GEMINI_PREFIX/$_INPROGRESS_SUFFIX,$GEMINI_PREFIX/$_CHANGES_SUFFIX" ;;
          changes-requested) gh issue edit "$PR_NUM" --add-label "$GEMINI_PREFIX/$_CHANGES_SUFFIX" --remove-label "$GEMINI_PREFIX/$_INPROGRESS_SUFFIX,$GEMINI_PREFIX/$_APPROVED_SUFFIX" ;;
          in-progress) gh issue edit "$PR_NUM" --add-label "$GEMINI_PREFIX/$_INPROGRESS_SUFFIX" --remove-label "$GEMINI_PREFIX/$_APPROVED_SUFFIX,$GEMINI_PREFIX/$_CHANGES_SUFFIX" ;;
      esac
  fi
  # CRITICAL: REVIEW_STATUS는 LLM이 본문 해석 후 결정. approved는 모든 unanswered가 fix됐고
  # decline 0건일 때만. 무조건 approved 부착 금지 (Anti-Patterns 참조).

  gemini_fallback_if_quota()    # Step 5 — Codex quota 초과 시에만

  # Wall-clock budget check
  if (now() - WALL_CLOCK_START) > WALL_CLOCK_BUDGET:
    notify_user("30분 경과. 계속 진행 할까요? (진행 / 중단)")
    break  # 사용자 응답 대기
```

**안전 가드:**

- 최대 라운드 수: 10 (각 라운드 ~4-6 LLM 호출 → 총 ~60 호출 상한)
- Wall-clock budget: 30분 — 초과 시 사용자에게 진행 여부 확인
- 같은 피드백 3회 반복 시: decline하고 다음으로
- **Stale review (stale=1, ≈10분 무반응)**: 실제 stale인 봇만 골라 `@codex review` / `/gemini review` 수동 트리거 1회 발송 후 다음 polling 대기 (GitHub silent-drop 회복 시도). 진행 중인 봇에 spurious 재트리거 보내지 않음.
- **Stale review (stale≥MAX_STALE, ≈20분 무반응)**: 수동 트리거 후에도 무반응 → Gemini fallback 또는 사용자 알림
- 총 소요 시간 모니터링 (각 라운드 로그)

## Step 7: Final Report

```
자동 코드 리뷰 사이클 완료:

- PR: #NNN
- 총 라운드: N
- Codex: ✅ 통과 / ❌ quota 초과 / ⏳ 미완료
- Gemini: ✅ 통과 / ❌ quota 초과 / ⏳ 미완료 / ➖ 미설정 (skipped)
- 수정한 피드백: N건
- Decline한 피드백: N건
- 총 소요 시간: Nm

PR이 머지 가능한 상태입니다. / 사용자 확인이 필요합니다.
```

## Anti-Patterns

| 잘못된 방식                                                  | 올바른 방식                                                                 |
| ------------------------------------------------------------ | --------------------------------------------------------------------------- |
| PR comments만 보고 리뷰 피드백 감지                          | review → review comments 구조로 조회                                        |
| 과거 quota 코멘트를 현재 quota로 오인                        | CYCLE_START_TIME 이후 코멘트만 확인                                         |
| 이미 답변된 코멘트를 다시 처리                               | in_reply_to_id로 미답변만 필터                                              |
| 모든 피드백을 무조건 수정                                    | 기술적 타당성 검증 후 판단                                                  |
| 이전 라운드 수정을 뒤집는 피드백 수용                        | 이전 결정 참조하여 decline                                                  |
| quota 초과 시 무한 대기                                      | 사용자에게 알림 후 중단                                                     |
| 테스트 없이 push                                             | 반드시 test/lint/build 통과 후 push                                         |
| 사이클 중간 진입 시 처음부터 다시 시작                       | 현재 상태를 파악하고 적절한 Step부터 진입                                   |
| `gh api` 조회 시 `--paginate` 누락 (reviews, comments 모두!) | 기본 30건 → 최신 리뷰/답변 누락. **모든 `gh api` 호출에** `--paginate` 사용 |
| `--paginate`와 array/count `--jq`를 한 번에 사용             | 페이지별 배열/카운트가 여러 줄로 출력되어 JSON/정수 비교가 깨짐. raw emit 후 `jq -s`로 전 페이지를 합산 |
| Bot login substring 매칭 (`test("codex")` / `test("gemini")`)         | 정확 매칭 상수 사용 — `CODEX_BOT_LOGIN="chatgpt-codex-connector[bot]"`, `GEMINI_BOT_LOGIN="gemini-code-assist[bot]"`를 Step 1에서 정의 후 모든 step에서 재사용. substring 매칭은 `fake-codex` 같은 이름의 사용자가 봇으로 위장 가능 (identity spoofing) |
| Gemini 미설정 repo에서 Gemini 대기                           | `GEMINI_ENABLED` 플래그로 Gemini 관련 로직 분기                             |
| polling 타임아웃 후 같은 리뷰 무한 재평가                    | 봇별 stale 카운터(`CODEX_STALE_COUNT`, `GEMINI_STALE_COUNT`)로 독립 감지, `>= MAX_STALE`(=2) 도달 시 fallback/알림 (stale=1 트리거 → stale=2 fallback). 단일 카운터는 cross-bot 누적으로 한 봇이 1라운드만 무반응이어도 MAX_STALE 도달로 오판되는 오염 발생 |
| 최신 리뷰만 확인하여 이전 리뷰 미답변 누락                   | `ALL_*_REVIEW_IDS`로 모든 리뷰의 코멘트를 스캔                              |
| 동의 답변에 리뷰어 멘션 포함                                 | 동의 시 멘션 생략 (재트리거 불필요, 토큰 낭비)                              |
| 반대(decline) 답변에 리뷰어 멘션 누락                        | `@<reviewer_login>` 멘션으로 재검토 트리거                                  |
| 답변을 commit/push 이전에 게시                               | `commit → push → 답변` 순서 엄수. 그러지 않으면 답변 시점 `commit_id`가 수정 이전을 가리켜 검증 불가 |
| 수정 답변에 commit hash 링크 누락                            | 답변 본문에 `[`short-hash`](commit URL)` 필수 — 리뷰어가 "수정 완료" 주장의 근거 커밋을 1-클릭 추적 |
| 답변 본문에 regex/glob 특수문자 포함 시 shell 해석 충돌       | URL을 따옴표로 감싸거나 HEREDOC + `--input -` 사용 (bash/zsh 공통). `noglob`은 zsh 전용이므로 범용 기본값으로 쓰지 말 것 |
| Codex 승인 판정 시 PR body 텍스트에서 👍 이모지 grep           | Codex는 PR(issue) `reactions` 엔드포인트에 `content: "+1"`로 반응. `gh api .../issues/$PR_NUM/reactions`를 codex bot 로그인 + `+1`로 필터 |
| Codex가 `eyes`(👀) 반응인 상태를 "무응답"으로 오인해 stale 카운트 증가 | `eyes`는 "리뷰 진행 중" 상태 — polling 계속. 최신 reaction content를 `approved`(+1) / `reviewing`(eyes) / `pending`(없음)으로 분기 |
| fix push 후 Codex 재리뷰가 완료되기 전에 이전 라운드의 `+1`만 보고 통과 판정 | PUSH_TIME 이후의 **최신** reaction content를 봐야 현재 코드 상태의 승인 여부 판정 가능. 새 push는 `+1`을 `eyes`로 되돌림 |
| Codex가 review submit과 +1 reaction을 거의 동시에 처리할 때, reaction만 먼저 보고 review-comments 미답변을 놓침 | Step 3-1에서 `ALL_*_REVIEW_IDS`를 매 라운드 재조회 + Step 3-3에서 CODEX_STATE=approved 직후 final sweep으로 reviews/review-comments 한 번 더 fetch |
| `ALL_*_REVIEW_IDS`를 Step 1의 cycle-start snapshot만 신뢰 | 매 라운드 Step 3-1 진입 시 재조회 — 사이클 도중 submit된 review를 누락하지 않도록 |
| Step 2 polling에서 PR 작성자의 리뷰 reply도 "새 리뷰"로 카운트 | `gh api .../reviews`에 bot 로그인 **정확 매칭** 필수 (`select(.user.login == $codex or .user.login == $gemini)`). substring `test("codex\|gemini")`는 identity spoofing 위험 있음 — Step 3-3의 가드와 일관되게 exact match 사용 |
| 봇이 quota 코멘트도 안 남기고 silent하게 멈춘 상태에서 무한 대기/즉시 fallback | polling 1회(≈10분) 무반응 시 stale=1 단계에서 `@codex review`(Codex) / `/gemini review`(Gemini) 코멘트로 **수동 재트리거 1회** 발송 후 다음 polling 대기. fallback/escalation은 그 후에도 무반응일 때만 |
| 라벨 갱신 안 하고 다음 cycle 대기 | Step 4-8에서 매 round 끝 라벨 부착 — Plan 08 termination gate가 라벨 기반이므로 미부착 시 polling timeout |
| Step 4-8에서 무조건 approved만 부착 (검증 없이) | LLM이 case A/B/C 명시 분기 — Case A는 모든 댓글 fix 완료 + decline 0 + commit hash 링크 답변 완료 시에만. 그 외 changes-requested(Case B) 또는 in-progress(Case C) |

## Related Skills

- `Code-Review-Reception` — 피드백 수신 및 처리 프로세스
- `Finishing a Development Branch` — PR 생성 및 마무리
