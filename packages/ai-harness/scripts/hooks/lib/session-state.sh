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
