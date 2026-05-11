#!/usr/bin/env bash
# Smoke test: mark_skip_with_check — Stage B auto-skip wrapper
# T1: by="auto" + worktree (exempt) → passthrough
# T2: by="auto" + research + SAZO_ALLOW_AUTO_SKIP=0 → hard_block (exit non-0)
# T3: by="auto" + research + SAZO_ALLOW_AUTO_SKIP=1 → pass + warn audit entry
# T4: by="user" + research → passthrough (regression)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

echo "=== Stage B auto-skip-block smoke ==="

# ---- helper: invoke mark_skip_with_check in a subshell ----

call_wrapper() {
    local sid="$1" stage="$2" by="$3" reason="$4"
    # Source lib and call the function. Capture exit code without set -e aborting.
    (
        set -uo pipefail
        export SAZO_STATE_DIR="$SAZO_STATE_DIR"
        export SAZO_CWD="/tmp"
        # shellcheck source=../hooks/lib/session-state.sh
        source "$LIB"
        state_init "$sid" "/tmp" "test"
        mark_skip_with_check "$sid" "$stage" "$by" "$reason" "/tmp"
    )
}

# ---- T1: by="auto" + worktree exempt → exit 0 ----
echo "--- T1: by=auto + worktree (exempt) → exit 0 ---"

SID1="skip-t1-$$"
T1_EXIT=0
SAZO_ALLOW_AUTO_SKIP=0 call_wrapper "$SID1" "worktree" "auto" "not a git repo" || T1_EXIT=$?

if [ "$T1_EXIT" = "0" ]; then
    assert_pass "T1: worktree exempt → exit 0"
else
    assert_fail "T1: worktree exempt → exit 0" "exit=$T1_EXIT"
fi

# Verify state was actually written
(
    source "$LIB"
    export SAZO_CWD="/tmp"
    if stage_is_passed "$SID1" "worktree" "/tmp"; then
        echo "  PASS T1b: worktree skipped in state"
        exit 0
    else
        echo "  FAIL T1b: worktree not skipped in state"
        exit 1
    fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# ---- T2: by="auto" + research + SAZO_ALLOW_AUTO_SKIP=0 → exit non-0 ----
echo "--- T2: by=auto + research + ALLOW=0 → exit non-0 ---"

SID2="skip-t2-$$"
T2_EXIT=0
SAZO_ALLOW_AUTO_SKIP=0 call_wrapper "$SID2" "research" "auto" "direct file specified" || T2_EXIT=$?

if [ "$T2_EXIT" != "0" ]; then
    assert_pass "T2: auto research blocked → exit $T2_EXIT (non-0)"
else
    assert_fail "T2: auto research blocked → expected non-0 exit" "exit=$T2_EXIT"
fi

# audit should have blocked entry
assert_file_contains "auto_skip_blocked" "$AUDIT_LOG" "T2b: blocked entry in audit"

# ---- T3: by="auto" + research + SAZO_ALLOW_AUTO_SKIP=1 → exit 0 + warn ----
echo "--- T3: by=auto + research + ALLOW=1 → exit 0 + warn audit ---"

SID3="skip-t3-$$"
T3_EXIT=0
SAZO_ALLOW_AUTO_SKIP=1 call_wrapper "$SID3" "research" "auto" "2 files direct" || T3_EXIT=$?

if [ "$T3_EXIT" = "0" ]; then
    assert_pass "T3: ALLOW=1 auto research → exit 0"
else
    assert_fail "T3: ALLOW=1 auto research → exit 0" "exit=$T3_EXIT"
fi

# audit should have warn entry
assert_file_contains "auto_skip_warn" "$AUDIT_LOG" "T3b: warn entry in audit"

# state should be marked skipped
(
    source "$LIB"
    export SAZO_CWD="/tmp"
    if stage_is_passed "$SID3" "research" "/tmp"; then
        echo "  PASS T3c: research skipped in state"
        exit 0
    else
        echo "  FAIL T3c: research not skipped in state"
        exit 1
    fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# ---- T4: by="user" + research → exit 0 (regression) ----
echo "--- T4: by=user + research → exit 0 (regression) ---"

SID4="skip-t4-$$"
T4_EXIT=0
SAZO_ALLOW_AUTO_SKIP=0 call_wrapper "$SID4" "research" "user" "file directly specified" || T4_EXIT=$?

if [ "$T4_EXIT" = "0" ]; then
    assert_pass "T4: by=user → exit 0"
else
    assert_fail "T4: by=user → exit 0" "exit=$T4_EXIT"
fi

# ---- T5: by="auto" + plan + SAZO_ALLOW_AUTO_SKIP=0 → exit non-0 ----
echo "--- T5: by=auto + plan (non-exempt) + ALLOW=0 → exit non-0 ---"

SID5="skip-t5-$$"
T5_EXIT=0
SAZO_ALLOW_AUTO_SKIP=0 call_wrapper "$SID5" "plan" "auto" "trivial" || T5_EXIT=$?

if [ "$T5_EXIT" != "0" ]; then
    assert_pass "T5: auto plan blocked → exit $T5_EXIT (non-0)"
else
    assert_fail "T5: auto plan blocked → expected non-0 exit" "exit=$T5_EXIT"
fi

# ---- summary ----
echo ""
echo "=== auto-skip-block.smoke: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
