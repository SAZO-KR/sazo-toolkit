#!/usr/bin/env bash
# Smoke test: mark_approval_complete atomic helper (Plan 13 Stage A0a)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../hooks/lib/session-state.sh"

TMP_STATE_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_STATE_DIR"' EXIT
export SAZO_STATE_DIR="$TMP_STATE_DIR"

# shellcheck source=/dev/null
source "$LIB"

PASS=0
FAIL=0

assert_true() {
    local label="$1"
    shift
    if "$@" 2>/dev/null; then
        PASS=$((PASS+1))
        echo "  ✓ $label"
    else
        FAIL=$((FAIL+1))
        echo "  ✗ $label (expected true)"
    fi
}

assert_false() {
    local label="$1"
    shift
    if "$@" 2>/dev/null; then
        FAIL=$((FAIL+1))
        echo "  ✗ $label (expected false)"
    else
        PASS=$((PASS+1))
        echo "  ✓ $label"
    fi
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1))
        echo "  ✓ $label"
    else
        FAIL=$((FAIL+1))
        echo "  ✗ $label (expected '$expected', got '$actual')"
    fi
}

state_jq() {
    local sid="$1" path="$2" cwd="$3"
    local sf; sf=$(state_file "$sid" "$cwd")
    jq -r "$path" "$sf"
}

CWD="/tmp/approval-cwd"

# --- T1: by="user" → stage_is_passed approval = true (기존 동작 보존) ---
echo "Test T1: by=user → stage_is_passed approval=true"
SID="ap-t1"
state_init "$SID" "$CWD" "test"
mark_approval_complete "$SID" "user" "/approved" "$CWD"
assert_true "T1.1 stage_is_passed approval=true for by=user" \
    stage_is_passed "$SID" "approval" "$CWD"

# Verify plan_approved_at set
approved_at=$(state_jq "$SID" '.plan_approved_at // "null"' "$CWD")
if [ "$approved_at" != "null" ] && [ -n "$approved_at" ]; then
    PASS=$((PASS+1)); echo "  ✓ T1.2 plan_approved_at non-null"
else
    FAIL=$((FAIL+1)); echo "  ✗ T1.2 plan_approved_at should be non-null (got: $approved_at)"
fi

# Verify history entry
hist_by=$(state_jq "$SID" '[.history[] | select(.stage=="approval" and .status=="completed")] | last.by // "none"' "$CWD")
assert_eq "user" "$hist_by" "T1.3 history entry by=user"

# --- T2: by="bypass" → stage_is_passed approval = true (신규) ---
echo "Test T2: by=bypass → stage_is_passed approval=true"
SID="ap-t2"
state_init "$SID" "$CWD" "test"
mark_approval_complete "$SID" "bypass" "SAZO_ALLOW_APPROVAL_BYPASS=1" "$CWD"
assert_true "T2.1 stage_is_passed approval=true for by=bypass" \
    stage_is_passed "$SID" "approval" "$CWD"

hist_by=$(state_jq "$SID" '[.history[] | select(.stage=="approval" and .status=="completed")] | last.by // "none"' "$CWD")
assert_eq "bypass" "$hist_by" "T2.2 history entry by=bypass"

# --- T3: by="auto" → stage_is_passed approval = false (회귀 방어) ---
echo "Test T3: by=auto → stage_is_passed approval=false (regression guard)"
SID="ap-t3"
state_init "$SID" "$CWD" "test"
mark_approval_complete "$SID" "auto" "auto-mark" "$CWD"
assert_false "T3.1 stage_is_passed approval=false for by=auto" \
    stage_is_passed "$SID" "approval" "$CWD"

# --- T4: stage 영속성 — atomic + single history entry ---
echo "Test T4: mark_approval_complete atomicity + single history entry"
SID="ap-t4"
state_init "$SID" "$CWD" "test"
mark_approval_complete "$SID" "bypass" "env-bypass" "$CWD"

# Exactly one approval completed entry
hist_count=$(state_jq "$SID" '[.history[] | select(.stage=="approval" and .status=="completed")] | length' "$CWD")
assert_eq "1" "$hist_count" "T4.1 exactly one history entry after mark_approval_complete"

# stage_is_passed should remain true after inspection (persistency)
assert_true "T4.2 stage_is_passed persists after read" \
    stage_is_passed "$SID" "approval" "$CWD"

# Calling mark_approval_complete again should not duplicate (idempotent state_init, but may add entry)
# The key thing is stage_is_passed still holds
mark_approval_complete "$SID" "bypass" "env-bypass-2" "$CWD"
assert_true "T4.3 stage_is_passed still true after second call" \
    stage_is_passed "$SID" "approval" "$CWD"

# --- T5: state auto-init when file missing ---
echo "Test T5: state auto-init when file not yet created"
SID="ap-t5"
# Do NOT call state_init — mark_approval_complete should handle it
mark_approval_complete "$SID" "user" "/approved" "$CWD"
assert_true "T5.1 stage_is_passed true even without prior state_init" \
    stage_is_passed "$SID" "approval" "$CWD"

# --- Summary ---
echo "─────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
