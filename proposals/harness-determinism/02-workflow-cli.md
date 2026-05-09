# 02. Workflow CLI (status / history / why-blocked) — REVISED v3

**우선순위**: P0
**의존**: audit.log normalize (이 plan 안에 포함), Plan 01 schema v2 (verdict_missing_count 등 신규 필드)
**예상 비용**: 0.7주 (audit.log normalize 추가로 +0.2)
**Revision**: 2026-05-10 (plan-critic v2 5건 BLOCK 반영)

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
# 두 가지 freeform 패턴 공존:
# 1) stage_mark inner (line 275): printf '[%s] %s stage=%s status=%s by=%s reason=%q\n'
# 2) simple_audit / lock_timeout / jq_error (line 92, 174, 195, 216, 237, 272, 456):
#    printf '[%s] event_or_message ...\n'
# timestamp format: $(date +%Y-%m-%dT%H:%M:%S%z) — local TZ + numeric offset (예: 2026-05-10T13:00:00+0900)
```

**변경 — `audit_log()` 함수 신규 (`session-state.sh`에 추가)**:

CRITIC FIX #1 (timestamp mismatch):
기존 freeform entry는 **local TZ + `%z` numeric offset** (`+0900`). 신규 JSON Lines도 **동일 format 유지**해야 timeline 정렬에서 두 형식이 섞여도 lexicographic order로 시간순 보존된다. `+%S%z` (현재) 그대로. UTC `Z` 사용 안 함.

```bash
# Append a single JSON Lines entry to audit.log.
# Args: event sid [stage] [status] [by] [reason]
# All optional fields default to empty string for stable JSON shape.
# Timestamp format MUST match existing freeform entries (%Y-%m-%dT%H:%M:%S%z, local TZ)
# so legacy and new entries sort consistently lexicographically.
audit_log() {
  local event="$1"
  local sid="${2:-}"
  local stage="${3:-}"
  local status="${4:-}"
  local by="${5:-}"
  local reason="${6:-}"
  local ts
  ts=$(date +%Y-%m-%dT%H:%M:%S%z)
  local entry
  entry=$(jq -nc \
    --arg ts "$ts" \
    --arg event "$event" \
    --arg sid "$sid" \
    --arg stage "$stage" \
    --arg status "$status" \
    --arg by "$by" \
    --arg reason "$reason" \
    '{ts:$ts,event:$event,sid:$sid,stage:$stage,status:$status,by:$by,reason:$reason}' 2>/dev/null) \
    || return 0  # jq 실패 시 silent — audit.log 자체는 best-effort
  printf '%s\n' "$entry" >> "$AUDIT_LOG" 2>/dev/null || true
}
```

**Backward compat**:
- 기존 freeform entry 그대로 두기 (마이그레이션 안 함)
- CLI가 parse 시 entry 첫 char(`head -c 1`)가 `{`면 JSON, 아니면 freeform fallback (best-effort 표시 — `ts` 추출 후 raw line 표시)
- 신규 entry부터 JSON Lines

**Block entry 추가** (이전 audit.log엔 block 사유 없음 — plan-critic 지적):

CRITIC FIX #2 (sid scope):
`workflow-state-machine.sh:70-77`의 `hard_block()` 함수는 sid 파라미터 미수신. 그러나 hook script 본체(line 33: `read_hook_payload`)가 `SAZO_SESSION_ID`를 export하고 hook 전체 lifetime에서 access 가능 → `hard_block()` 내부에서 `${SAZO_SESSION_ID:-}` 직접 읽기. 명시 파라미터 추가 불필요.

`workflow-state-machine.sh` 변경 (line 70-77 `hard_block()`, 그리고 soft_warn_or_block의 escalation 분기 line 60-67):

```bash
hard_block() {
    local stage="$1" msg="$2"
    audit_log "stage_block" "${SAZO_SESSION_ID:-}" "$stage" "blocked" "hook" "$msg"
    cat >&2 <<EOF
[workflow-block] stage=$stage 미통과 → $SAZO_TOOL_NAME 차단.
$msg
EOF
    exit 2
}
```

`soft_warn_or_block()` 내부 escalation 분기 (line 60-67, count > threshold)에도 동일 audit_log 호출 추가:
```bash
    audit_log "stage_block" "${SAZO_SESSION_ID:-}" "$stage" "blocked" "hook" "soft_warn_count=$count exceeded threshold $warn_threshold"
    cat >&2 <<EOF
[workflow-block] stage=$stage 미통과 $count회 — $SAZO_TOOL_NAME 차단.
...
```

**event 종류 표준화**:
- `stage_complete` (`stage_mark` 호출 시 추가 — 기존 freeform append는 그대로 두고 JSON Lines entry도 동시 append)
- `stage_skip` (skip stage_mark의 status=skipped variant)
- `stage_block` (PreToolUse hard_block 분기, 신규)
- `lock_timeout` (기존 freeform → `audit_log "lock_timeout" "" "" "" "" "file=..."` 추가, freeform line 92 유지)
- `jq_error` (동일 패턴, freeform line 174/195/216/237/272 유지)
- `verdict_missing`, `verdict_truncated`, `verdict_nonce_invalid`, `verdict_unknown_agent`, `verdict_parse_error`, `verdict_missing_block`, `verdict_missing_warn` (기존 simple_audit → 그대로 freeform 유지; CLI는 freeform parse fallback로 표시. 다음 plan에서 audit_log로 통일.)
- `state_corruption` (plan 05 의존)
- `recovery_acknowledged` (plan 05 의존)

**스코프 한정**: 본 plan에서 audit_log 호출은 **stage_block (hard_block 2 곳, soft_warn_or_block escalation 1 곳) 신규 추가만**. 기존 freeform entry는 호환 layer로 처리, JSON Lines로 마이그레이션은 후속 plan.

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

CRITIC FIX #3 (mtime sort):
원래 plan은 `find ... | xargs basename` 만으로 정렬을 보장한다고 가정. **find 출력은 inode order로 비결정적**. `stat -f '%m %N'` (BSD) / `stat -c '%Y %n'` (GNU) 양쪽 fallback을 사용해 mtime descending sort.

State filename은 `$sid--$cwd_hash.json` (line 56-63). session id 추출은 `--` split 사용.

`$SAZO_SESSION_ID` env 우선. fallback (없을 때):

```bash
# list_active_sessions: 최근 24h 내 mtime을 가진 state file의 session id를 mtime 내림차순 출력.
# stdout: 세션 id 줄 (중복 제거 — 같은 sid가 여러 cwd_hash로 존재 가능).
list_active_sessions() {
  local since_ts now
  now=$(date +%s)
  since_ts=$((now - 86400))  # 24h
  local files
  files=$(find "$STATE_DIR" -maxdepth 1 -name "*--*.json" -type f 2>/dev/null) || return 0
  [ -z "$files" ] && return 0
  # 각 file의 mtime + path를 한 줄에 출력. macOS/Linux 모두 동작.
  local rows=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local mt
    mt=$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null) || continue
    [ -z "$mt" ] && continue
    [ "$mt" -ge "$since_ts" ] || continue
    rows="$rows
$mt $f"
  done <<EOF
$files
EOF
  # mtime descending → session id 추출 (basename 후 '--' 앞부분), 중복 제거 (순서 유지).
  printf '%s\n' "$rows" \
    | sed '/^$/d' \
    | sort -rn -k1,1 \
    | awk '{print $2}' \
    | while IFS= read -r path; do
        local base="${path##*/}"
        printf '%s\n' "${base%%--*}"
      done \
    | awk '!seen[$0]++'
}

resolve_session() {
  local arg="$1"
  if [ -n "$arg" ]; then
    # 명시 session id — 어떤 cwd_hash든 매칭되는 state file 1개라도 있으면 OK
    if ls "$STATE_DIR/${arg}--"*.json >/dev/null 2>&1; then
      printf '%s' "$arg"
      return 0
    fi
    return 2
  fi

  if [ -n "${SAZO_SESSION_ID:-}" ]; then
    printf '%s' "$SAZO_SESSION_ID"
    return 0
  fi

  # fallback: most recent mtime
  local sessions count
  sessions=$(list_active_sessions)
  if [ -z "$sessions" ]; then
    return 2
  fi
  count=$(printf '%s\n' "$sessions" | wc -l | tr -d ' ')

  case "$count" in
    1) printf '%s' "$sessions"; return 0;;
    *)
      echo "Multiple active sessions detected (last 24h):" >&2
      printf '%s\n' "$sessions" | head -5 >&2
      echo "Using most recent (mtime). Specify --session <id> to disambiguate." >&2
      printf '%s' "$sessions" | head -1
      return 0
      ;;
  esac
}
```

**state file path 결정 (resolve 후)**: sid가 결정되어도 cwd_hash가 다수일 수 있음 — multi-worktree 케이스. CLI는 **가장 최근 mtime의 cwd_hash** 자동 선택 + warn (사용자가 cwd 지정 wanted면 `SAZO_CWD=...` 환경변수로 override).

```bash
resolve_state_file() {
  local sid="$1"
  local files
  files=$(ls "$STATE_DIR/${sid}--"*.json 2>/dev/null) || return 1
  [ -z "$files" ] && return 1
  local count
  count=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
  if [ "$count" = "1" ]; then
    printf '%s' "$files"
    return 0
  fi
  # 가장 최근 mtime 선택
  local newest=""
  local newest_mt=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local mt
    mt=$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null)
    [ -z "$mt" ] && continue
    if [ "$mt" -gt "$newest_mt" ]; then
      newest_mt="$mt"
      newest="$f"
    fi
  done <<EOF
$files
EOF
  echo "Multiple state files for session $sid (different cwd). Using newest." >&2
  printf '%s' "$newest"
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

CRITIC FIX #5 (Phase 2 promotion threshold):
Plan 12 (`12-phase2-default-on.md`) 4번 섹션 "Promotion criteria" 명시:
> - 14일 dogfood, 1주 이상 운영
> - state_corruption_count == 0
> - lock_timeout_count < 5 (전체 누적)
> - jq_error_count < 5
> - verdict_unset_expected_set_count < 10

본 plan의 `stats` 출력은 **위 5개 metric을 전부 표시**. `--days N`은 표시 범위 필터일 뿐, promotion 판단은 plan 12 기준대로 **누적 카운트** 기반.

CRITIC FIX (date 호환): macOS BSD `date -v-${days}d` + GNU `date -d "$days days ago"` fallback (현재 plan: 순서가 GNU → BSD라 macOS에서 GNU 시도 실패 후 BSD fallback이 바른 결과 반환. shellcheck/quoting 보강).

```bash
cmd_stats() {
  local days="${1:-30}"

  # 호환 since (UTC 비교는 audit.log entry가 local TZ %z인 점에서 위험 — 동일 format 사용)
  local since
  since=$(date -d "$days days ago" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null) \
    || since=$(date -v"-${days}d" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null) \
    || since=""

  # JSON Lines entry만 대상. freeform은 stats 집계에서 제외 (best-effort).
  local entries
  if [ -n "$since" ]; then
    entries=$(grep -h '^{' "$AUDIT_LOG" 2>/dev/null \
      | jq -c "select(.ts >= \"$since\")" 2>/dev/null) || entries=""
  else
    entries=$(grep -h '^{' "$AUDIT_LOG" 2>/dev/null) || entries=""
  fi

  # 누적 카운트 (Plan 12 promotion criteria 기준 — days 필터와 별도)
  local total_blocks lock_timeouts jq_errors verdict_missing state_corruptions verdict_unset
  total_blocks=$(printf '%s\n' "$entries"   | grep -c '"event":"stage_block"' || true)
  lock_timeouts=$(grep -c 'lock_timeout' "$AUDIT_LOG" 2>/dev/null || echo 0)
  jq_errors=$(grep -c 'jq_error' "$AUDIT_LOG" 2>/dev/null || echo 0)
  verdict_missing=$(grep -c 'verdict_missing' "$AUDIT_LOG" 2>/dev/null || echo 0)
  state_corruptions=$(grep -c 'state_corruption' "$AUDIT_LOG" 2>/dev/null || echo 0)
  # verdict_unset_expected_set_count: 누적 카운터는 state file에 들어있음 (plan 01 schema v2).
  # 모든 state file 합산 (다수 sid).
  verdict_unset=0
  local sf
  for sf in "$STATE_DIR"/*.json; do
    [ -f "$sf" ] || continue
    local v
    v=$(jq -r '.verdict_unset_expected_set_count // 0' "$sf" 2>/dev/null) || v=0
    verdict_unset=$((verdict_unset + v))
  done

  # most blocked stage (days 범위)
  local top_stage
  top_stage=$(printf '%s\n' "$entries" | jq -r 'select(.event=="stage_block") | .stage' 2>/dev/null \
    | sort | uniq -c | sort -rn | head -1 | awk '{print $2 ": " $1}')

  cat <<EOF
Stats (last $days days):
  Total stage_block events: $total_blocks
  Most blocked stage: ${top_stage:-—}

Cumulative (Plan 12 promotion criteria):
  state_corruption_count:        $state_corruptions  (target == 0)
  lock_timeout_count:            $lock_timeouts  (target < 5)
  jq_error_count:                $jq_errors  (target < 5)
  verdict_unset_expected_set:    $verdict_unset  (target < 10)
  verdict_missing_count:         $verdict_missing  (informational)
EOF

  # plan 12 promotion check — 5개 criteria 모두 통과
  if [ "$state_corruptions" -eq 0 ] \
    && [ "$lock_timeouts" -lt 5 ] \
    && [ "$jq_errors" -lt 5 ] \
    && [ "$verdict_unset" -lt 10 ]; then
    echo ""
    echo "[OK] Phase 2 promotion: all numeric criteria met."
    echo "     (Time criteria — 14일 dogfood — manual check)"
  else
    echo ""
    echo "[--] Phase 2 promotion: numeric criteria NOT met yet."
  fi

  # 분석 데이터 0개 (audit.log 비어 있음) → exit 2
  if [ -z "$entries" ] && [ "$lock_timeouts" -eq 0 ] && [ "$jq_errors" -eq 0 ]; then
    return 2
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

## 10. Test plan (mock-only fixture, plan 05 의존 제거)

CRITIC FIX #4: 원래 test 15는 `recover` 검증인데 plan 05 미구현. 본 plan에서는 `recover` 서브커맨드를 **stub으로 구현** (degraded mode marker file 부재 시 "no degraded state to recover" 출력 후 exit 2). plan 05 구현 시 logic 보강. test 15는 stub 동작만 검증 — 의존 제거.

`workflow-cli.smoke.sh` (17개):

1. 빈 STATE_DIR → `status` exit 2 (no session)
2. Mock state.json 1개 → `status` 핵심 필드 표시 (Stage / Plan approved / CI passed / Soft warn counts / Verdict missing)
3. `history --last 5` → 5개 entry, 시간순
4. JSON Lines block entry 1개 + audit.log → `why-blocked` exit 2 + 사유 + 권장 action
5. block entry 0 → `why-blocked` exit 0 "Not blocked"
6. `audit --filter stage_block` → 해당 event만 출력
7. `sessions --days 7` → mtime 기준 mock 2개 세션 모두 표시 (정렬: 최신 먼저)
8. `--json` flag — 모든 cmd JSON valid (`jq -e .` 통과)
9. `SAZO_STATE_DIR` override → 다른 dir의 state도 읽힘
10. `$SAZO_SESSION_ID` 미설정 + 다수 세션 → most recent 사용 + warn stderr
11. 명시 `--session bogus` + 미존재 → exit 2
12. Legacy freeform audit.log entry + JSON Lines 혼재 → audit cmd가 양쪽 표시 (JSON은 parsed, freeform은 raw)
13. `install.sh` mock run → `~/.local/bin/sazo-workflow` symlink 생성/멱등 update (재실행 시 노변동)
14. PATH 미등록 시 install/sync 함수 stderr warn
15. `recover` stub: degraded marker 없으면 exit 2 "no degraded state" (plan 05 미구현 환경에서 통과)
16. `stats --days 30` mock audit.log → Plan 12 5개 criteria 모두 표시 + promotion verdict 출력
17. macOS BSD vs GNU `date` 양쪽: `date -v-30d` 시도 후 `date -d "30 days ago"` fallback chain 검증 (PATH에 GNU date 없는 환경 시뮬)

**Fixture 전략**:
- 모든 테스트는 `mktemp -d`로 isolated `SAZO_STATE_DIR` 생성, `trap` cleanup.
- mock state.json은 `jq -n` 으로 구성. `schema_version`, `verdict_missing_count`, `soft_warn_count_*`, `last_verdicts.review.code-reviewer.verdict` 같은 필드 포함 — Plan 01 schema v2 의존.
- audit.log는 `printf` 로 직접 작성. JSON Lines 한 줄당 entry (jq compact).
- install/PATH 테스트(13, 14)는 `HOME=$(mktemp -d)`로 fakehome → symlink 검증.
- date 테스트(17)는 `PATH=/tmp/fakebin:$PATH` 으로 `date` shim 흉내 — 어렵다면 양쪽 명령 직접 호출하여 둘 다 valid output 반환하는지만 확인 (lenient).

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
