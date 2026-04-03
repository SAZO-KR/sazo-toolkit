---
name: Automated-Code-Review-Cycle
description: PR에 대해 Codex/Gemini 코드 리뷰를 자동으로 받고, 피드백 수정 → 재리뷰 사이클을 사용자 개입 없이 반복. 두 리뷰어 모두 통과하면 완료.
version: 1.0.0
when_to_use: PR 생성 후 코드 리뷰 사이클을 자동화하고 싶을 때. /auto-review 명령으로 호출.
---

<required>
*CRITICAL* Add the following steps to your Todo list using TodoWrite:

1. Detect target PR (worktree branch → PR, or ask user)
2. Wait for initial Codex/Gemini reviews (PR 생성 시 자동 trigger)
3. Fetch review comments and evaluate pass/fail
4. If feedback exists: fix → test → push → trigger re-review
5. Repeat step 3-4 until both reviewers pass or quota exhausted
6. Report final status to user
</required>

# Automated Code Review Cycle

## Overview

PR에 대해 Codex와 Gemini의 코드 리뷰를 자동으로 받고, 타당한 피드백은 수정하여 재리뷰를 요청하는 사이클을 사용자 개입 없이 반복합니다.

**Core principle:** Detect PR → Poll reviews → Fix valid feedback → Re-test → Push → Trigger re-review → Repeat until pass.

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

## Step 1: Review Strategy

**Codex 우선, Gemini fallback:**

| 리뷰어 | Trigger 방법 | 재리뷰 Trigger | Quota 초기화 |
|---------|-------------|---------------|-------------|
| Codex | PR 생성/커밋 시 자동 | 새 커밋 push 시 자동 | ~5시간 |
| Gemini | PR 생성 시 자동 | `/gemini review` 코멘트 | ~24시간 |

**전략:**
1. 새 커밋 push → Codex 자동 재리뷰 대기
2. Codex quota 초과 시 → `/gemini review`로 fallback
3. Gemini도 quota 초과 시 → 사용자에게 알림, 사이클 중단

## Step 2: Poll for Reviews

커밋 push 후 리뷰가 도착할 때까지 polling:

```bash
# 최신 리뷰 확인 (push 이후에 생성된 것)
LATEST_PUSH_TIME=<push timestamp>

# 30초 간격으로 최대 10분 polling
for i in $(seq 1 20); do
  sleep 30

  # Codex/Gemini 리뷰 확인
  REVIEWS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews \
    --jq "[.[] | select(.submitted_at > \"$LATEST_PUSH_TIME\")] | length")

  if [ "$REVIEWS" -gt "0" ]; then
    break
  fi
done
```

**Quota 감지:**

PR 코멘트에서 다음 문자열 확인:
- Codex quota: `You have reached your Codex usage limits` 또는 `You have reached your daily quota limit`
- Gemini quota: `You have reached your daily quota limit. Please wait up to 24 hours`

```bash
# 최근 코멘트에서 quota 메시지 확인
QUOTA_HIT=$(gh pr view $PR_NUM --comments --json comments \
  --jq '.comments[-3:] | .[] | select(.body | test("reached your.*quota|reached your.*usage limits")) | .author.login')
```

quota 감지 시:
- Codex quota → Gemini로 fallback (`gh pr comment $PR_NUM --body "/gemini review"`)
- Gemini quota → 사용자에게 알림, 사이클 중단

## Step 3: Evaluate Review Results

**통과 조건:**

| 리뷰어 | 통과 기준 |
|---------|----------|
| Codex | PR description에 👍 이모지 추가 |
| Gemini | 리뷰 코멘트에 하위 디스커션(인라인 코멘트)이 없고 의견만 있음 |

**Codex 통과 확인:**

```bash
# PR description에서 👍 확인
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

**피드백이 있으면:**

```bash
# Gemini 인라인 코멘트 가져오기
gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$LATEST_GEMINI_REVIEW/comments \
  --jq '.[] | {id: .id, body: .body[0:500], path: .path}'

# Codex 리뷰 코멘트 가져오기 (최신 리뷰)
gh api repos/$OWNER/$REPO/pulls/$PR_NUM/comments \
  --jq '[.[] | select(.user.login == "codex-gh[bot]" and .in_reply_to_id == null)] | sort_by(.created_at) | .[-10:] | .[] | {id: .id, body: .body[0:500], path: .path}'
```

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
# Push → Codex 자동 재리뷰
git push

# Codex quota 초과 상태면 Gemini fallback
if [ "$CODEX_QUOTA_HIT" = true ]; then
  gh pr comment $PR_NUM --body "/gemini review"
fi
```

## Step 6: Repeat Until Pass

**사이클 반복:**

```
while (not both_passed):
  poll_for_reviews()
  if quota_hit:
    if codex_quota → try gemini
    if both_quota → notify user, break
  evaluate_results()
  if has_feedback:
    fix_feedback()
    push_and_trigger_rereview()
  else:
    both_passed = true
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
| 모든 피드백을 무조건 수정 | 기술적 타당성 검증 후 판단 |
| 이전 라운드 수정을 뒤집는 피드백 수용 | 이전 결정 참조하여 decline |
| quota 초과 시 무한 대기 | 사용자에게 알림 후 중단 |
| 테스트 없이 push | 반드시 test/lint/build 통과 후 push |
| 한 라운드에 모든 피드백 한꺼번에 | blocking → simple → complex 순서 |

## Related Skills

- `Code-Review-Reception` — 피드백 수신 및 처리 프로세스
- `Finishing a Development Branch` — PR 생성 및 마무리
