# 03. Task Depth Counter — DEPRECATED

**상태**: 🔴 **폐기 (DEPRECATED)** — 2026-05-09 spike 결과
**사유**: Claude Code가 이미 nested Task 차단 (max depth=1, 공식 docs 확인). subagent의 tools list에 Task 포함되어 있어도 effectively disabled. 자체 depth counter 불필요.

**대체**: 만약 사용자 정의 orchestrator 패턴이 미래에 추가될 때 별도 plan으로 다시 검토.

**원래 plan은 참고용으로 보존**. 아래 본문은 spike 이전 작성된 초안.

---

**우선순위**: ~~P1~~ → DEPRECATED
**의존**: 없음
**예상 비용**: ~~0.3주~~
**결정성 이동**: 🟡 → 🟢 (subagent 재귀 제어를 prompt 지시문에서 hook으로)

## 목표

Subagent가 다른 subagent를 호출하는 재귀 폭발을 코드로 차단. 정당한 위임(plan-drafter → code-searcher 등)은 허용, 무한 재귀는 block.

## 현재 상태 / 문제

- 현재 agent 정의에 "do not call other subagents" 텍스트 지시만 있음 (강제 X)
- LLM이 무시하면 재귀 폭발 가능 — 토큰 비용/시간 폭증
- 단순 nested 호출 금지(원안 P2 #9)는 너무 광범위 — plan-drafter가 code-searcher 호출하는 정당 패턴까지 깸

## 제안

### 1. Depth env propagation

PreToolUse Task hook이 `SAZO_TASK_DEPTH` 환경변수 검사:

```
current_depth = $SAZO_TASK_DEPTH (default 0)
new_depth = current_depth + 1

if new_depth > $SAZO_TASK_DEPTH_MAX (default 2):
  echo "Task depth limit exceeded ($current_depth → $new_depth, max $SAZO_TASK_DEPTH_MAX)" >&2
  exit 2  # hard block

# 정상이면 환경변수 propagation
# Claude Code subagent invocation에 env가 inherit 되는지 확인 필요
```

### 2. Depth 정의

- main session: depth 0
- main이 Task 호출 → subagent 실행 시 depth 1
- 그 subagent가 또 Task 호출 → depth 2
- max 기본값 2 = "main → A → B" 까지 허용, "main → A → B → C" 차단

이유: plan-drafter (depth 1) → code-searcher (depth 2) 정상. depth 3 이상은 의도 외.

### 3. Override

- `SAZO_TASK_DEPTH_MAX` env로 조정 가능
- 특정 워크플로우(예: deep research mode)에서 한시적 상향 가능

### 4. State 기록

audit.log에 차단 entry 추가:
```
ts=... event=task_depth_block from_agent=<parent> attempted_subagent=<child> depth=N
```

`sazo-workflow audit` (plan 02)으로 사후 조회.

## 변경 파일

```
packages/ai-harness/scripts/hooks/pre-task-depth.sh    (신규, PreToolUse Task)
packages/ai-harness/scripts/lib/session-state.sh        (audit log entry helper 추가)
packages/ai-harness/scripts/hooks/lib/register-workflow-hooks.sh  (hook 등록)
packages/ai-harness/install.sh, scripts/auto-update.sh  (settings.json 등록)
packages/ai-harness/scripts/tests/task-depth.smoke.sh   (신규)
~/.claude/CLAUDE.md MANAGED BLOCK                       (depth 정책 명시)
```

## Test plan

`task-depth.smoke.sh`:

1. depth 0 → Task 호출 → pass (depth 1 set)
2. depth 1 → Task 호출 → pass (depth 2 set)
3. depth 2 → Task 호출 → block, exit 2
4. `SAZO_TASK_DEPTH_MAX=3` override → depth 3까지 허용
5. audit.log entry 포맷 검증
6. depth env가 subagent 환경에 propagation 되는지 (Claude Code spec 의존, spike 필요)

## Open questions

1. **Claude Code subagent inherit env?** 기본 inherit되면 simple. 안 되면 PreToolUse가 prompt에 depth marker 인젝트하는 패턴 필요. 1주 안에 spike.
2. **Default max=2가 충분한가?** 현재 정의된 정당 위임 패턴이 어디까지인지 audit 필요.
3. **재귀 자체가 의도된 케이스 (예: orchestrator agent)** — 별도 allowlist 필요?

## Risk

- **R1 (med)**: env propagation 미지원 → 차단 못 함. 옵션 B: prompt marker 인젝트 (more complex). 옵션 C: depth marker를 state.json `task_depth` 필드로 hook이 관리 (PreToolUse +1, PostToolUse -1) — race condition 위험.
- **R2 (low)**: 정당한 deep workflow 차단 → 사용자 friction. 완화: env override 안내 명시.

## Rollback

- `SAZO_TASK_DEPTH_MAX=99` env로 사실상 비활성
- Hook 자체 비활성: `SAZO_DISABLE_TASK_DEPTH=1`
- Hook 등록 제거: `auto-update.sh`가 멱등 sync, 이전 버전으로 revert

## Acceptance criteria

- [ ] PreToolUse Task hook에서 depth 검사 + 차단 동작
- [ ] depth 2 → 3 차단, exit 2
- [ ] audit.log entry 형식 일관
- [ ] `SAZO_TASK_DEPTH_MAX` 조정 가능
- [ ] Smoke test 통과
- [ ] CLAUDE.md에 depth 한계 명시
