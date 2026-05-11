#!/usr/bin/env bash
# Plan 13 Stage A — SessionEnd metrics hook
# Records session-end metrics to ~/.claude/state/session-metrics-<session_id>.jsonl
#
# Known limitations (see docs/workflow-hooks.md "SessionEnd hook known limitations"):
#   - /exit does not fire SessionEnd (GH#17885, #35892) — use Ctrl+D
#   - /clear does not fire SessionEnd (GH#6428)
#   - Ctrl+C → fires but may be mid-execution kill (GH#32712)
#   - --continue resume → stale session_id/transcript_path (GH#9188)
#   - async 5s+ tasks killed (GH#41577) — timeout 5 wrapper applied

set -uo pipefail

# Resolve harness dir (SAZO_HARNESS_DIR env > script-relative fallback)
if [ -z "${SAZO_HARNESS_DIR:-}" ]; then
    SAZO_HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fi

# Source dependencies
source "${SAZO_HARNESS_DIR}/scripts/hooks/lib/session-state.sh" \
    || { echo "post-session-end-metrics: failed to source session-state.sh" >&2; exit 0; }

# Portable timeout helper (BSD timeout absent on macOS base install)
# _with_lock is a shell function — external timeout/perl cannot exec it directly.
# When the target is a shell function, we export it and wrap in a subshell for
# timeout, or fall back to direct invocation (per OQ6 decision, Plan 13 Stage A).
# Record loss window <5s is accepted per Plan 13 R8 risk note.
_run_with_timeout() {
    local secs="$1"; shift

    # If first arg is a shell function, external timeout binaries cannot exec it.
    # Export all needed functions and run in a subshell with timeout -k.
    if [ "$(type -t "$1" 2>/dev/null)" = "function" ]; then
        if command -v timeout >/dev/null 2>&1; then
            # Export functions for subshell access
            export -f _with_lock _append_metrics_inner audit_log 2>/dev/null || true
            timeout "${secs}s" bash -c '"$@"' -- "$@"
        elif command -v gtimeout >/dev/null 2>&1; then
            export -f _with_lock _append_metrics_inner audit_log 2>/dev/null || true
            gtimeout "${secs}s" bash -c '"$@"' -- "$@"
        elif command -v perl >/dev/null 2>&1; then
            # perl alarm cannot invoke shell functions — skip lock + warn
            audit_log "session-end" "warn" "perl-timeout-fallback" "skips-lock" "" \
                "perl timeout fallback skips lock for shell function: $1"
            "$@"
        else
            audit_log "session-end" "warn" "no-timeout-binary" "" "" \
                "no timeout binary available; running without timeout"
            "$@"
        fi
    else
        # Simple external command — timeout can exec directly
        if command -v timeout >/dev/null 2>&1; then
            timeout "${secs}s" "$@"
        elif command -v gtimeout >/dev/null 2>&1; then
            gtimeout "${secs}s" "$@"
        elif command -v perl >/dev/null 2>&1; then
            perl -e 'alarm shift @ARGV; exec @ARGV' "$secs" "$@"
        else
            audit_log "session-end" "warn" "no-timeout-binary" "" "" \
                "no timeout binary available; running without timeout"
            "$@"
        fi
    fi
}

# Read SessionEnd payload from stdin
payload=$(cat 2>/dev/null || true)
[ -z "$payload" ] && exit 0

# jq required for payload parsing; if absent, exit gracefully
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

# Parse 4 confirmed fields
session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty')
transcript_path=$(printf '%s' "$payload" | jq -r '.transcript_path // empty')
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty')
reason=$(printf '%s' "$payload" | jq -r '.reason // "other"')

# GH#9188 stale defense — missing session_id → skip
[ -z "$session_id" ] && {
    audit_log "session-end" "warn" "missing-session-id" "" "" "missing session_id; skipping metric record"
    exit 0
}

# Build metric record (source field discriminates SessionEnd vs stop-fallback)
now=$(date +%Y-%m-%dT%H:%M:%S%z)
record=$(jq -cn \
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
