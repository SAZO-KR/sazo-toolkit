# Spike Results — Hook Payload Spec Investigation

**조사 일시**: 2026-05-09
**참조 plan**: 00-spike-hook-payload-spec.md
**조사 방법**: docs-researcher + code-searcher 병렬 subagent

## 종합

핵심 결정 5가지:

1. **Plan 01 viable** — `tool_response.result` 접근 가능. but `updatedInput` 신뢰 불가 → architect 권고 **Option D (caller-emitted nonce)** 채택.
2. **Plan 03 (Task depth) 폐기** — Claude Code가 이미 nested Task 차단 (max depth=1).
3. **Critical 새 위협**: subagent 내부 tool 호출은 parent hook fire 안 함 (GH #34692). 결정성 구멍 추가 발견.
4. **PreToolUse mutation 사용 금지** — multi-hook 시 silently ignored 버그.
5. Smoke test 패턴 확립됨: stdin payload, fake git repo, env -i isolation, `touch -t` time mock.

---

## Q1. PostToolUse Task `tool_response` 텍스트 접근

**Status**: PARTIAL — 접근 가능 but bugs.

**Schema** (Anthropic docs + GH issue 분석):
```json
{
  "tool_response": {
    "result": "<subagent final assistant message>",
    "usage": {...},
    "duration_ms": <int>
  }
}
```

추가로 우리 codebase에서 실제 사용 중인 필드 (`workflow-state-machine.sh:101-106`):
- `is_error` (boolean) — 사용
- `interrupted` (boolean) — 사용

**알려진 버그** (GH #20531):
- `result` 필드가 가끔 final text 대신 **전체 JSONL transcript** 반환. 고치는 중이지만 fragile.

**우리 코드 현 상태** (`workflow-state-machine.sh:101-152`):
- `.tool_response.is_error`, `.tool_response.interrupted`, `.tool_response.exit_code`, `.tool_response.success` 사용 중
- `.tool_response.result` 또는 `.tool_response.output` 미사용 → 신규 path

**Decision (Plan 01)**:
- jq path: `.tool_response.result // ""`
- Robust footer parser: regex로 마지막 `---\n^SAZO_VERDICT_NONCE.*\n^SAZO_VERDICT.*\n.*\n.*\n---$` envelope 매칭. 단순 grep | tail -1 회피 (JSONL transcript 안에서도 false match 위험).
- Truncation detection: closing `---` 없으면 "footer truncated" warn (Phase 1) / block (Phase 2).

---

## Q2. PreToolUse `tool_input` 변조

**Status**: CONFIRMED 가능하지만 UNSAFE.

**공식 docs**:
- PreToolUse가 stdout JSON으로 `hookSpecificOutput.updatedInput` 반환 가능
- 다음 형식:
```json
{
  "hookSpecificOutput": {
    "permissionDecision": "allow",
    "updatedInput": {...}
  }
}
```

**Critical bug (GH #15897)**:
- 동일 tool에 PreToolUse hook 여러 개 매칭 시 → `updatedInput` 무시 → 원본 input 그대로 실행
- 우리 repo는 이미 동일 tool에 다중 hook 존재 (`pre-worktree-gate.sh` + `pre-exploration-gate.sh` + `workflow-state-machine.sh pre` 모두 PreToolUse Bash). 즉 **mutation 사용해도 silently 무효**.

**Decision (Plan 01 nonce)**:
- ❌ Option A (PreToolUse에서 nonce inject) — 버그로 unsafe
- ❌ Option B (hook이 prompt placeholder 치환) — 같은 버그
- ⚠️ Option C (footer 강제, nonce 없음) — architect-advisor 지적: PR 본문 `SAZO_VERDICT: APPROVE` 인용 시 위조 가능 (medium-high risk)
- ✅ **Option D (caller-emitted nonce)** — main loop 또는 skill이 Task 호출 시 prompt 안에 nonce 직접 인젝트. hook은 검증만. updatedInput 의존 X.

**Option D 상세 설계**:
1. `state_init` 시 `verdict_nonce_pool` 발급 (random hex 16바이트, 5개 정도 pre-pool)
2. main이 reviewer/critic 호출 prompt 작성할 때 `commands/review.md` 또는 skill SKILL.md에서 nonce 1개 fetch + prompt 끝에 `Append to your final output: SAZO_VERDICT_NONCE: <hex>` 추가
3. 사용자가 직접 invoke하는 것이 아니라 **skill/command가 자동 생성** → 사용자가 잊을 수 없음
4. PostToolUse hook이 `result` 텍스트에서 nonce 검증 + 1회 소비

---

## Q3. Subagent env inherit

**Status**: UNCONFIRMED (공식 silent).

**관찰**:
- Subagent는 별도 프로세스 컨텍스트 (Task tool spawn)
- `CLAUDE_CODE_*` env vars 일부 docs에 언급
- `SAZO_*` custom env는 docs 미언급
- Likely standard Unix inheritance, but unconfirmed

**Decision**: Plan 03 폐기로 인해 무관 (Q4 참조). 다른 plan에서 env 의존하는 부분도 가능한 한 state.json으로 대체.

---

## Q4. Nested Task

**Status**: CONFIRMED BLOCKED — max depth = 1.

**공식 docs**:
> Subagents cannot spawn other subagents — architectural hard limit.
> If Task tool is in subagent's tools list, it is effectively disabled.

→ **Plan 03 (Task Depth Counter) 자체 불필요**. Claude Code가 이미 강제.

**Decision**: Plan 03 폐기. 우선순위 list에서 제거.

대안 — 만약 사용자 정의 orchestrator agent에서 nested 패턴 필요해진다면, 그때 별도 plan.

---

## Q5. UserPromptSubmit payload

**Status**: PARTIAL — 필드명 확정.

**Schema**:
```json
{
  "session_id": "...",
  "cwd": "...",
  "hook_event_name": "UserPromptSubmit",
  "prompt": "<user input text>"
}
```

**현 사용** (`user-prompt-approval-detect.sh`):
- `.prompt` 추출 후 trim → 첫 token이 정확히 `/approved` 매칭

**Decision**: 추가 slash command (`/override-skip-streak`, `/allow-dangerous`, `/skip-tdd-warn`)도 같은 패턴 — `user-prompt-approval-detect.sh`을 일반화 → `user-prompt-slash-detect.sh`로 rename + dispatch table.

---

## 🔴 Critical 새 발견 (계획에 반영 필요)

### GH #34692 — Subagent 내부 tool 호출은 hook fire 안 함

```
parent session (hooks 등록됨)
  └─ Task → subagent spawn
       └─ subagent가 Edit/Bash/etc 호출
            ↑ parent의 PreToolUse / PostToolUse 발동 안 됨
```

**영향**:
- subagent가 코드 변경 → ci_passed_at invalidate (plan 04) **발동 안 됨**
- subagent가 dangerous command 실행 → block (plan 10) **무력**
- subagent가 commit → pre-commit-lint **미발동**

**임시 완화**:
- agent definition (`agents/*.md`)의 tools 필드 감사 — Edit/Write/Bash 가진 agent 제한
- 또는: subagent별 allowed tools whitelist (이미 일부 있음)
- 또는: state machine이 PreToolUse Task 시점에 "subagent will mutate code" predict → ci_passed_at preemptive invalidate

**plan 04, 10 revision 필요** — subagent 내부 변경에 대한 fallback 정책.

### GH #15897 — Multiple PreToolUse → updatedInput ignored

위 Q2 결정에 반영 (Option D).

### GH #20531 — `tool_response.result` 가끔 JSONL transcript

위 Q1 footer parser 강건화로 대응. envelope marker `---` 사용.

---

## Smoke test 패턴 확립

### Mock payload 주입
```bash
echo '{"session_id":"test","cwd":"/tmp","tool_name":"Task","tool_input":{...},"tool_response":{...}}' \
  | bash hook.sh [pre|post]
```

### 격리 환경
```bash
# 가짜 git repo
mkdir -p "$TMP_REPO" && cd "$TMP_REPO"
git init -q -b main
git config user.email smoke@test
git config user.name smoke
git commit -q --allow-empty -m "init"

# 가짜 HOME
env -i HOME="$SANDBOX" PATH="/usr/bin:/bin" "$SCRIPT" --quiet
```

### 시간 mock
```bash
# macOS
touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "$MARKER"
# Linux
touch -t "$(date -d '1 hour ago' +%Y%m%d%H%M.%S)" "$MARKER"
```

### Assert helper
```bash
PASS=0; FAIL=0
assert_exit() {
  local expected="$1" actual="$2" label="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS+1)); echo "  ✓ $label"
  else
    FAIL=$((FAIL+1)); echo "  ✗ $label (expected $expected, got $actual)"
  fi
}
```

### State query
```bash
LAST_STATUS=$(state_get "$sid" '[.history[] | select(.stage=="ci")] | last.status' "$cwd")
```

**Decision**: 위 패턴을 `packages/ai-harness/scripts/tests/lib/test-helpers.sh` 헬퍼로 추출. 모든 신규 smoke test가 source.

---

## Plan별 후속 조치

| Plan | 조치 | 이유 |
|---|---|---|
| 01 | Revision (Option D nonce, envelope parser, JSONL bug 방어) | Q1, Q2 결정 |
| 02 | 진행 가능 (revision 필요하지만 spike 무관) | — |
| **03** | **폐기** | Q4 — Claude Code 이미 강제 |
| 04 | Revision + GH #34692 fallback | subagent 내부 변경 미감지 |
| 05 | 진행 가능 (state_corruption 정의 명시 필요) | — |
| 06 | 진행 가능 | — |
| 07 | Revision (subagent edits 감지 안 됨 명시) | GH #34692 |
| 08 | Revision (Option C 결정성 클레임 정정) | architect 지적 |
| 09 | 진행 가능 (slash detect 일반화 — Q5 dispatch table) | — |
| 10 | Revision + GH #34692 fallback | subagent dangerous cmd 미차단 |
| 11 | 진행 가능 | — |
| 12 | 진행 가능 (Plan 06 후) | — |

---

## 다음 단계

1. **Plan 01 revision** — 이 결과 반영 (Option D, envelope parser, _state_init_inner 업데이트, API 서명 정정)
2. **Plan 03 공식 폐기** (`03-task-depth-counter.md` 헤더에 DEPRECATED 표기 + 사유)
3. **Plan 04, 10 revision** — GH #34692 영향 반영 (subagent fallback)
4. **신규 plan 13?**: subagent tools whitelist enforcement (GH #34692 본질적 대응)
5. test-helpers.sh 추출 plan (모든 smoke test의 prerequisite)
