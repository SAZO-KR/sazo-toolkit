# 00-spike. Hook Payload Spec Investigation (Day 1 Spike)

**우선순위**: BLOCKING (모든 P0 plan의 prerequisite)
**의존**: 없음
**예상 비용**: 1일
**산출물**: 결정 문서 (Plan 01, 03 구조 확정 → revision 가능)

## 목표

Claude Code hook payload 스펙의 미확인 사항 결정. 결과로 Plan 01 (footer aggregation), Plan 03 (task depth) 의 근본 구조가 결정됨.

## 조사 항목

### Q1. PostToolUse Task hook이 subagent output 텍스트 접근 가능한가?

**검증 방법**:
1. Claude Code 공식 docs: hook payload spec 확인 (anthropic-ai/claude-code 공식 문서)
2. 현재 codebase: `workflow-state-machine.sh` 가 `SAZO_TOOL_RESPONSE` payload에서 어떤 필드 사용 중인지 audit
3. Test hook 실험: PostToolUse Task에서 payload 전체 dump → 실제 필드 구조 관찰

**결정 분기**:
- 접근 가능 (`tool_response.content[].text` 또는 유사 필드) → Plan 01 진행, 정확한 jq path 명시
- 접근 불가 → **Plan 01 폐기 또는 근본 재설계** (예: agent prompt에 verdict를 별도 출력 채널에 쓰도록 — 파일/state.json 직접 write 등)

### Q2. PreToolUse Task hook이 `tool_input.prompt` 변조 가능한가?

**검증 방법**:
1. Claude Code 공식 docs: PreToolUse hook의 input modification 채널
2. 기존 hook 패턴: `tool_input` rewrite 사례 있나
3. Test: PreToolUse에서 stdout JSON 반환하여 prompt 수정 시도

**결정 분기**:
- 가능 → Option A/B (hook이 nonce 자동 inject) 가능
- 불가능 → **Option D 채택** (caller가 prompt에 nonce 직접 인젝트, hook은 검증만)

### Q3. Subagent에 환경변수 inherit?

**검증 방법**:
1. Claude Code docs: subagent execution model
2. Test: `SAZO_TASK_DEPTH=1` 설정 후 Task 호출 → subagent가 echo $SAZO_TASK_DEPTH

**결정 분기**:
- Inherit → Plan 03 옵션 A (env propagation)
- 미inherit → Plan 03 **state.json 기반 카운터** (옵션 C, race 위험 있음 — atomic compare-and-swap helper 필요)

### Q4. Task subagent가 nested Task 호출 가능한가?

**검증 방법**:
1. Subagent definition (agents/*.md) 의 tools list에 Task 포함 여부
2. 실제 호출 시 동작 (parent session vs nested)

**결정 분기**:
- 가능 → Plan 03 depth counter 의미 있음
- 불가능 → Plan 03 자체 불필요 (이미 1단계로 제한)

### Q5. Hook payload 정확한 JSON schema

기록 대상 필드:
- PreToolUse: `session_id`, `tool_name`, `tool_input.*`
- PostToolUse: 위 + `tool_response.*`
- UserPromptSubmit: `session_id`, `prompt`

각 hook event별 정확한 schema dump. 향후 모든 plan의 reference.

### Q6. Smoke test fixture 패턴

기존 smoke test 분석:
- `packages/ai-harness/scripts/tests/sleep-guard.smoke.sh`
- `packages/ai-harness/scripts/tests/setup-rtk.smoke.sh`
- `workflow-hooks.smoke.sh`

추출:
- Mock payload 주입 방법 (stdin pipe?)
- 시간 mock 방법 (`SAZO_NOW_OVERRIDE` 등 helper 있나)
- gh CLI mock 패턴
- Hook 직접 invoke 패턴

→ Spike 산출물: `packages/ai-harness/scripts/tests/lib/test-helpers.sh` (공통 헬퍼) plan.

## 산출물

### `proposals/harness-determinism/spike-results.md` (신규)

Schema:
```markdown
# Spike Results

## Q1. PostToolUse Task output access
- Status: CONFIRMED | UNAVAILABLE | PARTIAL
- Evidence: <docs link, code reference, test output>
- Decision: <plan 01 path>
- Exact jq path: <if confirmed>

## Q2. PreToolUse tool_input.prompt mutation
- Status: ...
- Decision: <option A/B/C/D>

## Q3. Subagent env inherit
- Status: ...
- Decision: <plan 03 path>

## Q4. Nested Task
- Status: ...
- Decision: <plan 03 needed?>

## Q5. Hook payload schemas
- PreToolUse: <jq dump>
- PostToolUse: <jq dump>
- UserPromptSubmit: <jq dump>

## Q6. Test fixture pattern
- Mock payload: <method>
- Time mock: <method>
- gh CLI mock: <method>
- Helper plan: <path>
```

## 변경 파일 (spike 자체)

```
proposals/harness-determinism/spike-results.md  (신규, spike 결과)
packages/ai-harness/scripts/tests/spike/                 (신규, 임시 test scripts)
  payload-dump.smoke.sh    (PostToolUse payload dump)
  prompt-mutate.smoke.sh   (PreToolUse mutation 테스트)
  env-inherit.smoke.sh     (env propagation 테스트)
  nested-task.smoke.sh     (subagent nested Task)
```

테스트 스크립트는 spike 종료 후 삭제 또는 정식 테스트로 promote.

## Test plan (spike 자체)

조사 자체가 test. 각 Q마다:
1. docs 인용
2. 코드 reference
3. 실제 실험 (가능한 경우)
4. 결과 명시 (CONFIRMED / UNAVAILABLE / PARTIAL)

## 진행 절차

1. **A. Docs research** (병렬): docs-researcher subagent → Claude Code hook payload spec
2. **B. Code audit** (병렬): code-searcher subagent → 기존 hook payload usage
3. **C. Test 실험** (sequential, A/B 결과 후): 직접 hook invoke 또는 mock payload
4. **D. spike-results.md 작성**: 모든 결과 종합
5. **E. Plan 01, 03 revision 가능 신호**: Q1, Q2, Q3 status 확정

## Acceptance criteria

- [ ] Q1~Q6 모두 status 결정 (CONFIRMED/UNAVAILABLE/PARTIAL)
- [ ] spike-results.md 작성 완료
- [ ] Plan 01 revision 진행 가능 (Q1, Q2 결정)
- [ ] Plan 03 revision 진행 가능 (Q3, Q4 결정)
- [ ] Smoke test 공통 헬퍼 패턴 plan 또는 polished

## Open questions (spike 자체에는 없음)

— 이 plan 자체에는 open question 두지 않음. spike의 출력이 모든 plan의 open question을 closed로 만드는 게 목적.

## Risk

- **R1 (med)**: 공식 docs가 hook payload schema 명시 안 함 → 실험만으로 추론. spike 신뢰성 ↓.
- **R2 (low)**: Q1 답이 UNAVAILABLE → Plan 01 자체 폐기. sunk cost.
- **R3 (low)**: spike 자체가 1일 초과 → P0 plan 진행 지연.

## Rollback

— spike는 rollback 불필요 (조사만, 코드 변경 없음).

## Dependencies (downstream)

이 spike 완료 후 진행:
- Plan 01 revision (Q1, Q2 결정 반영)
- Plan 03 revision (Q3, Q4 결정 반영)
- 모든 plan의 smoke test 섹션 (Q6 헬퍼 패턴 적용)
