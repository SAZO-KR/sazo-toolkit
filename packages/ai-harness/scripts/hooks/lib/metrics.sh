#!/bin/bash
# metrics.sh — hook health check + metrics append helpers.
#
# Sourced by session-state.sh (bottom-source pattern).
# Do NOT source this file directly from hook scripts — source session-state.sh instead.
# Do NOT source session-state.sh here (would cycle).
#
# Deps (provided by parent at source time):
#   state_dir  — function (returns STATE_DIR path)
#   STATE_DIR  — variable
#
# No set directives — inherits caller's set -uo pipefail.

# ----- Plan 13 Stage A additions -----

# _append_metrics_inner: append a single JSONL line to dest.
# Called inside _with_lock to ensure atomic append.
_append_metrics_inner() {
    local line="$1" dest="$2"
    printf '%s\n' "$line" >> "$dest"
}

# hook_healthy 7-check:
#   1. ~/.claude/settings.json exists
#   2. .hooks.SessionEnd[] OR .hooks.PreToolUse[] defined (OR branch)
#   3. state_dir writable
#   4. jq available
#   5. _with_lock operable (mkdir simulate)
#   6. hook command paths all exist
#   7. SAZO_HARNESS_DIR resolvable
hook_healthy() {
    # check 1
    [ -f "${HOME}/.claude/settings.json" ] || return 1
    # check 2 — OR branch
    local has_pre has_end
    has_pre=$(jq -r '.hooks.PreToolUse // empty | length' "${HOME}/.claude/settings.json" 2>/dev/null)
    has_end=$(jq -r '.hooks.SessionEnd // empty | length' "${HOME}/.claude/settings.json" 2>/dev/null)
    { [ -n "$has_pre" ] && [ "$has_pre" -gt 0 ]; } \
        || { [ -n "$has_end" ] && [ "$has_end" -gt 0 ]; } \
        || return 1
    # check 3
    [ -w "$(state_dir)" ] || return 1
    # check 4
    command -v jq >/dev/null 2>&1 || return 1
    # check 5 — mkdir simulate (use state_dir() so SAZO_STATE_DIR override is respected)
    local check_path="$(state_dir)/.healthcheck-$$"
    mkdir -p "$check_path" 2>/dev/null || return 1
    rmdir "$check_path" 2>/dev/null || true
    # check 6 — hook command paths exist
    # Extract all command values from SessionEnd and PreToolUse hook arrays.
    # settings.json schema: .hooks.{SessionEnd,PreToolUse}[] can be:
    #   flat: {"type":"command","command":"<path>"}
    #   or nested: {"hooks":[{"type":"command","command":"<path>"}]}
    # We try both shapes with // empty to be safe.
    local cmd
    while IFS= read -r cmd; do
        [ -z "$cmd" ] && continue
        case "$cmd" in
            /*) [ -e "$cmd" ] || return 1 ;;
            *)  [ -e "${HOME}/.claude/${cmd}" ] || return 1 ;;
        esac
    done < <(jq -r '
        [
            (.hooks.SessionEnd // []),
            (.hooks.PreToolUse // [])
        ]
        | add
        | .[]?
        | (
            (.command // empty),
            ((.hooks // []) | .[]? | .command // empty)
        )
    ' "${HOME}/.claude/settings.json" 2>/dev/null)
    # check 7
    [ -n "${SAZO_HARNESS_DIR:-}" ] && [ -d "$SAZO_HARNESS_DIR" ] || return 1
    return 0
}
