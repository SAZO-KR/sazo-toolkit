---
description: 연속 skip streak hard block 해제 (1-shot). 사용자 직접 입력 전용.
allowed-tools: Bash(echo:*)
argument-hint: <reason>
---

# /override-skip-streak — skip streak 1-shot override

## 사용법

```
/override-skip-streak <reason>
```

**사용자 직접 입력 전용**. UserPromptSubmit hook이 사용자가 정확히 이 형식을 타이핑한 경우에만 nonce를 발급한다. Claude가 자의로 호출하면 nonce 미발급 → 다음 mutating tool에서 여전히 hard block.

## 동작

UserPromptSubmit hook(`user-prompt-approval-detect.sh`)이 이 입력을 감지하면:

1. `<reason>` 존재 확인 (없으면 거부, audit `skip_streak_override_rejected` 기록)
2. 32-hex nonce 발급 (`openssl rand -hex 16`)
3. `state.override_skip_streak_at`, `override_skip_streak_nonce`, `override_skip_streak_consumed = false` 기록
4. audit log `skip_streak_override` 기록

다음 mutating tool(Edit/Write/`gh pr create`/`gh pr merge`) 호출 시:
- `enforce_skip_streak_gate`가 nonce 존재 확인 → consume → audit `skip_streak_override_consumed` → pass
- 이후 같은 streak 상태라면 다시 block

!`bash -c 'echo "[skip-streak] /override-skip-streak는 UserPromptSubmit hook이 처리함. 이 bash 블록은 가시성 전용입니다."'`

## 주의사항

- nonce는 **첫 mutating tool 시점에 즉시 consume**. downstream gate(research/plan/approval) 별도 fail 시 nonce도 같이 소비됨.
- 따라서 `/override-skip-streak <reason>` 발급 후, downstream gate 다 통과한 상태에서 사용 권장.
- 잘못 사용 시 새 nonce 다시 발급 필요.

## 자율 실행 금지

이 slash command는 **사용자 의사결정**이 필요한 override gate다. Claude가 자의로 호출하거나 대신 타이핑하도록 유도 금지. 사용자에게 `/override-skip-streak <reason>` 직접 입력을 안내할 것.

## 환경변수 (긴급 opt-out)

- `SAZO_DISABLE_SKIP_STREAK_BLOCK=1` — streak 블록 전체 비활성 (warn-only 복귀)
- `SAZO_SKIP_STREAK_MAX=N` — 블록 임계값 조정 (기본 5)
