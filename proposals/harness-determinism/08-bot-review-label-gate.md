# 08. Bot Review GitHub API Label Gate

**우선순위**: P2
**의존**: 없음 (단, 라벨 정책 합의 필요)
**예상 비용**: 1주
**결정성 이동**: 🟡 → 🟢 (LLM이 PR 코멘트 텍스트 해석 → GitHub API 결정적 판정)

## 목표

`automated-code-review-cycle` skill의 종료 조건을 LLM이 PR 코멘트 읽고 판단 → GitHub API의 라벨/check 상태로 결정적 판정.

## 현재 상태 / 문제

`packages/ai-harness/skills/automated-code-review-cycle/SKILL.md` 의 종료 조건:
- "활성 리뷰어 전부 통과하면 완료"
- LLM이 Codex/Gemini 봇 댓글 텍스트 읽고 PASS 여부 판단
- 무한 루프 또는 조기 종료 위험

## 제안

### 1. 라벨 정책 정의

각 봇 리뷰어가 결과를 라벨로 표시:

| 라벨 | 의미 | 누가 붙임 |
|---|---|---|
| `bot-review/codex/approved` | Codex 통과 | Codex bot |
| `bot-review/codex/changes-requested` | Codex 수정 요청 | Codex bot |
| `bot-review/codex/in-progress` | Codex 검토 중 | (자동 또는 트리거) |
| `bot-review/gemini/approved` | Gemini 통과 | Gemini bot |
| `bot-review/gemini/changes-requested` | Gemini 수정 요청 | Gemini bot |
| `bot-review/gemini/in-progress` | Gemini 검토 중 | (자동 또는 트리거) |

### 2. 봇 라벨 부착 — 누가 어떻게?

**Option A**: 봇 자체가 라벨 자동 부착 (이상적, but 봇 개발 필요)
**Option B**: GitHub Actions workflow가 봇 댓글 detect → 라벨 자동 부착
**Option C**: skill이 라벨 직접 관리 — 봇 댓글 내용 해석은 여전히 LLM, but 결과를 라벨로 *기록*하여 다음 사이클에 결정적으로 참조

**제안**: Phase 1 = Option C (현실적), Phase 2 = Option B (자동화).

Option C 장점: skill이 LLM에 "댓글 읽고 판단해 라벨 붙여라" 요청 → 결과는 라벨이라는 결정적 기록 → 다음 cycle entry 시 라벨만 검사.

### 3. 종료 조건 (skill 변경)

```
종료 조건 (모두 만족):
- bot-review/codex/approved AND bot-review/gemini/approved
- 또는 사용자 명시 override (라벨 `bot-review/override`)

중간 조건:
- changes-requested 라벨 있음 → 수정 사이클
- in-progress 라벨만 있고 approved 없음 → 폴링 대기 (최대 timeout)
```

### 4. Polling 로직

`gh pr view <num> --json labels --jq '.labels[].name'` 정기 폴링.

```bash
while true; do
  labels=$(gh pr view "$PR" --json labels --jq '.labels[].name')
  if echo "$labels" | grep -q "bot-review/codex/approved" \
     && echo "$labels" | grep -q "bot-review/gemini/approved"; then
    break  # 통과
  fi
  if echo "$labels" | grep -q "bot-review/.*/changes-requested"; then
    # 수정 사이클 진입
    break  # skill flow에 위임
  fi
  sleep 30
  iter=$((iter+1))
  if [ "$iter" -ge "$MAX_ITER" ]; then
    echo "polling timeout" >&2
    exit 2
  fi
done
```

### 5. Repo별 활성 리뷰어 detect

현재 skill이 `gh repo view ... --json` 으로 봇 등록 여부 추정. 변경:

`packages/ai-harness/skills/automated-code-review-cycle/config.json` (신규):
```json
{
  "active_reviewers": {
    "codex": {"label_prefix": "bot-review/codex/", "comment_pattern": "Codex Review"},
    "gemini": {"label_prefix": "bot-review/gemini/", "comment_pattern": "@gemini-code-review"}
  }
}
```

Repo별 override: `.github/sazo-bot-review.json` 우선 (없으면 default skill config).

### 6. 라벨 자동 생성

`gh label create bot-review/codex/approved -c "00ff00" --force` 등.

`auto-update.sh` 또는 첫 cycle 진입 시 라벨 존재 검사 → 없으면 생성.

## Phase 1 Scope (Option C only)

**Phase 1 = Option C**: LLM이 봇 댓글 내용을 해석하여 라벨을 부착, skill이 라벨 폴링으로 결정적 판정.

- `setup-labels.sh`: 최초 cycle 진입 시 `ROUND==1`이면 라벨 자동 생성 (`--force` 멱등)
- `poll-labels.sh`: 라벨 상태 폴링, exit 0/2/3/4/5 반환
- SKILL.md Step 4-8에서 LLM이 봇 댓글 해석 후 `gh issue edit --add-label` 호출
- SKILL.md Step 6 termination block이 `poll-labels.sh` 반환 코드로 분기

## Deferred (Option A·B)

- **Option A** (봇 self-label): Codex/Gemini 봇이 직접 라벨 부착 — 봇 개발 또는 봇 설정 변경 필요. 현실적으로 불가.
- **Option B** (Actions auto-label): GitHub Actions workflow가 봇 댓글 detect → 라벨 자동 부착 — workflow 개발 및 유지 비용. Phase 2에서 검토.

## 변경 파일

```
packages/ai-harness/skills/automated-code-review-cycle/SKILL.md  (종료 조건 라벨 기반으로 변경)
packages/ai-harness/skills/automated-code-review-cycle/config.json  (신규, default reviewers)
packages/ai-harness/skills/automated-code-review-cycle/scripts/poll-labels.sh  (신규, 폴링 로직)
packages/ai-harness/skills/automated-code-review-cycle/scripts/setup-labels.sh  (신규, 라벨 생성)
packages/ai-harness/scripts/tests/bot-review-label.smoke.sh  (신규)
~/.claude/CLAUDE.md MANAGED BLOCK  (필요 시 정책 명시)
```

## State schema

skill 자체 state. session-state.sh와 별개 (PR 별 cycle state 추적은 GitHub state로 충분).

## Test plan

`bot-review-label.smoke.sh`:

1. 라벨 생성 검사 — 없으면 생성
2. Mock PR (test repo) → codex approved + gemini approved → poll 즉시 종료
3. codex approved + gemini in-progress → 계속 폴링
4. codex changes-requested → 수정 사이클 진입
5. Polling timeout → exit 2
6. `bot-review/override` 라벨 → 모두 통과로 간주
7. config.json override 동작 (custom reviewer prefix)
8. `.github/sazo-bot-review.json` 우선 적용
9. 봇 미등록 repo → polling skip
10. `gh` CLI 미설치 → 명시적 에러 + degraded warning

## Open questions

1. Label 부착 주체 — Option A/B/C 중 단기 어느 것? Option C로 시작 권장.
2. 봇 자체 변경 가능한가? (Codex / Gemini 봇 출력 형식 통제 가능?)
3. `bot-review/override` 사용자 명시 라벨 — 누가 부착? PR 작성자만?
4. Polling interval / max iteration — 기본값?
5. Repo가 GitHub Actions로 봇 운영 안 하면 — fallback to LLM 판단? 또는 skip?

## Risk

- **R1 (high)**: 봇이 라벨 안 붙임 → 영구 in-progress → polling timeout. 완화: Option C (LLM이 라벨 부착)부터 시작.
- **R2 (med)**: 라벨 prefix 충돌 — 다른 도구가 같은 prefix 사용. 완화: `bot-review/sazo/...` 같은 namespace.
- **R3 (low)**: GitHub API rate limit. 완화: polling interval ≥ 30s, gh CLI 캐시.

## Rollback

- Skill 이전 버전 revert (LLM 판단 종료)
- 라벨 자체는 무해 (남아있어도 무방)

## Acceptance criteria

- [ ] 라벨 6개 (codex/gemini × approved/changes-requested/in-progress) 정의
- [ ] Polling 스크립트 동작
- [ ] `config.json` 기본 + repo override
- [ ] Polling timeout 처리
- [ ] `bot-review/override` 라벨 우회 경로
- [ ] Smoke test 10개 통과
- [ ] Skill SKILL.md 종료 조건 라벨 기반으로 명시
