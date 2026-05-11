#!/usr/bin/env bash
# post-task-output-audit.sh — PostToolUse Task output audit hook.
#
# Warn-only. Applies output rules (secret pattern, large dump, binary content)
# to Task tool_response. Does not block (exit 0 always).
#
# Opt-out: SAZO_DISABLE_TASK_OUTPUT_AUDIT=1

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/session-state.sh
source "$LIB_DIR/session-state.sh"
# shellcheck source=lib/subagent-output-rules.sh
source "$LIB_DIR/subagent-output-rules.sh"

if [ "${SAZO_DISABLE_TASK_OUTPUT_AUDIT:-0}" = "1" ]; then
    exit 0
fi

# Only active when workflow hooks enabled (same guard as other hooks)
if ! workflow_hooks_enabled; then
    exit 0
fi

# Save stdin to a temp file first — large payloads (>1MB result fields) cannot
# be passed as shell arguments to jq without hitting ARG_MAX. Reading from a
# file is always safe regardless of size.
_AUDIT_PAYLOAD_TMP=$(mktemp)
trap 'rm -f "$_AUDIT_PAYLOAD_TMP"' EXIT
cat > "$_AUDIT_PAYLOAD_TMP"

# Parse fields from the saved payload file (no shell variable expansion of large strings).
_AUDIT_SESSION_ID=$(jq -r '.session_id // ""' "$_AUDIT_PAYLOAD_TMP" 2>/dev/null || true)
_AUDIT_CWD=$(jq -r '.cwd // ""' "$_AUDIT_PAYLOAD_TMP" 2>/dev/null || true)
_AUDIT_TOOL_NAME=$(jq -r '.tool_name // ""' "$_AUDIT_PAYLOAD_TMP" 2>/dev/null || true)
_AUDIT_MODEL=$(jq -r '.model // ""' "$_AUDIT_PAYLOAD_TMP" 2>/dev/null || true)

# Export what session-state.sh functions expect (used by audit_log).
export SAZO_SESSION_ID="$_AUDIT_SESSION_ID"
export SAZO_CWD="$_AUDIT_CWD"
export SAZO_TOOL_NAME="$_AUDIT_TOOL_NAME"
export SAZO_MODEL="$_AUDIT_MODEL"

# Only handle Task tool
[ "$SAZO_TOOL_NAME" = "Task" ] || exit 0

[ -z "${SAZO_SESSION_ID:-}" ] && exit 0

# Sanitize subagent_type for safe use in audit log keys
raw_type=$(jq -r '.tool_input.subagent_type // ""' "$_AUDIT_PAYLOAD_TMP" 2>/dev/null || true)
safe_type=$(subagent_type_sanitize "$raw_type")

# Skip if sanitized type is empty (metachars only input → injection attempt → skip)
if [ -z "$safe_type" ]; then
    audit_log "output_audit_skip_bad_type" "$SAZO_SESSION_ID" "" "" "rule" \
        "subagent_type sanitized to empty; raw=$raw_type"
    exit 0
fi

# Extract result text from the payload file (safe for any size).
result_text=$(jq -r '.tool_response.result // ""' "$_AUDIT_PAYLOAD_TMP" 2>/dev/null || true)

# Apply rules (all warn-only)
rule_secret_pattern "$result_text" "$SAZO_SESSION_ID" "$safe_type"
rule_large_dump "$result_text" "$SAZO_SESSION_ID" "$safe_type"
rule_binary_content "$result_text" "$SAZO_SESSION_ID" "$safe_type"

exit 0
