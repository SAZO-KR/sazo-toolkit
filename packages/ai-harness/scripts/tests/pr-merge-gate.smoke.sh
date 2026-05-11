#!/usr/bin/env bash
# pr-merge-gate.smoke.sh — workflow-state-machine gh pr merge gate smoke.
# M1: broad OFF  → exit 0 (gate inactive)
# M2: broad ON + review not passed + gh pr merge → exit 2 (hard block)
# M3: broad ON + review passed (verdict aggregation) + gh pr merge → exit 0
# M4: broad ON + SAZO_ALLOW_MERGE_BYPASS=1 + review not passed → exit 0 + idempotency
# M5: broad ON + review skipped (legacy path) + gh pr merge → exit 0
# M6: broad ON + gh pr merge --auto → exit 2 (subflag transparent)
# M7: broad ON + gh pr view (read-only) → exit 0

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$HERE/../.." && pwd)"
LIB="$HARNESS/scripts/hooks/lib/session-state.sh"
HOOK="$HARNESS/scripts/hooks/workflow-state-machine.sh"

export SAZO_STATE_DIR="/tmp/sazo-merge-gate-smoke-$$"
TMP_REPO="/tmp/sazo-merge-repo-$$"

cleanup() {
    rm -rf "$SAZO_STATE_DIR" "$TMP_REPO"
}
trap cleanup EXIT

mkdir -p "$TMP_REPO"
(
    cd "$TMP_REPO"
    git init -q -b main
    git config user.email smoke@test
    git config user.name smoke
    git commit -q --allow-empty -m "init"
) >/dev/null 2>&1

PASS=0
FAIL=0

assert_exit() {
    local expected="$1" actual="$2" label="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1))
        echo "  ✓ $label"
    else
        FAIL=$((FAIL+1))
        echo "  ✗ $label (expected exit=$expected, got $actual)"
    fi
}

run_hook() {
    local mode="$1" payload="$2"
    local rc
    echo "$payload" | bash "$HOOK" "$mode" >/dev/null 2>&1
    rc=$?
    echo "$rc"
}

mk_merge_payload() {
    local sid="$1" cmd="${2:-gh pr merge}"
    printf '%s' "{\"session_id\":\"$sid\",\"cwd\":\"$TMP_REPO\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$cmd\"}}"
}

# ─── M1: broad OFF → gate inactive ───
echo "=== M1: broad OFF ==="
rm -rf "$SAZO_STATE_DIR"
rc=$(SAZO_WORKFLOW_HOOKS_ENABLED= run_hook "pre" "$(mk_merge_payload "m1")")
assert_exit 0 "$rc" "M1: broad OFF + gh pr merge → pass (gate inactive)"

# ─── M2: broad ON + review not passed → hard block ───
echo "=== M2: broad ON + review not passed ==="
rm -rf "$SAZO_STATE_DIR"
rc=$(SAZO_WORKFLOW_HOOKS_ENABLED=1 run_hook "pre" "$(mk_merge_payload "m2")")
assert_exit 2 "$rc" "M2: broad ON + review not passed + gh pr merge → hard block (exit 2)"

# ─── M3: broad ON + review passed (verdict aggregation) → pass ───
echo "=== M3: broad ON + review passed via verdict aggregation ==="
rm -rf "$SAZO_STATE_DIR"
sid="m3"
(
    source "$LIB"
    state_init "$sid" "$TMP_REPO" "unknown"
    # init verdict cycle for review
    verdict_cycle_init "$sid" "$TMP_REPO" "review" '["code-reviewer","architect-advisor"]'
    # issue nonces for both reviewers
    nonce_cr=$(verdict_nonce_issue "$sid" "$TMP_REPO" "code-reviewer" "review")
    nonce_aa=$(verdict_nonce_issue "$sid" "$TMP_REPO" "architect-advisor" "review")
    # consume and record APPROVE for both
    verdict_consume_and_record "$sid" "$TMP_REPO" "$nonce_cr" "code-reviewer" "review" "APPROVE" 0
    verdict_consume_and_record "$sid" "$TMP_REPO" "$nonce_aa" "architect-advisor" "review" "APPROVE" 0
    # mark review completed (legacy compat)
    stage_mark "$sid" "review" "completed" "user" "smoke-M3" "$TMP_REPO"
) >/dev/null 2>&1
rc=$(SAZO_WORKFLOW_HOOKS_ENABLED=1 run_hook "pre" "$(mk_merge_payload "$sid")")
assert_exit 0 "$rc" "M3: broad ON + review verdict APPROVE × 2 + gh pr merge → pass"

# ─── M4: broad ON + SAZO_ALLOW_MERGE_BYPASS=1 → pass + idempotency ───
echo "=== M4: broad ON + SAZO_ALLOW_MERGE_BYPASS=1 ==="
rm -rf "$SAZO_STATE_DIR"
sid="m4"
(
    source "$LIB"
    state_init "$sid" "$TMP_REPO" "unknown"
) >/dev/null 2>&1
rc=$(SAZO_WORKFLOW_HOOKS_ENABLED=1 SAZO_ALLOW_MERGE_BYPASS=1 run_hook "pre" "$(mk_merge_payload "$sid")")
assert_exit 0 "$rc" "M4: SAZO_ALLOW_MERGE_BYPASS=1 + review not passed → pass (bypass)"
# idempotency: after bypass, stage_is_passed review should return true
(
    source "$LIB"
    if SAZO_CWD="$TMP_REPO" stage_is_passed "$sid" "review"; then
        echo "  ✓ M4-idempotent: stage_is_passed review true after bypass"
        exit 0
    else
        echo "  ✗ M4-idempotent: stage_is_passed review should be true after bypass"
        exit 1
    fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# ─── M5: broad ON + review skipped (legacy path) → pass ───
echo "=== M5: broad ON + review skipped via legacy stage_mark ==="
rm -rf "$SAZO_STATE_DIR"
sid="m5"
(
    source "$LIB"
    state_init "$sid" "$TMP_REPO" "unknown"
    # legacy path: no verdict_cycle_init, just stage_mark skipped by=user
    stage_mark "$sid" "review" "skipped" "user" "smoke-M5-skip" "$TMP_REPO"
) >/dev/null 2>&1
rc=$(SAZO_WORKFLOW_HOOKS_ENABLED=1 run_hook "pre" "$(mk_merge_payload "$sid")")
assert_exit 0 "$rc" "M5: review skipped (legacy by=user) + gh pr merge → pass"

# ─── M6: broad ON + gh pr merge --auto → exit 2 (subflag transparent) ───
echo "=== M6: broad ON + gh pr merge --auto ==="
rm -rf "$SAZO_STATE_DIR"
rc=$(SAZO_WORKFLOW_HOOKS_ENABLED=1 run_hook "pre" "$(mk_merge_payload "m6" "gh pr merge --auto")")
assert_exit 2 "$rc" "M6: gh pr merge --auto + review not passed → hard block"

# ─── M7: broad ON + gh pr view (read-only) → pass ───
echo "=== M7: broad ON + gh pr view (read-only) ==="
rm -rf "$SAZO_STATE_DIR"
rc=$(SAZO_WORKFLOW_HOOKS_ENABLED=1 run_hook "pre" "$(mk_merge_payload "m7" "gh pr view 123")")
assert_exit 0 "$rc" "M7: gh pr view → pass (not matched by merge regex)"

echo ""
echo "─────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
