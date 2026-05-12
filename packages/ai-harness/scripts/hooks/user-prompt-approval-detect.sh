#!/usr/bin/env bash
# user-prompt-approval-detect.sh — UserPromptSubmit hook.
#
# 사용자가 직접 입력한 메시지가 승인/스킵 패턴일 때 즉시 처리.
#
# /approved — mark_approval_complete by="user" 직접 호출 (Plan 13 A0a: nonce 우회).
# /skip <stage> <reason> — stage_mark skipped by="user" 직접 호출.
#
# 패턴 — "/approved" 또는 "/skip <stage> <reason>" (앞뒤 공백 허용).
# mixed slash ("/approved /skip") 는 무시.
# 한국어 자연어 "ok/승인/go" 등은 의도적으로 제외 — 명시적 슬래시 명령만 인정.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/session-state.sh
source "$LIB_DIR/session-state.sh"
# shellcheck source=lib/slash-commands.sh
source "$LIB_DIR/slash-commands.sh"

if ! narrow_hooks_enabled; then
    exit 0
fi

read_hook_payload

[ -z "${SAZO_SESSION_ID:-}" ] && exit 0

# Trim leading/trailing whitespace from user prompt
trimmed=$(trim_leading "$SAZO_USER_PROMPT")
trimmed_rev=$(printf '%s' "$trimmed" | sed -E 's/[[:space:]]+$//')

# Parse slash command (rejects mixed slash, empty input)
parsed=$(parse_slash_command "$trimmed_rev")

# Determine first token for dispatch
first_token="${trimmed_rev%%[[:space:]]*}"

case "$first_token" in
    /approved)
        if [ -n "$parsed" ]; then
            state_init "$SAZO_SESSION_ID" "$SAZO_CWD" "${SAZO_MODEL:-unknown}"
            mark_approval_complete "$SAZO_SESSION_ID" "user" "/approved" "$SAZO_CWD"
        fi
        ;;
    /skip)
        if [ -n "$parsed" ]; then
            # parsed = "skip <stage> <reason...>"
            # Strip "skip " prefix to get "<stage> <reason...>"
            local_rest="${parsed#skip}"
            local_rest=$(trim_leading "$local_rest")
            # Extract stage (first word) and reason (rest)
            skip_stage="${local_rest%%[[:space:]]*}"
            skip_reason_raw="${local_rest#"$skip_stage"}"
            skip_reason=$(trim_leading "$skip_reason_raw")
            if [ -n "$skip_stage" ]; then
                state_init "$SAZO_SESSION_ID" "$SAZO_CWD" "${SAZO_MODEL:-unknown}"
                stage_mark "$SAZO_SESSION_ID" "$skip_stage" "skipped" "user" "$skip_reason" "$SAZO_CWD"
            fi
        fi
        ;;
    /override-skip-streak)
        if [ -n "$parsed" ]; then
            local_rest="${parsed#override-skip-streak}"
            local_rest=$(trim_leading "$local_rest")
            local_rest=$(printf '%s' "$local_rest" | sed -E 's/[[:space:]]+$//')

            # Empty reason → reject (audit + no nonce mint).
            if [ -z "$local_rest" ]; then
                state_init "$SAZO_SESSION_ID" "$SAZO_CWD" "${SAZO_MODEL:-unknown}"
                audit_log "skip_streak_override_rejected" "$SAZO_SESSION_ID" "" "" "user" "reason=empty"
                echo "[skip-streak] /override-skip-streak requires <reason> argument" >&2
                exit 0
            fi

            state_init "$SAZO_SESSION_ID" "$SAZO_CWD" "${SAZO_MODEL:-unknown}"
            if command -v openssl >/dev/null 2>&1; then
                nonce=$(openssl rand -hex 16)
            else
                nonce=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 32)
            fi
            skip_streak_override_set "$SAZO_SESSION_ID" "$nonce" "$SAZO_CWD"
            audit_log "skip_streak_override" "$SAZO_SESSION_ID" "" "" "user" "reason=$local_rest"
            echo "[skip-streak] override issued. Next mutating tool will pass once." >&2
        fi
        ;;
    /allow-dangerous)
        if [ -n "$parsed" ]; then
            local_rest="${parsed#allow-dangerous}"
            local_rest=$(trim_leading "$local_rest")
            state_init "$SAZO_SESSION_ID" "$SAZO_CWD" "${SAZO_MODEL:-unknown}"
            nonce_val=""
            if command -v openssl >/dev/null 2>&1; then
                nonce_val=$(openssl rand -hex 16)
            else
                nonce_val=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 32)
            fi
            dangerous_nonce_set "$SAZO_SESSION_ID" "$nonce_val" "$local_rest" "$SAZO_CWD"
        fi
        ;;
esac

exit 0
