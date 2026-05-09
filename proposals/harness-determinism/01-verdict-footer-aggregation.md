# 01. Subagent Verdict Footer + Aggregation + Nonce Defense (REVISED)

**우선순위**: P0
**의존**: 00-spike (완료) — Q1 PARTIAL, Q2 unsafe → Option D 채택
**예상 비용**: 1주
**Revision**: 2026-05-09 (architect-advisor 리뷰 + spike 결과 반영)
**결정성 이동**: 🟡 → 🟢 (subagent 출력 해석을 main LLM에서 hook으로)

## 목표

Subagent 출력 verdict를 자유 텍스트가 아니라 코드가 정확히 parse 가능한 schema로 강제. 가장 큰 결정성 구멍(`workflow-state-machine.sh:122-125` — reviewer가 본문에 "BLOCK" 출력해도 stage 통과) 메움.

## Spike 결과 핵심 적용

| Spike Q | 결정 | Plan 01 영향 |
|---|---|---|
| Q1: `tool_response.result` 접근 | PARTIAL (가능, but JSONL leak 버그 GH #20531) | envelope marker parser (강건) |
| Q2: `tool_input.prompt` 변조 | UNSAFE (multi-hook GH #15897) | **Option D**: caller-emitted nonce |
| Q5: UserPromptSubmit `.prompt` | CONFIRMED | slash command 감지 일반화 가능 |
| GH #34692: subagent 내부 hook 미발동 | 영향 있음 | reviewer subagent의 verdict는 Task PostToolUse에서 받으므로 OK |

## 1. Footer Schema (envelope marker)

대상 subagent 출력 끝에 정확히 다음 envelope:

```
---SAZO_FOOTER_BEGIN---
SAZO_VERDICT_NONCE: <16-byte hex>
SAZO_VERDICT: APPROVE | BLOCK | NEEDS_REVISION
SAZO_BLOCKING_ISSUES: <int>
---SAZO_FOOTER_END---
```

**왜 envelope?**
- GH #20531 — `tool_response.result`가 가끔 전체 JSONL transcript 반환
- 단순 grep | tail -1 → JSONL 안의 다른 메시지에서 false match 가능
- 명시 begin/end marker 사이 텍스트만 parse → 강건

**`SAZO_NEXT_ACTION` 필드 제거** (architect 의견: derivable, 불필요).

**대상 subagent**:
- `code-reviewer` (review stage)
- `architect-advisor` (review stage, 병렬)
- `plan-critic` (plan stage 게이트)
- `plan-auditor` (plan stage gap 분석)

**대상 아님** (자유 텍스트 유지):
- `code-searcher`, `docs-researcher`, `image-analyzer` (탐색)
- `plan-drafter` (출력=플랜 자체)
- `plan-executor`, `ui-engineer`, `doc-writer` (실행)

## 2. Nonce — Option D (Caller-Emitted)

**왜 Option D**:
- Option A/B (PreToolUse가 prompt 변조) — GH #15897로 unsafe (multi-hook 시 silently ignored)
- Option C (footer만, nonce 없음) — architect 지적: PR 본문 echo 위조 가능 (medium-high risk)
- ✅ Option D — caller가 prompt 안에 nonce 직접 인젝트

**흐름**:

1. **Pool 발급** (`session-state.sh` `verdict_nonce_issue()`):
   ```bash
   verdict_nonce_issue() {
     local sid="$1" cwd="$2" agent="$3" stage="$4"
     local nonce
     nonce=$(openssl rand -hex 16)
     state_set_json "$sid" ".verdict_nonces[\"$nonce\"]" \
       "{\"agent\": \"$agent\", \"stage\": \"$stage\", \"issued_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"consumed\": false}" "$cwd"
     printf '%s' "$nonce"
   }

   verdict_nonce_consume() {
     local sid="$1" cwd="$2" nonce="$3" agent="$4"
     # nonce가 pool에 있고, agent 일치, consumed=false 검증
     local entry
     entry=$(state_get "$sid" ".verdict_nonces[\"$nonce\"] // null" "$cwd")
     [ "$entry" = "null" ] && return 1
     local registered_agent consumed
     registered_agent=$(printf '%s' "$entry" | jq -r '.agent')
     consumed=$(printf '%s' "$entry" | jq -r '.consumed')
     [ "$registered_agent" = "$agent" ] || return 1
     [ "$consumed" = "false" ] || return 1
     # consume
     state_set_json "$sid" ".verdict_nonces[\"$nonce\"].consumed" "true" "$cwd"
     return 0
   }
   ```

2. **Caller가 fetch + inject**:
   - `commands/review.md` (또는 review skill)에서 reviewer Task 호출 직전 nonce fetch
   - Task `prompt` 인자 끝에 다음 텍스트 자동 추가:
     ```
     ---
     IMPORTANT: At the end of your response, append exactly this footer (do not omit, do not modify):
     ---SAZO_FOOTER_BEGIN---
     SAZO_VERDICT_NONCE: <NONCE_VALUE>
     SAZO_VERDICT: <APPROVE|BLOCK|NEEDS_REVISION>
     SAZO_BLOCKING_ISSUES: <int>
     ---SAZO_FOOTER_END---
     ```
     (`<NONCE_VALUE>`는 fetch한 실제 nonce 16바이트 hex)

3. **PostToolUse Task hook이 검증** (`workflow-state-machine.sh`):
   - `tool_response.result`에서 envelope 추출
   - nonce 매치 + state에서 `consumed=false` 확인
   - 검증 후 `consumed=true` set
   - 1회 사용 후 폐기

4. **Pool 관리**:
   - 발급 후 1시간 미사용 → expired (TTL)
   - `verdict_nonces` 객체 크기 50개 cap (oldest expired 삭제)
   - SessionStart 시 expired sweep

**위조 방어**:
- 사용자 PR 본문 `SAZO_VERDICT_NONCE: deadbeef...` 인용 → state에 등록 안 된 nonce → reject
- Reviewer가 자기 nonce 알려면 caller(main loop or skill)가 인젝트한 prompt를 따라야 함 → 정상 흐름

## 3. PostToolUse Task hook parser

**위치**: `workflow-state-machine.sh` 의 `handle_post` 함수 안 Task 분기 (현 라인 96-126).

**리팩토링 단계**:
1. 현 라인 96-126의 Task 분기 전체를 새 함수 `_handle_post_task_legacy(sid, cwd, payload)`로 추출 (동일 동작).
2. 그 자리에 `_handle_post_task` 신규 호출 (아래 정의).
3. `_handle_post_task` 신규 함수가 verdict-tracked subagent_type만 footer parse, 나머지는 `_handle_post_task_legacy` 호출.

**`audit_log` 함수**: plan 02에서 정의 (JSON Lines 출력). plan 01은 plan 02 audit_log 함수에 dependency. plan 01 단독 구현 시 임시로 simple printf으로 audit log append.

**함수 정의** (`session-state.sh` 추가):

```bash
parse_verdict_footer() {
  local result_text="$1"

  # 마지막 envelope만 추출 (multi-envelope/JSONL leak 방어)
  local envelope
  envelope=$(printf '%s\n' "$result_text" | awk '
    /^---SAZO_FOOTER_BEGIN---$/{buf=""; flag=1; next}
    /^---SAZO_FOOTER_END---$/{
      if (flag) { last=buf; have=1 }
      flag=0; next
    }
    flag{buf = buf $0 "\n"}
    END{ if (have) printf "%s", last }
  ')

  if [ -z "$envelope" ]; then
    # BEGIN은 있는데 END 없는 경우 → truncated
    if printf '%s\n' "$result_text" | grep -q '^---SAZO_FOOTER_BEGIN---$'; then
      printf 'STATUS=truncated\n'
      return 0
    fi
    printf 'STATUS=missing\n'
    return 0
  fi

  local nonce verdict issues
  nonce=$(printf '%s\n' "$envelope" | grep -oE '^SAZO_VERDICT_NONCE: [0-9a-f]{32}$' | awk '{print $2}')
  verdict=$(printf '%s\n' "$envelope" | grep -oE '^SAZO_VERDICT: (APPROVE|BLOCK|NEEDS_REVISION)$' | awk '{print $2}')
  issues=$(printf '%s\n' "$envelope" | grep -oE '^SAZO_BLOCKING_ISSUES: [0-9]+$' | awk '{print $2}')

  if [ -z "$nonce" ] || [ -z "$verdict" ]; then
    printf 'STATUS=truncated\n'
    return 0
  fi

  printf 'STATUS=ok\nNONCE=%s\nVERDICT=%s\nISSUES=%s\n' "$nonce" "$verdict" "${issues:-0}"
}
```

**Hook 분기**:

```bash
_handle_post_task() {
  local sid="$1" cwd="$2" payload="$3"

  local subagent_type
  subagent_type=$(printf '%s' "$payload" | jq -r '.tool_input.subagent_type // ""')

  # verdict-tracked subagent만
  case "$subagent_type" in
    code-reviewer|architect-advisor|plan-critic|plan-auditor) ;;
    *) _handle_post_task_legacy "$sid" "$cwd" "$payload"; return ;;
  esac

  # 현 stage가 verdict 적용 가능 stage인지 확인
  local current_stage
  current_stage=$(state_get "$sid" ".stage" "$cwd")
  case "$subagent_type" in
    code-reviewer|architect-advisor)
      [ "$current_stage" = "review" ] || { _handle_post_task_legacy "$sid" "$cwd" "$payload"; return; }
      ;;
    plan-critic|plan-auditor)
      [ "$current_stage" = "plan" ] || { _handle_post_task_legacy "$sid" "$cwd" "$payload"; return; }
      ;;
  esac

  # 실패한 Task — verdict 무관
  local is_error interrupted
  is_error=$(printf '%s' "$payload" | jq -r '.tool_response.is_error // false')
  interrupted=$(printf '%s' "$payload" | jq -r '.tool_response.interrupted // false')
  if [ "$is_error" = "true" ] || [ "$interrupted" = "true" ]; then
    _record_reviewer_error "$sid" "$cwd" "$subagent_type"
    return
  fi

  # tool_response.result 추출 + footer parse
  local result_text
  result_text=$(printf '%s' "$payload" | jq -r '.tool_response.result // ""')

  local parse_output
  parse_output=$(parse_verdict_footer "$result_text")

  local status nonce verdict issues
  status=$(printf '%s' "$parse_output" | awk -F= '/^STATUS=/{print $2}')
  nonce=$(printf '%s' "$parse_output" | awk -F= '/^NONCE=/{print $2}')
  verdict=$(printf '%s' "$parse_output" | awk -F= '/^VERDICT=/{print $2}')
  issues=$(printf '%s' "$parse_output" | awk -F= '/^ISSUES=/{print $2}')

  case "$status" in
    missing)
      state_increment "$sid" ".verdict_missing_count.$subagent_type" "$cwd"
      _audit_log "verdict_missing" "$sid" "$subagent_type"
      if [ "${SAZO_VERDICT_FOOTER_ENFORCE:-warn}" = "block" ]; then
        # Phase 2: stage_mark 안 함
        return
      fi
      # Phase 1 (warn): 기존 동작 유지 (legacy stage_mark)
      _handle_post_task_legacy "$sid" "$cwd" "$payload"
      return
      ;;
    truncated)
      _audit_log "verdict_truncated" "$sid" "$subagent_type"
      # truncate는 항상 block (Phase 무관)
      return
      ;;
    ok)
      ;;
  esac

  # nonce 검증 — agent binding 강제
  if ! verdict_nonce_consume "$sid" "$cwd" "$nonce" "$subagent_type"; then
    audit_log "verdict_nonce_invalid" "$sid" "$current_stage" "" "hook" "agent=$subagent_type nonce=$nonce"
    return
  fi

  # last_verdicts replace-by-agent (architect 지적)
  state_set_json "$sid" ".last_verdicts.$current_stage[\"$subagent_type\"]" \
    "{\"verdict\": \"$verdict\", \"issues\": $issues, \"ts\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" "$cwd"

  # aggregation 평가
  if _evaluate_stage_completion "$sid" "$cwd" "$current_stage"; then
    stage_mark "$sid" "$cwd" "$current_stage" "completed" "auto" "all_reviewers_approve"
  fi
}
```

## 4. Aggregation 정책

**Active reviewer set 정의** (architect 지적):

`commands/review.md` 또는 review skill 시작 시 main loop가 `state.review_expected_set` 명시:

```bash
# 예: code-reviewer + architect-advisor 호출 의도
state_set_json "$sid" ".review_expected_set" '["code-reviewer","architect-advisor"]' "$cwd"
```

`_evaluate_stage_completion` 로직:

```bash
_evaluate_stage_completion() {
  local sid="$1" cwd="$2" stage="$3"
  local expected received

  case "$stage" in
    review) expected=$(state_get "$sid" ".review_expected_set // []" "$cwd");;
    plan)   expected='["plan-critic","plan-auditor"]';;  # plan stage 고정
    *) return 1;;
  esac

  # Empty expected_set 동작 (caller가 잊은 경우)
  local expected_count
  expected_count=$(printf '%s' "$expected" | jq 'length')
  if [ "$expected_count" -eq 0 ]; then
    state_increment "$sid" ".verdict_unset_expected_set_count" "$cwd"
    audit_log "verdict_unset_expected_set" "$sid" "$stage" "" "hook" "caller did not set review_expected_set"
    # Phase 1: fail-open (첫 reviewer APPROVE로 통과). Phase 2 검토.
    if [ "${SAZO_VERDICT_EMPTY_EXPECTED:-fail_open}" = "fail_closed" ]; then
      return 1
    fi
    # fail-open: received 1개 이상 + 그 1개가 APPROVE
    local first_verdict
    first_verdict=$(state_get "$sid" ".last_verdicts.$stage | to_entries | first.value.verdict // \"\"" "$cwd")
    [ "$first_verdict" = "APPROVE" ]
    return $?
  fi

  # 정상 경로: 모든 expected가 received이고 전원 APPROVE
  local result
  result=$(state_get "$sid" "
    (.review_expected_set // []) as \$exp |
    (.last_verdicts.$stage // {}) as \$last |
    if \$exp | length == 0 then false
    else
      (\$exp | map(\$last[.]?.verdict)) as \$verdicts |
      (\$verdicts | any(. == null) | not) and (\$verdicts | all(. == \"APPROVE\"))
    end
  " "$cwd")
  [ "$result" = "true" ]
}
```

**부분 PASS 미허용** (전원 APPROVE만).

**Empty expected_set 동작**:
- Phase 1: fail-open (첫 reviewer APPROVE로 통과) — caller(skill) 책임 명시
- Phase 2: `SAZO_VERDICT_EMPTY_EXPECTED=fail_closed` 권장
- 매 occurrence마다 `verdict_unset_expected_set_count` 증가 + audit log → metric으로 caller 누락 detect

**Reviewer error 처리** (`_record_reviewer_error` 정의):

```bash
_record_reviewer_error() {
  local sid="$1" cwd="$2" agent="$3"
  state_increment "$sid" ".verdict_errors.$agent" "$cwd"
  local count
  count=$(state_get "$sid" ".verdict_errors.$agent" "$cwd")
  if [ "$count" -ge 3 ]; then
    cat >&2 <<EOF
[workflow-block] reviewer $agent stuck ($count consecutive errors).
Action required:
  - Inspect last reviewer output
  - Rerun reviewer Task, OR
  - User: /skip review <reason>
EOF
    audit_log "reviewer_stuck" "$sid" "review" "" "hook" "$agent count=$count"
  fi
}
```

자동 재시도 안 함 — 사용자 명시 입력만 진행.

**plan-auditor 의미론** (architect 지적):
- `BLOCK` → plan stage 차단 + escalate to plan-critic 호출 권장 (audit log)
- `NEEDS_REVISION` → plan stage 미완료, plan-drafter 재호출 권장
- `APPROVE` → plan stage 통과 후보, plan-critic 출력과 AND

## 5. Footer 부재 fallback (Phase 정책)

| Phase | 환경변수 | 동작 |
|---|---|---|
| 1 (warn) | `SAZO_VERDICT_FOOTER_ENFORCE=warn` (default) | footer 부재 시 warn + 기존 stage_mark 동작 |
| 2 (block) | `SAZO_VERDICT_FOOTER_ENFORCE=block` | footer 부재/invalid → stage_mark 안 함 |

**Per-agent rollout**:
- code-reviewer: Phase 1 → 2 (가장 simple, 빨리 promote)
- plan-critic, plan-auditor, architect-advisor: 추가 1주 dogfood 후 Phase 2

**ENV 명명 통일** (codebase 기존 `SAZO_DISABLE_*` 어순 따름):
- `SAZO_VERDICT_FOOTER_ENFORCE` (warn|block, default warn) — global Phase
- `SAZO_VERDICT_FOOTER_ENFORCE_<agent>` (warn|block) — per-agent override (agent명 lowercase, e.g., `SAZO_VERDICT_FOOTER_ENFORCE_CODE_REVIEWER`)
- `SAZO_DISABLE_VERDICT_FOOTER` (=1) — 전체 kill switch
- `SAZO_DISABLE_VERDICT_FOOTER_<agent>` (=1) — per-agent kill switch
- `SAZO_VERDICT_EMPTY_EXPECTED` (fail_open|fail_closed, default fail_open)

## 6. Phase 1 → Phase 2 transition (정량)

조건 (모두 충족 시):
- per-agent `verdict_missing_count` rolling 50회 호출 중 < 5%
- 시간 가드: 최소 1주, 최대 4주
- `sazo-workflow stats` (plan 02)에서 측정

자동 promotion 안 함. 별도 PR에서 ENV default 변경.

## 7. State schema 변경

`session-state.sh` `_state_init_inner` (line 119-136) 의 jq -n literal 전체를 다음으로 교체:

```bash
_state_init_inner() {
  local sid="$1" cwd="$2"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  jq -nc \
    --arg sid "$sid" \
    --arg cwd "$cwd" \
    --arg ts "$ts" \
    '{
      schema_version: 2,
      sid: $sid,
      cwd: $cwd,
      created_at: $ts,
      stage: "init",
      history: [],
      explore_count: 0,
      plan_approved_at: null,
      approval_nonce: null,
      ci_passed_at: null,
      degraded_warned: false,
      verdict_nonces: {},
      last_verdicts: {review: {}, plan: {}},
      verdict_missing_count: {},
      verdict_errors: {},
      verdict_unset_expected_set_count: 0,
      review_expected_set: []
    }'
}
```

**Lazy access fallback** (기존 state file에 신규 필드 없을 때):
- 모든 신규 필드 access는 jq `// {}` 또는 `// []` 또는 `// 0` fallback
- 예: `state_get "$sid" ".last_verdicts.review // {}"`, `state_get "$sid" ".review_expected_set // []"`
- 기존 state.json 마이그레이션 불필요 (lazy)

**bound 정책** (architect 지적):
- `verdict_nonces`: consumed=true이고 issued > 24h 경과 → SessionStart sweep
- `last_verdicts.<stage>`: 객체 (key=agent), 자동 cap 없음 (agent 종류 < 10이라 무한 성장 X)
- review/plan stage 진입 시 (`stage_mark` 함수에서 자동) `last_verdicts.<stage> = {}` 초기화 (이전 BLOCK 잔존 차단)
- 총 state 파일 크기 cap: **1MB** (256KB → 1MB 상향, jq 처리 한계 충분 여유)
- 초과 시 truncation 정책:
  - **history 끝(최근 50개) 절대 보존**
  - **stage="completed"이고 stage∈{ci, approval} entry 우선 보존** (stage_is_passed 의존성)
  - 위 보존 후 oldest entry부터 truncate
  - audit.log 별도 파일 (제거 안 함, append-only)
- truncation 함수 (`session-state.sh`):
  ```bash
  _maybe_truncate_state() {
    local sid="$1" cwd="$2"
    local f="$STATE_DIR/${sid}.json"
    [ -f "$f" ] || return 0
    local sz; sz=$(wc -c <"$f")
    [ "$sz" -lt 1048576 ] && return 0  # 1MB

    # truncate: history 길이 100 → 50으로
    local tmp="$f.trunc.tmp"
    jq '
      . as $s |
      .history |= (
        # 보존 set: 최근 50개 + ci/approval completed
        ([.[-50:][]] + [.[] | select(.stage=="ci" or .stage=="approval") | select(.status=="completed")])
        | unique_by(.ts)
        | sort_by(.ts)
      )
    ' "$f" > "$tmp" && mv "$tmp" "$f"
    audit_log "state_truncated" "$sid" "" "" "hook" "size=$sz"
  }
  ```

## 8. 변경 파일

```
packages/ai-harness/agents/code-reviewer.md           (footer 지시 추가)
packages/ai-harness/agents/architect-advisor.md       (footer 지시)
packages/ai-harness/agents/plan-critic.md             (footer 지시)
packages/ai-harness/agents/plan-auditor.md            (footer 지시 + verdict 의미론)
packages/ai-harness/scripts/hooks/lib/session-state.sh  (verdict_nonce_*, parse_verdict_footer, _state_init_inner 업데이트, _audit_log helper)
packages/ai-harness/scripts/hooks/workflow-state-machine.sh  (_handle_post_task 신규 분기)
packages/ai-harness/commands/review.md                (review_expected_set 설정 + nonce inject prompt 추가)
packages/ai-harness/skills/review/SKILL.md            (caller-emitted nonce 흐름 명시)
packages/ai-harness/scripts/tests/lib/test-helpers.sh  (Q6 결과 — 공통 helper)
packages/ai-harness/scripts/tests/footer-parser.smoke.sh  (신규)
packages/ai-harness/docs/workflow-hooks.md            (verdict footer 정책)
~/.claude/CLAUDE.md MANAGED BLOCK                     (verdict footer + caller nonce 흐름 명시)
```

## 9. Test plan

`packages/ai-harness/scripts/tests/footer-parser.smoke.sh` (`test-helpers.sh` source):

1. envelope 정상 → APPROVE → state 기록 + stage_mark
2. envelope 정상 → BLOCK → stage 미완료
3. envelope 부재 + Phase 1 (warn) → legacy stage_mark 호출
4. envelope 부재 + Phase 2 (block) → stage_mark 안 함
5. truncated (begin marker만, end 없음) → 항상 block
6. nonce 미등록 (위조 시뮬) → reject + audit log
7. nonce 이미 consumed → reject
8. 동일 reviewer 재호출 + 새 nonce → 새 verdict로 replace (append 아님)
9. expected set = [code-reviewer, architect-advisor]:
   - code-reviewer만 APPROVE → stage 미완료 (architect 미수신)
   - architect-advisor도 APPROVE → stage 완료
10. expected set 일부 BLOCK → stage 미완료
11. reviewer error 3회 → user escalation message
12. JSONL leak 시뮬 (result에 transcript JSON 포함) + envelope 마지막 → envelope만 추출
13. plan stage: plan-critic APPROVE + plan-auditor NEEDS_REVISION → stage 미완료
14. plan stage: 둘 다 APPROVE → 완료
15. 다른 stage에서 reviewer 호출 (예: plan stage 중 code-reviewer) → verdict ignore (stage-context gating)
16. SessionStart sweep: expired nonce 제거 확인
17. State 256KB cap: oldest history truncate

## 10. Rollback

- `SAZO_DISABLE_VERDICT_FOOTER=1` env → `_handle_post_task` 진입 즉시 `_handle_post_task_legacy` fallback (정확한 위치: `workflow-state-machine.sh` 분기 첫 줄)
- per-agent: `SAZO_VERDICT_FOOTER_DISABLE_<agent>=1`
- state schema: forward-compat (없는 필드는 init에서 빈 객체)

## 11. 변경된 Open questions

원래 4개 → 모두 closed:

1. ~~Hook이 prompt 변조 가능?~~ → spike Q2 결과: unsafe → Option D
2. ~~tool_response.output 접근 가능?~~ → Q1: `.tool_response.result`. envelope parser
3. ~~plan-auditor verdict 의미론?~~ → 위 §4 명시
4. ~~nonce reissue 시 turn cap?~~ → 1시간 TTL + 50개 pool cap

## 12. Risk (revised)

- **R1 (med)**: GH #20531 (JSONL leak)이 결과를 어지럽힐 수 있음. 완화: envelope marker, awk sentinel parsing.
- **R2 (med)**: caller(main loop / skill)가 nonce 인젝트 잊으면 footer empty 또는 nonce 없음. 완화: skill SKILL.md에 명시 + smoke test로 review skill 검증.
- **R3 (low)**: per-agent rollout 복잡도 — env 4개. 완화: docs.
- **R4 (low)**: prompt 길이 증가 (nonce inject text). 완화: cache 활용 (cached prompt prefix).

## 13. Acceptance criteria

- [ ] 4개 agent prompt에 footer 지시 추가 (envelope marker 명시)
- [ ] `verdict_nonce_issue` / `verdict_nonce_consume` 함수 (`session-state.sh`)
- [ ] `parse_verdict_footer` envelope 기반 파서 (awk sentinel)
- [ ] PostToolUse `_handle_post_task` 신규 분기 — 정확한 라인 (현 108-126 대체)
- [ ] `_state_init_inner` 신규 필드 init (5개 객체)
- [ ] Stage-context gating (review에서만 code-reviewer, plan에서만 plan-critic)
- [ ] Replace-by-agent semantics (last_verdicts 객체 key=agent)
- [ ] expected set 미충족 시 stage 미완료
- [ ] `SAZO_VERDICT_FOOTER_ENFORCE` env (warn|block) 동작
- [ ] per-agent override env
- [ ] Reviewer error 3회 → escalation
- [ ] SessionStart expired nonce sweep
- [ ] State 256KB cap + truncation
- [ ] Smoke test 17개 통과
- [ ] CLAUDE.md MANAGED BLOCK 정책 명시 (caller nonce 흐름 + Phase 1/2)
- [ ] review skill SKILL.md에 caller-emitted nonce 흐름 명시
- [ ] Phase 1 → Phase 2 transition 정량 기준 + sazo-workflow stats 출력 (plan 02 dependency)
- [ ] `parse_verdict_footer` awk script — 마지막 envelope만 추출 (multi-envelope/JSONL leak 방어)
- [ ] `verdict_nonce_consume` agent 인자와 nonce.agent 일치 검증
- [ ] `review_expected_set=[]` 동작 명시 (`SAZO_VERDICT_EMPTY_EXPECTED` env) + `verdict_unset_expected_set_count` audit metric
- [ ] State 1MB cap + history 끝 50개 + ci/approval completed entry 우선 보존 (`_maybe_truncate_state`)
- [ ] ENV 명명 일관 (`SAZO_DISABLE_VERDICT_FOOTER_<agent>` 어순)
- [ ] `_handle_post_task_legacy` 명시 정의 (현 handle_post Task 분기 추출)
- [ ] `_record_reviewer_error` 함수 정의 (3회 escalation)

## 14. Dependencies (downstream)

- Plan 02 — `sazo-workflow stats`가 verdict_missing_count 출력 (Phase 2 promotion 기준)
- Plan 09 — slash command detection 일반화 시 같은 mechanism (user-prompt-slash-detect.sh)
- Plan 06 — Phase 1 default ON 시 verdict footer enforce=warn 같이 default
