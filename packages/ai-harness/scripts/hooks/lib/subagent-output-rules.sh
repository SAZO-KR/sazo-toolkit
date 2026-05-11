#!/usr/bin/env bash
# subagent-output-rules.sh — Stage A' output audit rule functions.
#
# Source this lib, then call rule_* functions against output text.
# Each rule emits a warn entry via audit_log (caller must source session-state.sh).
# All rules return 0 (warn-only; never block).
#
# subagent_type_sanitize: safe key for jq path / audit log.

set -uo pipefail

# subagent_type_sanitize <raw_type>
# Strips characters that could break jq path or log injection.
# Allowed: a-z A-Z 0-9 underscore. Everything else → removed.
# Additionally: dash/dot → underscore (tr), then strip remaining non-alnum-underscore.
subagent_type_sanitize() {
    local raw="$1"
    # BSD tr does not support multi-char string1 with '-' as a flag — use two tr calls.
    # First: dash → underscore, dot → underscore (each tr call handles one char class).
    # Then: strip everything not alnum-underscore.
    printf '%s' "$raw" \
        | tr -- '-' '_' \
        | tr '.' '_' \
        | tr -cd 'a-zA-Z0-9_'
}

# rule_secret_pattern <text>
# Detects common secret-like patterns in output.
# Returns 0 always; emits audit warn if pattern found.
rule_secret_pattern() {
    local text="$1" sid="${2:-}" agent="${3:-}"
    local found=0

    # Match common secret patterns (case-insensitive where feasible).
    # Patterns: KEY=, SECRET=, PASSWORD=, TOKEN=, PASSWD=, CREDENTIAL=, API_KEY=
    if printf '%s\n' "$text" | grep -qiE \
        '(AWS_SECRET|API_KEY|SECRET_KEY|PASSWORD|PASSWD|TOKEN|CREDENTIAL|PRIVATE_KEY)[[:space:]]*='; then
        found=1
    fi

    if [ "$found" = "1" ]; then
        audit_log "output_audit_warn_secret" "$sid" "" "" "rule" \
            "secret-like pattern detected in subagent output; agent=$agent"
    fi
    return 0
}

# rule_large_dump <text>
# Warns if output exceeds 1MB.
rule_large_dump() {
    local text="$1" sid="${2:-}" agent="${3:-}"
    local size
    size=$(printf '%s' "$text" | wc -c | tr -d ' ')
    if [ "${size:-0}" -gt 1048576 ] 2>/dev/null; then
        audit_log "output_audit_warn_large" "$sid" "" "" "rule" \
            "output size ${size} bytes exceeds 1MB; agent=$agent"
    fi
    return 0
}

# rule_binary_content <text>
# Warns if output contains NUL bytes or high ratio of non-printable chars.
# Uses a heuristic: if file -b sees binary indicators or grep -P finds NUL (GNU).
# Fallback on macOS where grep -P may be unsupported: check via awk NUL scan.
rule_binary_content() {
    local text="$1" sid="${2:-}" agent="${3:-}"
    local found=0

    # Method 1: grep -P NUL byte (GNU grep, Linux)
    if printf '%s' "$text" | grep -qP '\x00' 2>/dev/null; then
        found=1
    fi

    # Method 2: awk NUL scan (portable fallback)
    if [ "$found" = "0" ]; then
        if printf '%s' "$text" | awk 'BEGIN{RS=""}{for(i=1;i<=length($0);i++){c=substr($0,i,1);if(c=="\000"){found=1;exit}}}END{exit !found}' 2>/dev/null; then
            found=1
        fi
    fi

    if [ "$found" = "1" ]; then
        audit_log "output_audit_warn_binary" "$sid" "" "" "rule" \
            "binary content (NUL bytes) detected in subagent output; agent=$agent"
    fi
    return 0
}
