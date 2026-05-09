# 02. Workflow CLI (status / history / why-blocked) — REVISED

**우선순위**: P0
**의존**: audit.log normalize (이 plan 안에 포함)
**예상 비용**: 0.7주 (audit.log normalize 추가로 +0.2)
**Revision**: 2026-05-09 (plan-critic 피드백 반영)

## 목표

Stage state와 audit.log를 사용자가 사후 조회 가능한 CLI 추가. Phase 2 default ON 의 dogfood data 분석 enabler. plan 01 (verdict footer)의 promotion metric 출력.

## Revision 핵심 변경

| 원래 미정 | 결정 |
|---|---|
| audit.log 형식 | JSON Lines로 normalize (이 plan에 포함) |
| install 위치 | `~/.local/bin/sazo-workflow` symlink |
| why-blocked 데이터 출처 | block hook이 audit.log에 entry 추가 (workflow-state-machine.sh 수정) |
| exit code 정책 | 서브커맨드별 명시 표 |
| multi-session fallback | 명시: warn 출력 + active session 후보 list |

## 1. audit.log JSON Lines 마이그레이션

**현재** (`session-state.sh:22`):
```
AUDIT_LOG="$STATE_DIR/audit.log"
# printf '[%s] sid=%s stage=%s status=%s by=%s reason=%q\n' (freeform)
```

**변경**:
```bash
audit_log() {
  local event="$1" sid="$2" stage="$3" status="$4" by="$5" reason="$6"
  local entry
  entry=$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg event "$event" \
    --arg sid "$sid" \
    --arg stage "$stage" \
    --arg status "$status" \
    --arg by "$by" \
    --arg reason "$reason" \
    '{ts:$ts,event:$event,sid:$sid,stage:$stage,status:$status,by:$by,reason:$reason}')
  printf '%s\n' "$entry" >> "$AUDIT_LOG"
}
```

**Backward compat**:
- 기존 freeform entry 그대로 두기 (마이그레이션 안 함)
- CLI가 parse 시 `head -c 1`이 `{`면 JSON, else freeform fallback (best-effort 표시)
- 신규 entry부터 JSON Lines

**Block entry 추가** (이전 audit.log엔 block 사유 없음 — plan-critic 지적):

`workflow-state-machine.sh` 의 hard block 분기 (예: line 282-340 영역) 마다:
```bash
audit_log "stage_block" "$sid" "$stage" "blocked" "hook" "stage_not_passed: $stage"
echo "..." >&2
exit 2
```

**event 종류 표준화**:
- `stage_complete` (기존 stage_mark 동작)
- `stage_skip` (skip 기록)
- `stage_block` (PreToolUse block, 신규)
- `lock_timeout`
- `jq_error`
- `verdict_missing`, `verdict_truncated`, `verdict_nonce_invalid` (plan 01)
- `state_corruption` (plan 05)
- `recovery_acknowledged` (plan 05)

## 2. CLI 스크립트 위치 + install

**Install path**: `~/.local/bin/sazo-workflow` (PATH 등록 가정).

`install.sh` / `auto-update.sh` 수정:

```bash
# packages/ai-harness/install.sh 또는 auto-update.sh sync_workflow_cli()
sync_workflow_cli() {
  local target="$HOME/.local/bin/sazo-workflow"
  local source="$REPO_DIR/packages/ai-harness/scripts/sazo-workflow.sh"

  mkdir -p "$HOME/.local/bin"

  # 멱등 symlink
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
    return 0  # 이미 정확히 link됨
  fi

  if [ -e "$target" ] && [ ! -L "$target" ]; then
    # 일반 파일이면 충돌 — 사용자 안내
    echo "Warning: $target exists but is not a symlink. Skipping CLI install." >&2
    return 1
  fi

  ln -sfn "$source" "$target"
}
```

**PATH 검증**: `~/.local/bin` PATH 안에 없으면 install 시 경고 + `~/.zshrc` 추가 안내 (자동 수정 안 함, 사용자 동의 필요).

## 3. CLI 서브커맨드 (exit code 정책 명시)

| 서브커맨드 | 동작 | exit 0 | exit 1 | exit 2 |
|---|---|---|---|---|
| `status [--session <id>]` | 현재 상태 출력 | 정상 | 에러 | session 없음 |
| `history [--last N] [--session <id>]` | history timeline | 정상 | 에러 | session 없음 |
| `why-blocked` | 차단 사유 조회 | not blocked | 에러 | blocked (사유 출력 후) |
| `audit [--last N] [--filter <event>]` | audit.log 조회 | 정상 | 에러 | log 없음 |
| `sessions [--days N]` | 세션 list | 정상 | 에러 | 세션 0개 |
| `stats [--days N]` | aggregation | 정상 | 에러 | 분석 가능 데이터 없음 |
| `recover` | degraded mode reset (plan 05) | 정상 | 에러 | 이미 정상 |

**`--json` 플래그**: 모든 서브커맨드 지원, JSON 출력. 동일 exit code.

## 4. why-blocked 동작

audit.log에서 가장 최근 `event=stage_block` entry 추출:

```bash
why_blocked() {
  local last_block
  last_block=$(grep '"event":"stage_block"' "$AUDIT_LOG" | tail -1)

  if [ -z "$last_block" ]; then
    echo "Not blocked."
    return 0
  fi

  local stage reason ts
  stage=$(echo "$last_block" | jq -r '.stage')
  reason=$(echo "$last_block" | jq -r '.reason')
  ts=$(echo "$last_block" | jq -r '.ts')

  echo "Blocked at stage: $stage"
  echo "Time: $ts"
  echo "Reason: $reason"
  echo ""
  case "$stage" in
    research)
      echo "To proceed: invoke code-searcher or docs-researcher subagent (Task)."
      ;;
    plan)
      echo "To proceed: invoke plan-drafter subagent (Task) and produce a plan."
      ;;
    approval)
      echo "To proceed: get user approval, user types '/approved'."
      ;;
    ci)
      echo "To proceed: run project CI command (per CLAUDE.md) until exit 0."
      ;;
    review)
      echo "To proceed: invoke code-reviewer (and architect-advisor if needed) Task with verdict APPROVE."
      ;;
  esac
  return 2
}
```

## 5. Multi-session 처리 (명시)

`$SAZO_SESSION_ID` env 우선. fallback (없을 때):

```bash
list_active_sessions() {
  # mtime 기준 최근 24h 세션
  find "$STATE_DIR" -name "*.json" -mtime -1 -type f 2>/dev/null \
    | xargs -I {} basename {} .json 2>/dev/null
}

resolve_session() {
  local arg="$1"
  if [ -n "$arg" ]; then
    # 명시 session id
    if [ -f "$STATE_DIR/${arg}.json" ]; then
      printf '%s' "$arg"
      return 0
    fi
    return 2
  fi

  if [ -n "$SAZO_SESSION_ID" ]; then
    printf '%s' "$SAZO_SESSION_ID"
    return 0
  fi

  # fallback: most recent
  local sessions
  sessions=$(list_active_sessions)
  local count
  count=$(echo "$sessions" | wc -l | xargs)

  case "$count" in
    0) return 2;;  # session 없음
    1) printf '%s' "$sessions"; return 0;;
    *)
      # 다수 → warn + 선택 안내 (CLI 자체는 가장 최근 mtime 사용)
      echo "Multiple active sessions detected (last 24h):" >&2
      echo "$sessions" | head -5 >&2
      echo "Using most recent. Specify --session <id> to disambiguate." >&2
      printf '%s' "$sessions" | head -1
      return 0
      ;;
  esac
}
```

## 6. status 서브커맨드 (dynamic key 처리)

`soft_warn_count_*` 같은 동적 key 처리 (plan-critic 지적):

```bash
cmd_status() {
  local sid; sid=$(resolve_session "$1") || return $?
  local state; state=$(cat "$STATE_DIR/${sid}.json")

  echo "Session: $sid"
  echo "Stage: $(echo "$state" | jq -r '.stage')"
  echo "Plan approved at: $(echo "$state" | jq -r '.plan_approved_at // "—"')"
  echo "CI passed at: $(echo "$state" | jq -r '.ci_passed_at // "—"')"
  echo ""
  echo "History (last 10):"
  echo "$state" | jq -r '.history[-10:][] | "  \(.ts) \(.stage) \(.status) by=\(.by) \(.reason)"'
  echo ""
  echo "Soft warn counts:"
  echo "$state" | jq -r '. | to_entries[] | select(.key | startswith("soft_warn_count_")) | "  \(.key | sub("soft_warn_count_"; "")): \(.value)"'

  # plan 01 verdict 미스 카운트
  echo ""
  echo "Verdict missing counts:"
  echo "$state" | jq -r '.verdict_missing_count // {} | to_entries[] | "  \(.key): \(.value)"'

  echo ""
  echo "Active reviewers expected:"
  echo "$state" | jq -r '.review_expected_set // [] | join(", ")'

  return 0
}
```

## 7. stats 서브커맨드 (Phase 2 promotion data)

```bash
cmd_stats() {
  local days="${1:-30}"

  # audit.log JSON Lines 분석
  local since
  since=$(date -u -d "$days days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-${days}d +%Y-%m-%dT%H:%M:%SZ)  # macOS fallback

  local entries
  entries=$(grep -h '^{' "$AUDIT_LOG" | jq -c "select(.ts >= \"$since\")")

  local total_blocks lock_timeouts jq_errors verdict_missing state_corruptions
  total_blocks=$(echo "$entries" | grep -c '"event":"stage_block"')
  lock_timeouts=$(echo "$entries" | grep -c '"event":"lock_timeout"')
  jq_errors=$(echo "$entries" | grep -c '"event":"jq_error"')
  verdict_missing=$(echo "$entries" | grep -c '"event":"verdict_missing"')
  state_corruptions=$(echo "$entries" | grep -c '"event":"state_corruption"')

  # most blocked stage
  local top_stage
  top_stage=$(echo "$entries" | jq -r 'select(.event=="stage_block") | .stage' | sort | uniq -c | sort -rn | head -1)

  echo "Stats (last $days days):"
  echo "  Total blocks: $total_blocks"
  echo "  Lock timeouts: $lock_timeouts"
  echo "  JQ errors: $jq_errors"
  echo "  Verdict missing: $verdict_missing"
  echo "  State corruptions: $state_corruptions"
  echo "  Most blocked stage: $top_stage"

  # plan 12 promotion check
  if [ "$state_corruptions" -eq 0 ] && [ "$lock_timeouts" -lt 5 ]; then
    echo ""
    echo "✓ Phase 2 promotion criteria met (no corruption, lock timeouts < 5)"
  fi

  return 0
}
```

## 8. 변경 파일

```
packages/ai-harness/scripts/sazo-workflow.sh                    (신규, 메인 CLI dispatcher)
packages/ai-harness/scripts/lib/workflow-cli/                   (신규 dir)
  status.sh, history.sh, why-blocked.sh, audit.sh, sessions.sh, stats.sh
packages/ai-harness/scripts/hooks/lib/session-state.sh          (audit_log JSON Lines 함수)
packages/ai-harness/scripts/hooks/workflow-state-machine.sh     (block 시 audit_log 호출 추가)
packages/ai-harness/install.sh, scripts/auto-update.sh          (sync_workflow_cli)
packages/ai-harness/scripts/tests/lib/test-helpers.sh           (00-spike 결과)
packages/ai-harness/scripts/tests/workflow-cli.smoke.sh         (신규)
packages/ai-harness/docs/workflow-cli.md                        (신규)
~/.claude/CLAUDE.md MANAGED BLOCK                               ("막혔을 때 sazo-workflow why-blocked")
```

## 9. State schema 변경

없음. 기존 state.json + audit.log 읽기 + audit.log 형식만 마이그레이션.

## 10. Test plan (test-helpers.sh source)

`workflow-cli.smoke.sh`:

1. 빈 STATE_DIR → `status` exit 2
2. Mock state.json 1개 → `status` 모든 필드 표시
3. `history --last 5` → 5개 entry
4. block entry 1개 + audit.log → `why-blocked` exit 2 + 사유
5. block entry 0 → `why-blocked` "Not blocked" exit 0
6. `audit --filter stage_block` → JSON Lines 필터
7. `sessions --days 7` → list
8. `--json` flag — 모든 cmd JSON 유효
9. `SAZO_STATE_DIR` override 동작 (`session-state.sh:22`에서 이미 지원 확인됨)
10. `$SAZO_SESSION_ID` 미설정 + 다수 세션 → most recent 사용 + warn
11. 명시 `--session <id>` + 미존재 → exit 2
12. Legacy freeform audit.log entry + JSON Lines 혼재 → JSON만 parse, freeform skip
13. install — `~/.local/bin/sazo-workflow` symlink 생성/멱등 update
14. PATH 미등록 시 install warn
15. `recover` (plan 05 의존, integration test)
16. `stats --days 30` — Phase 2 criteria 평가
17. macOS BSD `date` 호환 (`date -v` fallback)

## 11. 변경된 Open questions (모두 closed)

- ~~install 위치~~ → `~/.local/bin/sazo-workflow` symlink
- ~~audit.log format~~ → JSON Lines (마이그레이션 포함)
- ~~stale session cleanup~~ → out-of-scope (별도 plan, 수동 cleanup OK)
- ~~multi-host sync~~ → out-of-scope

## 12. Risk

- **R1 (med)**: audit.log normalize 시 기존 entry 호환 layer 복잡. 완화: best-effort freeform parse, 신규부터 JSON.
- **R2 (low)**: PATH 미등록 사용자 (claude-notify 같은 패턴 따라 안내).
- **R3 (low)**: macOS vs Linux `date` 차이. 완화: 양쪽 fallback.

## 13. Rollback

- `~/.local/bin/sazo-workflow` symlink 제거 (또는 PATH 제거)
- audit.log JSON Lines 신규 entry는 freeform fallback parser가 동작 안 하지만 기존 freeform entry는 영향 없음 (forward 호환만)

## 14. Acceptance criteria

- [ ] 7개 서브커맨드 (status/history/why-blocked/audit/sessions/stats/recover) 동작
- [ ] 각 서브커맨드 exit code 정책 표대로
- [ ] `--json` 모든 cmd JSON 유효
- [ ] `audit_log` 함수 (`session-state.sh`) JSON Lines 출력
- [ ] `workflow-state-machine.sh` 모든 hard block 지점에 `audit_log "stage_block"` 호출
- [ ] `~/.local/bin/sazo-workflow` symlink (auto-update.sh 멱등 sync)
- [ ] PATH 미등록 시 warn (자동 수정 안 함)
- [ ] Multi-session 다수 시 warn + most recent 사용
- [ ] Legacy freeform audit.log entry 호환 (best-effort 표시)
- [ ] macOS / Linux `date` 양쪽 동작
- [ ] Smoke test 17개 통과
- [ ] CLAUDE.md 정책 + sazo-workflow 안내

## 15. Dependencies

- `test-helpers.sh` (00-spike 결과) — Q6 패턴 사용
- Plan 01 — verdict_missing_count 출력
- Plan 05 — `recover` 서브커맨드, state_corruption event
- Plan 12 — Phase 2 promotion criteria 측정 (`stats`)
