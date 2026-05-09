# 06. Phase 1 Default ON (Narrow Hooks)

**우선순위**: P1
**의존**: 02 (workflow CLI - dogfood data 분석용)
**예상 비용**: 0.3주
**결정성 이동**: opt-in alpha → default. 현재 사실상 prompt-only인 사용자에게 가드 켜기.

## 목표

`SAZO_WORKFLOW_HOOKS_ENABLED=1` 미설정해도 narrow hook은 기본 동작. workflow-state-machine 같은 광범위 hook은 Phase 2까지 opt-in 유지.

## 현재 상태 / 문제

- 모든 workflow hook이 `SAZO_WORKFLOW_HOOKS_ENABLED=1` 단일 gate (`session-state.sh:29-32`)
- 안 켜면 프로젝트 기여자가 결정성 없이 사용 → "MANDATORY 박는 prompt-only" 모드
- alpha 핑계로 영구 비활성 default 유지하면 가치 없음

## 제안

### 1. Hook을 "narrow" / "broad"로 분류

**Narrow (Phase 1 default ON 후보)**:
- `pre-worktree-gate.sh` — 보호 브랜치 첫 mutating tool 차단. 잘못 동작해도 사용자가 즉시 인지.
- `pre-commit-lint.sh` — staged 파일 lint autofix. 결과 즉시 보임.
- `pre-exploration-gate.sh` — Opus 직접 grep ≥3회 차단. 영향 좁음.
- `user-prompt-approval-detect.sh` — `/approved` nonce 발급. 부작용 없음 (passive).

**Broad (Phase 2까지 opt-in 유지)**:
- `workflow-state-machine.sh` — research/plan/approval/ci/review stage gate. 영향 큼, dogfood 필요.

### 2. Gate 함수 분리

`session-state.sh` 변경:

```bash
workflow_hooks_enabled() {
  # broad hook용 - default OFF
  [[ "${SAZO_WORKFLOW_HOOKS_ENABLED:-0}" == "1" ]]
}

narrow_hooks_enabled() {
  # narrow hook용 - default ON
  [[ "${SAZO_DISABLE_NARROW_HOOKS:-0}" != "1" ]]
}
```

각 hook 진입 시 해당 gate 함수 호출.

### 3. Migration / 안내

- README, CLAUDE.md MANAGED BLOCK 업데이트:
  - "narrow hook은 default ON. opt-out: `SAZO_DISABLE_NARROW_HOOKS=1`"
  - "broad workflow hook은 여전히 opt-in: `SAZO_WORKFLOW_HOOKS_ENABLED=1`"
- `auto-update.sh` SessionStart에서 첫 narrow hook 활성화 시 1회 알림 (opt-out 방법 안내)
- `~/.claude/settings.json` permission 업데이트 (auto-update가 자동 sync)

### 4. Phase 2 promotion 기준 (Phase 1과 함께 명시)

Phase 2 (= broad hook 전체 default ON) promotion:
- Phase 1 narrow hook 활성 후 30일 경과
- `verdict_missing_count` 류 metric 임계값 통과
- 명시적 audit.log 분석 (`sazo-workflow stats`로 측정)

별도 plan(12)에서 상세화.

## 변경 파일

```
packages/ai-harness/scripts/lib/session-state.sh    (narrow_hooks_enabled 추가, workflow_hooks_enabled는 기존 broad 의미 유지)
packages/ai-harness/scripts/hooks/pre-worktree-gate.sh  (narrow_hooks_enabled 사용)
packages/ai-harness/scripts/hooks/pre-commit-lint.sh    (narrow_hooks_enabled)
packages/ai-harness/scripts/hooks/pre-exploration-gate.sh  (narrow_hooks_enabled)
packages/ai-harness/scripts/hooks/user-prompt-approval-detect.sh  (narrow_hooks_enabled)
packages/ai-harness/scripts/auto-update.sh          (1회 알림 로직)
packages/ai-harness/README.md                       (Phase 1 안내)
packages/ai-harness/docs/workflow-hooks.md          (Phase 1/2 정책)
~/.claude/CLAUDE.md MANAGED BLOCK                   (narrow default ON 명시)
```

## Test plan

`packages/ai-harness/scripts/tests/phase1-default.smoke.sh`:

1. 환경변수 둘 다 미설정 → narrow hook 동작, broad hook 비활성
2. `SAZO_WORKFLOW_HOOKS_ENABLED=1` → narrow + broad 모두 동작
3. `SAZO_DISABLE_NARROW_HOOKS=1` → narrow 비활성, broad는 ENABLED env에 따름
4. `SAZO_DISABLE_NARROW_HOOKS=1` AND `SAZO_WORKFLOW_HOOKS_ENABLED=1` → broad만 동작
5. 첫 SessionStart 시 narrow hook 활성 알림 1회 출력
6. 두 번째 SessionStart 알림 미출력 (1회만)
7. 사용자가 알림 dismiss (state에 marker) → 알림 안 나옴

## Open questions

1. **Narrow 분류 정합성**: pre-commit-lint는 사실 mutating(autofix). 분류 옳은가?
2. **사용자 명시 opt-out 위치**: env가 적절한가, 아니면 `~/.claude/settings.json`의 별도 키?
3. **알림 UX**: SessionStart마다 1회는 too noisy? "첫 1회만"으로 limit?
4. **CI/CI hook이 사용자 머신마다 다른 환경 (예: jq 없음)** → narrow hook도 fail. 회로 (plan 05)와 통합 필요?

## Risk

- **R1 (high)**: 기존 사용자 워크플로 깨짐. 특히 pre-worktree-gate가 false positive 시 mutating 모두 block. 완화: opt-out env 명시, 첫 1주 모니터링.
- **R2 (med)**: Phase 1 활성화 자체로 신규 bug 노출 가능성. 완화: narrow hook은 이미 검증된 코드이므로 기존 alpha 사용자 데이터 = Phase 1 미리보기.
- **R3 (low)**: 사용자 알림 noise. 완화: 1회 only, dismiss option.

## Rollback

- `SAZO_DISABLE_NARROW_HOOKS=1` env → 즉시 비활성
- 코드 revert: `auto-update.sh` 멱등 sync, 다음 SessionStart에 복구

## Acceptance criteria

- [ ] `narrow_hooks_enabled()` 함수 추가, default ON
- [ ] `workflow_hooks_enabled()` 의미 broad로 좁힘 (기존 단일 gate에서)
- [ ] 4개 narrow hook이 새 gate 사용
- [ ] 환경변수 4가지 조합 동작 확인 (smoke test)
- [ ] SessionStart 알림 1회 출력
- [ ] README, CLAUDE.md 명시
- [ ] Phase 2 promotion 기준 plan 12와 일관성

## Dependencies

- Plan 02 (workflow CLI) — 사용자가 차단 사유 조회 가능해야 narrow hook frustration 줄임
- Plan 05 (circuit breaker) — narrow hook fail시 degraded mode 진입
