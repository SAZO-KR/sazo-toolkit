---
name: Automated-Code-Review-Cycle
description: PR에 대해 Codex/Gemini 코드 리뷰를 자동으로 받고, 피드백 수정 → 재리뷰 사이클을 사용자 개입 없이 반복. 활성 리뷰어 전부 통과하면 완료. Gemini 미설정 repo는 Codex만으로 판단.
version: 1.6.0
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
# 1. 모든 Codex/Gemini 리뷰 ID 수집 (봇 이름 동적 감지)
# CRITICAL: --paginate 필수! 기본 30건만 반환 → 리뷰 많은 PR에서 누락
# CRITICAL: 최신 리뷰만이 아니라 모든 리뷰를 수집해야 이전 리뷰의 미답변 코멘트를 놓치지 않음
ALL_CODEX_REVIEW_IDS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews --paginate \
  --jq '[.[] | select(.user.login | test("codex"))] | sort_by(.submitted_at) | [.[].id]')

ALL_GEMINI_REVIEW_IDS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews --paginate \
  --jq '[.[] | select(.user.login | test("gemini"))] | sort_by(.submitted_at) | [.[].id]')

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

### 3-1. 모든 리뷰의 피드백 조회

**CRITICAL: 최신 리뷰만이 아니라 모든 리뷰의 코멘트를 수집해야 한다.** Codex/Gemini가 여러 리뷰를 제출한 경우, 이전 리뷰의 미답변 코멘트가 누락되는 버그를 방지.

```bash
# 모든 Codex 리뷰의 코멘트를 하나의 배열로 수집
# CRITICAL: reviewer_login 필드 포함 — Step 4에서 decline 답변 시 @멘션에 사용
CODEX_ALL_COMMENTS='[]'
for REVIEW_ID in $(echo "$ALL_CODEX_REVIEW_IDS" | jq -r '.[]'); do
  COMMENTS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$REVIEW_ID/comments \
    --jq '[.[] | {id: .id, body: .body[0:500], path: .path, line: .line, reviewer_login: .user.login, review_id: '$REVIEW_ID'}]')
  CODEX_ALL_COMMENTS=$(echo "$CODEX_ALL_COMMENTS" | jq --argjson c "$COMMENTS" '. + $c')
done

# Gemini도 동일 (활성 시에만)
if [ "$GEMINI_ENABLED" = true ]; then
  GEMINI_ALL_COMMENTS='[]'
  for REVIEW_ID in $(echo "$ALL_GEMINI_REVIEW_IDS" | jq -r '.[]'); do
    COMMENTS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews/$REVIEW_ID/comments \
      --jq '[.[] | {id: .id, body: .body[0:500], path: .path, line: .line, reviewer_login: .user.login, review_id: '$REVIEW_ID'}]')
    GEMINI_ALL_COMMENTS=$(echo "$GEMINI_ALL_COMMENTS" | jq --argjson c "$COMMENTS" '. + $c')
  done
fi
```

### 3-2. 미답변 코멘트만 필터

답변 여부는 전체 PR comments에서 `in_reply_to_id`로 확인:

```bash
# CRITICAL: --paginate 필수! 기본 30건만 반환 → 코멘트 많은 PR에서 최신 답변 누락
REPLIED_IDS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/comments --paginate \
  --jq '[.[] | select(.in_reply_to_id != null) | .in_reply_to_id]')

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
if [ "$CODEX_QUOTA_HIT" = true ] && [ "$GEMINI_ENABLED" = true ]; then
  gh pr comment $PR_NUM --body "/gemini review"
elif [ "$CODEX_QUOTA_HIT" = true ] && [ "$GEMINI_ENABLED" = false ]; then
  echo "Codex quota 초과, Gemini 미설정 — 사용자에게 알림"
fi
```

## Step 6: Repeat Until Pass

```
ROUND=0
MAX_ROUNDS=10          # 각 라운드 = (리뷰 polling + fix + push + reply) ≈ 4-6회 LLM 호출.
                       # 10 라운드면 최대 ~60회 호출 — 비용 상한. 초과 시 사용자에게 에스컬레이트.
STALE_COUNT=0          # 새 리뷰 없이 같은 review를 재평가한 연속 횟수
MAX_STALE=2            # 이 횟수 초과 시 리뷰어 무응답으로 판단
PREV_LATEST_REVIEW=""  # 이전 라운드의 최신 review ID
WALL_CLOCK_START=$(date +%s)
WALL_CLOCK_BUDGET=1800 # 30분 — 초과 시 진행 중이라도 사용자 확인 요청

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

  fix_commit_push_reply()       # Step 4 — 수정 → 테스트 → 커밋 → push → 답변(commit hash)
  gemini_fallback_if_quota()    # Step 5 — Codex quota 초과 시에만

  # Wall-clock budget check
  if (now - WALL_CLOCK_START) > WALL_CLOCK_BUDGET:
    notify_user("30분 경과. 계속 진행 할까요? (진행 / 중단)")
    break  # 사용자 응답 대기
```

**안전 가드:**

- 최대 라운드 수: 10 (각 라운드 ~4-6 LLM 호출 → 총 ~60 호출 상한)
- Wall-clock budget: 30분 — 초과 시 사용자에게 진행 여부 확인
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
| 최신 리뷰만 확인하여 이전 리뷰 미답변 누락                   | `ALL_*_REVIEW_IDS`로 모든 리뷰의 코멘트를 스캔                              |
| 동의 답변에 리뷰어 멘션 포함                                 | 동의 시 멘션 생략 (재트리거 불필요, 토큰 낭비)                              |
| 반대(decline) 답변에 리뷰어 멘션 누락                        | `@<reviewer_login>` 멘션으로 재검토 트리거                                  |
| 답변을 commit/push 이전에 게시                               | `commit → push → 답변` 순서 엄수. 그러지 않으면 답변 시점 `commit_id`가 수정 이전을 가리켜 검증 불가 |
| 수정 답변에 commit hash 링크 누락                            | 답변 본문에 `[`short-hash`](commit URL)` 필수 — 리뷰어가 "수정 완료" 주장의 근거 커밋을 1-클릭 추적 |
| 답변 본문에 regex/glob 특수문자 포함 시 shell 해석 충돌       | URL을 따옴표로 감싸거나 HEREDOC + `--input -` 사용 (bash/zsh 공통). `noglob`은 zsh 전용이므로 범용 기본값으로 쓰지 말 것 |

## Related Skills

- `Code-Review-Reception` — 피드백 수신 및 처리 프로세스
- `Finishing a Development Branch` — PR 생성 및 마무리
