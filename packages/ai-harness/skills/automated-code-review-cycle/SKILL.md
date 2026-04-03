---
name: Automated-Code-Review-Cycle
description: PR에 대해 Codex/Gemini 코드 리뷰를 자동으로 받고, 피드백 수정 → 재리뷰 사이클을 사용자 개입 없이 반복. 두 리뷰어 모두 통과하면 완료.
version: 1.1.0
when_to_use: PR 생성 후 코드 리뷰 사이클을 자동화하고 싶을 때. /auto-review 명령으로 호출.
---

<required>
*CRITICAL* Add the following steps to your Todo list using TodoWrite:

1. Detect target PR (worktree branch → PR, or ask user)
2. Record CYCLE_START_TIME (현재 시각) — 이 시각 이후의 코멘트만 처리
3. Determine current state: 미처리 리뷰가 있는지, 새 리뷰를 trigger해야 하는지
4. Fetch review comments and evaluate pass/fail
5. If feedback exists: fix → test → push → trigger re-review
6. Repeat step 4-5 until both reviewers pass or quota exhausted
7. Report final status to user
</required>

# Automated Code Review Cycle

## Overview

PR에 대해 Codex와 Gemini의 코드 리뷰를 자동으로 받고, 타당한 피드백은 수정하여 재리뷰를 요청하는 사이클을 사용자 개입 없이 반복합니다.

**Core principle:** Detect PR → Determine state → Fix feedback → Re-test → Push → Trigger re-review → Repeat until pass.

**Announce at start:** "자동 코드 리뷰 사이클을 시작합니다."

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

이 시각은 다음 용도로 사용:
- Quota 코멘트 필터링: CYCLE_START_TIME 이후의 코멘트만 quota로 판단
- 리뷰 필터링: 이미 처리된(답변된) 리뷰와 새 리뷰를 구분

**현재 상태 파악:**

사이클 중간에 시작될 수 있으므로, 먼저 PR의 현재 상태를 파악:

```bash
# 마지막 push 시각
LAST_PUSH_TIME=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM --jq '.updated_at')

# 마지막 push 이후 리뷰가 있는지
PENDING_REVIEWS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews \
  --jq "[.[] | select(.submitted_at > \"$LAST_PUSH_TIME\")] | length")

# 미답변 인라인 코멘트가 있는지 (답변이 없는 top-level 코멘트)
UNANSWERED_COMMENTS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/comments \
  --jq '[.[] | select(.in_reply_to_id == null)] | map(
    select(
      .user.login == "gemini-code-assist[bot]" or .user.login == "codex-gh[bot]"
    )
  ) | map(
    select(
      .id as $id | 
      [.[] | select(.in_reply_to_id == $id)] | length == 0
    )
  ) | length')
```

**상태별 진입점:**

| 상태 | 진입점 |
|------|--------|
| 미답변 리뷰 코멘트 있음 | → Step 3 (리뷰 평가부터) |
| 리뷰 없음, 마지막 push 이후 리뷰 대기 중 | → Step 2 (polling) |
| 리뷰 없음, 새 리뷰 trigger 필요 | → push 또는 `/gemini review` 후 Step 2 |

## Step 2: Review Strategy & Polling

**Codex 우선, Gemini fallback:**

| 리뷰어 | Trigger 방법 | 재리뷰 Trigger | Quota 초기화 |
|---------|-------------|---------------|-------------|
| Codex | PR 생성/커밋 시 자동 | 새 커밋 push 시 자동 | ~5시간 |
| Gemini | PR 생성 시 자동 | `/gemini review` 코멘트 | ~24시간 |

**Polling:**

커밋 push 후 리뷰가 도착할 때까지 polling:

```bash
# 30초 간격으로 최대 10분 polling
PUSH_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

for i in $(seq 1 20); do
  sleep 30

  # PUSH_TIME 이후에 생성된 리뷰만 확인
  NEW_REVIEWS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews \
    --jq "[.[] | select(.submitted_at > \"$PUSH_TIME\")] | length")

  if [ "$NEW_REVIEWS" -gt "0" ]; then
    break
  fi

  # CYCLE_START_TIME 이후의 quota 코멘트만 확인
  QUOTA_COMMENT=$(gh pr view $PR_NUM --comments --json comments \
    --jq "[.comments[] | select(
      .createdAt > \"$CYCLE_START_TIME\" and 
      (.body | test(\"reached your.*quota|reached your.*usage limits\"))
    )] | length")

  if [ "$QUOTA_COMMENT" -gt "0" ]; then
    # quota 초과 — fallback 또는 중단
    break
  fi
done
```

**Quota 감지 (CYCLE_START_TIME 이후만):**

```bash
# CRITICAL: 과거 quota 코멘트는 무시. CYCLE_START_TIME 이후의 코멘트만 확인.
CODEX_QUOTA=$(gh pr view $PR_NUM --comments --json comments \
  --jq "[.comments[] | select(
    .createdAt > \"$CYCLE_START_TIME\" and
    .author.login == \"codex-gh[bot]\" and
    (.body | test(\"reached your.*quota|reached your.*usage limits\"))
  )] | length")

GEMINI_QUOTA=$(gh pr view $PR_NUM --comments --json comments \
  --jq "[.comments[] | select(
    .createdAt > \"$CYCLE_START_TIME\" and
    .author.login == \"gemini-code-assist[bot]\" and
    (.body | test(\"reached your daily quota limit\"))
  )] | length")
```

Quota 감지 시:
- Codex quota → Gemini로 fallback (`gh pr comment $PR_NUM --body "/gemini review"`)
- Gemini quota → 사용자에게 알림, 사이클 중단
- 양쪽 모두 → 사용자에게 알림, 사이클 중단

## Step 3: Evaluate Review Results

**미답변 코멘트만 처리 대상:**

리뷰 코멘트 중 이미 답변된 것은 skip. 답변 여부는 `in_reply_to_id`로 확인:

```bash
# 모든 리뷰 코멘트 (top-level만)
ALL_COMMENTS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/comments \
  --jq '[.[] | select(.in_reply_to_id == null)]')

# 답변이 달린 코멘트 ID 수집
REPLIED_IDS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/comments \
  --jq '[.[] | select(.in_reply_to_id != null) | .in_reply_to_id] | unique')

# 미답변 코멘트만 필터 (Codex 또는 Gemini가 작성, 답변 없음)
UNANSWERED=$(echo "$ALL_COMMENTS" | jq --argjson replied "$REPLIED_IDS" '
  [.[] | select(
    (.user.login == "gemini-code-assist[bot]" or .user.login == "codex-gh[bot]") and
    (.id | tostring | IN($replied[] | tostring) | not)
  )]
')
```

**통과 조건:**

| 리뷰어 | 통과 기준 |
|---------|----------|
| Codex | PR description에 👍 이모지가 있음 |
| Gemini | 최신 리뷰에 인라인 코멘트(하위 디스커션)가 0건 |

**Codex 통과 확인:**

```bash
PR_BODY=$(gh pr view $PR_NUM --json body -q .body)
if echo "$PR_BODY" | grep -q "👍"; then
  CODEX_PASSED=true
fi
```

**Gemini 통과 확인:**

```bash
# 최신 Gemini 리뷰의 inline comments 확인
LATEST_GEMINI_REVIEW=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews \
  --jq '[.[] | select(.user.login == "gemini-code-assist[bot]")] | sort_by(.submitted_at) | last | .id')

INLINE_COMMENTS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$LATEST_GEMINI_REVIEW/comments \
  --jq 'length')

if [ "$INLINE_COMMENTS" -eq "0" ]; then
  GEMINI_PASSED=true
fi
```

**미답변 피드백이 있으면 → Step 4로.**
**미답변 피드백 0건이면 → 통과. Step 7로.**

## Step 4: Fix Feedback

Code-Review-Reception 스킬의 프로세스를 따르되, 자동화:

1. **분석**: 각 피드백을 P1/P2/P3으로 분류
2. **판단**: 기술적으로 타당한지 검증 (코드베이스 확인)
   - 타당 → 수정
   - 부당 → decline 답변 (기술적 이유와 함께)
   - 이전 라운드와 모순 → decline 답변 (이전 결정 참조)
3. **수정**: blocking → simple → complex 순서로 구현
4. **테스트**: `yarn test` + `yarn lint` + `yarn build`
5. **커밋**: 수정 내용을 요약한 커밋 메시지
6. **답변**: 각 코멘트에 gh api로 답변 게시

```bash
# 답변 템플릿
gh api repos/$OWNER/$REPO/pulls/$PR_NUM/comments/$COMMENT_ID/replies \
  -f body="✅ **수정 완료**: <설명>"

# decline 템플릿
gh api repos/$OWNER/$REPO/pulls/$PR_NUM/comments/$COMMENT_ID/replies \
  -f body="📝 <기술적 이유>"
```

## Step 5: Trigger Re-review

```bash
# Push → Codex 자동 재리뷰 (quota 미초과 시)
git push

# Codex quota 초과 상태면 Gemini fallback
if [ "$CODEX_QUOTA_HIT" = true ]; then
  gh pr comment $PR_NUM --body "/gemini review"
fi
```

## Step 6: Repeat Until Pass

**사이클 반복:**

```
ROUND=0
while (not all_passed and ROUND < MAX_ROUNDS):
  ROUND++
  log("=== Round $ROUND ===")
  
  poll_for_reviews()          # Step 2
  
  check_quota()               # CYCLE_START_TIME 이후만
  if both_quota_hit:
    notify_user("양쪽 quota 초과. 대기 필요.")
    break
  
  evaluate_results()          # Step 3 — 미답변 코멘트만
  if no_unanswered_feedback:
    all_passed = true
    break
  
  fix_feedback()              # Step 4
  push_and_trigger_rereview() # Step 5
```

**안전 가드:**
- 최대 라운드 수: 30 (초과 시 사용자에게 알림)
- 같은 피드백 3회 반복 시: decline하고 다음으로
- 총 소요 시간 모니터링 (각 라운드 로그)

## Step 7: Final Report

```
자동 코드 리뷰 사이클 완료:

- PR: #NNN
- 총 라운드: N
- Codex: ✅ 통과 / ❌ quota 초과
- Gemini: ✅ 통과 / ❌ quota 초과
- 수정한 피드백: N건
- Decline한 피드백: N건
- 총 소요 시간: Nm

PR이 머지 가능한 상태입니다. / 사용자 확인이 필요합니다.
```

## Anti-Patterns

| 잘못된 방식 | 올바른 방식 |
|------------|------------|
| 과거 quota 코멘트를 현재 quota로 오인 | CYCLE_START_TIME 이후 코멘트만 확인 |
| 이미 답변된 코멘트를 다시 처리 | in_reply_to_id로 미답변만 필터 |
| 모든 피드백을 무조건 수정 | 기술적 타당성 검증 후 판단 |
| 이전 라운드 수정을 뒤집는 피드백 수용 | 이전 결정 참조하여 decline |
| quota 초과 시 무한 대기 | 사용자에게 알림 후 중단 |
| 테스트 없이 push | 반드시 test/lint/build 통과 후 push |
| 한 라운드에 모든 피드백 한꺼번에 | blocking → simple → complex 순서 |
| 사이클 중간 진입 시 처음부터 다시 시작 | 현재 상태를 파악하고 적절한 Step부터 진입 |

## Related Skills

- `Code-Review-Reception` — 피드백 수신 및 처리 프로세스
- `Finishing a Development Branch` — PR 생성 및 마무리
