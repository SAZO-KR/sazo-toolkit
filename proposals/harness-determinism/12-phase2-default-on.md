# 12. Phase 2 Default ON (Workflow State Machine)

**우선순위**: P3
**의존**: 02 (workflow CLI), 06 (Phase 1), dogfood 데이터
**예상 비용**: 0.3주
**결정성 이동**: opt-in → 전체 default ON

## 목표

`workflow-state-machine.sh` 같은 broad hook도 default ON. 사용자가 명시 opt-out해야만 비활성. 결정성을 default 상태로.

## 현재 상태 / 문제

- Phase 1 (plan 06)에서 narrow hook만 default ON
- broad hook은 여전히 `SAZO_WORKFLOW_HOOKS_ENABLED=1` 명시 필요
- 사용자 1명 기준 dogfood 결과 누적 후 결정 가능

## 제안

### 1. Promotion 기준 (정량)

다음 모두 만족 시 Phase 2 promotion:

- Phase 1 narrow hook 활성 후 **30일** 경과
- `audit.log` 분석 (`sazo-workflow stats --days 30`):
  - **lock_timeout** 이벤트 < 5건 (1000 hook 호출당)
  - **state_corruption** 이벤트 0건
  - 사용자 명시 `/skip` 비율 < 30% (정상 use case)
- Footer 강제 (plan 01 Phase 2 모드) 활성 후 **2주** 경과:
  - `verdict_missing_count` < 5% (rolling 50 invocations)

### 2. Gate 함수 변경

`session-state.sh`:

```bash
workflow_hooks_enabled() {
  # broad hook용 - Phase 2부터 default ON
  [[ "${SAZO_DISABLE_WORKFLOW_HOOKS:-0}" != "1" ]]
}
```

이전 `SAZO_WORKFLOW_HOOKS_ENABLED=1` env는 deprecated (단, 1.0 동안 backward compat 유지: 둘 중 하나라도 false면 비활성).

### 3. Migration 안내

- README, CLAUDE.md MANAGED BLOCK 업데이트
- 첫 SessionStart 시 1회 알림: "broad workflow hook now default ON. opt-out: SAZO_DISABLE_WORKFLOW_HOOKS=1"
- 기존 사용자가 `SAZO_WORKFLOW_HOOKS_ENABLED=1` 설정하던 것 → 자동으로 동작 (deprecated 안내)

### 4. Rollback path

- `SAZO_DISABLE_WORKFLOW_HOOKS=1` env → Phase 1 상태로 회귀
- 코드 revert: `auto-update.sh` 멱등 sync로 가능

### 5. Phase 2 후 모니터링

- 30일 추가 모니터링 (Phase 2 stable):
  - 사용자 frustration 신호 (`/skip` 빈도, override nonce 빈도)
  - hook 실패율
- 임계값 초과 시 사용자에게 alert (sazo-workflow degraded warning)

## 변경 파일

```
packages/ai-harness/scripts/lib/session-state.sh    (workflow_hooks_enabled gate 의미 변경)
packages/ai-harness/scripts/auto-update.sh          (Phase 2 알림 1회)
packages/ai-harness/README.md                       (Phase 2 명시)
packages/ai-harness/docs/workflow-hooks.md          (Phase 1/2 history 표)
~/.claude/CLAUDE.md MANAGED BLOCK                   (broad default ON)
```

## State schema

기존 그대로. 알림 marker는 plan 06과 동일 mechanism.

## Test plan

`packages/ai-harness/scripts/tests/phase2-default.smoke.sh`:

1. env 미설정 → broad hook 동작
2. `SAZO_DISABLE_WORKFLOW_HOOKS=1` → broad 비활성 (narrow는 plan 06 따라 동작)
3. legacy `SAZO_WORKFLOW_HOOKS_ENABLED=1` → 동작 (deprecated 경고)
4. 둘 다 set → DISABLE 우선 (안전 default)
5. SessionStart Phase 2 알림 1회
6. 두 번째 SessionStart 알림 없음

## Open questions

1. 30일 대기는 calendar days vs 활성 일? 사용자 휴가 등.
2. Stats 임계값 — dogfood 데이터 누적 후 조정 가능?
3. Phase 2 promotion이 자동 vs 수동 (별도 PR)? 자동은 위험.

## Risk

- **R1 (high)**: Phase 2 활성 후 수많은 신규 hook 호출 → 성능 영향, edge case 대규모 노출. 완화: dogfood data 충분히 누적 후 진행.
- **R2 (med)**: 사용자 설정 마이그레이션 실패. 완화: deprecated env 1.0 동안 유지.
- **R3 (med)**: Phase 1 dogfood 부족 → premature promotion. 완화: 정량 임계값 통과 강제, 자동 진행 안 함.

## Rollback

- `SAZO_DISABLE_WORKFLOW_HOOKS=1` env
- 코드 revert via `auto-update.sh` 이전 버전

## Acceptance criteria

- [ ] Phase 2 promotion 정량 기준 명시 (30일 + audit 임계값)
- [ ] `SAZO_DISABLE_WORKFLOW_HOOKS` opt-out env
- [ ] Legacy `SAZO_WORKFLOW_HOOKS_ENABLED` backward compat 유지
- [ ] SessionStart Phase 2 알림 1회
- [ ] Smoke test 6개 통과
- [ ] README, CLAUDE.md 명시
- [ ] Phase 2 진입은 별도 PR (자동 진행 금지) — promotion 결정 문서화
