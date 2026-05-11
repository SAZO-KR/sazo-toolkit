# Workflow Enforcement Hooks

## 배경

CLAUDE.md `<required>` 개발 워크플로우가 정의돼도 Claude 세션이 단계를 건너뛰는 사례 발생. 원인은 "지시문 준수 실패" — Auto mode 리마인더, system-reminder 노이즈, Opus 인지적 shortcut 등. 지시문 강화로는 한계 → **행동 레벨 hook**으로 준수 강제.

## 성숙도

- **Narrow hooks**: Plan 06부터 **default ON**. 영향 좁고 결과 가시적. 문제 시 `SAZO_DISABLE_NARROW_HOOKS=1`.
- **Broad hooks** (`workflow-state-machine`): 여전히 **Alpha / opt-in**. dogfood 의지 표현. False positive 발생 시 issue 등록 부탁. Phase 2 default-on 전 다음 항목 정리 필요:
  - Validator allowlist 강화 (`by:user` 위장 차단)
  - CI 커맨드 결정적 source (`.ai-harness/ci-command` 같은 별도 config)
  - Subagent lineage 추적
  - Schema migration 함수 (v2 도입 시)

## 활성화 (Phase 1 narrow vs Phase 2 broad)

### Narrow hooks — 기본 활성 (Plan 06부터)

영향 범위 좁고 사용자가 결과를 즉시 인지 가능. 별도 설정 없이 동작:
- `pre-worktree-gate` — 보호 브랜치 mutating 차단
- `pre-commit-lint` — staged 파일 lint autofix
- `pre-exploration-gate` — Opus 직접 grep/find/glob 3회 후 block (Plan 14에서 Glob 추가)
- `pre-task-general-purpose-gate` — Opus가 `general-purpose` subagent 호출 시 soft warn (전용 subagent 권장; Plan 14)
- `user-prompt-approval-detect` — `/approved` nonce 발급

비활성화:
```bash
export SAZO_DISABLE_NARROW_HOOKS=1
```

### Broad hooks — opt-in alpha

광범위 영향. 사용자가 명시 활성화해야 동작:
- `workflow-state-machine` — research/plan/approval/ci/review stage gate

활성화:
```bash
export SAZO_WORKFLOW_HOOKS_ENABLED=1
```
`~/.zshrc`/`~/.bashrc`에 영구 등록 또는 세션별 `.envrc` 사용.

비활성화: 변수 unset 또는 `SAZO_DISABLE_WORKFLOW_HOOKS=1`.

### Phase 2 promotion 기준 (broad default ON)

Plan 12에서 상세화. 요건:
- narrow hook 활성 후 30일 경과
- `verdict_missing_count` 류 metric 임계값 통과
- `sazo-workflow stats` 기반 audit.log 분석

## Stage 정의

```
init → worktree → research → plan → approval → implementation → ci → review → done
```

implementation에는 별도 gate 없음 (approval ~ ci 사이 자유 구간). PR 생성이 done 트리거.

## Gate 정책

| Stage | Hook 시점 | 완료 판정 | 강도 | Autonomous skip | User skip |
|---|---|---|---|---|---|
| worktree | 첫 mutating tool 전 | 보호 브랜치 아님 + 정상 worktree | hard block | **금지** | `/skip worktree <reason>` |
| research | Write/Edit 전 | code-searcher/docs-researcher Task ≥1 | soft warn ×3 → block | 파일/라인 사용자 지정, ≤2 파일 | `/skip research <reason>` |
| plan | Write/Edit 전 | plan-drafter Task or assistant 메시지 plan | soft warn ×3 → block | ≤5줄·단일파일·typo/주석 | `/skip plan <reason>` |
| approval | Write/Edit 전 | `/approved` (사용자 직접 입력 nonce 검증) | soft warn only | **금지** | — |
| ci | `gh pr create` 전 | 프로젝트 CLAUDE.md CI 커맨드 정확 매치 + exit 0 | hard block | **금지** (env override) | — |
| review | `gh pr create` 전 | code-reviewer Task ≥1 | hard block | 문서/주석만 | `/skip review <reason>` |

### 강도 분리 근거

- **Write/Edit (research/plan/approval)** = soft warn 3회 후 block. TDD 첫 Red test가 Write이라 hard block은 ritual 강제, false positive 多.
- **`gh pr create` (ci/review)** = 그 자체가 외부 영향을 미치는 시점. hard block 가치 있음.
- **approval = soft only**. `/approved`는 architecturally Claude가 자의적으로 호출 가능 — UserPromptSubmit hook이 nonce 발급해 사용자 직접 입력만 인정하지만, 그래도 hard gate로 만들면 일반 작업 진행 불가. soft warn으로 충분.

## Skip 경로

1. **사용자 명시**: `/skip <stage> <reason>`. reason 필수.
2. **사용자 제안 승인**: Claude가 "skip 제안 (이유: ...)" → 사용자 동의 → Claude가 `/skip` 실행.
3. **Autonomous (research/plan/review만)**: Claude가 lib `stage_mark` 호출. by:"auto" + reason 기록.
4. **Env override** (CI만): `SAZO_ALLOW_CI_SKIP=1`. 자동 skipped 마킹 + 진행.

### Validator

`stage_is_passed`가 approval/ci에 대해 `by != "auto-claude"` 체크 — Claude가 lib 우회로 직접 jq write해도 approval/ci는 통과 안 됨. 정식 경로(사용자 직접 입력 또는 env override) 필수.

### 안전장치

- 연속 ≥3 stage skip → hook 경고 ("workflow bypass 의도 맞나? 사용자 추가 확인 권장")
- Skip 전체 내역은 `~/.claude/session-state/audit.log`에 append. `/harness-retro`가 retrospective에서 참조.

## Session State

경로: `~/.claude/session-state/$SESSION_ID--$CWD_HASH.json`

**cwd hash 포함 이유**: 같은 session_id가 worktree 옮겨다닐 때 stage marker leak 방지 (M1 fix).

```json
{
  "schema_version": 1,
  "session_id": "...",
  "cwd": "/...",
  "model": "claude-opus-4-7",
  "started_at": "...",
  "stage": "plan",
  "history": [
    {"stage":"worktree","status":"completed","by":"auto","ts":"..."},
    {"stage":"research","status":"completed","by":"auto","reason":"subagent=code-searcher","ts":"..."}
  ],
  "explore_count": 2,
  "soft_warn_count": 0,
  "plan_approved_at": null,
  "approval_nonce": null,
  "ci_passed_at": null,
  "ci_cmd_hash": null,
  "review_ts": null
}
```

**동시성**: PreToolUse hook은 병렬 실행될 수 있음 (Claude Code 스펙). 모든 mutation은 mkdir 기반 lock + stale 60s timeout.

## Hook 목록

| Hook | 타입 | matcher | 역할 |
|---|---|---|---|
| `pre-worktree-gate.sh` | PreToolUse | `Write\|Edit\|NotebookEdit\|Bash` | worktree 격리 검증 |
| `pre-exploration-gate.sh` | PreToolUse | `Grep\|Glob\|Bash` | Opus 직접 탐색 block (Plan 14: Glob 추가) |
| `pre-task-general-purpose-gate.sh` | PreToolUse | `Task` | Opus가 `general-purpose` subagent 호출 시 soft warn (Plan 14) |
| `workflow-state-machine.sh pre` | PreToolUse | `Task\|Write\|Edit\|NotebookEdit\|Bash` | research/plan/approval/ci/review gate |
| `workflow-state-machine.sh post` | PostToolUse | `Task\|Bash\|Edit\|Write\|NotebookEdit` | stage 자동 완료 + explore_count decay |
| `user-prompt-approval-detect.sh` | UserPromptSubmit | (none) | 사용자 직접 `/approved` 입력 시 nonce 발급 |

### 공통 lib

`scripts/hooks/lib/session-state.sh` — read/write/transition/lock 함수. slash command (`/skip`, `/approved`)도 동일 lib source.

## Override Flag

Narrow / broad gate가 독립적. **모든 hook을 끄려면 두 flag 모두 필요**.

Narrow hook 전체 비활성:
```
SAZO_DISABLE_NARROW_HOOKS=1
```

Broad hook (workflow-state-machine) 전체 비활성:
```
SAZO_DISABLE_WORKFLOW_HOOKS=1
```

개별 비활성:
```
SAZO_SKIP_WORKTREE_GATE=1
SAZO_SKIP_EXPLORE_GATE=1
SAZO_SKIP_STATE_MACHINE=1
SAZO_ALLOW_CI_SKIP=1
SAZO_ALLOW_GREP_ONCE=1    # 1회 사용
```

## 비침습성

각 hook 독립 실행. 하나 실패해도 나머지 작동. narrow는 default-on(좁은 영향), broad는 opt-in(광범위) — 도입 충격 최소화.

## Roadmap

- subagent lineage 추적 (현재 main session의 직접 Task 호출만 감지)
- session 종료 시 stale state 파일 cleanup
- 프로젝트 CI 커맨드 fingerprint를 더 정밀하게 (현재는 backtick fenced + ≥3 chained heuristic)
