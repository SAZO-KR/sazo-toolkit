# 11. Approval Nonce Idle TTL

**우선순위**: P2
**의존**: 없음
**예상 비용**: 0.3주
**결정성 이동**: 🟢 강화 (영구 nonce → idle 만료)

## 목표

`/approved` nonce가 영구 유효한 현 동작 → idle 시간 기준 만료. Stale approval 재사용 방지.

## 현재 상태 / 문제

`session-state.sh:317-332` 발급된 `approval_nonce`는 만료 없이 한 세션 내 영구 유효. 며칠 후 resume 시 같은 nonce로 통과 가능.

## 제안

### 1. Idle TTL 도입

기준: **last hook activity ≥ 30분이면 stale**.

state schema:
```json
{
  "approval_nonce": "<hex>",
  "approval_nonce_issued_at": "<ts>",
  "last_hook_activity_at": "<ts>"   // 신규
}
```

### 2. Activity 추적

모든 PreToolUse / PostToolUse hook 진입 시 `last_hook_activity_at = now()` 업데이트.

(주의: 매 hook마다 state write → 락 비용. 캐시 5초 이내면 skip 등 최적화 검토.)

### 3. 만료 검사

`approval_nonce_consume()` (`session-state.sh:319` 부근) 변경:

```bash
issued_at=$(state_get "$sid" ".approval_nonce_issued_at")
last_active=$(state_get "$sid" ".last_hook_activity_at")
now_ts=$(date +%s)

# idle = (now - last_active)
idle=$((now_ts - $(date -d "$last_active" +%s)))
if [ "$idle" -gt 1800 ]; then  # 30분
  # stale → nonce 무효
  state_set_str "$sid" ".approval_nonce" "null"
  echo "Approval nonce expired (idle ${idle}s). Re-approve required." >&2
  return 1
fi
```

### 4. 만료 시 사용자 안내

`approval` stage 진입 시 nonce stale → PreToolUse hook이 stderr 안내 + `/approved` 재입력 요구.

### 5. 만료 임계값 조정

env `SAZO_APPROVAL_IDLE_TTL_SECONDS` (기본 1800).

## 변경 파일

```
packages/ai-harness/scripts/hooks/lib/session-state.sh    (TTL 검사, last_hook_activity_at)
packages/ai-harness/scripts/hooks/workflow-state-machine.sh  (모든 hook entry에 activity 업데이트)
packages/ai-harness/scripts/tests/approval-ttl.smoke.sh   (신규)
~/.claude/CLAUDE.md MANAGED BLOCK                          (TTL 정책 명시)
```

## State schema

`approval_nonce_issued_at`, `last_hook_activity_at` 추가. backward compat: 기존 state.json은 init 시 default null.

null 처리: null이면 stale 검사 skip (legacy nonce는 통과 — 또는 일률 stale 처리, 보수적 선택).

## Test plan

`approval-ttl.smoke.sh`:

1. nonce 발급 → 즉시 consume → pass
2. nonce 발급 → 1700초 sleep → consume → pass (idle < TTL)
3. nonce 발급 → 1900초 sleep → consume → fail (idle > TTL)
4. activity 업데이트 → 다시 consume → pass
5. `SAZO_APPROVAL_IDLE_TTL_SECONDS=60` → 100초 sleep → fail
6. legacy state.json (필드 없음) → 일률 stale 처리 vs pass 동작 정의 확인
7. activity 캐시 (5초 이내 skip) 동작 확인 (write 락 비용 측정)

## Open questions

1. activity 추적이 모든 hook마다? 또는 mutating hook만? 비용 vs 정확성 tradeoff.
2. 30분 적절? 사용자 frequent context switch 대응. 60분?
3. legacy nonce — 일률 invalidate vs 통과? 보수적 invalidate 권장.

## Risk

- **R1 (med)**: activity 캐시 race condition. 완화: 5초 이내 캐시는 같은 PID에서만, 다른 hook은 항상 update.
- **R2 (low)**: 사용자가 30분 동안 hook 활동 없으면 stale → frustration. 완화: env로 조정 가능, 30분은 실험 후 조정.
- **R3 (low)**: state 락 비용 증가 (매 hook write). 완화: 캐시 + 비동기 write 검토 (out-of-scope, 추후).

## Rollback

- `SAZO_DISABLE_APPROVAL_TTL=1` env → TTL 검사 skip
- 기존 동작 (영구 nonce)으로 회귀

## Acceptance criteria

- [ ] approval_nonce_issued_at, last_hook_activity_at 필드
- [ ] consume 시 idle 검사 + stale invalidate
- [ ] env로 TTL 조정 가능
- [ ] Stale 시 사용자 안내
- [ ] Smoke test 7개 통과
- [ ] Legacy state.json backward compat 동작 정의 명시
