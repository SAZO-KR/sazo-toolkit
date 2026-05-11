#!/usr/bin/env bash
# Smoke test: approval hard block + bypass — Stage B
# T1: approval 미완료 + gh pr create + SAZO_ALLOW_APPROVAL_BYPASS=0 → hard_block
# T2: approval 미완료 + SAZO_ALLOW_APPROVAL_BYPASS=1 + gh pr create → pass + bypass mark
# T3: bypass 후 stage 영속성 — 다음 hook invoke도 통과
# T4: approval 완료 (by="user") + gh pr create → passthrough (regression)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/workflow-state-machine.sh"
LIB="$SCRIPT_DIR/../hooks/lib/session-state.sh"

PASS=0
FAIL=0

assert_pass() {
    PASS=$((PASS+1))
    echo "  PASS $1"
}

assert_fail() {
    FAIL=$((FAIL+1))
    echo "  FAIL $1${2:+ — $2}"
}

assert_file_contains() {
    local needle="$1" file="$2" label="$3"
    if grep -qF "$needle" "$file" 2>/dev/null; then
        PASS=$((PASS+1))
        echo "  PASS $label"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL $label (needle='$needle' not in $file)"
    fi
}

# ---- setup ----

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

export SAZO_STATE_DIR="$TMP_DIR/state"
mkdir -p "$SAZO_STATE_DIR"
AUDIT_LOG="$SAZO_STATE_DIR/audit.log"
touch "$AUDIT_LOG"

export SAZO_WORKFLOW_HOOKS_ENABLED=1
export SAZO_DISABLE_WORKFLOW_HOOKS=0
export SAZO_SKIP_STATE_MACHINE=0

echo "=== Stage B approval-bypass smoke ==="

# helper: build gh pr create pre-hook payload
make_pr_payload() {
    local sid="$1"
    jq -nc \
        --arg sid "$sid" \
        '{
            session_id: $sid,
            cwd: "/tmp",
            tool_name: "Bash",
            tool_input: {command: "gh pr create --title test --body body"},
            tool_response: {},
            model: "test"
        }'
}

run_pre_hook() {
    local payload="$1"
    echo "$payload" | bash "$HOOK" "pre" 2>/dev/null
}

run_pre_hook_exit() {
    local payload="$1"
    local rc=0
    echo "$payload" | bash "$HOOK" "pre" 2>/dev/null || rc=$?
    echo "$rc"
}

# Advance a session through worktree+research+plan+ci+review stages so the
# only missing stage is approval.
advance_stages_except_approval() {
    local sid="$1"
    (
        source "$LIB"
        export SAZO_CWD="/tmp"
        state_init "$sid" "/tmp" "test"
        stage_mark "$sid" "worktree" "completed" "user" "smoke" "/tmp"
        stage_mark "$sid" "research" "completed" "auto" "smoke" "/tmp"
        stage_mark "$sid" "plan" "completed" "auto" "smoke" "/tmp"
        # ci: need ci_passed_at set too
        state_set_str "$sid" ".ci_passed_at" "2026-01-01T00:00:00+0000" "/tmp"
        stage_mark "$sid" "ci" "completed" "auto" "smoke" "/tmp"
        stage_mark "$sid" "review" "completed" "auto" "smoke" "/tmp"
    )
}

# Advance through all stages INCLUDING approval
advance_all_stages() {
    local sid="$1"
    advance_stages_except_approval "$sid"
    (
        source "$LIB"
        export SAZO_CWD="/tmp"
        mark_approval_complete "$sid" "user" "user approved" "/tmp"
    )
}

# ---- T1: approval 미완료 + BYPASS=0 → hard_block (exit 2) ----
echo "--- T1: approval 미완료 + BYPASS=0 → hard_block ---"

SID1="appr-t1-$$"
advance_stages_except_approval "$SID1"

T1_PAYLOAD=$(make_pr_payload "$SID1")
T1_EXIT=$(SAZO_ALLOW_APPROVAL_BYPASS=0 run_pre_hook_exit "$T1_PAYLOAD")

if [ "$T1_EXIT" != "0" ]; then
    assert_pass "T1: approval missing + BYPASS=0 → exit $T1_EXIT (non-0)"
else
    assert_fail "T1: approval missing + BYPASS=0 → expected non-0" "exit=$T1_EXIT"
fi

# ---- T2: approval 미완료 + BYPASS=1 → exit 0 + bypass mark ----
echo "--- T2: approval 미완료 + BYPASS=1 → exit 0 + mark_approval_complete by=bypass ---"

SID2="appr-t2-$$"
advance_stages_except_approval "$SID2"

T2_PAYLOAD=$(make_pr_payload "$SID2")
T2_EXIT=0
SAZO_ALLOW_APPROVAL_BYPASS=1 SAZO_ALLOW_CI_SKIP=1 run_pre_hook "$T2_PAYLOAD" || T2_EXIT=$?

if [ "$T2_EXIT" = "0" ]; then
    assert_pass "T2: BYPASS=1 → exit 0"
else
    assert_fail "T2: BYPASS=1 → exit 0" "exit=$T2_EXIT"
fi

# audit should have bypass warn entry
assert_file_contains "approval_bypass_warn" "$AUDIT_LOG" "T2b: bypass warn in audit"

# state should now have approval completed by=bypass
APPROVAL_STATUS=$(
    source "$LIB"
    export SAZO_CWD="/tmp"
    state_get "$SID2" '.history[] | select(.stage == "approval" and .by == "bypass") | .status' "/tmp" 2>/dev/null | head -1
)
if [ "$APPROVAL_STATUS" = "completed" ]; then
    assert_pass "T2c: approval completed by=bypass in state"
else
    assert_fail "T2c: approval completed by=bypass in state" "got='$APPROVAL_STATUS'"
fi

# ---- T3: bypass 후 stage_is_passed → 다음 invoke도 통과 ----
echo "--- T3: after bypass, stage_is_passed('approval') = true ---"

(
    source "$LIB"
    export SAZO_CWD="/tmp"
    if stage_is_passed "$SID2" "approval" "/tmp"; then
        echo "  PASS T3: stage_is_passed(approval) = true after bypass"
        exit 0
    else
        echo "  FAIL T3: stage_is_passed(approval) = false after bypass"
        exit 1
    fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# Second gh pr create invoke should also pass (idempotent)
T3_PAYLOAD=$(make_pr_payload "$SID2")
T3_EXIT=0
SAZO_ALLOW_APPROVAL_BYPASS=1 SAZO_ALLOW_CI_SKIP=1 run_pre_hook "$T3_PAYLOAD" || T3_EXIT=$?

if [ "$T3_EXIT" = "0" ]; then
    assert_pass "T3b: second invoke also exits 0"
else
    assert_fail "T3b: second invoke exits 0" "exit=$T3_EXIT"
fi

# ---- T4: approval by=user → gh pr create passes (regression) ----
echo "--- T4: approval completed by=user → gh pr create exit 0 (regression) ---"

SID4="appr-t4-$$"
advance_all_stages "$SID4"

T4_PAYLOAD=$(make_pr_payload "$SID4")
T4_EXIT=0
SAZO_ALLOW_APPROVAL_BYPASS=0 SAZO_ALLOW_CI_SKIP=1 run_pre_hook "$T4_PAYLOAD" || T4_EXIT=$?

if [ "$T4_EXIT" = "0" ]; then
    assert_pass "T4: approval by=user + gh pr create → exit 0"
else
    assert_fail "T4: approval by=user + gh pr create → exit 0" "exit=$T4_EXIT"
fi

# ---- summary ----
echo ""
echo "=== approval-bypass.smoke: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
