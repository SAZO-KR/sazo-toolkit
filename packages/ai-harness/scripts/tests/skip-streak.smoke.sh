#!/usr/bin/env bash
# Smoke test: skip streak hard escalation (Plan 09)
# Tests: schema v5 fields, override nonce primitives, UserPromptSubmit handler,
#        PreToolUse gate enforcement, streak reset on completion, env overrides.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../hooks/lib"
HOOKS_DIR="$SCRIPT_DIR/../hooks"

# ---- test harness ----

TMP_DIR=$(mktemp -d)
COUNT_FILE="$TMP_DIR/counts"
printf '0 0\n' > "$COUNT_FILE"
trap 'rm -rf "$TMP_DIR"' EXIT

# assert helpers write results to COUNT_FILE so subshells can accumulate
_pass() {
    echo "  PASS $1"
    local p f; read -r p f < "$COUNT_FILE"; echo "$((p+1)) $f" > "$COUNT_FILE"
}

_fail() {
    echo "  FAIL $1${2:+ — $2}"
    local p f; read -r p f < "$COUNT_FILE"; echo "$p $((f+1))" > "$COUNT_FILE"
}

assert_pass() { _pass "$1"; }
assert_fail() { _fail "$1" "${2:-}"; }

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [ "$expected" = "$actual" ]; then _pass "$label"
    else _fail "$label" "expected='$expected' actual='$actual'"; fi
}

assert_ne() {
    local unexpected="$1" actual="$2" label="$3"
    if [ "$unexpected" != "$actual" ]; then _pass "$label"
    else _fail "$label" "should not equal '$unexpected'"; fi
}

# ---- shared setup ----

export SAZO_STATE_DIR="$TMP_DIR/state"
mkdir -p "$SAZO_STATE_DIR"
AUDIT_LOG="$SAZO_STATE_DIR/audit.log"
touch "$AUDIT_LOG"

export SAZO_WORKFLOW_HOOKS_ENABLED=1
export SAZO_DISABLE_WORKFLOW_HOOKS=0
export SAZO_CWD="/tmp/test-cwd-skip-streak"
export SAZO_MODEL="test-model"

# source lib once (SAZO_STATE_DIR is already set)
source "$LIB_DIR/session-state.sh"
source "$LIB_DIR/slash-commands.sh"

# Helper: APPEND n skip entries to existing history (use AFTER stage marks)
_add_skip_history_append() {
    local f="$1" n="$2"
    local i ts tmp
    ts=$(date +%Y-%m-%dT%H:%M:%S%z)
    for i in $(seq 1 "$n"); do
        tmp=$(mktemp)
        jq --arg ts "$ts" --arg i "$i" \
            '.history += [{stage: ("skip_stage" + $i), status: "skipped", by: "user", reason: "test", ts: $ts, cycle_id: ""}]' \
            "$f" > "$tmp" && mv "$tmp" "$f"
    done
}

echo "=== T-INIT-1: fresh state schema v5 fields ==="
SID="t_init_1"
state_init "$SID" "$SAZO_CWD" "test-model"
f=$(state_file "$SID" "$SAZO_CWD")
assert_eq "5" "$(jq -r '.schema_version' "$f")" "T-INIT-1.1 schema_version=5"
assert_eq "null" "$(jq -r '.override_skip_streak_at' "$f")" "T-INIT-1.2 override_skip_streak_at=null"
assert_eq "false" "$(jq -r '.override_skip_streak_consumed' "$f")" "T-INIT-1.3 override_skip_streak_consumed=false"
assert_eq "null" "$(jq -r '.override_skip_streak_nonce' "$f")" "T-INIT-1.4 override_skip_streak_nonce=null"
assert_eq "0" "$(jq -r '.skip_streak_blocked_count' "$f")" "T-INIT-1.5 skip_streak_blocked_count=0"
assert_eq "null" "$(jq -r '.dangerous_override_nonce' "$f")" "T-INIT-1.6 dangerous_override_nonce=null"
assert_eq "array" "$(jq -r '.dangerous_override_history | type' "$f")" "T-INIT-1.7 dangerous_override_history=[]"

echo "=== T-MIG-V5: v3 → v5 direct upgrade ==="
(
    TMP_HOME=$(mktemp -d)
    export SAZO_STATE_DIR="$TMP_HOME/.claude/state"
    mkdir -p "$SAZO_STATE_DIR"
    source "$LIB_DIR/session-state.sh"

    SID="t_mig_v5"; CWD="/tmp/test-cwd"
    f=$(state_file "$SID" "$CWD")
    cat > "$f" <<'EOF'
{"schema_version": 3, "history": [], "approval_nonce": null}
EOF
    PRE_VER=$(jq -r '.schema_version' "$f")
    assert_eq "3" "$PRE_VER" "T-MIG-V5.0 v3 file created"

    state_init "$SID" "$CWD" "test-model"

    POST_VER=$(jq -r '.schema_version' "$f")
    assert_eq "5" "$POST_VER" "T-MIG-V5.1 schema_version upgraded to 5"
    assert_eq "null" "$(jq -r '.dangerous_override_nonce' "$f")" "T-MIG-V5.2 dangerous_override_nonce field"
    assert_eq "array" "$(jq -r '.dangerous_override_history | type' "$f")" "T-MIG-V5.3 dangerous_override_history field"
    assert_eq "null" "$(jq -r '.override_skip_streak_at' "$f")" "T-MIG-V5.4 override_skip_streak_at field"
    assert_eq "false" "$(jq -r '.override_skip_streak_consumed' "$f")" "T-MIG-V5.5 override_skip_streak_consumed"
    assert_eq "null" "$(jq -r '.override_skip_streak_nonce' "$f")" "T-MIG-V5.6 override_skip_streak_nonce"
    assert_eq "0" "$(jq -r '.skip_streak_blocked_count' "$f")" "T-MIG-V5.7 skip_streak_blocked_count"
    assert_eq "null" "$(jq -r '.approval_nonce' "$f")" "T-MIG-V5.8 approval_nonce preserved"

    rm -rf "$TMP_HOME"
)

echo "=== T-SLASH-1: /override-skip-streak parse ==="
parsed=$(parse_slash_command "/override-skip-streak emergency docs")
if [ -n "$parsed" ] && [ "${parsed%% *}" = "override-skip-streak" ]; then
    assert_pass "T-SLASH-1 parse_slash_command recognizes /override-skip-streak"
else
    assert_fail "T-SLASH-1 parse_slash_command empty (likely is_known_slash missing entry)" "parsed='$parsed'"
fi

echo "=== T-NONCE-1: issue → consume same nonce returns 0 ==="
SID="t_nonce_1"
state_init "$SID" "$SAZO_CWD" "test-model"
nonce="aabbccddee112233aabbccddee112233"
skip_streak_override_set "$SID" "$nonce" "$SAZO_CWD"
if skip_streak_override_consume "$SID" "$nonce" "$SAZO_CWD"; then
    assert_pass "T-NONCE-1 consume same nonce returns 0"
else
    assert_fail "T-NONCE-1 consume same nonce returned non-0"
fi

echo "=== T-NONCE-2: double-consume returns 1 ==="
SID="t_nonce_2"
state_init "$SID" "$SAZO_CWD" "test-model"
nonce="aabbccddee112233aabbccddee112233"
skip_streak_override_set "$SID" "$nonce" "$SAZO_CWD"
skip_streak_override_consume "$SID" "$nonce" "$SAZO_CWD" || true
if skip_streak_override_consume "$SID" "$nonce" "$SAZO_CWD"; then
    assert_fail "T-NONCE-2 double-consume should return 1"
else
    assert_pass "T-NONCE-2 double-consume returns 1 (rejected)"
fi

echo "=== T-NONCE-3: mismatched nonce returns 1 ==="
SID="t_nonce_3"
state_init "$SID" "$SAZO_CWD" "test-model"
nonce_a="aabbccddee112233aabbccddee112233"
nonce_b="ff00ff00ff00ff00ff00ff00ff00ff00"
skip_streak_override_set "$SID" "$nonce_a" "$SAZO_CWD"
if skip_streak_override_consume "$SID" "$nonce_b" "$SAZO_CWD"; then
    assert_fail "T-NONCE-3 mismatched nonce should return 1"
else
    assert_pass "T-NONCE-3 mismatched nonce returns 1 (rejected)"
fi

echo "=== T-PROMPT-1: UserPromptSubmit /override-skip-streak emergency ==="
SID="t_prompt_1"
state_init "$SID" "$SAZO_CWD" "test-model"
> "$AUDIT_LOG"  # reset audit log
export SAZO_SESSION_ID="$SID"
payload=$(jq -nc \
    --arg sid "$SID" \
    --arg cwd "$SAZO_CWD" \
    --arg prompt "/override-skip-streak emergency docs only" \
    --arg model "test-model" \
    '{session_id:$sid, cwd:$cwd, prompt:$prompt, model:$model, tool_name:"", tool_input:{}, tool_response:{}}')
echo "$payload" | bash "$HOOKS_DIR/user-prompt-approval-detect.sh" 2>/dev/null || true

f=$(state_file "$SID" "$SAZO_CWD")
at=$(jq -r '.override_skip_streak_at' "$f")
nonce_val=$(jq -r '.override_skip_streak_nonce' "$f")
consumed=$(jq -r '.override_skip_streak_consumed' "$f")
assert_ne "null" "$at" "T-PROMPT-1.1 override_skip_streak_at set"
assert_ne "null" "$nonce_val" "T-PROMPT-1.2 override_skip_streak_nonce set"
assert_eq "false" "$consumed" "T-PROMPT-1.3 override_skip_streak_consumed=false"
if grep -q "skip_streak_override" "$AUDIT_LOG" 2>/dev/null; then
    assert_pass "T-PROMPT-1.4 audit entry skip_streak_override"
else
    assert_fail "T-PROMPT-1.4 audit entry skip_streak_override missing"
fi

echo "=== T-PROMPT-2: /override-skip-streak (no reason) → rejected ==="
SID="t_prompt_2"
state_init "$SID" "$SAZO_CWD" "test-model"
> "$AUDIT_LOG"
export SAZO_SESSION_ID="$SID"
payload=$(jq -nc \
    --arg sid "$SID" \
    --arg cwd "$SAZO_CWD" \
    --arg prompt "/override-skip-streak" \
    --arg model "test-model" \
    '{session_id:$sid, cwd:$cwd, prompt:$prompt, model:$model, tool_name:"", tool_input:{}, tool_response:{}}')
echo "$payload" | bash "$HOOKS_DIR/user-prompt-approval-detect.sh" 2>/dev/null || true

f=$(state_file "$SID" "$SAZO_CWD")
at=$(jq -r '.override_skip_streak_at' "$f")
assert_eq "null" "$at" "T-PROMPT-2.1 override_skip_streak_at remains null (rejected)"
if grep -q "skip_streak_override_rejected" "$AUDIT_LOG" 2>/dev/null; then
    assert_pass "T-PROMPT-2.2 audit entry skip_streak_override_rejected"
else
    assert_fail "T-PROMPT-2.2 audit entry skip_streak_override_rejected missing"
fi

echo "=== T-PROMPT-3: mixed slash /override-skip-streak /skip → rejected ==="
SID="t_prompt_3"
state_init "$SID" "$SAZO_CWD" "test-model"
> "$AUDIT_LOG"
export SAZO_SESSION_ID="$SID"
payload=$(jq -nc \
    --arg sid "$SID" \
    --arg cwd "$SAZO_CWD" \
    --arg prompt "/override-skip-streak /skip something" \
    --arg model "test-model" \
    '{session_id:$sid, cwd:$cwd, prompt:$prompt, model:$model, tool_name:"", tool_input:{}, tool_response:{}}')
echo "$payload" | bash "$HOOKS_DIR/user-prompt-approval-detect.sh" 2>/dev/null || true

f=$(state_file "$SID" "$SAZO_CWD")
at=$(jq -r '.override_skip_streak_at' "$f")
assert_eq "null" "$at" "T-PROMPT-3 mixed slash → nonce not set"

echo "=== T-GATE-1: 4 consecutive skips → Edit pre-hook exits 0 ==="
SID="t_gate_1"
state_init "$SID" "$SAZO_CWD" "test-model"
f=$(state_file "$SID" "$SAZO_CWD")
stage_mark "$SID" "research" "completed" "user" "test" "$SAZO_CWD"
stage_mark "$SID" "plan" "completed" "user" "test" "$SAZO_CWD"
mark_approval_complete "$SID" "user" "/approved" "$SAZO_CWD"
_add_skip_history_append "$f" 4

export SAZO_SESSION_ID="$SID"
payload=$(jq -nc \
    --arg sid "$SID" \
    --arg cwd "$SAZO_CWD" \
    --arg model "test-model" \
    '{session_id:$sid, cwd:$cwd, model:$model, tool_name:"Edit", tool_input:{file_path:"/tmp/foo.sh",old_string:"a",new_string:"b"}, tool_response:{}}')
rc=0
echo "$payload" | bash "$HOOKS_DIR/workflow-state-machine.sh" pre 2>/dev/null || rc=$?
assert_eq "0" "$rc" "T-GATE-1 4 skips → Edit exits 0 (no block)"

echo "=== T-GATE-2: 5 consecutive skips → Edit pre-hook exits 2 ==="
SID="t_gate_2"
state_init "$SID" "$SAZO_CWD" "test-model"
f=$(state_file "$SID" "$SAZO_CWD")
stage_mark "$SID" "research" "completed" "user" "test" "$SAZO_CWD"
stage_mark "$SID" "plan" "completed" "user" "test" "$SAZO_CWD"
mark_approval_complete "$SID" "user" "/approved" "$SAZO_CWD"
_add_skip_history_append "$f" 5

export SAZO_SESSION_ID="$SID"
payload=$(jq -nc \
    --arg sid "$SID" \
    --arg cwd "$SAZO_CWD" \
    --arg model "test-model" \
    '{session_id:$sid, cwd:$cwd, model:$model, tool_name:"Edit", tool_input:{file_path:"/tmp/foo.sh",old_string:"a",new_string:"b"}, tool_response:{}}')
rc=0
err=$(echo "$payload" | bash "$HOOKS_DIR/workflow-state-machine.sh" pre 2>&1) || rc=$?
assert_eq "2" "$rc" "T-GATE-2 5 skips → exit 2"
if echo "$err" | grep -q "skip streak\|skip-streak\|연속.*skip"; then
    assert_pass "T-GATE-2 stderr mentions skip streak"
else
    assert_fail "T-GATE-2 stderr missing skip streak mention" "got: $err"
fi
blocked=$(jq -r '.skip_streak_blocked_count' "$(state_file "$SID" "$SAZO_CWD")")
assert_eq "1" "$blocked" "T-GATE-2 skip_streak_blocked_count=1"

echo "=== T-GATE-3: 5 skips + active override → Edit exits 0, override consumed ==="
> "$AUDIT_LOG"
SID="t_gate_3"
state_init "$SID" "$SAZO_CWD" "test-model"
f=$(state_file "$SID" "$SAZO_CWD")
stage_mark "$SID" "research" "completed" "user" "test" "$SAZO_CWD"
stage_mark "$SID" "plan" "completed" "user" "test" "$SAZO_CWD"
mark_approval_complete "$SID" "user" "/approved" "$SAZO_CWD"
_add_skip_history_append "$f" 5
nonce="deadbeef12345678deadbeef12345678"
skip_streak_override_set "$SID" "$nonce" "$SAZO_CWD"

export SAZO_SESSION_ID="$SID"
payload=$(jq -nc \
    --arg sid "$SID" \
    --arg cwd "$SAZO_CWD" \
    --arg model "test-model" \
    '{session_id:$sid, cwd:$cwd, model:$model, tool_name:"Edit", tool_input:{file_path:"/tmp/foo.sh",old_string:"a",new_string:"b"}, tool_response:{}}')
rc=0
echo "$payload" | bash "$HOOKS_DIR/workflow-state-machine.sh" pre 2>/dev/null || rc=$?
assert_eq "0" "$rc" "T-GATE-3 5 skips + override → exit 0"
consumed=$(jq -r '.override_skip_streak_consumed' "$(state_file "$SID" "$SAZO_CWD")")
assert_eq "true" "$consumed" "T-GATE-3 override consumed"
if grep -q "skip_streak_override_consumed" "$AUDIT_LOG" 2>/dev/null; then
    assert_pass "T-GATE-3 audit skip_streak_override_consumed"
else
    assert_fail "T-GATE-3 audit skip_streak_override_consumed missing"
fi

echo "=== T-GATE-4: 5 skips + override consumed → next Edit exits 2 (single-use) ==="
SID="t_gate_4"
state_init "$SID" "$SAZO_CWD" "test-model"
f=$(state_file "$SID" "$SAZO_CWD")
stage_mark "$SID" "research" "completed" "user" "test" "$SAZO_CWD"
stage_mark "$SID" "plan" "completed" "user" "test" "$SAZO_CWD"
mark_approval_complete "$SID" "user" "/approved" "$SAZO_CWD"
_add_skip_history_append "$f" 5
nonce="deadbeef12345678deadbeef12345678"
skip_streak_override_set "$SID" "$nonce" "$SAZO_CWD"
skip_streak_override_consume "$SID" "$nonce" "$SAZO_CWD" || true

export SAZO_SESSION_ID="$SID"
payload=$(jq -nc \
    --arg sid "$SID" \
    --arg cwd "$SAZO_CWD" \
    --arg model "test-model" \
    '{session_id:$sid, cwd:$cwd, model:$model, tool_name:"Edit", tool_input:{file_path:"/tmp/foo.sh",old_string:"a",new_string:"b"}, tool_response:{}}')
rc=0
echo "$payload" | bash "$HOOKS_DIR/workflow-state-machine.sh" pre 2>/dev/null || rc=$?
assert_eq "2" "$rc" "T-GATE-4 consumed override → exit 2 (single-use)"

echo "=== T-GATE-5: SAZO_DISABLE_SKIP_STREAK_BLOCK=1 → exit 0 ==="
SID="t_gate_5"
state_init "$SID" "$SAZO_CWD" "test-model"
f=$(state_file "$SID" "$SAZO_CWD")
stage_mark "$SID" "research" "completed" "user" "test" "$SAZO_CWD"
stage_mark "$SID" "plan" "completed" "user" "test" "$SAZO_CWD"
mark_approval_complete "$SID" "user" "/approved" "$SAZO_CWD"
_add_skip_history_append "$f" 5

export SAZO_SESSION_ID="$SID"
export SAZO_DISABLE_SKIP_STREAK_BLOCK=1
payload=$(jq -nc \
    --arg sid "$SID" \
    --arg cwd "$SAZO_CWD" \
    --arg model "test-model" \
    '{session_id:$sid, cwd:$cwd, model:$model, tool_name:"Edit", tool_input:{file_path:"/tmp/foo.sh",old_string:"a",new_string:"b"}, tool_response:{}}')
rc=0
echo "$payload" | bash "$HOOKS_DIR/workflow-state-machine.sh" pre 2>/dev/null || rc=$?
assert_eq "0" "$rc" "T-GATE-5 DISABLE=1 → exit 0 (no block)"
unset SAZO_DISABLE_SKIP_STREAK_BLOCK

echo "=== T-GATE-6: SAZO_SKIP_STREAK_MAX=10, 5 skips → exit 0 ==="
SID="t_gate_6"
state_init "$SID" "$SAZO_CWD" "test-model"
f=$(state_file "$SID" "$SAZO_CWD")
stage_mark "$SID" "research" "completed" "user" "test" "$SAZO_CWD"
stage_mark "$SID" "plan" "completed" "user" "test" "$SAZO_CWD"
mark_approval_complete "$SID" "user" "/approved" "$SAZO_CWD"
_add_skip_history_append "$f" 5

export SAZO_SESSION_ID="$SID"
export SAZO_SKIP_STREAK_MAX=10
payload=$(jq -nc \
    --arg sid "$SID" \
    --arg cwd "$SAZO_CWD" \
    --arg model "test-model" \
    '{session_id:$sid, cwd:$cwd, model:$model, tool_name:"Edit", tool_input:{file_path:"/tmp/foo.sh",old_string:"a",new_string:"b"}, tool_response:{}}')
rc=0
echo "$payload" | bash "$HOOKS_DIR/workflow-state-machine.sh" pre 2>/dev/null || rc=$?
assert_eq "0" "$rc" "T-GATE-6 MAX=10, 5 skips → exit 0 (under threshold)"
unset SAZO_SKIP_STREAK_MAX

echo "=== T-GATE-7: 5 skips → gh pr create Bash pre-hook exits 2 ==="
SID="t_gate_7"
state_init "$SID" "$SAZO_CWD" "test-model"
f=$(state_file "$SID" "$SAZO_CWD")
mark_approval_complete "$SID" "user" "/approved" "$SAZO_CWD"
state_set_str "$SID" ".ci_passed_at" "$(date +%Y-%m-%dT%H:%M:%S%z)" "$SAZO_CWD"
stage_mark "$SID" "review" "completed" "user" "test" "$SAZO_CWD"
stage_mark "$SID" "research" "completed" "user" "test" "$SAZO_CWD"
stage_mark "$SID" "plan" "completed" "user" "test" "$SAZO_CWD"
_add_skip_history_append "$f" 5

export SAZO_SESSION_ID="$SID"
payload=$(jq -nc \
    --arg sid "$SID" \
    --arg cwd "$SAZO_CWD" \
    --arg model "test-model" \
    '{session_id:$sid, cwd:$cwd, model:$model, tool_name:"Bash", tool_input:{command:"gh pr create --title test --body body"}, tool_response:{}}')
rc=0
echo "$payload" | bash "$HOOKS_DIR/workflow-state-machine.sh" pre 2>/dev/null || rc=$?
assert_eq "2" "$rc" "T-GATE-7 5 skips → gh pr create exits 2"

echo "=== T-GATE-8: 5 skips → gh pr merge Bash pre-hook exits 2 ==="
SID="t_gate_8"
state_init "$SID" "$SAZO_CWD" "test-model"
f=$(state_file "$SID" "$SAZO_CWD")
stage_mark "$SID" "review" "completed" "user" "test" "$SAZO_CWD"
stage_mark "$SID" "research" "completed" "user" "test" "$SAZO_CWD"
stage_mark "$SID" "plan" "completed" "user" "test" "$SAZO_CWD"
mark_approval_complete "$SID" "user" "/approved" "$SAZO_CWD"
_add_skip_history_append "$f" 5

export SAZO_SESSION_ID="$SID"
payload=$(jq -nc \
    --arg sid "$SID" \
    --arg cwd "$SAZO_CWD" \
    --arg model "test-model" \
    '{session_id:$sid, cwd:$cwd, model:$model, tool_name:"Bash", tool_input:{command:"gh pr merge --merge"}, tool_response:{}}')
rc=0
echo "$payload" | bash "$HOOKS_DIR/workflow-state-machine.sh" pre 2>/dev/null || rc=$?
assert_eq "2" "$rc" "T-GATE-8 5 skips → gh pr merge exits 2"

echo "=== T-RESET-1: 5 skips + active override + stage_mark completed → streak=0, override cleared ==="
SID="t_reset_1"
state_init "$SID" "$SAZO_CWD" "test-model"
f=$(state_file "$SID" "$SAZO_CWD")
_add_skip_history_append "$f" 5
nonce="aabb1122aabb1122aabb1122aabb1122"
skip_streak_override_set "$SID" "$nonce" "$SAZO_CWD"
stage_mark "$SID" "ci" "completed" "auto" "smoke" "$SAZO_CWD"
streak=$(consecutive_skip_count "$SID" "$SAZO_CWD")
assert_eq "0" "$streak" "T-RESET-1.1 consecutive_skip_count=0 after completed"
override_at=$(jq -r '.override_skip_streak_at' "$(state_file "$SID" "$SAZO_CWD")")
assert_eq "null" "$override_at" "T-RESET-1.2 override_skip_streak_at=null"
consumed_val=$(jq -r '.override_skip_streak_consumed' "$(state_file "$SID" "$SAZO_CWD")")
assert_eq "false" "$consumed_val" "T-RESET-1.3 override_skip_streak_consumed=false"

echo "=== T-AUDIT-1: block fires → audit log skip_streak_block with streak+tool ==="
> "$AUDIT_LOG"
SID="t_audit_1"
state_init "$SID" "$SAZO_CWD" "test-model"
f=$(state_file "$SID" "$SAZO_CWD")
stage_mark "$SID" "research" "completed" "user" "test" "$SAZO_CWD"
stage_mark "$SID" "plan" "completed" "user" "test" "$SAZO_CWD"
mark_approval_complete "$SID" "user" "/approved" "$SAZO_CWD"
_add_skip_history_append "$f" 5

export SAZO_SESSION_ID="$SID"
payload=$(jq -nc \
    --arg sid "$SID" \
    --arg cwd "$SAZO_CWD" \
    --arg model "test-model" \
    '{session_id:$sid, cwd:$cwd, model:$model, tool_name:"Edit", tool_input:{file_path:"/tmp/foo.sh",old_string:"a",new_string:"b"}, tool_response:{}}')
echo "$payload" | bash "$HOOKS_DIR/workflow-state-machine.sh" pre 2>/dev/null || true

if grep -q "skip_streak_block" "$AUDIT_LOG" 2>/dev/null; then
    assert_pass "T-AUDIT-1.1 audit log has skip_streak_block"
else
    assert_fail "T-AUDIT-1.1 audit log missing skip_streak_block"
fi
if grep -q "streak=5" "$AUDIT_LOG" 2>/dev/null; then
    assert_pass "T-AUDIT-1.2 audit log has streak=5"
else
    assert_fail "T-AUDIT-1.2 audit log missing streak=5" "audit: $(cat "$AUDIT_LOG")"
fi

echo "=== T-AUDIT-2: override consumed → audit skip_streak_override_consumed ==="
> "$AUDIT_LOG"
SID="t_audit_2"
state_init "$SID" "$SAZO_CWD" "test-model"
f=$(state_file "$SID" "$SAZO_CWD")
stage_mark "$SID" "research" "completed" "user" "test" "$SAZO_CWD"
stage_mark "$SID" "plan" "completed" "user" "test" "$SAZO_CWD"
mark_approval_complete "$SID" "user" "/approved" "$SAZO_CWD"
_add_skip_history_append "$f" 5
nonce="cafebeef12345678cafebeef12345678"
skip_streak_override_set "$SID" "$nonce" "$SAZO_CWD"

export SAZO_SESSION_ID="$SID"
payload=$(jq -nc \
    --arg sid "$SID" \
    --arg cwd "$SAZO_CWD" \
    --arg model "test-model" \
    '{session_id:$sid, cwd:$cwd, model:$model, tool_name:"Edit", tool_input:{file_path:"/tmp/foo.sh",old_string:"a",new_string:"b"}, tool_response:{}}')
echo "$payload" | bash "$HOOKS_DIR/workflow-state-machine.sh" pre 2>/dev/null || true

if grep -q "skip_streak_override_consumed" "$AUDIT_LOG" 2>/dev/null; then
    assert_pass "T-AUDIT-2 audit skip_streak_override_consumed present"
else
    assert_fail "T-AUDIT-2 audit skip_streak_override_consumed missing"
fi

# ---- summary ----

echo ""
echo "----- skip-streak.smoke summary -----"
read -r PASS FAIL < "$COUNT_FILE"
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
