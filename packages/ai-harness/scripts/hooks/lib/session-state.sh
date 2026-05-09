#!/bin/bash
# session-state.sh — workflow hook 공통 lib.
#
# Usage: `source scripts/hooks/lib/session-state.sh` 후 함수 호출.
# Hook 스크립트는 stdin으로 Claude Code payload JSON을 받는다.
# read_hook_payload로 session_id/cwd/tool_name/tool_input/model을 export.
#
# State 파일: ~/.claude/session-state/$SESSION_ID--$CWD_HASH.json
#   - cwd hash 포함 — 같은 session_id가 여러 worktree를 옮겨다닐 때 stage history leak 방지.
# Audit log: ~/.claude/session-state/audit.log (전 세션 공용 append-only)
#
# 동시성: hook들이 PreToolUse에서 병렬 실행될 수 있으므로 모든 mutation은 mkdir-lock
# 가드 (macOS는 flock 미지원). lock timeout/jq 실패는 audit.log에 기록.
#
# Schema versioning: state file에 schema_version 필드. 향후 migration 분기.
#
# Opt-in: 기본 비활성. 활성화하려면 SAZO_WORKFLOW_HOOKS_ENABLED=1.

set -uo pipefail

STATE_DIR="${SAZO_STATE_DIR:-$HOME/.claude/session-state}"
AUDIT_LOG="$STATE_DIR/audit.log"
SCHEMA_VERSION=2
mkdir -p -m 700 "$STATE_DIR" 2>/dev/null || mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

# ----- opt-in -----

workflow_hooks_enabled() {
    [ "${SAZO_WORKFLOW_HOOKS_ENABLED:-0}" = "1" ] \
        && [ "${SAZO_DISABLE_WORKFLOW_HOOKS:-0}" != "1" ]
}

# ----- state file path (session_id + cwd hash) -----

cwd_hash() {
    local cwd="$1"
    # short hash to avoid filename length issues; collisions extremely unlikely per session.
    # shasum: macOS. sha1sum: Linux minimal install. md5sum 마지막 fallback.
    if [ -z "$cwd" ]; then
        echo "nocwd"
        return
    fi
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$cwd" | shasum -a 1 | cut -c1-12
    elif command -v sha1sum >/dev/null 2>&1; then
        printf '%s' "$cwd" | sha1sum | cut -c1-12
    elif command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$cwd" | md5sum | cut -c1-12
    else
        # last resort: cwd를 그대로 사용 (slash를 underscore로 replace)
        printf '%s' "$cwd" | tr '/' '_' | cut -c1-40
    fi
}

state_file() {
    local sid="${1:-${SAZO_SESSION_ID:-}}"
    local cwd="${2:-${SAZO_CWD:-}}"
    [ -z "$sid" ] && return 1
    local h
    h=$(cwd_hash "$cwd")
    echo "$STATE_DIR/$sid--$h.json"
}

# ----- mutation guard (mkdir-based lock; macOS lacks flock) -----

# _with_lock <state-file> <command...>
# mkdir is atomic on POSIX FS — use as lock primitive.
# Retry budget: 50 × 100ms = 5s. Stale lock (≥60s) auto-cleared (only when mtime
# can be determined — undetermined mtime treated as fresh to avoid false stale).
# Lock timeout → caller fails with rc=99 + audit log entry. Mutation NOT executed
# without lock — prevents silent corruption.
_with_lock() {
    local f="$1"; shift
    local lockdir="$f.lockd"
    local i=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        # stale lock detection — both stat variants must succeed
        local mtime
        mtime=$(stat -f %m "$lockdir" 2>/dev/null || stat -c %Y "$lockdir" 2>/dev/null || echo "")
        if [ -n "$mtime" ]; then
            local age=$(( $(date +%s) - mtime ))
            if [ "$age" -gt 60 ]; then
                rmdir "$lockdir" 2>/dev/null || true
                continue
            fi
        fi
        i=$((i + 1))
        if [ "$i" -gt 50 ]; then
            local ts
            ts=$(date +%Y-%m-%dT%H:%M:%S%z)
            printf '[%s] lock_timeout file=%s\n' "$ts" "$f" >> "$AUDIT_LOG" 2>/dev/null
            echo "[session-state] lock timeout for $f — mutation skipped" >&2
            return 99
        fi
        sleep 0.1
    done
    # 락 획득. cleanup은 outer rmdir 한 곳에서만 (subshell trap 제거 — 이전 V3에는
    # 둘 다 있어 다른 acquired lock을 가로채는 race 가능 (V3 reviewer #1)).
    local rc=0
    ( "$@" ) || rc=$?
    rmdir "$lockdir" 2>/dev/null || true
    return $rc
}

# ----- init -----

state_init() {
    local sid="$1" cwd="${2:-}" model="${3:-unknown}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] && return 0
    _with_lock "$f" _state_init_inner "$f" "$sid" "$cwd" "$model"
}

_state_init_inner() {
    local f="$1" sid="$2" cwd="$3" model="$4"
    [ -f "$f" ] && return 0
    jq -n \
        --arg sid "$sid" --arg cwd "$cwd" --arg model "$model" \
        --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        --argjson sv "$SCHEMA_VERSION" '{
            schema_version: $sv,
            session_id: $sid,
            cwd: $cwd,
            model: $model,
            started_at: $ts,
            stage: "init",
            history: [],
            explore_count: 0,
            plan_approved_at: null,
            approval_nonce: null,
            ci_passed_at: null,
            review_ts: null,
            verdict_nonces: {},
            last_verdicts: {review: {}, plan: {}},
            verdict_missing_count: {},
            verdict_errors: {},
            verdict_unset_expected_set_count: 0,
            review_expected_set: []
        }' > "$f"
}

# ----- read -----

state_get() {
    local sid="$1" path="$2" cwd="${3:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || return 1
    jq -r "$path // empty" "$f" 2>/dev/null
}

# ----- write -----

state_set_json() {
    local sid="$1" path="$2" json_value="$3" cwd="${4:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || { echo "[session-state] state missing for $sid; call state_init first" >&2; return 1; }
    _with_lock "$f" _state_set_json_inner "$f" "$path" "$json_value"
}

_state_set_json_inner() {
    local f="$1" path="$2" json_value="$3"
    local tmp
    tmp=$(mktemp)
    if jq --argjson v "$json_value" "$path = \$v" "$f" > "$tmp"; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        printf '[%s] jq_error file=%s op=set_json path=%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$f" "$path" >> "$AUDIT_LOG" 2>/dev/null
        return 1
    fi
}

state_set_str() {
    local sid="$1" path="$2" str_value="$3" cwd="${4:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || { echo "[session-state] state missing for $sid; call state_init first" >&2; return 1; }
    _with_lock "$f" _state_set_str_inner "$f" "$path" "$str_value"
}

_state_set_str_inner() {
    local f="$1" path="$2" str_value="$3"
    local tmp
    tmp=$(mktemp)
    if jq --arg v "$str_value" "$path = \$v" "$f" > "$tmp"; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        printf '[%s] jq_error file=%s op=set_str path=%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$f" "$path" >> "$AUDIT_LOG" 2>/dev/null
        return 1
    fi
}

state_increment() {
    local sid="$1" path="$2" cwd="${3:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || { echo "[session-state] state missing for $sid; call state_init first" >&2; return 1; }
    _with_lock "$f" _state_increment_inner "$f" "$path"
}

_state_increment_inner() {
    local f="$1" path="$2"
    local tmp
    tmp=$(mktemp)
    if jq "$path = ($path // 0) + 1" "$f" > "$tmp"; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        printf '[%s] jq_error file=%s op=increment path=%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$f" "$path" >> "$AUDIT_LOG" 2>/dev/null
        return 1
    fi
}

state_decrement() {
    local sid="$1" path="$2" cwd="${3:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || return 0
    _with_lock "$f" _state_decrement_inner "$f" "$path"
}

_state_decrement_inner() {
    local f="$1" path="$2"
    local tmp
    tmp=$(mktemp)
    if jq "$path = (if ($path // 0) > 0 then $path - 1 else 0 end)" "$f" > "$tmp"; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        printf '[%s] jq_error file=%s op=decrement path=%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$f" "$path" >> "$AUDIT_LOG" 2>/dev/null
        return 1
    fi
}

# ----- stage transitions -----

# stage_mark <sid> <stage> <status:completed|skipped> [by] [reason] [cwd]
stage_mark() {
    local sid="$1" stage="$2" status="$3" by="${4:-}" reason="${5:-}" cwd="${6:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || state_init "$sid" "$cwd" "${SAZO_MODEL:-unknown}"
    _with_lock "$f" _stage_mark_inner "$f" "$stage" "$status" "$by" "$reason" "$sid"
}

_stage_mark_inner() {
    local f="$1" stage="$2" status="$3" by="$4" reason="$5" sid="$6"
    local tmp ts
    tmp=$(mktemp)
    ts=$(date +%Y-%m-%dT%H:%M:%S%z)
    if jq --arg stage "$stage" --arg status "$status" --arg by "$by" \
        --arg reason "$reason" --arg ts "$ts" '
        .history += [{stage: $stage, status: $status, by: $by, reason: $reason, ts: $ts}]
        | .stage = $stage
    ' "$f" > "$tmp"; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        printf '[%s] jq_error file=%s op=stage_mark stage=%s\n' "$ts" "$f" "$stage" >> "$AUDIT_LOG" 2>/dev/null
        return 1
    fi
    printf '[%s] %s stage=%s status=%s by=%s reason=%q\n' \
        "$ts" "$sid" "$stage" "$status" "$by" "$reason" >> "$AUDIT_LOG"
}

# stage_is_passed <sid> <stage> [cwd]
# completed OR skipped 이면 passed.
# Validator (defense-in-depth):
# - approval: completed면 by="user" required (UserPromptSubmit→nonce 경로) AND
#             plan_approved_at not null. skipped는 절대 인정 안 함.
# - ci: completed면 by="user" or by="auto" (PostToolUse hook이 ci 매치 시 마킹).
#       skipped는 by="user" only (SAZO_ALLOW_CI_SKIP env 경로).
# 다른 stage: completed/skipped 어느 쪽이든 by 무관 (일반 stage).
stage_is_passed() {
    local sid="$1" stage="$2" cwd="${3:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || return 1
    case "$stage" in
        approval)
            jq -e '
                (.plan_approved_at != null)
                and (.history | any(.stage == "approval" and .status == "completed" and .by == "user"))
            ' "$f" >/dev/null 2>&1
            ;;
        ci)
            jq -e '
                .history | any(
                    .stage == "ci"
                    and ((.status == "completed" and (.by == "user" or .by == "auto"))
                        or (.status == "skipped" and .by == "user"))
                )
            ' "$f" >/dev/null 2>&1
            ;;
        *)
            jq -e --arg s "$stage" '
                .history | any(.stage == $s and (.status == "completed" or .status == "skipped"))
            ' "$f" >/dev/null 2>&1
            ;;
    esac
}

# 가장 최근 history 끝부터 연속 skipped 개수
consecutive_skip_count() {
    local sid="$1" cwd="${2:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || { echo 0; return; }
    [ -f "$f" ] || { echo 0; return; }
    jq -r '[.history[].status] | reverse | .[]' "$f" 2>/dev/null | awk '
        /^skipped$/ { count++; next }
        { exit }
        END { print count+0 }
    '
}

# ----- approval nonce (UserPromptSubmit hook이 set, /approved가 consume) -----

approval_nonce_set() {
    local sid="$1" nonce="$2" cwd="${3:-${SAZO_CWD:-}}"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || state_init "$sid" "$cwd" "${SAZO_MODEL:-unknown}"
    state_set_str "$sid" ".approval_nonce" "$nonce" "$cwd"
}

approval_nonce_consume() {
    local sid="$1" nonce="$2" cwd="${3:-${SAZO_CWD:-}}"
    local stored
    stored=$(state_get "$sid" ".approval_nonce" "$cwd")
    [ -n "$stored" ] && [ "$stored" = "$nonce" ] || return 1
    state_set_json "$sid" ".approval_nonce" "null" "$cwd"
    return 0
}

# ----- hook payload reader -----

read_hook_payload() {
    local payload
    payload=$(cat)
    export SAZO_HOOK_PAYLOAD="$payload"
    export SAZO_SESSION_ID
    SAZO_SESSION_ID=$(echo "$payload" | jq -r '.session_id // ""')
    export SAZO_CWD
    SAZO_CWD=$(echo "$payload" | jq -r '.cwd // ""')
    export SAZO_TOOL_NAME
    SAZO_TOOL_NAME=$(echo "$payload" | jq -r '.tool_name // ""')
    export SAZO_TOOL_INPUT
    SAZO_TOOL_INPUT=$(echo "$payload" | jq -c '.tool_input // {}')
    export SAZO_TOOL_RESPONSE
    SAZO_TOOL_RESPONSE=$(echo "$payload" | jq -c '.tool_response // {}')
    export SAZO_MODEL
    SAZO_MODEL=$(echo "$payload" | jq -r '.model // env.CLAUDE_MODEL // ""')
    export SAZO_USER_PROMPT
    SAZO_USER_PROMPT=$(echo "$payload" | jq -r '.prompt // ""')
}

# simple_audit: temporary audit log helper. plan 02 will replace with JSON Lines audit_log.
simple_audit() {
    local event="$1"
    shift
    local extras=""
    while [ $# -gt 0 ]; do
        extras="$extras $1"
        shift
    done
    printf '[%s] %s%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$event" "$extras" >> "$AUDIT_LOG" 2>/dev/null || true
}

# process_verdict_tracked_post_task: end-to-end handler for verdict-tracked subagent
# Task PostToolUse. Parses footer, validates nonce, records verdict, evaluates
# stage completion. Honors SAZO_VERDICT_FOOTER_ENFORCE (warn|block).
#
# Args: sid cwd stage agent result_text
# Returns: 0 always (decisions encoded in audit log + state)
process_verdict_tracked_post_task() {
    local sid="$1" cwd="$2" stage="$3" agent="$4" result_text="$5"

    # Allowlist: caller (handle_post Task case statement) already filters, but
    # defense-in-depth — reject unknown agents to prevent shell injection via
    # agent name in env var lookup below.
    case "$agent" in
        code-reviewer|architect-advisor|plan-critic|plan-auditor) ;;
        *)
            simple_audit "verdict_unknown_agent" "agent=$agent"
            return 0
            ;;
    esac

    local parse status
    parse=$(parse_verdict_footer "$result_text")
    status=$(printf '%s\n' "$parse" | awk -F= '/^STATUS=/{print $2; exit}')

    case "$status" in
        truncated)
            simple_audit "verdict_truncated" "agent=$agent" "stage=$stage"
            return 0
            ;;
        missing)
            state_increment "$sid" ".verdict_missing_count[\"$agent\"]" "$cwd"
            local enforce_global enforce_agent enforce
            enforce_global="${SAZO_VERDICT_FOOTER_ENFORCE:-warn}"
            # Indirect expansion via ${!var} (bash 4+) — no eval needed.
            # agent already validated by allowlist above; agent_upper is
            # ASCII-only after tr.
            local agent_upper
            agent_upper=$(printf '%s' "$agent" | tr 'a-z-' 'A-Z_')
            local agent_var="SAZO_VERDICT_FOOTER_ENFORCE_${agent_upper}"
            enforce_agent="${!agent_var:-}"
            enforce="${enforce_agent:-$enforce_global}"

            if [ "$enforce" = "block" ]; then
                simple_audit "verdict_missing_block" "agent=$agent" "stage=$stage"
                return 0
            fi
            # Phase 1 warn: legacy fallback stage_mark
            simple_audit "verdict_missing_warn" "agent=$agent" "stage=$stage"
            stage_is_passed "$sid" "$stage" \
                || stage_mark "$sid" "$stage" "completed" "auto" "subagent=$agent (Phase 1: footer missing)" "$cwd"
            return 0
            ;;
        ok)
            ;;
        *)
            simple_audit "verdict_parse_error" "agent=$agent" "stage=$stage" "status=$status"
            return 0
            ;;
    esac

    # status=ok — extract fields
    local nonce verdict issues
    nonce=$(printf '%s\n' "$parse" | awk -F= '/^NONCE=/{print $2; exit}')
    verdict=$(printf '%s\n' "$parse" | awk -F= '/^VERDICT=/{print $2; exit}')
    issues=$(printf '%s\n' "$parse" | awk -F= '/^ISSUES=/{print $2; exit}')

    # Validate nonce + agent binding
    if ! verdict_nonce_consume "$sid" "$cwd" "$nonce" "$agent"; then
        simple_audit "verdict_nonce_invalid" "agent=$agent" "stage=$stage" "nonce=$nonce"
        return 0
    fi

    # Record verdict (replace-by-agent)
    local entry
    entry=$(jq -nc --arg v "$verdict" --argjson i "${issues:-0}" --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '{verdict: $v, issues: $i, ts: $ts}')
    state_set_json "$sid" ".last_verdicts[\"$stage\"][\"$agent\"]" "$entry" "$cwd"

    # Evaluate stage completion
    if _evaluate_stage_completion "$sid" "$cwd" "$stage"; then
        stage_is_passed "$sid" "$stage" \
            || stage_mark "$sid" "$stage" "completed" "auto" "verdict aggregation: all APPROVE" "$cwd"
    fi

    # Cap state.json size (best-effort; failure is non-fatal).
    _maybe_truncate_state "$sid" "$cwd" || true

    return 0
}

# _maybe_truncate_state: cap state.json size to 1MB. Preserve invariants:
#   1. Last 50 history entries (recent activity)
#   2. All ci/approval completed entries (stage_is_passed dependency — line 273-300)
# Drop oldest non-essential entries. audit.log untouched (separate file).
SAZO_STATE_MAX_BYTES="${SAZO_STATE_MAX_BYTES:-1048576}"  # 1MB

_maybe_truncate_state() {
    local sid="$1" cwd="$2"
    local f
    f=$(state_file "$sid" "$cwd") || return 1
    [ -f "$f" ] || return 0

    local sz
    sz=$(wc -c <"$f" | tr -d ' ')
    [ "$sz" -lt "$SAZO_STATE_MAX_BYTES" ] && return 0

    local tmp="$f.trunc.tmp"
    if jq '
        .history |= (
            (
                ([.[-50:][]]) +
                ([.[] | select(.stage=="ci" or .stage=="approval") | select(.status=="completed")])
            )
            | unique_by(.ts + "|" + (.stage // "") + "|" + (.status // "") + "|" + (.by // "") + "|" + (.reason // ""))
            | sort_by(.ts)
        )
    ' "$f" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"
    else
        rm -f "$tmp"
        return 1
    fi
}

# _record_reviewer_error: increment per-agent error counter; emit user escalation
# at threshold 3. Stage gate stays incomplete (no stage_mark). Called by hook when
# subagent Task returned is_error/interrupted.
_record_reviewer_error() {
    local sid="$1" cwd="$2" agent="$3"
    state_increment "$sid" ".verdict_errors[\"$agent\"]" "$cwd"
    local count
    count=$(state_get "$sid" ".verdict_errors[\"$agent\"]" "$cwd")
    if [ -n "$count" ] && [ "$count" -ge 3 ] 2>/dev/null; then
        cat >&2 <<EOF
[workflow-block] reviewer $agent stuck ($count consecutive errors).
Action required:
  - Inspect last reviewer Task output
  - Rerun reviewer Task with same expected output, OR
  - User: /skip review <reason>
EOF
    fi
}

# _evaluate_stage_completion: returns 0 if stage can be marked completed based on
# verdict aggregation, 1 otherwise. Reads review_expected_set (or fixed plan set),
# checks all expected reviewers responded with APPROVE.
# Honors SAZO_VERDICT_EMPTY_EXPECTED (fail_open|fail_closed, default fail_open)
# when expected_set is empty.
_evaluate_stage_completion() {
    local sid="$1" cwd="$2" stage="$3"

    local expected_json
    case "$stage" in
        review)
            expected_json=$(state_get "$sid" '.review_expected_set // []' "$cwd")
            [ -z "$expected_json" ] && expected_json='[]'
            ;;
        plan)
            expected_json='["plan-critic","plan-auditor"]'
            ;;
        *)
            return 1
            ;;
    esac

    local expected_count
    expected_count=$(printf '%s' "$expected_json" | jq 'length')

    if [ "$expected_count" -eq 0 ]; then
        # Empty expected_set — caller (skill/command) didn't declare reviewer set.
        state_increment "$sid" ".verdict_unset_expected_set_count" "$cwd"

        local mode="${SAZO_VERDICT_EMPTY_EXPECTED:-fail_open}"
        if [ "$mode" = "fail_closed" ]; then
            return 1
        fi
        # fail_open: pass if any received verdict is APPROVE
        local any_approve
        any_approve=$(state_get "$sid" ".last_verdicts[\"$stage\"] // {} | to_entries | map(.value.verdict) | any(. == \"APPROVE\")" "$cwd")
        # state_get strips false→empty; treat "true" string as success
        [ "$any_approve" = "true" ]
        return $?
    fi

    # Normal path: every expected agent must have APPROVE in last_verdicts.<stage>
    local sf
    sf=$(state_file "$sid" "$cwd")
    local result
    result=$(jq -r --argjson exp "$expected_json" --arg stage "$stage" '
        (.last_verdicts[$stage] // {}) as $last |
        ($exp | map($last[.]?.verdict)) as $vs |
        if ($vs | any(. == null)) then "false"
        elif ($vs | all(. == "APPROVE")) then "true"
        else "false"
        end
    ' "$sf")
    [ "$result" = "true" ]
}

# verdict_nonce_issue: mint a random nonce bound to (agent, stage). Caller embeds
# the nonce into the Task prompt so subagent must echo it in its footer.
# Returns the nonce on stdout (32-hex chars).
verdict_nonce_issue() {
    local sid="$1" cwd="$2" agent="$3" stage="$4"
    local nonce
    if command -v openssl >/dev/null 2>&1; then
        nonce=$(openssl rand -hex 16)
    else
        nonce=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 32)
    fi
    local entry
    entry=$(jq -nc \
        --arg agent "$agent" \
        --arg stage "$stage" \
        --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        '{agent: $agent, stage: $stage, issued_at: $ts, consumed: false}')
    state_set_json "$sid" ".verdict_nonces[\"$nonce\"]" "$entry" "$cwd" || return 1
    printf '%s' "$nonce"
}

# verdict_nonce_consume: validate (nonce exists, agent matches, not yet consumed)
# and atomically mark consumed. Returns 0 on success, 1 on rejection.
verdict_nonce_consume() {
    local sid="$1" cwd="$2" nonce="$3" agent="$4"

    # Validate nonce format defensively
    case "$nonce" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) return 1 ;;
    esac

    # Lookup entry
    local entry
    entry=$(state_get "$sid" ".verdict_nonces[\"$nonce\"] // null" "$cwd")
    if [ -z "$entry" ] || [ "$entry" = "null" ]; then
        return 1
    fi

    local registered_agent consumed
    registered_agent=$(printf '%s' "$entry" | jq -r '.agent // ""')
    consumed=$(printf '%s' "$entry" | jq -r '.consumed // false')

    if [ "$registered_agent" != "$agent" ]; then
        return 1
    fi
    if [ "$consumed" != "false" ]; then
        return 1
    fi

    # Atomically flip consumed (state_set_json wraps with _with_lock)
    state_set_json "$sid" ".verdict_nonces[\"$nonce\"].consumed" "true" "$cwd" || return 1
    return 0
}

# parse_verdict_footer: extract last SAZO verdict envelope from subagent output text.
# Robust against JSONL leak (GH #20531): only the LAST complete envelope is parsed.
# Outputs key=value lines on stdout. Fields: STATUS, NONCE, VERDICT, ISSUES.
# STATUS values:
#   ok        - envelope complete and well-formed
#   truncated - BEGIN marker found but END missing, or envelope present but missing required fields
#   missing   - no BEGIN marker found
parse_verdict_footer() {
    local text="$1"

    # Extract last complete BEGIN..END block via awk sentinel pattern.
    local envelope
    envelope=$(printf '%s\n' "$text" | awk '
        /^---SAZO_FOOTER_BEGIN---$/{ buf=""; flag=1; next }
        /^---SAZO_FOOTER_END---$/{
            if (flag) { last=buf; have=1 }
            flag=0; next
        }
        flag{ buf = buf $0 "\n" }
        END{ if (have) printf "%s", last }
    ')

    if [ -z "$envelope" ]; then
        # Distinguish truncated (BEGIN seen, no END) vs fully missing.
        if printf '%s\n' "$text" | grep -q '^---SAZO_FOOTER_BEGIN---$'; then
            printf 'STATUS=truncated\n'
            return 0
        fi
        printf 'STATUS=missing\n'
        return 0
    fi

    # Parse fields from envelope. Strict regex — anything else = malformed.
    local nonce verdict issues
    nonce=$(printf '%s\n' "$envelope" | grep -oE '^SAZO_VERDICT_NONCE: [0-9a-f]{32}$' | awk '{print $2}')
    verdict=$(printf '%s\n' "$envelope" | grep -oE '^SAZO_VERDICT: (APPROVE|BLOCK|NEEDS_REVISION)$' | awk '{print $2}')
    issues=$(printf '%s\n' "$envelope" | grep -oE '^SAZO_BLOCKING_ISSUES: [0-9]+$' | awk '{print $2}')

    if [ -z "$nonce" ] || [ -z "$verdict" ]; then
        printf 'STATUS=truncated\n'
        return 0
    fi

    printf 'STATUS=ok\nNONCE=%s\nVERDICT=%s\nISSUES=%s\n' \
        "$nonce" "$verdict" "${issues:-0}"
}
