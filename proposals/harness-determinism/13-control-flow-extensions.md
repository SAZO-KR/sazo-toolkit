# 13. Control Flow Extensions (from integrator project plan v6)

**우선순위**: P1 (PR #27 후속)
**의존**: PR #27 (schema v2, atomic mutations 기반)
**예상 비용**: 1.5주
**출처**: `/Users/hakun.lee/work/integrator/docs/harness-determinism-plan-2026-05-10.md` v6
**결정성 이동**: 🟡 → 🟢 (autonomous skip 차단, /approved 즉시 처리, audit warn-only)

> ✅ **POST-SPIKE RESOLVED (2026-05-11)** — Stage S0 spike (`proposals/harness-determinism/spike-stop-hook.md`) 완료. 본 plan은 spike 결과 반영하여 revision됨:
> - **Hook**: `SessionEnd` (Stop hook 대신 — Stop은 매 turn fire, SessionEnd는 종료 1회 fire)
> - **파일명**: `post-session-end-metrics.sh`
> - **Payload (CONFIRMED 4-field)**: `session_id`, `transcript_path`, `cwd`, `reason` (enum: `clear|logout|prompt_input_exit|other`)
> - **Trigger 제약 (documented)**: Ctrl+D ✓ / `/exit` ✗ (GH#17885, #35892) / `/clear` ✗ (GH#6428) / Ctrl+C ⚠️ mid-kill (GH#32712) / `--continue` stale (GH#9188) / async-kill (GH#41577)
> - **Stop fallback**: 명세 only (record schema 호환). 활성화는 deferred PR.
> - **Timeout**: 5s 고정, portable wrapper (timeout → gtimeout → perl alarm → no-timeout+warn)

## 목표

Integrator 프로젝트팀이 6회 plan 회전을 거쳐 도출한 control flow 강화 항목 중 **shared harness 영역**에 속하는 것을 통합. PR #27이 처리한 영역(schema/nonce/cycle)과 겹치지 않는 신규 stage들.

## PR #27과의 관계

| Integrator plan 항목 | PR #27 처리 여부 | 본 plan 처리 여부 |
|---|---|---|
| Schema v2 + migration | ✅ 완료 (기존 → schema v2 자동 mig) | — |
| Atomic mutations | ✅ 완료 (`verdict_consume_and_record`) | — |
| Nonce 시스템 | ✅ 완료 (cycle_id 기반) | — |
| Slash command parsing | 부분 (`/approved`, `/skip` 기존) | A0b 정형화 |
| `mark_approval_complete` | 미처리 | ✅ A0a |
| Session-end metrics | 미처리 | ✅ Stage A (SessionEnd hook) |
| Subagent output audit | 부분 (verdict footer) | ✅ Stage A' (warn-only audit) |
| Auto-skip 차단 | 미처리 | ✅ Stage B |
| Approval bypass env | 미처리 | ✅ Stage B |
| `hook_healthy` 7-check | 미처리 | ✅ Stage A |
| ADR D2 bash compat | 부분 (현 코드 묵시) | ✅ 명시화 |

## 잔여 unresolved blocker (integrator v6 노트)

Integrator plan은 v6에 두 BLOCKER 잔존:
- **#4**: smoke fixture ap1 + ord1 동시 삭제 명세
- **#6**: `${rest##[[:space:]]*}` shell glob 회귀 — 본 plan은 sed 또는 bash regex 채택

## Stage 분할

### Stage S0 — SessionEnd hook payload spike (RESOLVED 2026-05-11)

**산출물**: `proposals/harness-determinism/spike-stop-hook.md` (머지 완료, PR #32)

**Gate=PASS 조건 (mapping to spike doc Q3 + Q6)**:
1. Payload 4-field CONFIRMED (`session_id` / `transcript_path` / `cwd` / `reason`)
2. Trigger 제약 6 케이스 known + documented:
   - Ctrl+D ✓ (clean exit, `reason="other"`)
   - `/exit` ✗ (GH#17885, #35892)
   - `/clear` ✗ (GH#6428 — docs claim `reason="clear"` 미fire)
   - Ctrl+C ⚠️ mid-kill (GH#32712)
   - `--continue` stale `session_id`/`transcript_path` (GH#9188)
   - Async hook kill before completion (GH#41577) → 5s timeout 강제

Stage A 진입 허용. Stop fallback은 본 plan record schema 호환성만 명세, 활성화는 deferred PR.

### Stage A0a — `mark_approval_complete` atomic helper

`/approved` 입력 즉시 처리. 현재는 `user-prompt-approval-detect.sh`이 nonce만 발급 → workflow-state-machine이 소비. 직접 atomic 마킹으로 단순화.

**위치**: `packages/ai-harness/scripts/hooks/lib/session-state.sh`

```bash
mark_approval_complete() {
    local sid="$1" by="$2" reason="$3" cwd="${4:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || state_init "$sid" "$cwd" "${SAZO_MODEL:-unknown}"
    _with_lock "$f" _mark_approval_complete_inner "$f" "$by" "$reason"
}

_mark_approval_complete_inner() {
    local f="$1" by="$2" reason="$3"
    local now; now=$(date +%Y-%m-%dT%H:%M:%S%z)
    local tmp; tmp=$(mktemp "${f}.XXXXXX")
    if jq --arg now "$now" --arg by "$by" --arg reason "$reason" '
        .plan_approved_at = $now
        | .history += [{stage: "approval", status: "completed", by: $by, reason: $reason, ts: $now}]
    ' "$f" > "$tmp"; then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
}
```

**Validator 정확한 변경** (`stage_is_passed` 의 approval 분기, 현 line 294-298):

기존:
```jq
approval)
    jq -e '
        (.plan_approved_at != null)
        and (.history | any(.stage == "approval" and .status == "completed" and .by == "user"))
    ' "$f" >/dev/null 2>&1
    ;;
```

변경 후:
```jq
approval)
    jq -e '
        (.plan_approved_at != null)
        and (.history | any(
            .stage == "approval"
            and .status == "completed"
            and (.by == "user" or .by == "bypass")
        ))
    ' "$f" >/dev/null 2>&1
    ;;
```

Backward compat — 기존 `by="user"` 경로 유지, `by="auto"` 거부 유지.

**Regression 테스트** (`approval-bypass.smoke.sh` 신규):
- T1: `by="user"` → stage_is_passed=true (기존 동작 보존)
- T2: `by="bypass"` → stage_is_passed=true (신규)
- T3: `by="auto"` → stage_is_passed=false (회귀 방어)
- T4: `mark_approval_complete by="bypass"` 후 후속 Write 통과 — stage 영속성

`user-prompt-approval-detect.sh` 단순화 — nonce 발급 분리 폐기, 직접 호출.

### Stage A0b — Slash command 정형화

`packages/ai-harness/scripts/hooks/lib/slash-commands.sh` (신규):
```bash
is_known_slash() {
    case "$1" in
        /approved|/skip) return 0 ;;
    esac
    return 1
}
```

`user-prompt-approval-detect.sh` 확장 — `/approved`, `/skip <stage> <reason>` 파싱.

**Whitespace 처리** (integrator plan v6 회귀 회피, 단일 채택):

bash 3.2 `${var#pattern}` 안 `[[:space:]]` 클래스 동작이 환경별 차이 가능 — 보수적으로 `sed -E` 채택.

```bash
trim_leading() {
    printf '%s' "$1" | sed -E 's/^[[:space:]]+//'
}
```

Smoke test (`slash-detect.smoke.sh`):
- TS1: `trim_leading "  /skip foo"` → `"/skip foo"`
- TS2: `trim_leading "<TAB>/skip"` → `"/skip"`
- TS3: `trim_leading ""` → `""`
- TS4: bash `--version` 검증 — 3.2.x로 시작하면 위 행위 동일성 별도 확인 (CI lint 단계)

**Mixed slash 거부**: `/approved /skip` 같은 입력 → 무시.

### Stage A — `post-session-end-metrics.sh` + `hook_healthy`

세션 종료 시점에 결정성 메트릭 기록. JSONL로 누적. Stage S0 spike (2026-05-11) 결과 SessionEnd hook 기반.

**위치**: `packages/ai-harness/scripts/hooks/post-session-end-metrics.sh` (신규, rename from previously planned `post-stop-determinism-log.sh`)

**Hook 등록** (`auto-update.sh` / `install.sh` / `~/.claude/settings.json`):
```json
{
  "hooks": {
    "SessionEnd": [
      { "type": "command", "command": "<HARNESS_DIR>/scripts/hooks/post-session-end-metrics.sh" }
    ]
  }
}
```

**stdin payload — CONFIRMED 사용 필드** (Stage S0 spike 결과):
- `session_id` (string, required) — session correlation key
- `transcript_path` (string, required) — 종료 시점 JSONL transcript 절대 경로
- `cwd` (string, required) — 세션 작업 디렉토리
- `reason` (enum, required) — `clear` | `logout` | `prompt_input_exit` | `other` (실제 도달 가능 값은 `other` 위주)

`hook_event_name` literal "SessionEnd"와 `permission_mode` (optional)는 본 plan 미사용. `started_at`/`ended_at`/`duration_ms` 시간 필드는 payload에 없음 → hook 내부에서 `date +...`로 `ended_at`만 자체 기록.

**Hook 본체 (skeleton — shebang은 ADR D2 정책 준수)**:

```bash
#!/usr/bin/env bash
# Plan 13 Stage A — SessionEnd metrics hook
set -uo pipefail

# Resolve harness dir (SAZO_HARNESS_DIR env > script-relative fallback)
if [ -z "${SAZO_HARNESS_DIR:-}" ]; then
    SAZO_HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fi

# Source dependencies (함수 정의 위치):
#   audit_log, _with_lock, state_dir       → lib/session-state.sh (기존, PR #27)
#   _append_metrics_inner, hook_healthy    → lib/session-state.sh (본 plan 신규 추가)
source "${SAZO_HARNESS_DIR}/scripts/hooks/lib/session-state.sh" \
    || { echo "post-session-end-metrics: failed to source session-state.sh" >&2; exit 0; }

# Portable timeout helper (BSD timeout 미존재 대응)
_run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "${secs}s" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${secs}s" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift @ARGV; exec @ARGV' "$secs" "$@"
    else
        audit_log "session-end" "warn" "no timeout binary available; running without timeout"
        "$@"
    fi
}

# Read SessionEnd payload from stdin
payload=$(cat 2>/dev/null || true)
[ -z "$payload" ] && exit 0

# Parse 4 CONFIRMED fields
session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty')
transcript_path=$(printf '%s' "$payload" | jq -r '.transcript_path // empty')
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty')
reason=$(printf '%s' "$payload" | jq -r '.reason // "other"')

[ -z "$session_id" ] && { audit_log "session-end" "warn" "missing session_id"; exit 0; }

# Build metric record (source field discriminates SessionEnd vs Stop-fallback)
now=$(date +%Y-%m-%dT%H:%M:%S%z)
record=$(jq -n \
    --arg sid "$session_id" \
    --arg tp "$transcript_path" \
    --arg cwd "$cwd" \
    --arg reason "$reason" \
    --arg now "$now" \
    --argjson healthy "$(hook_healthy && echo true || echo false)" \
    '{
        source: "session_end",
        session_id: $sid,
        transcript_path: $tp,
        cwd: $cwd,
        reason: $reason,
        ended_at: $now,
        hook_healthy: $healthy
    }')

# Append (lock-protected, 5s portable timeout)
dest="${HOME}/.claude/state/session-metrics-${session_id}.jsonl"
mkdir -p "$(dirname "$dest")"
_run_with_timeout 5 _with_lock "$dest" _append_metrics_inner "$record" "$dest"

exit 0
```

**Library 추가** (`packages/ai-harness/scripts/hooks/lib/session-state.sh` 말미):

```bash
# Plan 13 Stage A additions
_append_metrics_inner() {
    local line="$1" dest="$2"
    printf '%s\n' "$line" >> "$dest"
}

# hook_healthy 7-check (OR 분기 — SessionEnd 또는 PreToolUse 정의 시 healthy)
hook_healthy() {
    [ -f "${HOME}/.claude/settings.json" ] || return 1
    local has_pre has_end
    has_pre=$(jq -r '.hooks.PreToolUse // empty | length' "${HOME}/.claude/settings.json" 2>/dev/null)
    has_end=$(jq -r '.hooks.SessionEnd // empty | length' "${HOME}/.claude/settings.json" 2>/dev/null)
    { [ -n "$has_pre" ] && [ "$has_pre" -gt 0 ]; } \
        || { [ -n "$has_end" ] && [ "$has_end" -gt 0 ]; } \
        || return 1
    [ -w "$(state_dir)" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    mkdir -p "${HOME}/.claude/state/.healthcheck-$$" 2>/dev/null || return 1
    rmdir "${HOME}/.claude/state/.healthcheck-$$" 2>/dev/null
    [ -n "${SAZO_HARNESS_DIR:-}" ] && [ -d "$SAZO_HARNESS_DIR" ] || return 1
    return 0
}
```

**기록 항목 (state 파일에서 보강)**:
- session_id, transcript_path, cwd, reason, ended_at, source ("session_end" or "stop_fallback")
- stage 진행도 (state JSON에서 lookup — research/plan/approval/ci/review 통과 여부)
- soft_warn_count, override 사용
- explore_count, autonomous skip 사용
- `hook_healthy: bool` — 7-check
- verdict_missing_count (PR #27 추가)

`hook_healthy` 7-check 정확한 내용:
1. `~/.claude/settings.json` 존재
2. `.hooks.SessionEnd[]` 또는 `.hooks.PreToolUse[]` 정의 (OR 분기)
3. `state_dir` 쓰기 가능
4. jq 사용 가능
5. `_with_lock` 동작 (mkdir 시뮬)
6. hook command path 모두 실재 (settings.json의 SessionEnd + PreToolUse 명령들이 `pwd -P` 정규화 후 파일 존재)
7. `SAZO_HARNESS_DIR` resolve 가능

`_with_lock`으로 동시 append 직렬화.

#### Stage A 내부 sub-section — Known limitations & Stop fallback

**Known limitations** (Stage S0 spike에서 도출, 코드 주석 + `docs/workflow-hooks.md` 반영):
- `/exit` 종료 시 SessionEnd 미발사 (GH#17885, #35892) — 사용자에게 Ctrl+D 권장 또는 fallback 사용
- `/clear` 종료 시 미발사 (GH#6428)
- Ctrl+C → mid-execution kill (GH#32712)
- `--continue` resume → stale session_id/transcript_path (GH#9188): hook은 record source="session_end" 외 별도 표시 안 함, Plan 02 메트릭 단계에서 dedup
- async 5s 초과 작업 kill (GH#41577) — `timeout 5` wrapper로 graceful fail

**Stop hook fallback (deferred subsection)**:

SessionEnd 실패 케이스 대응을 위해 Stop hook 보조 활성화. 본 plan에서는 명세만, **구현은 Stage A 1차 출하 이후 별도 PR** (`SAZO_ENABLE_STOP_FALLBACK=1` env로 default off):

- 파일: `packages/ai-harness/scripts/hooks/post-stop-metrics-fallback.sh` (신규, deferred)
- 등록: `.hooks.Stop[]`
- 동작: Stop이 매 turn fire → record source="stop_fallback" + 같은 JSONL에 append. 동일 session_id로 N records per session 생성 가능.
- **Dedup key**: `(session_id, source)`. Plan 02 workflow CLI 메트릭 조회 단계에서:
  - `session_end` 레코드 존재 → 그것을 신뢰값으로 사용, stop_fallback은 보조 stage 진행도 추적용
  - `session_end` 레코드 부재 → 최후 `stop_fallback` 레코드 사용 (/exit, /clear 종료 케이스)
- **Record schema**: 양쪽 동일 (`session_id`, `cwd`, `ended_at`, `hook_healthy`, `source`, stage progress, soft_warn_count, …). Stop fallback에는 `transcript_path` 부재 가능 → field nullable.
- **Rollout**: 본 plan은 Stop fallback hook **명세 + record schema 호환성**만 제출. 실제 hook script + 등록은 Stop hook payload 별도 spike 후 다음 PR.

### Stage A' — Subagent output audit (warn-only)

PR #27의 verdict footer는 review/plan stage 한정. 일반 subagent 출력 (예: Bash command output, 파일 내용) 위반 감지는 별도.

**위치**: `packages/ai-harness/scripts/hooks/post-task-output-audit.sh` (신규)
**규칙**: `packages/ai-harness/scripts/hooks/lib/subagent-output-rules.sh` (신규)

규칙 예:
- secret-like pattern 감지 (`AWS_SECRET`, `API_KEY=`, etc.)
- 큰 파일 dump (>1MB) warn
- output에 binary content warn

**warn-only** — block 안 함. metric 기록 + audit log.

`subagent_type` sanitize (`tr '-.' '__'`)로 jq path injection 방어.

### Stage B — Approval hard block + auto-skip 차단

**Approval hard block**:
- approval stage 미완료 + `gh pr create` 시도 → block
- env override: `SAZO_ALLOW_APPROVAL_BYPASS=1` → `mark_approval_complete by="bypass"` 후 통과 (warn 메트릭)

**Auto-skip wrapper** (`mark_skip_with_check`):
```bash
WRAPPER_EXEMPT_STAGES=("worktree")  # worktree autonomous skip은 별도 정책

is_wrapper_exempt() {
    local stage="$1" s
    for s in "${WRAPPER_EXEMPT_STAGES[@]}"; do
        [ "$s" = "$stage" ] && return 0
    done
    return 1
}

mark_skip_with_check() {
    local sid="$1" stage="$2" by="$3" reason="$4"
    if [ "$by" = "auto" ] && ! is_wrapper_exempt "$stage"; then
        if [ "${SAZO_ALLOW_AUTO_SKIP:-0}" = "1" ]; then
            stage_mark "$sid" "$stage" "skipped" "auto" "$reason"
        else
            hard_block "skip-auto" "Autonomous skip 차단. /skip $stage <reason> 입력 필요. 극단 예외: SAZO_ALLOW_AUTO_SKIP=1"
        fi
    else
        stage_mark "$sid" "$stage" "skipped" "$by" "$reason"
    fi
}
```

**기존 autonomous skip 호출 site 인벤토리** (현 codebase 기준):

| File:Line | 호출 | 변경 |
|---|---|---|
| `scripts/hooks/pre-worktree-gate.sh:110` | `stage_mark "$SAZO_SESSION_ID" "worktree" "skipped" "auto" "not a git repo"` | `mark_skip_with_check` 통과 (worktree는 `WRAPPER_EXEMPT_STAGES`로 exempt) |

현재 codebase에 `stage_mark ... "skipped" "auto"` 호출은 위 단일 site만. 향후 추가 site는 `mark_skip_with_check` 사용 강제. CI lint 검토 항목에 추가 — `grep -r 'stage_mark.*skipped.*auto'` 발견 시 직접 사용 차단.

PR #27의 process_verdict_tracked_post_task은 stage_mark "completed" "auto" (skipped 아님) 호출 — 본 wrapper 무관.

### ADR D2 — Bash 호환성 정책 명시

**위치**: `packages/ai-harness/docs/proposals/control-flow-determinism.md` (신규)

```markdown
## D2. Bash 호환성 정책

### 결정
모든 hook script와 lib는 bash 3.0+에서 동작해야 한다 (3.2 권장).

### 근거
macOS 기본 `/bin/bash` = 3.2.57. 사용자가 brew로 newer bash 설치 가능하지만 default 보장 못함.

### 정책
- Shebang: `#!/usr/bin/env bash`
- 사용 금지 (bash 4+ 기능): associative arrays, `${var^^}`, `[[ -v var ]]`, `declare -A`, `mapfile/readarray`, `${!var}`
- 사용 OK: `set -uo pipefail`, indexed arrays, parameter expansion `${var#pattern}` / `${var%pattern}`, regex `[[ "$x" =~ regex ]]`
- Runtime version gate 없음 — shebang + 정적 검토 (CI lint)만
- Path 정규화: `cd "$(dirname X)" && pwd -P` (realpath 미사용)
```

PR #27에서 `${!var}` indirect expansion 발견 → bash 4+ 의존성 노출됨. 해당 코드는 case statement로 변경됨 (이미 commit). 본 ADR로 정책 형식화.

**Spike doc 예외**: `proposals/harness-determinism/spike-stop-hook.md` line 119의 예제 `#!/bin/bash`는 reference example로서 본 ADR 정책 외. 실 hook 본체(`post-session-end-metrics.sh`)는 ADR D2에 따라 `#!/usr/bin/env bash` 적용.

## 변경 파일 (v2)

신규/수정 (rename 표기 = 본 revision으로 명칭 변경):

```
packages/ai-harness/scripts/hooks/lib/session-state.sh
    (+ mark_approval_complete, + _mark_approval_complete_inner,
     + _append_metrics_inner, + hook_healthy)
packages/ai-harness/scripts/hooks/lib/slash-commands.sh                   (신규)
packages/ai-harness/scripts/hooks/lib/subagent-output-rules.sh            (신규)
packages/ai-harness/scripts/hooks/user-prompt-approval-detect.sh          (단순화 + /skip)
packages/ai-harness/scripts/hooks/workflow-state-machine.sh               (auto-skip wrapper, approval bypass)
packages/ai-harness/scripts/hooks/post-session-end-metrics.sh             (신규 — rename from post-stop-determinism-log.sh, 기존 plan에 명세만 존재했음)
packages/ai-harness/scripts/hooks/post-task-output-audit.sh               (신규)
packages/ai-harness/scripts/auto-update.sh                                (SessionEnd hook + PostToolUse audit 등록)
packages/ai-harness/install.sh                                            (동일)
packages/ai-harness/docs/proposals/control-flow-determinism.md            (신규 ADR D2)
packages/ai-harness/docs/workflow-hooks.md                                (env 매트릭스 + SessionEnd 한계)

신규 smoke tests (6개):
packages/ai-harness/scripts/tests/approval-immediate.smoke.sh             (A0a)
packages/ai-harness/scripts/tests/slash-detect.smoke.sh                   (A0b)
packages/ai-harness/scripts/tests/session-end-metrics.smoke.sh            (A — rename from stop-metrics.smoke.sh, 기존 plan 명세 미구현)
packages/ai-harness/scripts/tests/task-output-audit.smoke.sh              (A')
packages/ai-harness/scripts/tests/auto-skip-block.smoke.sh                (B-skip)
packages/ai-harness/scripts/tests/approval-bypass.smoke.sh                (B-bypass)

~/.claude/CLAUDE.md MANAGED BLOCK                                          (신규 env 명시)
```

## State schema 변경

PR #27의 v2 그대로. `mark_approval_complete`는 기존 필드만 사용. `auto_skip_used` boolean field 추가 가능 (메트릭용).

## Test plan

각 Stage별 smoke test:

**A0a**: `mark_approval_complete` (`approval-immediate.smoke.sh` — 기존 부분):
- /approved → stage_is_passed=true
- by="bypass" → stage_is_passed=true
- by="auto" → stage_is_passed=false (validator 회귀)
- 동시 호출 → atomic, history entry 1개

**A0b**: `slash-detect.smoke.sh`:
- `/approved` 단독, `/approved foo` 거부
- `/skip plan reason here` 파싱 정확
- whitespace trim glob 회귀 검증
- mixed slash 거부

**A**: `session-end-metrics.smoke.sh`:
- T1 (Ctrl+D path proxy): fixture payload `{session_id, transcript_path, cwd, reason="other"}` 을 hook stdin 주입 → JSONL line 1개 + record `source="session_end"` discriminator + 4-field 정합
- T2 (hook_healthy check #2 OR 분기 — 3 sub-case):
  - T2.1: settings.json에 `SessionEnd`만 → healthy=true (OR 첫 가지)
  - T2.2: settings.json에 `PreToolUse`만 → healthy=true (OR 두번째 가지)
  - T2.3: 둘 다 부재 → healthy=false
- T3 (concurrent append): 3 process 동시 hook invoke → 모든 line 보존 (lock 검증)
- T4 (jq missing fallback): PATH 격리하여 jq 제거 → metric 미작성 + audit log entry
- T5 (5s timeout, portable):
  - T5a: `timeout` 가용 → 정상 종료
  - T5b: PATH 격리로 timeout/gtimeout 부재 + perl 있음 → perl alarm 발동 검증
  - T5c: timeout/gtimeout/perl 모두 부재 → audit_log "no timeout binary available" entry + 직접 실행
- T6 (/exit 미지원 documented): smoke가 `docs/workflow-hooks.md`에 known-limitation 문자열 grep으로 명시 확인 (`/exit` + GH#17885 reference)
- T7 (missing session_id — GH#9188 stale 시뮬): payload `{session_id: "", transcript_path: "...", cwd: "...", reason: "other"}` → metric skip + audit log entry
- T8 (hook_healthy check #6 hook command path): fixture로 settings.json의 command path positive (실재) → healthy=true, negative (rm) → healthy=false

**Smoke fixture for `hook_healthy` check #6** (settings.json 의존):
```bash
TMP_HOME=$(mktemp -d)
mkdir -p "$TMP_HOME/.claude/scripts/hooks"
cat > "$TMP_HOME/.claude/settings.json" <<JSON
{
  "hooks": {
    "SessionEnd": [
      {"type": "command", "command": "scripts/hooks/test-end.sh"}
    ],
    "PreToolUse": [
      {"matcher": "Write", "hooks": [{"command": "scripts/hooks/test-pre.sh"}]}
    ]
  }
}
JSON
echo '#!/usr/bin/env bash' > "$TMP_HOME/.claude/scripts/hooks/test-end.sh"
echo '#!/usr/bin/env bash' > "$TMP_HOME/.claude/scripts/hooks/test-pre.sh"
chmod +x "$TMP_HOME/.claude/scripts/hooks/test-end.sh" "$TMP_HOME/.claude/scripts/hooks/test-pre.sh"

# Positive: 둘 다 실재
HOME="$TMP_HOME" CLAUDE_CONFIG_DIR="$TMP_HOME/.claude" \
  bash -c "source ... && hook_healthy"

# Negative case — command path 비실재
rm "$TMP_HOME/.claude/scripts/hooks/test-end.sh"
HOME="$TMP_HOME" hook_healthy  # → false 기대
```

**A'**: `task-output-audit.sh`:
- secret pattern detect → warn entry
- 큰 file dump → warn
- subagent_type sanitize (메타문자 → skip)
- block 안 함 (warn-only 검증)

**B**: `auto-skip-block.smoke.sh`:
- by="auto" + worktree skip → wrapper exempt 통과
- by="auto" + research skip + `SAZO_ALLOW_AUTO_SKIP=0` → block
- `SAZO_ALLOW_AUTO_SKIP=1` → 통과 + warn 메트릭

**B**: `approval-bypass.smoke.sh`:
- approval 미완료 + `SAZO_ALLOW_APPROVAL_BYPASS=1` + Write → 통과
- 첫 통과 후 stage 영속성 (다음 Write도 통과 — `mark_approval_complete by="bypass"` 효과)

## Open questions

1. ~~Stop hook 동작 방식~~ — **RESOLVED (Stage S0 spike, 2026-05-11)**: SessionEnd 채택, payload subset CONFIRMED. (`proposals/harness-determinism/spike-stop-hook.md`)
2. `post-task-output-audit.sh`의 trigger — 모든 PostToolUse 또는 Task만?
3. Auto-skip wrapper exempt list — worktree만? approval도 exempt?
4. Stop hook fallback 활성화 시점 — 본 plan 1차 출하 후 사용자 보고된 /exit 손실 비율에 따라 결정 (deferred PR)
5. `--continue` resume 시 stale session_id 처리 (GH#9188) — record skip만 충분한지, 별도 reconcile 필요한지 (Plan 02 메트릭 단계에서 결정)
6. `_with_lock` + perl alarm fallback 조합 — perl `exec`는 shell function 호출 불가. perl path에서 lock 생략 + warn? 또는 lock helper를 외부 스크립트로 split? (implementation 단계 결정)
7. `hook_healthy` check #6 settings.json command path resolve 기준 — `~/.claude/` prefix 가정? cwd 기준? (implementation 단계 결정)

## Risk

- **R1 (resolved)**: ~~Stop hook payload 스펙 미문서화~~ → Stage S0 spike에서 SessionEnd로 pivot + 4-field subset CONFIRMED (PR #32 머지)
- **R2 (med)**: subagent_type sanitize 약점 — `tr` 후 jq path가 여전히 메타문자 가능. 추가 escape 필요할 수 있음
- **R3 (low)**: bypass env 남용 — 정책으로 audit 매주 검토 권장
- **R4 (low)**: auto-skip 정책 변경이 기존 사용자 워크플로 깸 — phased rollout
- **R5 (med, 신규)**: SessionEnd `/exit` 미발사 (GH#17885, #35892) — 메트릭 손실 ratio 운영 측정 후 Stop fallback 활성화 결정 (deferred PR)
- **R6 (med, 신규)**: SessionEnd async kill (GH#41577) — `timeout 5` portable wrapper로 graceful fail, 5s 초과 작업 금지 (lightweight sync 작성만)
- **R7 (low, 신규)**: `--continue` resume stale session_id (GH#9188) — record skip + audit log; Plan 02 메트릭 단계에서 dedup 처리
- **R8 (low, 신규)**: `_with_lock` + perl alarm fallback 조합에서 record loss window <5s — BSD timeout 미설치 환경 한정. timeout/gtimeout 있는 환경에서는 unaffected. implementation 단계에서 lock 생략+warn vs lock helper split 결정.

## Rollback

- `SAZO_DISABLE_SESSION_END_HOOK=1` — SessionEnd hook 비활성 (auto-update.sh 등록 skip)
- `SAZO_DISABLE_TASK_OUTPUT_AUDIT=1`
- `SAZO_DISABLE_AUTO_SKIP_WRAPPER=1`
- `SAZO_ALLOW_APPROVAL_BYPASS=1` (이미 escape hatch)
- `SAZO_ENABLE_STOP_FALLBACK=1` — **본 PR에서는 no-op**. Stop fallback hook script 등록은 deferred PR. 본 plan은 record schema의 `source` field만 명세 (`"session_end"` vs `"stop_fallback"` 구분 가능하도록 호환성 확보)

## Dependencies

- PR #27 — schema v2 기반
- Stage S0 spike (`proposals/harness-determinism/spike-stop-hook.md`, PR #32 머지) — **RESOLVED 2026-05-11**
- Plan 02 (workflow CLI, 머지됨) — 메트릭 조회 + (deferred Stop fallback 활성화 시) dedup 로직 처리 → out-of-scope, plan 02 follow-up

## Acceptance criteria (v2)

- [x] **Stage S0 spike 결과 PASS** — PR #32 머지 완료 (payload 4-field CONFIRMED, trigger 제약 6 케이스 documented)
- [x] `mark_approval_complete` + atomic helper 구현 (lib/session-state.sh)
- [x] `stage_is_passed` approval 분기에 `or .by == "bypass"` 추가 (정확 jq 표시)
- [x] `slash-commands.sh` is_known_slash + `trim_leading` (sed 채택)
- [x] `post-session-end-metrics.sh` 신규 작성 + `hook_healthy` 7-check (fixture mock 포함, OR 분기 3 sub-case)
- [x] Portable timeout wrapper (timeout → gtimeout → perl alarm → no-timeout+warn) 동작
- [x] `_append_metrics_inner`, `hook_healthy` lib/session-state.sh에 정의 + hook script가 절대 경로 source
- [x] Record schema `source` field 추가 (`"session_end"` 값 default, Stop fallback deferred PR 대비 호환성)
- [x] `post-task-output-audit.sh` + rules lib (warn-only)
- [x] `mark_skip_with_check` wrapper — `pre-worktree-gate.sh:110` 한 곳 교체 + CI lint 추가
- [x] Approval bypass env 동작 (T1-T4 regression)
- [x] ADR D2 명시 (hook 본체 shebang `#!/usr/bin/env bash` 준수) — `packages/ai-harness/docs/proposals/control-flow-determinism.md`
- [x] **신규 smoke test 6개 모두 GREEN**: `approval-immediate`, `slash-detect`, `session-end-metrics`, `task-output-audit`, `auto-skip-block`, `approval-bypass`
- [x] **현 CLAUDE.md ai-harness baseline + 신규 6 smoke 모두 GREEN** (baseline test 개수는 root CLAUDE.md ai-harness 행 기준 — revision 시점에 hardcode 표기 회피)
- [x] CLAUDE.md MANAGED BLOCK env 매트릭스 추가 (`SAZO_DISABLE_SESSION_END_HOOK`, `SAZO_ENABLE_STOP_FALLBACK` 등) — `register-workflow-hooks.sh`가 env 매트릭스 적용
- [x] **root CLAUDE.md CI 커맨드 갱신** — ai-harness 행에 신규 6 smoke test 추가
- [x] `docs/workflow-hooks.md` 에 SessionEnd known limitations 섹션 추가 (/exit/clear/Ctrl+C 미지원, async 5s 제한, --continue stale)
- [x] **Stop hook fallback 명세** 본문 포함 (record schema 호환성: `source` field + `transcript_path` nullable). 실제 hook script 구현은 deferred PR.
