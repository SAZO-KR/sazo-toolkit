# 09. Skip Streak Hard Escalation

**우선순위**: P2
**의존**: 없음
**예상 비용**: 0.3주
**결정성 이동**: 🟡 → 🟢 (skip 누적을 LLM "주의" 지시 → hook hard block)

## 목표

CLAUDE.md 명시된 "연속 3 stage skip 시 hook이 경고" 가 현재 warn만 출력. 사용자가 무시하면 결정성 약함. Hard block + 사용자 명시 nonce로 escalation.

## 현재 상태 / 문제

- `session-state.sh:302-313` `consecutive_skip_count()` 구현 존재
- `workflow-state-machine.sh:81-89` `emit_skip_warning_if_needed()` warn 출력
- LLM이 warn 무시하고 다음 stage skip 가능 → CLAUDE.md 의도 위반

## 제안

### 1. 임계값 정의

- 0~2 skip: 정상 동작
- 3~4 skip: warn (현재 동작 유지)
- 5+ skip: **hard block** + `/override-skip-streak` nonce 요구

이유: 3 = 단순 우연 가능 (research + plan + review skip), 5 = 거의 모든 stage skip = 결정성 포기.

### 2. Hard block 진입

`workflow-state-machine.sh` PreToolUse 분기:

```bash
streak=$(consecutive_skip_count "$sid")
if [ "$streak" -ge 5 ]; then
  if ! state_get "$sid" ".override_skip_streak_at" | grep -q -v null; then
    echo "Skip streak: $streak. Override required: /override-skip-streak <reason>" >&2
    exit 2
  fi
fi
```

### 3. `/override-skip-streak` slash command

`packages/ai-harness/commands/override-skip-streak.md`:
- 사용자 입력 → state에 `override_skip_streak_at: ts, reason: ...`
- nonce 1회용 (consume 후 폐기)
- audit log entry

### 4. Streak reset 정책

- 통과(`completed`) stage 1개 → streak 0 reset
- skip 누적만 카운트

`consecutive_skip_count()` 기존 로직 그대로 사용.

### 5. Override 후 동작

- nonce 소비 → 다음 1개 mutating tool은 skip-streak block 없이 통과
- 그 후 skip 추가 누적 시 다시 임계값 도달하면 또 block

## 변경 파일

```
packages/ai-harness/scripts/hooks/workflow-state-machine.sh  (hard block 분기)
packages/ai-harness/scripts/hooks/lib/session-state.sh       (override nonce 발급/소비)
packages/ai-harness/scripts/hooks/user-prompt-approval-detect.sh  (또는 별도 detect script)
packages/ai-harness/commands/override-skip-streak.md         (신규)
packages/ai-harness/scripts/tests/skip-streak.smoke.sh       (신규)
~/.claude/CLAUDE.md MANAGED BLOCK                            (5+ skip 정책 명시)
```

## State schema

추가 필드:
```json
{
  "override_skip_streak_at": null | "ts",
  "override_skip_streak_consumed": false
}
```

## Test plan

`skip-streak.smoke.sh`:

1. skip × 4 → warn 출력, mutating 통과
2. skip × 5 → hard block + override 안내
3. `/override-skip-streak <reason>` → nonce set
4. nonce 후 mutating 1회 통과
5. nonce consumed → 추가 mutating은 다시 block (skip 5+ 유지 시)
6. completed stage 1개 → streak 0 reset → block 해제
7. Audit log entry "skip_streak_block" / "skip_streak_override"
8. nonce reuse 시도 → reject

## Open questions

1. 임계값 5가 합리적? 4 또는 6?
2. Override nonce 만료 — 즉시 1회 소비 (제안), 아니면 시간 (15분)?
3. `completed` stage가 정확히 무엇? `stage_mark` "completed"만? autonomous skip은 reset 트리거 X?

## Risk

- **R1 (low)**: 사용자 frustration — 일부러 많은 skip 의도된 워크플로 (예: docs-only PR). 완화: override nonce 단순.
- **R2 (low)**: streak counter 부정확 시 false block. 완화: 기존 `consecutive_skip_count` 검증된 함수 재사용.

## Rollback

- `SAZO_DISABLE_SKIP_STREAK_BLOCK=1` env → warn만, block 안 함
- 기존 동작 (warn only)으로 회귀

## Acceptance criteria

- [ ] skip 5+ 시 hard block + override 안내
- [ ] `/override-skip-streak` nonce 1회용 동작
- [ ] completed stage → streak 0 reset
- [ ] Audit log entry
- [ ] Smoke test 8개 통과
- [ ] CLAUDE.md 명시
