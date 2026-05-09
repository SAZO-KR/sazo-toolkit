# 13. Control Flow Extensions (from integrator project plan v6)

**우선순위**: P1 (PR #27 후속)
**의존**: PR #27 (schema v2, atomic mutations 기반)
**예상 비용**: 1.5주
**출처**: `/Users/hakun.lee/work/integrator/docs/harness-determinism-plan-2026-05-10.md` v6
**결정성 이동**: 🟡 → 🟢 (autonomous skip 차단, /approved 즉시 처리, audit warn-only)

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
| Stop hook metrics | 미처리 | ✅ Stage A |
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

**Validator 확장** (bypass 분기):
```jq
approval)
    (.plan_approved_at != null)
    and (.history | any(.stage == "approval" and .status == "completed"
        and (.by == "user" or .by == "bypass")))
```

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

**Whitespace 처리** (integrator plan 회귀 회피):
```bash
# bash 3.2 호환, glob 회피
trim_leading() {
    local s="$1"
    while [ "${s#[[:space:]]}" != "$s" ]; do s="${s#[[:space:]]}"; done
    printf '%s' "$s"
}
```

또는 sed:
```bash
echo "$rest" | sed -E 's/^[[:space:]]+//'
```

**Mixed slash 거부**: `/approved /skip` 같은 입력 → 무시.

### Stage A — `post-stop-determinism-log.sh` + `hook_healthy`

세션 종료 시점에 결정성 메트릭 기록. JSONL로 누적.

**위치**: `packages/ai-harness/scripts/hooks/post-stop-determinism-log.sh` (신규)

기록 항목:
- session_id, started_at, ended_at
- stage 진행도 (research/plan/approval/ci/review 통과 여부)
- soft_warn_count, override 사용
- explore_count, autonomous skip 사용
- `hook_healthy: bool` — 7-check
- verdict_missing_count (PR #27 추가)

**`hook_healthy` 7-check**:
1. `~/.claude/settings.json` 존재
2. `.hooks.PreToolUse[]` 정의
3. `state_dir` 쓰기 가능
4. jq 사용 가능
5. `_with_lock` 동작 (mkdir 시뮬)
6. hook command path 모두 실재 (settings.json의 PreToolUse 명령들이 `pwd -P` 정규화 후 파일 존재)
7. `SAZO_HARNESS_DIR` resolve 가능

`_append_metrics_inner` (PR #27 simple_audit 패턴 재사용 가능):
```bash
_append_metrics_inner() {
    local line="$1" dest="$2"
    printf '%s\n' "$line" >> "$dest"
}
```

`_with_lock`으로 동시 append 직렬화.

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

기존 `workflow-state-machine.sh`에서 autonomous skip을 호출하는 모든 지점을 `mark_skip_with_check`로 교체.

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

## 변경 파일

```
packages/ai-harness/scripts/hooks/lib/session-state.sh    (mark_approval_complete + _mark_approval_complete_inner)
packages/ai-harness/scripts/hooks/lib/slash-commands.sh   (신규)
packages/ai-harness/scripts/hooks/lib/subagent-output-rules.sh  (신규)
packages/ai-harness/scripts/hooks/user-prompt-approval-detect.sh  (단순화 + /skip 추가)
packages/ai-harness/scripts/hooks/workflow-state-machine.sh  (auto-skip wrapper 채택, approval bypass)
packages/ai-harness/scripts/hooks/post-stop-determinism-log.sh  (신규)
packages/ai-harness/scripts/hooks/post-task-output-audit.sh  (신규)
packages/ai-harness/scripts/auto-update.sh                (Stop hook + PostToolUse audit 등록)
packages/ai-harness/install.sh                            (동일)
packages/ai-harness/docs/proposals/control-flow-determinism.md  (신규 ADR)
packages/ai-harness/docs/workflow-hooks.md                (env 매트릭스 + Stop hook 한계)
packages/ai-harness/scripts/tests/{stop-metrics,task-output-audit,auto-skip-block,approval-bypass}.smoke.sh  (신규)
~/.claude/CLAUDE.md MANAGED BLOCK                          (신규 env 명시)
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

**A**: `stop-metrics.smoke.sh`:
- session 종료 시 JSONL line 1개
- hook_healthy 7-check 각 항목
- 동시 append (3 process) → 모든 line 보존
- jq missing 시 metric 미작성, audit log entry

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

1. Stop hook 동작 방식 — Claude Code의 Stop event spec 명확? (alpha 기능 가능성)
2. `post-task-output-audit.sh`의 trigger — 모든 PostToolUse 또는 Task만?
3. Auto-skip wrapper exempt list — worktree만? approval도 exempt?

## Risk

- **R1 (med)**: Stop hook payload 스펙 미문서화 — 0-spike 필요 (Plan 0 spike 패턴 재사용)
- **R2 (med)**: subagent_type sanitize 약점 — `tr` 후 jq path가 여전히 메타문자 가능. 추가 escape 필요할 수 있음
- **R3 (low)**: bypass env 남용 — 정책으로 audit 매주 검토 권장
- **R4 (low)**: auto-skip 정책 변경이 기존 사용자 워크플로 깸 — phased rollout

## Rollback

- `SAZO_DISABLE_STOP_HOOK=1`
- `SAZO_DISABLE_TASK_OUTPUT_AUDIT=1`
- `SAZO_DISABLE_AUTO_SKIP_WRAPPER=1`
- `SAZO_ALLOW_APPROVAL_BYPASS=1` (이미 escape hatch)

## Dependencies

- PR #27 — schema v2 기반
- 0-spike — Stop hook payload 검증 필요 (별도 mini-spike)
- Plan 02 (workflow CLI, 미실행) — 메트릭 조회용 → out-of-scope, plan 02에서 처리

## Acceptance criteria

- [ ] `mark_approval_complete` + atomic helper 구현
- [ ] `slash-commands.sh` is_known_slash + parsing whitespace 안전
- [ ] `post-stop-determinism-log.sh` + hook_healthy 7-check
- [ ] `post-task-output-audit.sh` + rules lib (warn-only)
- [ ] `mark_skip_with_check` wrapper, autonomous skip 차단
- [ ] Approval bypass env 동작
- [ ] ADR D2 명시
- [ ] 5 smoke test 모두 GREEN
- [ ] 71 baseline + PR #27 verdict tests + 신규 GREEN
- [ ] CLAUDE.md MANAGED BLOCK env 매트릭스 추가
