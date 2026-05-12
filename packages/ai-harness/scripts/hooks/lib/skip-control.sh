#!/bin/bash
# skip-control.sh — autonomous-skip guard helpers.
#
# Sourced by session-state.sh (bottom-source pattern).
# Do NOT source this file directly from hook scripts — source session-state.sh instead.
# Do NOT source session-state.sh here (would cycle).
#
# Deps (provided by parent at source time):
#   audit_log   — function
#   stage_mark  — function
#   hard_block  — function (optional; callers may set SAZO_ALLOW_AUTO_SKIP instead)
#
# No set directives — inherits caller's set -uo pipefail.

# ----- Plan 13 Stage B: auto-skip wrapper -----

# WRAPPER_EXEMPT_STAGES — stages eligible for auto-skip regardless of SAZO_ALLOW_AUTO_SKIP.
#
# "worktree" is exempt because it manages its own skip policy (e.g., allowing
# passthrough on non-git repos). The global wrapper should not block these
# internal decisions, as the worktree gate itself ensures that mutation
# only happens in safe environments.
#
# Bar for adding new exempt stages: only stages that implement their own
# safety invariants and should not be subject to the global auto-skip toggle.
#
# See: proposals/harness-determinism/13-control-flow-extensions.md (Stage B).
WRAPPER_EXEMPT_STAGES=("worktree")

is_wrapper_exempt() {
    local stage="$1" s
    for s in "${WRAPPER_EXEMPT_STAGES[@]}"; do
        [ "$s" = "$stage" ] && return 0
    done
    return 1
}

# mark_skip_with_check <sid> <stage> <by> <reason> [cwd]
# Wrapper around stage_mark for skipped entries.
# - by="auto" + non-exempt stage + SAZO_ALLOW_AUTO_SKIP != 1 → hard_block (exit 2 via stderr)
# - by="auto" + non-exempt stage + SAZO_ALLOW_AUTO_SKIP=1 → warn metric + stage_mark
# - by="auto" + exempt stage → stage_mark directly
# - by != "auto" → stage_mark directly
#
# Callers that are NOT inside workflow-state-machine.sh (no hard_block helper) should
# source this lib and define hard_block before calling, or set SAZO_ALLOW_AUTO_SKIP.
mark_skip_with_check() {
    local sid="$1" stage="$2" by="$3" reason="$4" cwd="${5:-${SAZO_CWD:-}}"

    if [ "$by" = "auto" ] && ! is_wrapper_exempt "$stage"; then
        if [ "${SAZO_ALLOW_AUTO_SKIP:-0}" = "1" ]; then
            # Permitted but warn
            audit_log "auto_skip_warn" "$sid" "$stage" "skipped" "auto" \
                "SAZO_ALLOW_AUTO_SKIP=1; reason=$reason"
            stage_mark "$sid" "$stage" "skipped" "auto" "$reason" "$cwd"
        else
            # Block — emit to stderr then exit non-zero
            audit_log "auto_skip_blocked" "$sid" "$stage" "blocked" "auto" \
                "SAZO_ALLOW_AUTO_SKIP not set; reason=$reason"
            printf '[auto-skip-block] Autonomous skip of stage "%s" blocked.\n' "$stage" >&2
            printf 'Provide explicit user skip: /skip %s <reason>\n' "$stage" >&2
            printf 'Emergency override: SAZO_ALLOW_AUTO_SKIP=1\n' >&2
            # Use hard_block if available, else exit 2 directly
            if command -v hard_block >/dev/null 2>&1; then
                hard_block "skip-auto" "Autonomous skip 차단. /skip $stage <reason> 입력 필요. 극단 예외: SAZO_ALLOW_AUTO_SKIP=1"
            else
                exit 2
            fi
        fi
    else
        stage_mark "$sid" "$stage" "skipped" "$by" "$reason" "$cwd"
    fi
}
