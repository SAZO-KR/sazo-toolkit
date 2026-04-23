#!/bin/bash
# workflow-state-machine.sh — PreToolUse + PostToolUse hook.
#
# Usage: workflow-state-machine.sh {pre|post}
#
# Stage: init → worktree → research → plan → approval → implementation → ci → review → done
#
# 정책 (재설계 후):
# - Write/Edit gate (research/plan/approval): **soft warn** 3회까지, 4회부터 hard block.
#   approval은 항상 soft (architecturally unenforceable; UserPromptSubmit hook이 보조).
# - `gh pr create` gate (ci/review): **hard block**. 실제 PR 생성은 의도적으로 막을 가치.
# - SAZO_ALLOW_CI_SKIP=1 환경변수로 ci block 우회 가능 (메시지대로 실제 enforce).
#
# PostToolUse:
# - Task subagent 호출 → stage 자동 완료 마킹 (research/plan/review)
# - Task 호출 시 explore_count -1 decay (위임 보상)
# - Bash CI 명령 exit 0 시 ci_cmd_hash 기록 — 프로젝트 CI 커맨드 정확 매치 시만 ci 마킹
# - TodoWrite는 신호로 사용 안 함 (3개 dummy로 bypass되는 약한 신호)

set -uo pipefail

MODE="${1:-}"
[ -z "$MODE" ] && { echo "usage: $0 {pre|post}" >&2; exit 0; }

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/session-state.sh
source "$LIB_DIR/session-state.sh"

if ! workflow_hooks_enabled || [ "${SAZO_SKIP_STATE_MACHINE:-0}" = "1" ]; then
    exit 0
fi

read_hook_payload

[ -z "${SAZO_SESSION_ID:-}" ] && exit 0

state_init "$SAZO_SESSION_ID" "$SAZO_CWD" "$SAZO_MODEL"

# ----- soft warn helper -----
# stage별 카운터 분리 — research/plan/approval 동시 fail 시 한 Write 호출에서
# 카운터가 3번 증가해 즉시 block되는 버그 방지.

soft_warn_or_block() {
    local stage="$1" msg="$2" warn_threshold="${3:-3}"
    local path=".soft_warn_count_${stage}"
    state_increment "$SAZO_SESSION_ID" "$path"
    local count
    count=$(state_get "$SAZO_SESSION_ID" "$path")
    count=${count:-0}
    if [ "$count" -le "$warn_threshold" ]; then
        cat >&2 <<EOF
[workflow-warn $count/$warn_threshold] stage=$stage 미통과.
$msg
$((warn_threshold + 1))회부터 hard block. Override:
  - skip: /skip $stage <reason>
  - 전체 비활성: SAZO_SKIP_STATE_MACHINE=1
EOF
        return 0
    fi
    cat >&2 <<EOF
[workflow-block] stage=$stage 미통과 $count회 — $SAZO_TOOL_NAME 차단.
$msg
Override:
  - skip: /skip $stage <reason>
  - 전체 비활성: SAZO_SKIP_STATE_MACHINE=1
EOF
    return 2
}

hard_block() {
    local stage="$1" msg="$2"
    cat >&2 <<EOF
[workflow-block] stage=$stage 미통과 → $SAZO_TOOL_NAME 차단.
$msg
EOF
    exit 2
}

# ----- consecutive skip warning -----

emit_skip_warning_if_needed() {
    local n
    n=$(consecutive_skip_count "$SAZO_SESSION_ID")
    if [ "${n:-0}" -ge 3 ]; then
        cat >&2 <<EOF
[workflow-warn] 연속 ${n} stage skip 감지. 워크플로우 전체 bypass 의도가 맞나? 사용자 추가 확인 권장.
EOF
    fi
}

# ----- PostToolUse: stage 자동 완료 -----

handle_post() {
    case "$SAZO_TOOL_NAME" in
        Task)
            local subagent_type
            subagent_type=$(echo "$SAZO_TOOL_INPUT" | jq -r '.subagent_type // ""')
            case "$subagent_type" in
                code-searcher|docs-researcher|explore|Explore|\
                nori-codebase-locator|nori-codebase-analyzer|nori-codebase-pattern-finder|\
                nori-web-search-researcher|image-analyzer|multimodal-looker)
                    stage_is_passed "$SAZO_SESSION_ID" "research" \
                        || stage_mark "$SAZO_SESSION_ID" "research" "completed" "auto" "subagent=$subagent_type"
                    # 위임 보상: explore_count decay
                    state_decrement "$SAZO_SESSION_ID" ".explore_count"
                    ;;
                plan-drafter|plan-auditor|plan-critic|Plan)
                    stage_is_passed "$SAZO_SESSION_ID" "plan" \
                        || stage_mark "$SAZO_SESSION_ID" "plan" "completed" "auto" "subagent=$subagent_type"
                    ;;
                code-reviewer|architect-advisor|nori-code-reviewer)
                    stage_is_passed "$SAZO_SESSION_ID" "review" \
                        || stage_mark "$SAZO_SESSION_ID" "review" "completed" "auto" "subagent=$subagent_type"
                    ;;
            esac
            ;;
        Bash)
            # CI detection: 프로젝트 CLAUDE.md의 CI 커맨드와 정확 매치 시만 ci 마킹.
            # 단순 부분 명령(`yarn lint` 단독)은 무시.
            local cmd exit_code
            cmd=$(echo "$SAZO_TOOL_INPUT" | jq -r '.command // ""')
            exit_code=$(echo "$SAZO_TOOL_RESPONSE" | jq -r '.exit_code // .success // -1' 2>/dev/null)
            # success bool 처리: true → 0, false → 1
            case "$exit_code" in
                true) exit_code=0 ;;
                false) exit_code=1 ;;
            esac
            if [ "$exit_code" = "0" ] && _is_full_ci_command "$cmd"; then
                if ! stage_is_passed "$SAZO_SESSION_ID" "ci"; then
                    # ci_passed_at 실패하면 stage_mark 호출 안 함 (rc=99 lock timeout
                    # 등으로 inconsistent state 방지).
                    if state_set_str "$SAZO_SESSION_ID" ".ci_passed_at" "$(date +%Y-%m-%dT%H:%M:%S%z)"; then
                        stage_mark "$SAZO_SESSION_ID" "ci" "completed" "auto" "ci-cmd matched"
                    else
                        echo "[workflow] ci_passed_at write failed (lock timeout?); ci not marked" >&2
                    fi
                fi
            fi
            ;;
    esac
    exit 0
}

# 프로젝트 CI 커맨드 정확 매치 검사. CLAUDE.md/AGENTS.md 표 안의 코드 펜스에서
# 가장 긴 chained 커맨드를 추출해 비교. 부분 일치는 거부.
_is_full_ci_command() {
    local cmd="$1"
    local proj_md
    for candidate in "$SAZO_CWD/CLAUDE.md" "$SAZO_CWD/AGENTS.md" "$SAZO_CWD/.claude/CLAUDE.md"; do
        [ -f "$candidate" ] && proj_md="$candidate" && break
    done
    [ -z "${proj_md:-}" ] && return 1

    # CLAUDE.md backtick fenced 명령 중 `&&`가 ≥1개 들어있는 chained command 추출.
    # (이전 V3는 ≥3 요구해 Go 패키지의 `cd dir && go build ./...` 같은 단일 && CI를
    # 영구 false negative — V3 reviewer #4).
    local ci_cmds
    ci_cmds=$(grep -oE '`[^`]+&&[^`]+`' "$proj_md" 2>/dev/null | sed 's/^`//;s/`$//')
    [ -z "$ci_cmds" ] && return 1

    # 정확 매치만 인정. substring 매치는 `echo 'CHAIN' && malicious` 같은 prefix
    # injection이 가능해 거부 (code-reviewer V2 M3).
    while IFS= read -r ci_cmd; do
        [ -z "$ci_cmd" ] && continue
        if [ "$cmd" = "$ci_cmd" ]; then
            return 0
        fi
    done <<< "$ci_cmds"
    return 1
}

# ----- PreToolUse: stage gate -----

handle_pre() {
    local rc
    case "$SAZO_TOOL_NAME" in
        Write|Edit|NotebookEdit)
            # research — soft warn (3회 후 block)
            if ! stage_is_passed "$SAZO_SESSION_ID" "research"; then
                soft_warn_or_block "research" "리서치 subagent 위임 권장.
  Task(subagent_type=\"code-searcher\", ...) 또는 Task(subagent_type=\"docs-researcher\", ...)
파일/라인 직접 지정됐으면: /skip research <reason>"
                rc=$?
                [ "$rc" = "2" ] && exit 2
            fi

            # plan — soft warn (3회 후 block)
            if ! stage_is_passed "$SAZO_SESSION_ID" "plan"; then
                soft_warn_or_block "plan" "플랜 제시 권장.
  Task(subagent_type=\"plan-drafter\", ...) 또는 plan 메시지 + 사용자 승인
≤5줄 단일파일 typo 수정: /skip plan <reason>"
                rc=$?
                [ "$rc" = "2" ] && exit 2
            fi

            # approval — 항상 soft warn (architecturally unenforceable)
            if ! stage_is_passed "$SAZO_SESSION_ID" "approval"; then
                cat >&2 <<EOF
[workflow-warn] approval marker 없음. 사용자가 직접 /approved 입력해야 정식 통과 (Claude 자동 호출은 차단됨).
플랜 제시 후 사용자에게 승인 요청 권장.
EOF
            fi
            ;;
        Bash)
            local cmd
            cmd=$(echo "$SAZO_TOOL_INPUT" | jq -r '.command // ""')
            # gh pr create — hard block
            if echo "$cmd" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+create\b'; then
                if ! stage_is_passed "$SAZO_SESSION_ID" "ci"; then
                    if [ "${SAZO_ALLOW_CI_SKIP:-0}" = "1" ]; then
                        stage_mark "$SAZO_SESSION_ID" "ci" "skipped" "user" "SAZO_ALLOW_CI_SKIP=1"
                    else
                        emit_skip_warning_if_needed
                        hard_block "ci" "PR 생성 전 CI 통과 확인 필수. 프로젝트 CI 커맨드(CLAUDE.md/AGENTS.md 명시) 정확 실행.
극단 예외: SAZO_ALLOW_CI_SKIP=1"
                    fi
                fi
                if ! stage_is_passed "$SAZO_SESSION_ID" "review"; then
                    emit_skip_warning_if_needed
                    hard_block "review" "독립 리뷰 필수.
  Task(subagent_type=\"code-reviewer\", ...) 또는 architect-advisor
문서/주석만 수정: /skip review <reason>"
                fi
            fi
            ;;
    esac
    exit 0
}

case "$MODE" in
    pre) handle_pre ;;
    post) handle_post ;;
    *) echo "unknown mode: $MODE" >&2; exit 0 ;;
esac
