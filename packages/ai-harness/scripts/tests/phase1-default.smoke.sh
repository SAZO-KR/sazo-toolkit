#!/bin/bash
# phase1-default.smoke.sh — Plan 06 narrow vs broad hook gate split.
# Verifies narrow_hooks_enabled (default ON) vs workflow_hooks_enabled (broad, default OFF).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$HERE/../.." && pwd)"
LIB="$HARNESS/scripts/hooks/lib/session-state.sh"
HOOKS="$HARNESS/scripts/hooks"

export SAZO_STATE_DIR="/tmp/sazo-phase1-smoke-$$"
cleanup() { rm -rf "$SAZO_STATE_DIR"; }
trap cleanup EXIT
mkdir -p "$SAZO_STATE_DIR"

PASS=0
FAIL=0
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }

# Run gate fn in subshell with custom env; print result code.
# Source failure is fatal (separate from gate result).
gate_check() {
    local fn="$1"
    local env_str="$2"
    bash -c "$env_str source '$LIB' || { echo 'FATAL: source failed' >&2; exit 99; }; $fn"
    local rc=$?
    if [ "$rc" = "99" ]; then
        echo "FATAL: session-state.sh source failed under env [$env_str]" >&2
        exit 1
    fi
    return $rc
}

echo "=== 1. Default state (no env) ==="
gate_check narrow_hooks_enabled "unset SAZO_WORKFLOW_HOOKS_ENABLED SAZO_DISABLE_NARROW_HOOKS SAZO_DISABLE_WORKFLOW_HOOKS;" \
    && pass "narrow_hooks_enabled default ON" \
    || fail "narrow_hooks_enabled default should be ON"

gate_check workflow_hooks_enabled "unset SAZO_WORKFLOW_HOOKS_ENABLED SAZO_DISABLE_NARROW_HOOKS SAZO_DISABLE_WORKFLOW_HOOKS;" \
    && fail "workflow_hooks_enabled default should be OFF" \
    || pass "workflow_hooks_enabled default OFF"

echo "=== 2. SAZO_WORKFLOW_HOOKS_ENABLED=1 ==="
gate_check narrow_hooks_enabled "export SAZO_WORKFLOW_HOOKS_ENABLED=1; unset SAZO_DISABLE_NARROW_HOOKS;" \
    && pass "narrow ON when broad enabled" \
    || fail "narrow should stay ON when broad enabled"

gate_check workflow_hooks_enabled "export SAZO_WORKFLOW_HOOKS_ENABLED=1; unset SAZO_DISABLE_WORKFLOW_HOOKS;" \
    && pass "broad ON when SAZO_WORKFLOW_HOOKS_ENABLED=1" \
    || fail "broad should be ON when SAZO_WORKFLOW_HOOKS_ENABLED=1"

echo "=== 3. SAZO_DISABLE_NARROW_HOOKS=1 ==="
gate_check narrow_hooks_enabled "export SAZO_DISABLE_NARROW_HOOKS=1; unset SAZO_WORKFLOW_HOOKS_ENABLED;" \
    && fail "narrow should be OFF when disabled" \
    || pass "narrow OFF when SAZO_DISABLE_NARROW_HOOKS=1"

gate_check workflow_hooks_enabled "export SAZO_DISABLE_NARROW_HOOKS=1; unset SAZO_WORKFLOW_HOOKS_ENABLED;" \
    && fail "broad should still be OFF (default)" \
    || pass "broad OFF by default regardless of narrow"

echo "=== 4. Both NARROW disabled + broad enabled ==="
gate_check narrow_hooks_enabled "export SAZO_DISABLE_NARROW_HOOKS=1 SAZO_WORKFLOW_HOOKS_ENABLED=1;" \
    && fail "narrow should be OFF when explicitly disabled" \
    || pass "narrow OFF (explicit disable wins)"

gate_check workflow_hooks_enabled "export SAZO_DISABLE_NARROW_HOOKS=1 SAZO_WORKFLOW_HOOKS_ENABLED=1;" \
    && pass "broad ON independent of narrow flag" \
    || fail "broad should be ON"

echo "=== 4b. SAZO_DISABLE_WORKFLOW_HOOKS=1 does NOT affect narrow ==="
gate_check narrow_hooks_enabled "export SAZO_DISABLE_WORKFLOW_HOOKS=1; unset SAZO_DISABLE_NARROW_HOOKS SAZO_WORKFLOW_HOOKS_ENABLED;" \
    && pass "narrow ON when only broad-disable set" \
    || fail "narrow should stay ON when broad-disable set (orthogonal flags)"

gate_check workflow_hooks_enabled "export SAZO_DISABLE_WORKFLOW_HOOKS=1 SAZO_WORKFLOW_HOOKS_ENABLED=1;" \
    && fail "broad should be OFF when DISABLE_WORKFLOW_HOOKS overrides ENABLE" \
    || pass "broad OFF when DISABLE_WORKFLOW_HOOKS wins over ENABLE"

echo "=== 5. Hooks use narrow_hooks_enabled (early exit when narrow OFF) ==="
# Each narrow hook should exit 0 cleanly when SAZO_DISABLE_NARROW_HOOKS=1, even without other env.
# We can't fully exercise the hook (needs payload), but invoking with empty stdin + disabled narrow
# should not crash AND should not enforce gating.
test_hook_disabled() {
    local hook="$1"
    local out rc
    out=$(SAZO_DISABLE_NARROW_HOOKS=1 SAZO_WORKFLOW_HOOKS_ENABLED=1 SAZO_STATE_DIR="$SAZO_STATE_DIR" bash "$HOOKS/$hook" </dev/null 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        pass "$hook exits 0 when narrow disabled"
    else
        fail "$hook exit=$rc when narrow disabled (out=$out)"
    fi
}

test_hook_disabled "pre-worktree-gate.sh"
test_hook_disabled "pre-exploration-gate.sh"
test_hook_disabled "user-prompt-approval-detect.sh"

# pre-commit-lint lives one level up
test_pcl_disabled() {
    local out rc
    out=$(SAZO_DISABLE_NARROW_HOOKS=1 SAZO_WORKFLOW_HOOKS_ENABLED=1 SAZO_STATE_DIR="$SAZO_STATE_DIR" bash "$HARNESS/scripts/pre-commit-lint.sh" </dev/null 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        pass "pre-commit-lint.sh exits 0 when narrow disabled"
    else
        fail "pre-commit-lint.sh exit=$rc when narrow disabled (out=$out)"
    fi
}
test_pcl_disabled

echo "=== 6. workflow-state-machine uses broad gate (not narrow) ==="
# state-machine should early-exit when broad OFF (default). narrow flag must NOT affect this.
test_wsm_broad_off_only() {
    local label="$1" env_str="$2"
    local rc
    bash -c "$env_str SAZO_STATE_DIR='$SAZO_STATE_DIR' SAZO_TOOL_NAME=Bash bash '$HOOKS/workflow-state-machine.sh' pre </dev/null >/dev/null 2>&1"
    rc=$?
    if [ $rc -eq 0 ]; then
        pass "$label: state-machine early-exits (broad gate honored)"
    else
        fail "$label: state-machine exit=$rc when broad OFF"
    fi
}
test_wsm_broad_off_only "broad OFF, narrow ON (default)" "unset SAZO_WORKFLOW_HOOKS_ENABLED SAZO_DISABLE_NARROW_HOOKS;"
test_wsm_broad_off_only "broad OFF, narrow OFF" "export SAZO_DISABLE_NARROW_HOOKS=1; unset SAZO_WORKFLOW_HOOKS_ENABLED;"

echo "=== 7. explore_count decay runs under narrow gate (broad OFF) ==="
# Codex P2 (Plan 06 PR review): pre-exploration-gate (narrow) increments .explore_count;
# decay must also run on narrow-only path so Task(code-searcher) delegation
# resets the gate.
test_decay_narrow_only() {
    local sid="phase1-decay-$$"
    local cwd="/tmp/phase1-decay-cwd-$$"
    local payload

    # Seed state via inline session-state.sh source (current shell, no subshell loss).
    (
        export SAZO_STATE_DIR
        source "$HARNESS/scripts/hooks/lib/session-state.sh"
        state_init "$sid" "$cwd" "claude-opus-4-7" >/dev/null
        state_set_json "$sid" ".explore_count" 2 "$cwd"
    )
    local before
    before=$(
        export SAZO_STATE_DIR
        source "$HARNESS/scripts/hooks/lib/session-state.sh"
        state_get "$sid" ".explore_count" "$cwd"
    )
    if [ "$before" != "2" ]; then
        fail "could not seed explore_count (got '$before' expected 2)"
        return
    fi

    payload=$(jq -n --arg sid "$sid" --arg cwd "$cwd" \
        '{session_id:$sid, cwd:$cwd, tool_name:"Task", tool_input:{subagent_type:"code-searcher"}, tool_response:{}, model:"claude-opus-4-7"}')
    echo "$payload" | SAZO_STATE_DIR="$SAZO_STATE_DIR" \
        bash "$HOOKS/workflow-state-machine.sh" post >/dev/null 2>&1

    local after
    after=$(
        export SAZO_STATE_DIR
        source "$HARNESS/scripts/hooks/lib/session-state.sh"
        state_get "$sid" ".explore_count" "$cwd"
    )
    if [ "$after" = "1" ]; then
        pass "explore_count 2→1 under narrow ON + broad OFF"
    else
        fail "explore_count decay failed: before=$before after=$after (expected 1)"
    fi

    # SAZO_DISABLE_NARROW_HOOKS=1 should NOT decay
    (
        export SAZO_STATE_DIR
        source "$HARNESS/scripts/hooks/lib/session-state.sh"
        state_set_json "$sid" ".explore_count" 5 "$cwd"
    )
    echo "$payload" | SAZO_DISABLE_NARROW_HOOKS=1 SAZO_STATE_DIR="$SAZO_STATE_DIR" \
        bash "$HOOKS/workflow-state-machine.sh" post >/dev/null 2>&1
    local after2
    after2=$(
        export SAZO_STATE_DIR
        source "$HARNESS/scripts/hooks/lib/session-state.sh"
        state_get "$sid" ".explore_count" "$cwd"
    )
    if [ "$after2" = "5" ]; then
        pass "explore_count NOT decayed when narrow disabled"
    else
        fail "explore_count changed despite narrow disabled: 5→$after2"
    fi
}
test_decay_narrow_only

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

[ "$FAIL" -eq 0 ]
