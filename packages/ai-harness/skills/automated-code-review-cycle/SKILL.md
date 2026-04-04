---
name: Automated-Code-Review-Cycle
description: PR에 대해 Codex/Gemini 코드 리뷰를 자동으로 받고, 피드백 수정 → 재리뷰 사이클을 사용자 개입 없이 반복. 두 리뷰어 모두 통과하면 완료.
version: 1.2.0
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

PR에 대해 Codex와 Gemini의 코드 리뷰를 자동으로 받고, 타당한 피드백은 수정하여 재리뷰를 요청하는 사이클을 사용자 개입 없이 반복합니다.

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
1. `gh api repos/.../pulls/NNN/reviews` → 리뷰 목록 (Codex/Gemini별 최신 review ID)
2. `gh api repos/.../pulls/NNN/reviews/{ID}/comments` → 해당 리뷰의 실제 피드백
3. `gh api repos/.../pulls/NNN/comments` → 전체 인라인 코멘트 (답변 여부 확인용)

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
# 1. 최신 Codex/Gemini 리뷰 찾기
LATEST_CODEX_REVIEW=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews \
  --jq '[.[] | select(.user.login == "codex-gh[bot]")] | sort_by(.submitted_at) | last | .id')

LATEST_GEMINI_REVIEW=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews \
  --jq '[.[] | select(.user.login == "gemini-code-assist[bot]")] | sort_by(.submitted_at) | last | .id')

# 2. 최신 리뷰의 하위 코멘트 확인
if [ -n "$LATEST_CODEX_REVIEW" ]; then
  CODEX_COMMENTS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$LATEST_CODEX_REVIEW/comments \
    --jq 'length')
fi

if [ -n "$LATEST_GEMINI_REVIEW" ]; then
  GEMINI_COMMENTS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$LATEST_GEMINI_REVIEW/comments \
    --jq 'length')
fi

# 3. 미답변 코멘트 수 확인 (전체 인라인 코멘트에서 답변 여부 체크)
```

**상태별 진입점:**

| 상태 | 진입점 |
|------|--------|
| 미답변 리뷰 코멘트 있음 | → Step 3 (피드백 평가부터) |
| 리뷰 없음, push 후 대기 중 | → Step 2 (polling) |
| 리뷰 없음, trigger 필요 | → push 또는 `/gemini review` 후 Step 2 |

## Step 2: Review Strategy & Polling

**Codex 우선, Gemini fallback:**

| 리뷰어 | Trigger 방법 | 재리뷰 Trigger | Quota 초기화 |
|---------|-------------|---------------|-------------|
| Codex | PR 생성/커밋 시 자동 | 새 커밋 push 시 자동 | ~5시간 |
| Gemini | PR 생성 시 자동 | `/gemini review` 코멘트 | ~24시간 |

**Polling (push 후):**

```bash
PUSH_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# 30초 간격으로 최대 10분 polling
for i in $(seq 1 20); do
  sleep 30

  # PUSH_TIME 이후에 제출된 리뷰 확인
  NEW_REVIEWS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews \
    --jq "[.[] | select(.submitted_at > \"$PUSH_TIME\")] | length")

  if [ "$NEW_REVIEWS" -gt "0" ]; then
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

# Gemini quota는 별도 패턴
GEMINI_QUOTA=$(gh pr view $PR_NUM --comments --json comments \
  --jq "[.comments[] | select(
    .createdAt > \"$CYCLE_START_TIME\" and
    (.body | test(\"reached your daily quota limit\"))
  )] | length")
```

Quota 감지 시:
- Codex quota → Gemini로 fallback (`gh pr comment $PR_NUM --body "/gemini review"`)
- Gemini quota → 사용자에게 알림, 사이클 중단

## Step 3: Fetch & Evaluate Review Feedback

**CRITICAL: 리뷰는 review → review comments 구조로 조회해야 한다.**

### 3-1. 최신 리뷰의 피드백 조회

```bash
# Codex 최신 리뷰의 하위 코멘트
CODEX_FEEDBACK=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$LATEST_CODEX_REVIEW/comments \
  --jq '.[] | {id: .id, body: .body[0:500], path: .path, line: .line}')

# Gemini 최신 리뷰의 하위 코멘트
GEMINI_FEEDBACK=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$LATEST_GEMINI_REVIEW/comments \
  --jq '.[] | {id: .id, body: .body[0:500], path: .path, line: .line}')
```

### 3-2. 미답변 코멘트만 필터

답변 여부는 전체 PR comments에서 `in_reply_to_id`로 확인:

```bash
# 전체 인라인 코멘트에서 답변된 comment ID 수집
REPLIED_IDS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/comments \
  --jq '[.[] | select(.in_reply_to_id != null) | .in_reply_to_id] | unique')

# 미답변 피드백만 필터 (review comments 중 답변이 없는 것)
# 각 review comment의 id가 REPLIED_IDS에 없으면 미답변
```

### 3-3. 통과 조건

| 리뷰어 | 통과 기준 |
|---------|----------|
| Codex | PR description에 👍 이모지가 있음 |
| Gemini | 최신 리뷰에 하위 코멘트(review comments)가 0건 |

```bash
# Codex 통과 확인
PR_BODY=$(gh pr view $PR_NUM --json body -q .body)
CODEX_PASSED=false
if echo "$PR_BODY" | grep -q "👍"; then
  CODEX_PASSED=true
fi

# Gemini 통과 확인
GEMINI_PASSED=false
if [ "$GEMINI_COMMENTS" -eq "0" ] || [ -z "$GEMINI_COMMENTS" ]; then
  GEMINI_PASSED=true
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

# Codex quota 초과 상태면 Gemini fallback
if [ "$CODEX_QUOTA_HIT" = true ]; then
  gh pr comment $PR_NUM --body "/gemini review"
fi
```

## Step 6: Repeat Until Pass

```
ROUND=0
MAX_ROUNDS=30

while ROUND < MAX_ROUNDS:
  ROUND++
  log("=== Round $ROUND ===")
  
  poll_for_reviews()            # Step 2 — push 후 새 리뷰 대기
  
  check_quota()                 # CYCLE_START_TIME 이후만
  if both_quota_hit:
    notify_user("양쪽 quota 초과. 대기 필요.")
    break
  
  fetch_review_feedback()       # Step 3 — review → review comments 구조로 조회
  filter_unanswered()           # in_reply_to_id로 미답변만
  
  if no_unanswered_feedback:
    check_pass_conditions()     # 👍 / 인라인 0건
    if all_passed: break
    # 통과 조건 미충족이면 다음 라운드 대기
  
  fix_feedback()                # Step 4
  push_and_trigger_rereview()   # Step 5
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
- Codex: ✅ 통과 / ❌ quota 초과 / ⏳ 미완료
- Gemini: ✅ 통과 / ❌ quota 초과 / ⏳ 미완료
- 수정한 피드백: N건
- Decline한 피드백: N건
- 총 소요 시간: Nm

PR이 머지 가능한 상태입니다. / 사용자 확인이 필요합니다.
```

## Anti-Patterns

| 잘못된 방식 | 올바른 방식 |
|------------|------------|
| PR comments만 보고 리뷰 피드백 감지 | review → review comments 구조로 조회 |
| 과거 quota 코멘트를 현재 quota로 오인 | CYCLE_START_TIME 이후 코멘트만 확인 |
| 이미 답변된 코멘트를 다시 처리 | in_reply_to_id로 미답변만 필터 |
| 모든 피드백을 무조건 수정 | 기술적 타당성 검증 후 판단 |
| 이전 라운드 수정을 뒤집는 피드백 수용 | 이전 결정 참조하여 decline |
| quota 초과 시 무한 대기 | 사용자에게 알림 후 중단 |
| 테스트 없이 push | 반드시 test/lint/build 통과 후 push |
| 사이클 중간 진입 시 처음부터 다시 시작 | 현재 상태를 파악하고 적절한 Step부터 진입 |

## Related Skills

- `Code-Review-Reception` — 피드백 수신 및 처리 프로세스
- `Finishing a Development Branch` — PR 생성 및 마무리
