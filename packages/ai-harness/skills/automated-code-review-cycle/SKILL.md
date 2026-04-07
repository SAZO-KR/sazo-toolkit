---
name: Automated-Code-Review-Cycle
description: PR에 대해 Codex/Gemini 코드 리뷰를 자동으로 받고, 피드백 수정 → 재리뷰 사이클을 사용자 개입 없이 반복. 활성 리뷰어 전부 통과하면 완료. Gemini 미설정 repo는 Codex만으로 판단.
version: 1.3.2
when_to_use: PR 생성 후 코드 리뷰 사이클을 자동화하고 싶을 때
---

<required>
*CRITICAL* Add the following steps to your Todo list using TodoWrite:

1. Detect target PR (worktree branch → PR, or ask user)
2. Record CYCLE_START_TIME — 이 시각 이후의 quota 코멘트만 인식
3. Determine current state: 미처리 리뷰가 있는지 파악
4. Fetch review feedback and evaluate pass/fail
5. If feedback exists: fix → test → push → trigger re-review
6. Repeat step 4-5 until both reviewers pass or quota exhausted
7. Report final status to user
   </required>

# Automated Code Review Cycle

## Overview

PR에 대해 Codex(및 Gemini가 설정된 경우)의 코드 리뷰를 자동으로 받고, 타당한 피드백은 수정하여 재리뷰를 요청하는 사이클을 사용자 개입 없이 반복합니다. Gemini가 미설정된 repo에서는 Codex만으로 통과 판단합니다.

**Core principle:** Detect PR → Determine state → Fix feedback → Re-test → Push → Trigger re-review → Repeat until pass.

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
# 1. 최신 Codex/Gemini 리뷰 찾기 (봇 이름 동적 감지)
# CRITICAL: --paginate 필수! 기본 30건만 반환 → 리뷰 많은 PR에서 최신 리뷰 누락
# Codex: login에 "codex"가 포함된 bot (codex-gh[bot], chatgpt-codex-connector[bot] 등)
LATEST_CODEX_REVIEW=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews --paginate \
  --jq '[.[] | select(.user.login | test("codex"))] | sort_by(.submitted_at) | last | .id')

# Gemini: login에 "gemini"가 포함된 bot (gemini-code-assist[bot] 등)
LATEST_GEMINI_REVIEW=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews --paginate \
  --jq '[.[] | select(.user.login | test("gemini"))] | sort_by(.submitted_at) | last | .id')

# Gemini 활성 여부 판단 (한 번도 리뷰하지 않았으면 미설정으로 간주)
GEMINI_ENABLED=false
if [ -n "$LATEST_GEMINI_REVIEW" ] && [ "$LATEST_GEMINI_REVIEW" != "null" ]; then
  GEMINI_ENABLED=true
fi

# 2. 최신 리뷰의 하위 코멘트 확인
if [ -n "$LATEST_CODEX_REVIEW" ] && [ "$LATEST_CODEX_REVIEW" != "null" ]; then
  CODEX_COMMENTS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$LATEST_CODEX_REVIEW/comments \
    --jq 'length')
fi

if [ "$GEMINI_ENABLED" = true ]; then
  GEMINI_COMMENTS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$LATEST_GEMINI_REVIEW/comments \
    --jq 'length')
fi

# 3. 미답변 코멘트 수 확인 (전체 인라인 코멘트에서 답변 여부 체크)
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
PUSH_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
NEW_REVIEW_FOUND=false

# 30초 간격으로 최대 10분 polling
for i in $(seq 1 20); do
  sleep 30

  # PUSH_TIME 이후에 제출된 리뷰 확인 (--paginate 필수)
  NEW_REVIEWS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews --paginate \
    --jq "[.[] | select(.submitted_at > \"$PUSH_TIME\")] | length")

  if [ "$NEW_REVIEWS" -gt "0" ]; then
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

### 3-1. 최신 리뷰의 피드백 조회

```bash
# Codex 최신 리뷰의 하위 코멘트
CODEX_FEEDBACK=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$LATEST_CODEX_REVIEW/comments \
  --jq '.[] | {id: .id, body: .body[0:500], path: .path, line: .line}')

# Gemini 최신 리뷰의 하위 코멘트 (Gemini 활성 시에만)
if [ "$GEMINI_ENABLED" = true ]; then
  GEMINI_FEEDBACK=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$LATEST_GEMINI_REVIEW/comments \
    --jq '.[] | {id: .id, body: .body[0:500], path: .path, line: .line}')
fi
```

### 3-2. 미답변 코멘트만 필터

답변 여부는 전체 PR comments에서 `in_reply_to_id`로 확인:

```bash
# CRITICAL: --paginate 필수! 기본 30건만 반환 → 코멘트 많은 PR에서 최신 답변 누락
# 전체 인라인 코멘트에서 답변된 comment ID 수집
REPLIED_IDS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/comments --paginate \
  --jq '[.[] | select(.in_reply_to_id != null) | .in_reply_to_id]')

# 미답변 피드백만 필터: review comments의 id가 REPLIED_IDS에 없으면 미답변
# jq --argjson로 REPLIED_IDS 배열을 전달하여 비교
UNANSWERED_CODEX=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$LATEST_CODEX_REVIEW/comments \
  | jq --argjson replied "$REPLIED_IDS" \
  '[.[] | select(.id as $cid | ($replied | index($cid)) | not)]')

UNANSWERED_CODEX_COUNT=$(echo "$UNANSWERED_CODEX" | jq 'length')

if [ "$GEMINI_ENABLED" = true ]; then
  UNANSWERED_GEMINI=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$LATEST_GEMINI_REVIEW/comments \
    | jq --argjson replied "$REPLIED_IDS" \
    '[.[] | select(.id as $cid | ($replied | index($cid)) | not)]')
  UNANSWERED_GEMINI_COUNT=$(echo "$UNANSWERED_GEMINI" | jq 'length')
else
  UNANSWERED_GEMINI_COUNT=0
fi
```

### 3-3. 통과 조건

| 리뷰어 | 통과 기준                                      |
| ------ | ---------------------------------------------- |
| Codex  | PR description에 👍 이모지가 있음              |
| Gemini | 최신 리뷰에 하위 코멘트(review comments)가 0건 |

```bash
# Codex 통과 확인
PR_BODY=$(gh pr view $PR_NUM --json body -q .body)
CODEX_PASSED=false
if echo "$PR_BODY" | grep -q "👍"; then
  CODEX_PASSED=true
fi

# Gemini 통과 확인 (활성 시에만 평가, 미설정 시 자동 통과)
if [ "$GEMINI_ENABLED" = true ]; then
  GEMINI_PASSED=false
  if [ "${GEMINI_COMMENTS:-0}" -eq "0" ]; then
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

**미답변 피드백이 있으면 → Step 4로.**
**미답변 피드백 0건이면 → 통과 확인 후 Step 7로.**

## Step 4: Fix Feedback

Code-Review-Reception 스킬의 프로세스를 따르되, 자동화:

1. **분석**: 각 피드백을 P1/P2/P3으로 분류
2. **판단**: 기술적으로 타당한지 검증 (코드베이스 확인)
   - 타당 → 수정
   - 부당 → decline 답변 (기술적 이유와 함께)
   - 이전 라운드와 모순 → decline 답변 (이전 결정 참조)
3. **수정**: blocking → simple → complex 순서로 구현
4. **테스트**: 프로젝트 테스트/린트/빌드 명령 실행
5. **커밋**: 수정 내용을 요약한 커밋 메시지
6. **답변**: 각 코멘트에 gh api로 답변 게시

```bash
# 답변 (review comment에 reply)
gh api repos/$OWNER/$REPO/pulls/$PR_NUM/comments/$COMMENT_ID/replies \
  -f body="✅ **수정 완료**: <설명>"

# decline
gh api repos/$OWNER/$REPO/pulls/$PR_NUM/comments/$COMMENT_ID/replies \
  -f body="📝 <기술적 이유>"
```

## Step 5: Trigger Re-review

```bash
# Push → Codex 자동 재리뷰
git push

# Codex quota 초과 상태면 Gemini fallback (Gemini 활성 시에만)
if [ "$CODEX_QUOTA_HIT" = true ] && [ "$GEMINI_ENABLED" = true ]; then
  gh pr comment $PR_NUM --body "/gemini review"
elif [ "$CODEX_QUOTA_HIT" = true ] && [ "$GEMINI_ENABLED" = false ]; then
  echo "Codex quota 초과, Gemini 미설정 — 사용자에게 알림"
fi
```

## Step 6: Repeat Until Pass

```
ROUND=0
MAX_ROUNDS=30
STALE_COUNT=0          # 새 리뷰 없이 같은 review를 재평가한 연속 횟수
MAX_STALE=2            # 이 횟수 초과 시 리뷰어 무응답으로 판단
PREV_LATEST_REVIEW=""  # 이전 라운드의 최신 review ID

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

  # ── Stale review 감지 ──
  # polling 타임아웃 시 (NEW_REVIEW_FOUND=false), 최신 review ID가 동일하면 stale
  current_latest_review = get_latest_codex_review_id()
  if not NEW_REVIEW_FOUND and current_latest_review == PREV_LATEST_REVIEW:
    STALE_COUNT++
    log("리뷰어 무응답 (stale #{STALE_COUNT}/{MAX_STALE})")
    if STALE_COUNT > MAX_STALE:
      if GEMINI_ENABLED:
        log("Codex 무응답 → Gemini fallback")
        gh pr comment $PR_NUM --body "/gemini review"
        STALE_COUNT = 0   # Gemini trigger 후 카운트 리셋
        continue           # Gemini 리뷰 대기를 위해 다음 라운드로
      else:
        notify_user("Codex가 ${MAX_STALE}회 연속 무응답. 수동 확인 필요.")
        break
  else:
    STALE_COUNT = 0        # 새 리뷰가 왔으면 카운트 리셋
  PREV_LATEST_REVIEW = current_latest_review

  fetch_review_feedback()       # Step 3 — review → review comments 구조로 조회
  filter_unanswered()           # in_reply_to_id로 미답변만

  if no_unanswered_feedback:
    check_pass_conditions()     # 👍 / 인라인 0건 (Gemini 미설정 시 Codex만)
    if all_passed: break        # ALL_PASSED = Codex통과 && (Gemini통과 or 미설정)
    # 통과 조건 미충족 + 새 리뷰 없음 → stale로 처리됨 (위 로직)

  fix_feedback()                # Step 4
  push_and_trigger_rereview()   # Step 5
```

**안전 가드:**

- 최대 라운드 수: 30 (초과 시 사용자에게 알림)
- 같은 피드백 3회 반복 시: decline하고 다음으로
- **Stale review**: 2회 연속 같은 리뷰 → Gemini fallback 또는 사용자 알림
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
| Codex bot 이름 하드코딩 (`codex-gh[bot]`)                    | `test("codex")`로 동적 감지 (이름 변경 대응)                                |
| Gemini 미설정 repo에서 Gemini 대기                           | `GEMINI_ENABLED` 플래그로 Gemini 관련 로직 분기                             |
| polling 타임아웃 후 같은 리뷰 무한 재평가                    | `STALE_COUNT`로 무응답 감지, 2회 초과 시 fallback/알림                      |

## Related Skills

- `Code-Review-Reception` — 피드백 수신 및 처리 프로세스
- `Finishing a Development Branch` — PR 생성 및 마무리
