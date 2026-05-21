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

## Phase 1 Trust Boundaries

Phase 1은 **dogfood 모델** — Codex/Gemini 봇 리뷰 결과를 LLM(Claude)이 해석하고, 승인 라벨을 직접 부착한다.

| 신뢰 경계 | Phase 1 동작 | 위험 |
|---|---|---|
| 라벨 부착 주체 | LLM (SKILL.md Step 4-8) | LLM이 잘못 평가 시 라벨 오염 가능 |
| 라벨 신뢰도 | LLM 판단과 동급 (human trust ≠ bot trust) | 라벨만으로 머지 게이트 통과 위험 |
| 봇 identity | `bot_login` 정확 매칭 (substring 금지) | spoofing 방어 |

**Phase 1 → Phase 2 마이그레이션 계획**: Phase 2에서는 GitHub Actions가 봇 리뷰 이벤트를 감지해 라벨을 자동 부착한다. LLM의 라벨 부착 권한(`label_authority: "skill"`)이 Actions(`"label_authority": "actions"`)로 전환되며, LLM은 라벨 읽기/해석만 담당한다. 전환 시점은 `config.json`의 `label_authority` 필드로 추적한다.

### label_authority 필드 (Phase 2 준비)

`config.json`의 각 `active_reviewers` 항목에 `label_authority` 필드가 있다:

```json
{
  "active_reviewers": {
    "codex": {
      "label_authority": "skill"
    }
  }
}
```

| 값 | 의미 | 활성 단계 |
|---|---|---|
| `"skill"` | LLM(SKILL.md Step 4-8)이 라벨 부착 | Phase 1 (현재) |
| `"actions"` | GitHub Actions가 라벨 자동 부착 | Phase 2 (미래) |

Phase 1에서 `poll-labels.sh`는 이 필드를 읽지만 분기하지 않는다 (forward-compatible 읽기).

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

> 아래 1, 3번 포함 모든 `gh api` 호출에 `--paginate` 필수.

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
# 0. [R1] Bot login은 config.json에서 읽음 (각 스크립트 내부에서 처리).
# GEMINI_ENABLED 초기값은 false. Step 3 fetch-reviews.sh가 실제 Gemini 리뷰
# 존재 여부로 판정해 덮어쓴다 (원래 인라인 로직과 동일).
HARNESS="${SAZO_HARNESS_DIR:-$HOME/.config/sazo-ai-harness/packages/ai-harness}"
REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
GEMINI_ENABLED=false

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
# GitHub 서버 권위 push time 확보 + 30초 간격 최대 10분 polling.
# 상세 로직: scripts/poll-new-reviews.sh (PUSH_TIME hard-fail 포함).
HARNESS="${SAZO_HARNESS_DIR:-$HOME/.config/sazo-ai-harness/packages/ai-harness}"
REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
POLL_RESULT=$(bash "$HARNESS/skills/automated-code-review-cycle/scripts/poll-new-reviews.sh" \
  --pr "$PR_NUM" \
  --repo-dir "$REPO_DIR")

PUSH_TIME=$(echo "$POLL_RESULT" | jq -r '.push_time')
NEW_REVIEW_FOUND=$(echo "$POLL_RESULT" | jq -r '.new_review_found')
CODEX_REACTION=$(echo "$POLL_RESULT" | jq -r '.codex_reaction')
NEW_REVIEWS=$(echo "$POLL_RESULT" | jq -r '.new_review_count')
```

**Quota 감지 (CYCLE_START_TIME 이후만):**

```bash
# CYCLE_START_TIME 이후의 PR 코멘트만 확인.
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

모든 리뷰의 코멘트를 수집하고, `ALL_*_REVIEW_IDS`를 매 라운드 재조회한다.

```bash
# 모든 리뷰 ID/코멘트 수집 + 미답변 필터 로직은 scripts/fetch-reviews.sh로 추출.
HARNESS="${SAZO_HARNESS_DIR:-$HOME/.config/sazo-ai-harness/packages/ai-harness}"
REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
FETCH_RESULT=$(bash "$HARNESS/skills/automated-code-review-cycle/scripts/fetch-reviews.sh" \
  --pr "$PR_NUM" \
  --repo-dir "$REPO_DIR")

ALL_CODEX_REVIEW_IDS=$(echo "$FETCH_RESULT" | jq '.codex.review_ids')
ALL_GEMINI_REVIEW_IDS=$(echo "$FETCH_RESULT" | jq '.gemini.review_ids')
CODEX_ALL_COMMENTS=$(echo "$FETCH_RESULT" | jq '.codex.all_comments')
GEMINI_ALL_COMMENTS=$(echo "$FETCH_RESULT" | jq '.gemini.all_comments')
GEMINI_ENABLED=$(echo "$FETCH_RESULT" | jq -r '.gemini_enabled')
```

### 3-2. 미답변 코멘트만 필터

답변 여부는 전체 PR comments에서 `in_reply_to_id`로 확인:

```bash
REPLIED_IDS=$(echo "$FETCH_RESULT" | jq '.replied_ids')
UNANSWERED_CODEX=$(echo "$FETCH_RESULT" | jq '.codex.unanswered')
UNANSWERED_CODEX_COUNT=$(echo "$FETCH_RESULT" | jq -r '.codex.unanswered_count')
UNANSWERED_GEMINI=$(echo "$FETCH_RESULT" | jq '.gemini.unanswered')
UNANSWERED_GEMINI_COUNT=$(echo "$FETCH_RESULT" | jq -r '.gemini.unanswered_count')
```

### 3-3. 통과 조건

| 리뷰어 | 상태 | 판정 근거 |
| ------ | ---- | ---------- |
| Codex  | **approved** (통과) | PR(issue) reactions에 Codex bot의 최신 reaction이 `+1`(👍) |
| Codex  | **reviewing** (리뷰 중) | 최신 reaction이 `eyes`(👀) — polling 계속, stale 카운트 증가 안 함 |
| Codex  | **pending** (반응 없음) | PUSH_TIME 이후 Codex reaction 없음 — stale 대상 |
| Gemini | **passed** | 최신 리뷰에 하위 코멘트(review comments)가 0건 |

```bash
HARNESS="${SAZO_HARNESS_DIR:-$HOME/.config/sazo-ai-harness/packages/ai-harness}"
REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
STATE_RESULT=$(bash "$HARNESS/skills/automated-code-review-cycle/scripts/check-codex-state.sh" \
  --pr "$PR_NUM" \
  --push-time "$PUSH_TIME" \
  --gemini-enabled "$GEMINI_ENABLED" \
  --unanswered-gemini-count "$UNANSWERED_GEMINI_COUNT" \
  --repo-dir "$REPO_DIR")

CODEX_STATE=$(echo "$STATE_RESULT" | jq -r '.codex_state')
CODEX_PASSED=$(echo "$STATE_RESULT" | jq -r '.codex_passed')
GEMINI_PASSED=$(echo "$STATE_RESULT" | jq -r '.gemini_passed')
ALL_PASSED=$(echo "$STATE_RESULT" | jq -r '.all_passed')

SWEEP_RACE_DETECTED=$(echo "$STATE_RESULT" | jq -r '.sweep_race_detected')
if [ "$SWEEP_RACE_DETECTED" = "true" ]; then
  CODEX_ALL_COMMENTS=$(echo "$STATE_RESULT" | jq '.override_codex_all_comments')
  UNANSWERED_CODEX=$(echo "$STATE_RESULT" | jq '.override_unanswered_codex')
  UNANSWERED_CODEX_COUNT=$(echo "$STATE_RESULT" | jq -r '.override_unanswered_codex_count')
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
  - 예: `<bot-login>[bot]` → `@<bot-login>`
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

# push 직후 CODEX_STATE를 "pending"으로 강제 reset.
# 이전 라운드의 approved/reviewing이 남아있으면 stale 감지가 영구 실패.
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
# Codex quota 초과 → Gemini fallback (활성 시에만).
# GEMINI_FALLBACK_REQUESTED=true 함께 set (cached pass 상태에서도 stale 추적 활성).
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
CODEX_STALE_COUNT=0    # Codex 무반응 연속 라운드 수
GEMINI_STALE_COUNT=0   # Gemini 무반응 연속 라운드 수
MAX_STALE=2            # stale=1(수동 트리거) → stale=2(fallback). 봇별 카운터 분리 필수.
PREV_CODEX_LATEST_REVIEW=""    # 이전 라운드의 Codex 최신 review ID
PREV_GEMINI_LATEST_REVIEW=""   # 이전 라운드의 Gemini 최신 review ID (활성 시)
CODEX_STATE="pending"   # Step 3-3에서 갱신. loop 진입 전 초기화 필수.
CODEX_FALLBACK_DONE=false  # Gemini fallback 발사 여부. spurious 재발사 방지. Codex 응답 시 reset.
GEMINI_FALLBACK_REQUESTED=false  # fallback 후 Gemini 응답 대기 상태. cached pass와 무관하게 stale 추적.
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
  # reviewing(eyes) = not stale. pending 또는 review ID 미변동 = stale.
  # CODEX_STATE는 이전 라운드 값 참조 (Step 3-3에서 갱신). push 후 reset 필수.
  current_codex_latest = get_latest_codex_review_id()    # 없으면 ""
  current_gemini_latest = get_latest_gemini_review_id()  # 미활성/없으면 ""
  codex_progressed = (CODEX_STATE in {"reviewing", "approved"})
  # CODEX_FALLBACK_DONE=true면 Codex stale 재인식 차단 (spurious 재발사 방지).
  # review가 한번도 없는 케이스(current_codex_latest == "")도 stale로 인정.
  codex_id_static = (current_codex_latest != "" 
                     and current_codex_latest == PREV_CODEX_LATEST_REVIEW)
  codex_no_review = (current_codex_latest == "")
  codex_stale = (not CODEX_FALLBACK_DONE
                 and not codex_progressed
                 and (codex_id_static or codex_no_review))
  # Gemini: "미통과 + review ID 미변동"으로 stale 추정.
  # GEMINI_FALLBACK_REQUESTED=true면 cached pass와 무관하게 stale 판정 활성.
  gemini_stale = (GEMINI_ENABLED
                  and current_gemini_latest != ""
                  and current_gemini_latest == PREV_GEMINI_LATEST_REVIEW
                  and (not GEMINI_PASSED or GEMINI_FALLBACK_REQUESTED))

  # ── 봇별 카운터 갱신 (progress한 봇만 0으로 reset) ──
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
  # 실제 stale인 봇만 재호출. ==1 비교로 streak당 1회만 발송 보장.
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
    # continue 전에 PREV_*_LATEST_REVIEW 갱신 필수 (미갱신 시 즉시 re-stale).
    PREV_CODEX_LATEST_REVIEW = current_codex_latest
    PREV_GEMINI_LATEST_REVIEW = current_gemini_latest
    continue   # 수동 트리거 후 다음 polling 라운드 대기

  # ── stale ≥ MAX_STALE fallback (per-bot) ──
  # 봇별 카운터 기반 분기. `not GEMINI_PASSED` 가드 의도적 제외
  # (cached pass는 현 push 기준이 아니므로 fallback을 gate하면 안 됨).
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

  # ── 매 라운드 PREV_* 갱신 (frozen ID 방지) ──
  PREV_CODEX_LATEST_REVIEW = current_codex_latest
  PREV_GEMINI_LATEST_REVIEW = current_gemini_latest

  if CODEX_STATE == "reviewing":
    log("Codex 리뷰 진행 중 (👀) — polling 계속")

  fetch_review_feedback()       # Step 3 — review → review comments 구조로 조회
  filter_unanswered()           # in_reply_to_id로 미답변만

  # Plan 08: label-based termination. Exit 3 (changes-requested) falls through
  # to fix_commit_push_reply — same logic as legacy LLM-based pass-condition fail.
  # Infinite oscillation prevented by MAX_ROUNDS=10 bound (no per-round flag needed).

  # CRITICAL: resolve HARNESS/REPO_DIR and run label setup BEFORE the
  # no_unanswered_feedback branch. setup-labels.sh was previously nested inside
  # `if no_unanswered_feedback`, so ROUND==1 with findings (the common first cycle)
  # skipped label creation entirely — Step 4-8's `gh issue edit --add-label` then
  # fails because the repository labels don't exist yet.
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
          echo "WARN: setup-labels.sh failed (see $SETUP_LOG). Label writes may fail silently." >&2
      }
  }

  if no_unanswered_feedback:
    # Plan 08: label-based deterministic termination (Phase 1 = Option C)

    # CRITICAL: write verdict label BEFORE calling poll-labels.sh, but ONLY when
    # the verdict is confirmed by the bot's own state — not unconditionally.
    # Writing approved without checking CODEX_PASSED / GEMINI_PASSED lets the
    # poller exit 0 on a self-written label even when the bot issued a top-level
    # changes-requested (or has not yet signalled pass via +1 reaction).
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
    _NUF_GEMINI_LOGIN=$(echo "$_NUF_MERGED" | jq -r '.active_reviewers.gemini.bot_login // empty')
    _NUF_APPROVED_SUFFIX=$(echo "$_NUF_MERGED" | jq -r '.labels.approved.suffix // "approved"')
    _NUF_INPROGRESS_SUFFIX=$(echo "$_NUF_MERGED" | jq -r '.labels.in_progress.suffix // "in-progress"')
    _NUF_CHANGES_SUFFIX=$(echo "$_NUF_MERGED" | jq -r '.labels.changes_requested.suffix // "changes-requested"')
    # Gate: write Codex approved only if CODEX_PASSED=true (i.e. CODEX_STATE=="approved").
    # If Codex has not signalled +1 yet (e.g. top-level changes-requested with all inline
    # comments answered), write in-progress instead — poll-labels.sh will then wait for
    # the bot-review/codex/approved label to appear organically.
    if [ "$CODEX_PASSED" = true ]; then
      gh issue edit "$PR_NUM" \
          --add-label "$_NUF_CODEX_PREFIX/$_NUF_APPROVED_SUFFIX" \
          --remove-label "$_NUF_CODEX_PREFIX/$_NUF_INPROGRESS_SUFFIX,$_NUF_CODEX_PREFIX/$_NUF_CHANGES_SUFFIX" 2>/dev/null || true
    else
      gh issue edit "$PR_NUM" \
          --add-label "$_NUF_CODEX_PREFIX/$_NUF_INPROGRESS_SUFFIX" \
          --remove-label "$_NUF_CODEX_PREFIX/$_NUF_APPROVED_SUFFIX,$_NUF_CODEX_PREFIX/$_NUF_CHANGES_SUFFIX" 2>/dev/null || true
    fi
    # CRITICAL: only write Gemini approved label if Gemini has reviewed the CURRENT
    # push AND GEMINI_PASSED=true. GEMINI_ENABLED=true means Gemini has reviewed at
    # some point historically, but its last review may predate the current push.
    # Writing the approved label for a stale Gemini pass lets poll-labels.sh exit 0
    # without Gemini ever evaluating the latest changes.
    # Guard: check whether any Gemini review was submitted after PUSH_TIME.
    _GEMINI_FRESH=false
    if [ "$GEMINI_ENABLED" = true ] && [ -n "$_NUF_GEMINI_LOGIN" ]; then
      _GEMINI_LATEST_AT=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUM/reviews --paginate \
        --jq ".[] | select(.user.login == \"$_NUF_GEMINI_LOGIN\") | .submitted_at" \
        2>/dev/null | sort | tail -1)
      if [[ -n "$_GEMINI_LATEST_AT" ]] && [[ "$_GEMINI_LATEST_AT" > "$PUSH_TIME" ]]; then
        _GEMINI_FRESH=true
      fi
    fi
    if [ "$GEMINI_ENABLED" = true ] && [ "$_GEMINI_FRESH" = true ] && [ "$GEMINI_PASSED" = true ]; then
      _NUF_GEMINI_PREFIX=$(echo "$_NUF_MERGED" | jq -r '.active_reviewers.gemini.label_prefix // "bot-review/gemini/"' | sed 's|/$||')
      gh issue edit "$PR_NUM" \
          --add-label "$_NUF_GEMINI_PREFIX/$_NUF_APPROVED_SUFFIX" \
          --remove-label "$_NUF_GEMINI_PREFIX/$_NUF_INPROGRESS_SUFFIX,$_NUF_GEMINI_PREFIX/$_NUF_CHANGES_SUFFIX" 2>/dev/null || true
    elif [ "$GEMINI_ENABLED" = true ] && [ "$_GEMINI_FRESH" = false ]; then
      # Gemini is active but hasn't reviewed this push yet. Trigger a fresh review
      # and mark in-progress. poll-labels.sh will wait for the actual verdict label.
      # Do NOT skip Gemini from the gate — that bypasses the "all active reviewers
      # passed" requirement for a PR Gemini has previously engaged with.
      gh pr comment "$PR_NUM" --body "/gemini review" 2>/dev/null || true
      _NUF_GEMINI_PREFIX=$(echo "$_NUF_MERGED" | jq -r '.active_reviewers.gemini.label_prefix // "bot-review/gemini/"' | sed 's|/$||')
      gh issue edit "$PR_NUM" \
          --add-label "$_NUF_GEMINI_PREFIX/$_NUF_INPROGRESS_SUFFIX" \
          --remove-label "$_NUF_GEMINI_PREFIX/$_NUF_APPROVED_SUFFIX,$_NUF_GEMINI_PREFIX/$_NUF_CHANGES_SUFFIX" 2>/dev/null || true
    fi

    # CRITICAL: pass --skip-reviewer gemini only when GEMINI_ENABLED=false.
    # When Gemini is enabled but stale (_GEMINI_FRESH=false), we trigger /gemini review
    # above and let poll-labels.sh wait for the fresh verdict — skipping Gemini from
    # the gate would bypass the "all active reviewers passed" requirement.
    _SKIP_ARGS=()
    [ "$GEMINI_ENABLED" = false ] && _SKIP_ARGS+=(--skip-reviewer gemini)
    # WALL_CLOCK_BUDGET vs poll-labels timeout interaction:
    # - WALL_CLOCK_BUDGET (1800s, outer): guards the entire skill run; user-confirm on breach.
    # - poll-labels.sh inner loop: polling.max_iterations × polling.interval_seconds (default 60×30=1800s).
    # Both can time out independently. WALL_CLOCK_BUDGET may fire mid-poll if prior rounds used time.
    # Repo overrides (polling.max_iterations, polling.interval_seconds in .github/sazo-bot-review.json)
    # shrink the inner budget without affecting WALL_CLOCK_BUDGET — intended for fast-feedback repos.
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

  # label_prefix는 config.json + repo override에서 읽기 (하드코딩 시 gate timeout).
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
  # suffix도 config에서 읽기 (poll-labels.sh/setup-labels.sh와 일치 필수).
  _APPROVED_SUFFIX=$(echo "$_MERGED" | jq -r '.labels.approved.suffix // "approved"')
  _INPROGRESS_SUFFIX=$(echo "$_MERGED" | jq -r '.labels.in_progress.suffix // "in-progress"')
  _CHANGES_SUFFIX=$(echo "$_MERGED" | jq -r '.labels.changes_requested.suffix // "changes-requested"')

  # LLM determines status per-reviewer based on review evaluation:
  # - approved: 모든 unanswered 댓글 답변 완료 + decline 0건
  # - changes-requested: decline 있거나 새 fix 요청 진행 중
  # - in-progress: 트리거만 보낸 상태 (응답 대기)

  # ⚠️ WARNING: "approved" below is a PLACEHOLDER only. LLM MUST evaluate actual review
  # content and replace with the real verdict before executing the case statement.
  # Auto-filling "approved" without evaluation is an Anti-Pattern (see Anti-Patterns section).
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
      # ⚠️ WARNING: "approved" below is a PLACEHOLDER only. LLM MUST evaluate actual review
      # content and replace with the real verdict before executing the case statement.
      # Auto-filling "approved" without evaluation is an Anti-Pattern (see Anti-Patterns section).
      REVIEW_STATUS_GEMINI="approved"  # ← LLM 평가
      case "$REVIEW_STATUS_GEMINI" in
          approved) gh issue edit "$PR_NUM" --add-label "$GEMINI_PREFIX/$_APPROVED_SUFFIX" --remove-label "$GEMINI_PREFIX/$_INPROGRESS_SUFFIX,$GEMINI_PREFIX/$_CHANGES_SUFFIX" ;;
          changes-requested) gh issue edit "$PR_NUM" --add-label "$GEMINI_PREFIX/$_CHANGES_SUFFIX" --remove-label "$GEMINI_PREFIX/$_INPROGRESS_SUFFIX,$GEMINI_PREFIX/$_APPROVED_SUFFIX" ;;
          in-progress) gh issue edit "$PR_NUM" --add-label "$GEMINI_PREFIX/$_INPROGRESS_SUFFIX" --remove-label "$GEMINI_PREFIX/$_APPROVED_SUFFIX,$GEMINI_PREFIX/$_CHANGES_SUFFIX" ;;
      esac
  fi
  # REVIEW_STATUS는 LLM이 본문 해석 후 결정. 무조건 approved 부착 금지.

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

Rules R1-R6와 함께 아래 운영 체크리스트를 적용한다.

- PR comments만 보고 판단하지 말고 review → review comments 구조를 사용
- 이미 답변된 코멘트는 재처리 금지 (`in_reply_to_id` 기준)
- 테스트/린트/빌드 통과 전 push 금지
- 답변 멘션 규칙 준수: 동의=멘션 없음, decline=`@<reviewer_login>`
- Codex 상태는 reaction content(`+1`/`eyes`/`none`) 기준으로만 판정
- stale 감지는 봇별 카운터로 추적하고 `>= MAX_STALE`에서 fallback/알림
- Step 4-8 라벨은 review verdict와 일치하도록 갱신

## Related Skills

- `Code-Review-Reception`
- `Finishing a Development Branch`
