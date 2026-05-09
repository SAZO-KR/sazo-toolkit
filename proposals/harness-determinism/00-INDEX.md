# Harness Determinism Improvements — Index

기사 "Agents Need Control Flow, Not More Prompts" 관점으로 ai-harness 검토 후 도출한 개선 plan 모음.

## 배경

현재 harness는 `workflow-state-machine.sh`, `session-state.sh` 기반 stage gate + nonce 시스템 보유. but:

- Opt-in alpha (default 비활성)
- Subagent 출력 자유 텍스트 → main LLM이 verdict 해석
- 일부 gate가 LLM 자율 판단에 의존

리뷰(architect-advisor + plan-critic) 결과를 반영한 우선순위:

| # | Plan | 우선순위 | 의존 | 비용 |
|---|---|---|---|---|
| 00-spike | **Hook payload spec spike** | BLOCKING | — | ✅ 완료 |
| 01 | Subagent verdict footer + aggregation + nonce 방어 | P0 (revision) | 00-spike | 1주 |
| 02 | Workflow CLI (status/history/why-blocked) | P0 | 없음 | 0.5주 |
| ~~03~~ | ~~Task depth counter~~ — **DEPRECATED** | — | — | spike Q4: Claude Code가 이미 강제 |
| 04 | ci_passed_at invalidation (+ GH #34692 fallback) | P1 (revision) | 00-spike | 0.5주 |
| 05 | Hook circuit breaker (degraded mode) | P1 | 없음 | 0.5주 |
| 06 | Phase 1 default ON (narrow hooks) | P1 | 02 | 0.3주 |
| 07 | Test edits counter (warn only) | P2 (revision) | 00-spike | 0.5주 |
| 08 | Bot review GitHub API label gate | P2 (revision) | — | 1주 |
| 09 | Skip streak hard escalation | P2 | — | 0.3주 |
| 10 | Dangerous command sandbox (+ GH #34692 fallback) | P2 (revision) | 00-spike | 0.3주 |
| 11 | Approval nonce idle TTL | P2 | — | 0.3주 |
| 12 | Phase 2 default ON (workflow-state-machine) | P3 | 02, 06, dogfood | 0.3주 |
| 13? | (proposed) subagent tools whitelist enforcement | P1 candidate | — | TBD |

## 공통 가이드

- 모든 변경은 `packages/ai-harness/` 내 hook/lib/scripts에서.
- `~/.claude/CLAUDE.md` MANAGED BLOCK은 `install.sh` / `auto-update.sh`가 sync 한다 — 정책 변경 시 두 곳 모두 업데이트.
- Smoke test는 `packages/ai-harness/scripts/tests/`에 추가, CLAUDE.md ai-harness CI 커맨드에 합류.
- Backward compat: 기존 사용자 설치 깨면 안 됨. `auto-update.sh` 멱등성 유지.

## 결정성 분류 (각 plan 헤더에 표기)

- **🟢 결정적 layer**: 코드가 강제 (hook, lock, schema, exit code)
- **🟡 LLM layer**: 모델이 판단 (자유 prompt)
- **🔵 사용자 layer**: 사용자만 가능한 동작 (nonce, /skip)

각 plan은 어떤 부분을 결정적으로 옮기는지 명시.
