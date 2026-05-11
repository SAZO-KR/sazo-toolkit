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
| 06 | Phase 1 default ON (narrow hooks) | **P0 (상향)** | 02 | 0.3주 |
| 07 | Test edits counter (warn only) | P2 (revision) | 00-spike | 0.5주 |
| 08 | Bot review GitHub API label gate | P2 (revision) | — | 1주 |
| 09 | Skip streak hard escalation | P2 | — | 0.3주 |
| 10 | Dangerous command sandbox (+ GH #34692 fallback) | P2 (revision) | 00-spike | 0.3주 |
| 11 | Approval nonce idle TTL | P2 | — | 0.3주 |
| 12 | Phase 2 default ON (workflow-state-machine) | P3 | 02, 06, dogfood | 0.3주 |
| 13 | Control flow extensions (integrator wishlist 통합) | P1 (PR #27 후속) | PR #27 | 1.5주 |
| 14? | (proposed) subagent routing enforcement (general-purpose 차단 + tools whitelist + Glob exploration-gate) | **P0 candidate** | 06 | TBD |

### 우선순위 변경 사유 (2026-05-11)

**Plan 06 P1 → P0 상향** + **Plan 14 후보 P0**.

`ccusage daily -s 20260501 -b` 측정 결과 2026-05 Opus 비용 비율 95-100%. 기대치 30-50% (탐색/리뷰/문서는 haiku/sonnet 위임). 원인 분석:

1. **메인 루프 직접 탐색 차단 부재** — Grep 777 / Glob 475 / Bash grep-find 다수가 메인 Opus에서 직접. `pre-exploration-gate` 있지만 `SAZO_WORKFLOW_HOOKS_ENABLED` 미설정 시 비활성. → **Plan 06**이 narrow hook으로 default ON 분리하면 해결.
2. **`general-purpose` subagent 남용 (10일 181건)** — Opus 부모 모델 inherit. 컨텍스트만 절약, 토큰 비용 동일. plan revision / 자동 리뷰 / /review wrap 등에 광범위 사용. → **Plan 14**가 routing 강제로 차단.
3. **Glob tool exploration-gate 미포함** — 현재 gate는 Grep + Bash만. Glob 475건은 메인 Opus에서 그대로. → Plan 14에서 Glob도 gate에 포함.

`SAZO_WORKFLOW_HOOKS_ENABLED=1` 임시 활성으로 1번 부분 해결 (Grep + Bash grep만). 2/3번은 plan 진행 필요.

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
