# 05. Hook Circuit Breaker (Degraded Mode) — REVISED

**우선순위**: P1
**의존**: 02 (audit_log JSON Lines 함수, recover 서브커맨드)
**예상 비용**: 0.5주
**Revision**: 2026-05-09 (plan-critic 피드백 반영)

## 목표

Hook 자체가 실패(jq missing, lock timeout, state corruption)할 때 silent fail 대신 명시적 degraded mode로 전환.

## Revision 핵심 변경

| 원래 미정 | 결정 |
|---|---|
| jq 없는 상태에서 카운터 어떻게? | 별도 simple file 카운터 (`degraded_marker`) |
| Rolling window 측정 | timestamps 배열 + 1시간 cap, 50개 제한 |
| Critical hook list | worktree, ci, review만 fail-open. approval은 fail-closed (위험성 차이 큼) |
| `state_corruption` 정의 | jq parse 실패 또는 schema_version mismatch |
| `/harness-degraded-ack` vs sazo-workflow recover 중복 | recover 단일 (plan 02 dependency) |
| SessionStart self-check 시간 | sync 동작이라 100ms target 보장 어려움 — async 백그라운드 spawn |

## 1. Failure event 정의

| Event | 정의 | Detect 위치 |
|---|---|---|
| `lock_timeout` | `_with_lock` rc=99 | `session-state.sh:90-94` 기존 |
| `jq_error` | jq 호출 실패 (exit code != 0) | `session-state.sh:162-168` 기존 |
| `state_corruption` | (a) state.json jq parse 실패 (b) `schema_version` 필드 불일치 | `state_init`, `state_get` 진입 시 |
| `hook_script_error` | hook 자체 unexpected exit (trap ERR) | 모든 hook entry — `trap '...' ERR` |

## 2. 카운터 저장 (jq 없을 때 fallback)

**문제**: jq missing → state.json 못 읽음 → 카운터 못 씀.

**해결**: 별도 simple text 파일 사용 — `~/.claude/session-state/degraded.lock` 와 `degraded.events`.

```
~/.claude/session-state/
├── degraded.lock          # 존재하면 degraded mode (mkdir 기반 marker)
└── degraded.events        # 1줄=1 event timestamp + type, jq 안 씀
```

`degraded.events` 형식 (text only, jq 불필요):
```
2026-05-09T10:00:00Z lock_timeout
2026-05-09T10:01:00Z jq_error
...
```

**카운터 함수**:

```bash
record_degraded_event() {
  local event_type="$1"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s %s\n' "$now" "$event_type" >> "$STATE_DIR/degraded.events"
  # 1시간 이전 entry trim (best-effort, jq 불필요)
  _trim_degraded_events
  _check_degraded_threshold "$event_type"
}

_trim_degraded_events() {
  local f="$STATE_DIR/degraded.events"
  [ -f "$f" ] || return 0
  local cutoff
  cutoff=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)
  awk -v cutoff="$cutoff" '$1 >= cutoff' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

_check_degraded_threshold() {
  local event_type="$1"
  local count
  case "$event_type" in
    lock_timeout)
      count=$(grep -c lock_timeout "$STATE_DIR/degraded.events" 2>/dev/null || echo 0)
      [ "$count" -ge "${SAZO_LOCK_TIMEOUT_THRESHOLD:-5}" ] && enter_degraded "lock_timeout_threshold"
      ;;
    jq_error)
      count=$(grep -c jq_error "$STATE_DIR/degraded.events" 2>/dev/null || echo 0)
      [ "$count" -ge "${SAZO_JQ_ERROR_THRESHOLD:-3}" ] && enter_degraded "jq_error_threshold"
      ;;
    state_corruption)
      enter_degraded "state_corruption"  # 즉시
      ;;
  esac
}

enter_degraded() {
  local reason="$1"
  if mkdir "$STATE_DIR/degraded.lock" 2>/dev/null; then
    # 처음 진입
    printf '%s\n' "$reason" > "$STATE_DIR/degraded.lock/reason"
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_DIR/degraded.lock/since"
    # audit_log은 jq 의존 — best-effort만
    audit_log "degraded_enter" "" "" "" "hook" "$reason" 2>/dev/null || true
  fi
}

is_degraded() {
  [ -d "$STATE_DIR/degraded.lock" ]
}
```

## 3. Critical hook 분류 (확정)

| Hook | Degraded mode 동작 |
|---|---|
| `pre-worktree-gate.sh` | **Fail-open** (warn but pass) — block이 사용자 즉시 막음, false positive 비용 큼 |
| `pre-commit-lint.sh` | **Fail-open** — autofix 안 되도 commit 진행, 사용자 인지 가능 |
| `pre-exploration-gate.sh` | **Fail-open** — 단순 경고만 사라짐 |
| `user-prompt-approval-detect.sh` | **Fail-open** — nonce 발급 안 되면 사용자가 인지 |
| `workflow-state-machine.sh` (broad) | **Fail-open** — degraded는 임시, recovery 강제 |
| ~~approval stage~~ | (state-machine 안 분기, 그래서 별도 정책 X) |

**결정**: 모든 hook fail-open in degraded. 단, 매 hook 진입 시 stderr에 명시 경고 (1회/세션).

이유: degraded는 환경 문제 (jq 없음, lock dir 부서짐 등). 차단 의미 없음. 사용자에게 **명시적**으로 알리고 회복 요구.

## 4. SessionStart self-check (async)

**문제**: SessionStart hook은 동기 — `auto-update.sh`가 사용자 첫 응답 대기시킴.

**해결**: self-check를 백그라운드 disown:

```bash
# auto-update.sh
sazo_self_check() {
  (
    # 별도 프로세스, 백그라운드
    if ! command -v jq >/dev/null 2>&1; then
      record_degraded_event state_corruption
      enter_degraded "jq_missing"
    fi
    # state dir 쓰기 권한
    if [ ! -w "$STATE_DIR" ] && ! mkdir -p "$STATE_DIR" 2>/dev/null; then
      record_degraded_event state_corruption
      enter_degraded "state_dir_unwritable"
    fi
  ) </dev/null >/dev/null 2>&1 &
  disown
}
```

100ms 보장 — disown으로 즉시 return.

## 5. Degraded 진입 시 사용자 안내

각 hook entry 첫줄:

```bash
if is_degraded; then
  # 세션당 1회 stderr (state.json에 marker)
  if state_get "$sid" ".degraded_warned" "$cwd" | grep -qv true; then
    cat >&2 <<EOF
⚠️  HARNESS DEGRADED MODE
Reason: $(cat "$STATE_DIR/degraded.lock/reason" 2>/dev/null)
Since: $(cat "$STATE_DIR/degraded.lock/since" 2>/dev/null)
Recover: sazo-workflow recover --reason "<your fix>"
All workflow gates currently warn-only.
EOF
    state_set_str "$sid" ".degraded_warned" "true" "$cwd"
  fi
  # fail-open: 모든 hook이 그대로 진행 (warn만)
  exit 0
fi
```

## 6. Recovery (`sazo-workflow recover`)

plan 02의 서브커맨드:

```bash
cmd_recover() {
  local reason="$1"
  if [ -z "$reason" ]; then
    echo "Usage: sazo-workflow recover --reason \"<your fix description>\"" >&2
    return 1
  fi

  if ! is_degraded; then
    echo "Not in degraded mode."
    return 2
  fi

  rm -rf "$STATE_DIR/degraded.lock"
  rm -f "$STATE_DIR/degraded.events"
  audit_log "recovery_acknowledged" "" "" "" "user" "$reason" 2>/dev/null || true

  echo "Recovery acknowledged. Reason: $reason"
  echo "Hooks fully active again."
  return 0
}
```

자동 recovery 안 함. 사용자가 환경 (jq install 등) 직접 수정 후 명시 명령.

## 7. `_state_init_inner` 추가 필드

기존 jq -n literal에 `degraded_warned: false` 1개 추가 (per-session marker):

```jq
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
    degraded_warned: false      // 신규
  }'
```

(주의: `schema_version: 2` 추가 — 기존 1과 구분, mismatch 시 state_corruption event 발생.)

## 8. 변경 파일

```
packages/ai-harness/scripts/hooks/lib/session-state.sh    (record_degraded_event, _trim_degraded_events, _check_degraded_threshold, enter_degraded, is_degraded, schema_version mismatch detect)
packages/ai-harness/scripts/hooks/workflow-state-machine.sh    (각 hook entry에 is_degraded check)
packages/ai-harness/scripts/hooks/pre-worktree-gate.sh         (is_degraded check)
packages/ai-harness/scripts/hooks/pre-commit-lint.sh           (is_degraded check)
packages/ai-harness/scripts/hooks/pre-exploration-gate.sh      (is_degraded check)
packages/ai-harness/scripts/hooks/user-prompt-approval-detect.sh  (is_degraded check)
packages/ai-harness/scripts/auto-update.sh                     (sazo_self_check async)
packages/ai-harness/scripts/sazo-workflow.sh                   (recover 서브커맨드 — plan 02)
packages/ai-harness/scripts/tests/circuit-breaker.smoke.sh     (신규)
packages/ai-harness/scripts/tests/lib/test-helpers.sh          (00-spike)
~/.claude/CLAUDE.md MANAGED BLOCK                              (degraded mode 정책)
```

## 9. State schema

기존 + `degraded_warned: false` per-session field. degraded.lock/events는 state.json 외부 파일.

`schema_version: 2`로 bump. 기존 1인 state.json은:
- `state_init`이 보면 mismatch detect → record_degraded_event "state_corruption" → enter_degraded
- 또는: 자동 마이그레이션 (1→2 upgrade jq script). 보수적 선택 = state_corruption.

## 10. Test plan (test-helpers.sh source)

`circuit-breaker.smoke.sh`:

1. lock_timeout × 5회 → degraded 진입 (`degraded.lock` dir 생성)
2. jq_error × 3회 → degraded
3. state_corruption × 1회 (schema_version mismatch fixture) → 즉시 degraded
4. degraded 진입 시 hook entry stderr 경고 (1회/세션)
5. `sazo-workflow recover --reason "fixed jq"` → degraded 해제
6. SessionStart self-check 백그라운드 동작 확인 (foreground 100ms 이내)
7. jq missing 시뮬 (PATH 조작) → state_corruption 진입
8. state_dir 쓰기 권한 없음 시뮬 → degraded
9. degraded mode에서 모든 narrow hook fail-open 확인
10. degraded mode에서 broad workflow-state-machine fail-open 확인
11. `degraded.events` 1시간 cutoff trim 동작
12. 1시간 cutoff 외부 entry는 카운트 안 됨
13. SessionStart 시 state.json schema_version=1 → 마이그레이션 또는 state_corruption (선택)
14. `is_degraded` 함수 — `degraded.lock` dir 존재 여부

## 11. Open questions (closed)

- ~~jq 없을 때 카운터?~~ → text 파일 (degraded.events)
- ~~rolling window?~~ → 1시간, awk trim, no 절대 cap (자동 trim)
- ~~critical hook list?~~ → 모두 fail-open (이유: degraded는 일시 환경 문제)
- ~~중복 recover?~~ → sazo-workflow recover 단일 (plan 02)
- ~~self-check 100ms?~~ → async disown
- ~~state corruption 정의?~~ → schema_version mismatch + jq parse fail
- ~~recovery counter reset?~~ → events 파일 삭제 (audit log에 recovery_acknowledged event 보존)

## 12. Risk

- **R1 (med)**: 모든 hook fail-open이 결정성 일시 상실. 의도된 trade-off — degraded 알림이 사용자 압력.
- **R2 (med)**: false positive degraded → 사용자 frustration. 완화: 임계값 보수적, env 조정 가능.
- **R3 (low)**: text 파일 race (concurrent append). 완화: append-only로 race 안전.
- **R4 (low)**: schema_version 마이그레이션 미정 → state_corruption 빈발. 완화: phase 1에서 1→2 자동 upgrade jq, phase 2에서 state_corruption 강제.

## 13. Rollback

- `SAZO_DISABLE_CIRCUIT_BREAKER=1` env → record/check 모두 skip
- `degraded.lock`, `degraded.events` 파일 수동 삭제 → 즉시 정상
- schema_version 2→1 downgrade 스크립트 (필요 시)

## 14. Acceptance criteria

- [ ] `record_degraded_event`, `enter_degraded`, `is_degraded` 함수 (jq 의존 없음)
- [ ] `degraded.lock` dir + `degraded.events` 파일 운영
- [ ] 3가지 failure 카운터 + 임계값 진입 (env 조정 가능)
- [ ] degraded 시 hook entry stderr 경고 (세션당 1회)
- [ ] SessionStart self-check async (disown)
- [ ] `schema_version: 2` 추가 + mismatch detect
- [ ] `sazo-workflow recover` 동작 (plan 02 dependency)
- [ ] 모든 hook degraded 시 fail-open
- [ ] Smoke test 14개 통과
- [ ] CLAUDE.md degraded mode 정책 명시
- [ ] env 4개 (`SAZO_DISABLE_CIRCUIT_BREAKER`, `SAZO_LOCK_TIMEOUT_THRESHOLD`, `SAZO_JQ_ERROR_THRESHOLD`, `SAZO_STATE_DIR`) 동작

## 15. Dependencies

- Plan 02 — `sazo-workflow recover` 서브커맨드 + audit_log JSON Lines 함수
- 00-spike — test-helpers.sh
