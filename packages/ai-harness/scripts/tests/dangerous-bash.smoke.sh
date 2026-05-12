#!/usr/bin/env bash
# Smoke test: dangerous-bash-block hook (Plan 10)
# 41 cases: 11 spec + T_ESC + R-co + R6 + R7 + R-hs + T_MIG + T4b + T3b + T3c + narrow_off + T_FP1 + T_FP2 + T_REC + T_SUDO + T_REASON + R9a + R9b + R9c
# R10 additions: R10a + R10b + R10c + R10d + R10e + R10f + R10g + R10h
# R11 additions: R11a (sql FP grep) + R11b (sql FP echo) + R11c (sql real psql block)
# R12 additions: R12a (printf|psql pipeline) + R12b (echo|mysql pipeline) + R12c (cat|psql no-keyword pass)
# R13 additions: R13a (rm /* -r flag-after-path) + R13b (git -C /repo push --force global opts)
#                R13c (printf|sudo psql SQL wrapped client) + R13d (git branch -d -f main split flags)
# R14 additions: R14a (echo|env psql SQL env(1) wrapper)
#
# Tests the hook directly via simulated payloads and tests lib helpers via sourcing.
# SAZO_STATE_DIR is isolated per-test to prevent contamination.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/dangerous-bash-block.sh"
LIB_DIR="$SCRIPT_DIR/../hooks/lib"

PASS=0
FAIL=0

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1))
        echo "  PASS $label"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL $label (expected='$expected', got='$actual')"
    fi
}

assert_exit() {
    local expected_rc="$1" label="$2"
    shift 2
    local actual_rc=0
    "$@" 2>/dev/null || actual_rc=$?
    if [ "$actual_rc" -eq "$expected_rc" ]; then
        PASS=$((PASS+1))
        echo "  PASS $label"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL $label (expected exit=$expected_rc, got=$actual_rc)"
    fi
}

# Helper: run hook with a simulated Bash command payload.
# Returns the hook exit code.
run_hook() {
    local cmd="$1"
    local sid="${2:-test-sid-$$}"
    local state_dir="${3:-$TMP_MAIN}"
    local disable_block="${4:-0}"
    local narrow_off="${5:-0}"

    local payload
    payload=$(jq -nc \
        --arg sid "$sid" \
        --arg cmd "$cmd" \
        '{
            session_id: $sid,
            cwd: "/tmp/test-cwd",
            tool_name: "Bash",
            tool_input: {command: $cmd},
            tool_response: {},
            model: "claude-test"
        }')

    local rc=0
    SAZO_STATE_DIR="$state_dir" \
    SAZO_DISABLE_DANGEROUS_BLOCK="$disable_block" \
    SAZO_DISABLE_NARROW_HOOKS="$narrow_off" \
        bash "$HOOK" <<< "$payload" 2>/dev/null || rc=$?
    return $rc
}

# ---- setup ----

TMP_MAIN=$(mktemp -d)
trap 'rm -rf "$TMP_MAIN"' EXIT
mkdir -p "$TMP_MAIN"

echo "=== dangerous-bash-block smoke tests ==="

# ---- T1: git push --force → block (exit 2) ----
echo "Test T1: git_push_force block"
assert_exit 2 "T1 git push --force → exit 2" \
    run_hook "git push --force"

# ---- T2: git push --force-with-lease → pass (exit 0) ----
echo "Test T2: force-with-lease pass"
assert_exit 0 "T2 git push --force-with-lease → exit 0" \
    run_hook "git push --force-with-lease"

# ---- T3: rm -rf build/ → pass (exit 0) ----
echo "Test T3: rm -rf build/ pass"
assert_exit 0 "T3 rm -rf build/ → exit 0" \
    run_hook "rm -rf build/"

# ---- T4: rm -rf / → block (exit 2) ----
echo "Test T4: rm_rf_root block"
assert_exit 2 "T4 rm -rf / → exit 2" \
    run_hook "rm -rf /"

# ---- T4b: rm -rf / & → block (trailing background op) ----
echo "Test T4b: rm_rf_root with trailing & block"
assert_exit 2 "T4b rm -rf / & → exit 2" \
    run_hook "rm -rf / &"

# ---- T3b: rm -rf /app → pass (not a system dir) ----
echo "Test T3b: rm_rf_abs_system_path /app → pass (restricted to system dirs)"
assert_exit 0 "T3b rm -rf /app → exit 0" \
    run_hook "rm -rf /app"

# ---- T3c: rm -rf /usr → block (system dir) ----
echo "Test T3c: rm_rf_abs_system_path /usr → block"
assert_exit 2 "T3c rm -rf /usr → exit 2" \
    run_hook "rm -rf /usr"

# ---- T5: rm -rf $HOME → block (exit 2) ----
echo "Test T5: rm_rf_home block"
assert_exit 2 "T5 rm -rf \$HOME → exit 2" \
    run_hook 'rm -rf $HOME'

# ---- T6: git reset --hard origin/main → block (exit 2) ----
echo "Test T6: git_reset_hard_protected block"
assert_exit 2 "T6 git reset --hard origin/main → exit 2" \
    run_hook "git reset --hard origin/main"

# ---- T7: git branch -D main → block (exit 2) ----
echo "Test T7: git_branch_force_delete block"
assert_exit 2 "T7 git branch -D main → exit 2" \
    run_hook "git branch -D main"

# ---- T8: psql -c "DROP TABLE users;" → block (exit 2) ----
echo "Test T8: sql_destructive block"
assert_exit 2 "T8 DROP TABLE users → exit 2" \
    run_hook 'psql -c "DROP TABLE users;"'

# ---- T9: nonce set via /allow-dangerous ----
echo "Test T9: nonce set (UserPromptSubmit /allow-dangerous)"
TMP_T9=$(mktemp -d)
APPROVAL_HOOK="$SCRIPT_DIR/../hooks/user-prompt-approval-detect.sh"
SID_T9="t9-session-$$"
payload_t9=$(jq -nc \
    --arg sid "$SID_T9" \
    '{
        session_id: $sid,
        cwd: "/tmp/test-cwd",
        tool_name: "",
        tool_input: {},
        tool_response: {},
        model: "claude-test",
        prompt: "/allow-dangerous fix urgent"
    }')
SAZO_STATE_DIR="$TMP_T9" bash "$APPROVAL_HOOK" <<< "$payload_t9" 2>/dev/null || true
# Check state file for 32-hex nonce via subprocess (avoids RETURN-trap + source pollution)
nonce_t9=$(SAZO_STATE_DIR="$TMP_T9" bash -c "source \"$LIB_DIR/session-state.sh\"; state_get \"$SID_T9\" '.dangerous_override_nonce' '/tmp/test-cwd'" 2>/dev/null)
if printf '%s' "$nonce_t9" | grep -qE '^[0-9a-f]{32}$'; then
    PASS=$((PASS+1))
    echo "  PASS T9 nonce is 32-hex: $nonce_t9"
else
    FAIL=$((FAIL+1))
    echo "  FAIL T9 nonce not 32-hex (got='$nonce_t9')"
fi
rm -rf "$TMP_T9"

# ---- T10: nonce → passthrough; T11: consumed → block ----
echo "Test T10+T11: nonce lifecycle"
TMP_T10=$(mktemp -d)
APPROVAL_HOOK="$SCRIPT_DIR/../hooks/user-prompt-approval-detect.sh"
SID_T10="t10-session-$$"

# Set nonce via /allow-dangerous
payload_t10=$(jq -nc \
    --arg sid "$SID_T10" \
    '{
        session_id: $sid,
        cwd: "/tmp/test-cwd",
        tool_name: "",
        tool_input: {},
        tool_response: {},
        model: "claude-test",
        prompt: "/allow-dangerous fix urgent"
    }')
SAZO_STATE_DIR="$TMP_T10" bash "$APPROVAL_HOOK" <<< "$payload_t10" 2>/dev/null || true

# T10: git push --force should pass (nonce consumed)
rc_t10=0
run_hook "git push --force" "$SID_T10" "$TMP_T10" || rc_t10=$?
if [ "$rc_t10" -eq 0 ]; then
    PASS=$((PASS+1))
    echo "  PASS T10 nonce present → git push --force exit 0"
else
    FAIL=$((FAIL+1))
    echo "  FAIL T10 expected exit 0 with nonce, got exit=$rc_t10"
fi

# T11: second git push --force should be blocked (nonce consumed)
rc_t11=0
run_hook "git push --force" "$SID_T10" "$TMP_T10" || rc_t11=$?
if [ "$rc_t11" -eq 2 ]; then
    PASS=$((PASS+1))
    echo "  PASS T11 nonce consumed → git push --force exit 2"
else
    FAIL=$((FAIL+1))
    echo "  FAIL T11 expected exit 2 after nonce consumed, got exit=$rc_t11"
fi

# Also verify nonce is null in state (read raw JSON via subprocess)
nonce_after=$(SAZO_STATE_DIR="$TMP_T10" bash -c "
source \"$LIB_DIR/session-state.sh\"
f=\$(state_file \"$SID_T10\" '/tmp/test-cwd')
[ -f \"\$f\" ] && jq -r '.dangerous_override_nonce' \"\$f\" 2>/dev/null || echo 'no-file'
" 2>/dev/null)
assert_eq "null" "$nonce_after" "T11.verify nonce reset to null after consume"
rm -rf "$TMP_T10"

# ---- T_ESC: SAZO_DISABLE_DANGEROUS_BLOCK=1 → passthrough ----
echo "Test T_ESC: escape valve SAZO_DISABLE_DANGEROUS_BLOCK=1"
assert_exit 0 "T_ESC DISABLE=1 git push --force → exit 0" \
    run_hook "git push --force" "test-sid-esc" "$TMP_MAIN" "1"

# ---- R-co: git checkout -- . → block (8th pattern) ----
echo "Test R-co: git_checkout_discard block"
assert_exit 2 "R-co git checkout -- . → exit 2" \
    run_hook "git checkout -- ."

# ---- R6: tab-separated command → block ----
echo "Test R6: tab-separated git push --force"
tab_cmd=$(printf 'git\tpush\t--force')
assert_exit 2 "R6 tab-separated git push --force → exit 2" \
    run_hook "$tab_cmd"

# ---- R7: env-prefix git push --force → block ----
echo "Test R7: env-prefix GIT_DIR=x git push --force"
assert_exit 2 "R7 GIT_DIR=x git push --force → exit 2" \
    run_hook "GIT_DIR=x git push --force"

# ---- R-hs: here-string TRUNCATE TABLE → block ----
echo "Test R-hs: here-string TRUNCATE TABLE"
assert_exit 2 "R-hs psql <<< TRUNCATE TABLE → exit 2" \
    run_hook 'psql <<< "TRUNCATE TABLE x;"'

# ---- R9a: git push --force-with-lease --force → block (carve-out removed) ----
echo "Test R9a: git push --force-with-lease --force → block"
assert_exit 2 "R9a git push --force-with-lease --force → exit 2" \
    run_hook "git push --force-with-lease --force"

# ---- R9b: git checkout . → block (no -- required) ----
echo "Test R9b: git checkout . → block"
assert_exit 2 "R9b git checkout . → exit 2" \
    run_hook "git checkout ."

# ---- R9c: backslash-newline bypass prevention → block ----
echo "Test R9c: backslash-newline bypass → block"
assert_exit 2 "R9c rm -rf backslash-newline / → exit 2" \
    run_hook "$(printf 'rm -rf \\\n/')"

# ---- T_MIG: v3 → v5 schema migration (v3→v4→v5 dispatcher chain) ----
echo "=== T_MIG: v3 → v5 schema migration ==="
(
    TMP_HOME=$(mktemp -d)
    SAZO_STATE_DIR="$TMP_HOME/.claude/state"
    mkdir -p "$SAZO_STATE_DIR"

    # Source lib (sets STATE_DIR / SCHEMA_VERSION=5 after P09 v5 merge)
    source "$LIB_DIR/session-state.sh"

    # Manually create a v3 state file (pre-v4 schema, will be upgraded to v5)
    SID="t_mig_session"
    CWD="/tmp/test-cwd"
    f=$(state_file "$SID" "$CWD")
    cat > "$f" <<'EOF'
{
  "schema_version": 3,
  "history": [],
  "approval_nonce": null
}
EOF

    # Sanity: confirm v3 file written
    PRE_VER=$(jq -r '.schema_version' "$f")
    assert_eq "3" "$PRE_VER" "T_MIG.0 v3 file created with schema_version=3"

    # Trigger state_init — should call _state_schema_upgrade BEFORE short-circuit
    state_init "$SID" "$CWD" "test-model"

    # Verify migration happened
    POST_VER=$(jq -r '.schema_version' "$f")
    assert_eq "5" "$POST_VER" "T_MIG.1 schema_version upgraded to 5 (v3→v4→v5 chain)"

    POST_NONCE=$(jq -r '.dangerous_override_nonce' "$f")
    assert_eq "null" "$POST_NONCE" "T_MIG.2 dangerous_override_nonce field added (null)"

    POST_HIST=$(jq -r '.dangerous_override_history | type' "$f")
    assert_eq "array" "$POST_HIST" "T_MIG.3 dangerous_override_history field added (empty array)"

    # Verify pre-existing fields preserved
    POST_APPROVAL=$(jq -r '.approval_nonce' "$f")
    assert_eq "null" "$POST_APPROVAL" "T_MIG.4 pre-existing approval_nonce preserved"

    rm -rf "$TMP_HOME"
)

# ---- T_REC: rm --recursive / → block (long option) ----
echo "Test T_REC: rm --recursive / → block"
assert_exit 2 "T_REC rm --recursive / → exit 2" \
    run_hook "rm --recursive /"

# ---- T_SUDO: sudo -u root git push --force → block (sudo with flags) ----
echo "Test T_SUDO: sudo -u root git push --force → block"
assert_exit 2 "T_SUDO sudo -u root git push --force → exit 2" \
    run_hook "sudo -u root git push --force"

# ---- T_REASON: nonce reason stored in history ----
echo "Test T_REASON: /allow-dangerous reason stored in history"
TMP_TR=$(mktemp -d)
APPROVAL_HOOK="$SCRIPT_DIR/../hooks/user-prompt-approval-detect.sh"
SID_TR="t-reason-$$"

payload_tr=$(jq -nc \
    --arg sid "$SID_TR" \
    '{
        session_id: $sid,
        cwd: "/tmp/test-cwd",
        tool_name: "",
        tool_input: {},
        tool_response: {},
        model: "claude-test",
        prompt: "/allow-dangerous my urgent reason"
    }')
SAZO_STATE_DIR="$TMP_TR" bash "$APPROVAL_HOOK" <<< "$payload_tr" 2>/dev/null || true

# Consume via git push --force
run_hook "git push --force" "$SID_TR" "$TMP_TR" 2>/dev/null || true

# Check history entry has reason field
reason_in_hist=$(SAZO_STATE_DIR="$TMP_TR" bash -c "
source \"$LIB_DIR/session-state.sh\"
f=\$(state_file \"$SID_TR\" '/tmp/test-cwd')
[ -f \"\$f\" ] && jq -r '.dangerous_override_history[-1].reason // \"null\"' \"\$f\" 2>/dev/null || echo 'no-file'
" 2>/dev/null)
if [ "$reason_in_hist" != "null" ] && [ -n "$reason_in_hist" ] && [ "$reason_in_hist" != "no-file" ]; then
    PASS=$((PASS+1))
    echo "  PASS T_REASON history has reason: $reason_in_hist"
else
    FAIL=$((FAIL+1))
    echo "  FAIL T_REASON expected reason in history, got='$reason_in_hist'"
fi
rm -rf "$TMP_TR"

# ---- T_FP1: echo "git push --force" → pass (false positive guard) ----
echo "Test T_FP1: echo with dangerous string → pass (anchor guard)"
assert_exit 0 'T_FP1 echo "git push --force" → exit 0' \
    run_hook 'echo "git push --force"'

# ---- T_FP2: grep "rm -rf /" file → pass (false positive guard) ----
echo "Test T_FP2: grep with dangerous string → pass (anchor guard)"
assert_exit 0 'T_FP2 grep "rm -rf /" file → exit 0' \
    run_hook 'grep "rm -rf /" file'

# ---- Narrow hooks off → passthrough ----
echo "Test: narrow hooks off → passthrough"
assert_exit 0 "narrow_off git push --force → exit 0" \
    run_hook "git push --force" "test-sid-narrow" "$TMP_MAIN" "0" "1"

# ---- R10a: git push --force>/dev/null → block (redirect bypass) ----
echo "Test R10a: git push --force redirect bypass → block"
assert_exit 2 "R10a git push --force>/dev/null → exit 2" \
    run_hook "git push --force>/dev/null"

# ---- R10b: rm -rf /* → block (root glob) ----
echo "Test R10b: rm -rf /* root glob → block"
assert_exit 2 "R10b rm -rf /* → exit 2" \
    run_hook "rm -rf /*"

# ---- R10c: git reset --hard origin/main-feature → pass (false positive guard) ----
echo "Test R10c: git reset --hard origin/main-feature → pass (not protected branch)"
assert_exit 0 "R10c git reset --hard origin/main-feature → exit 0" \
    run_hook "git reset --hard origin/main-feature"

# ---- R10d: git reset --hard origin/main → block (exact branch name) ----
echo "Test R10d: git reset --hard origin/main → block"
assert_exit 2 "R10d git reset --hard origin/main → exit 2" \
    run_hook "git reset --hard origin/main"

# ---- R10e: git branch -D main-feature → pass (false positive guard) ----
echo "Test R10e: git branch -D main-feature → pass (not protected branch)"
assert_exit 0 "R10e git branch -D main-feature → exit 0" \
    run_hook "git branch -D main-feature"

# ---- R10f: git checkout .gitignore → pass (false positive guard) ----
echo "Test R10f: git checkout .gitignore → pass (not cwd discard)"
assert_exit 0 "R10f git checkout .gitignore → exit 0" \
    run_hook "git checkout .gitignore"

# ---- R10g: rm -rf /usr>/dev/null → block (redirect bypass on system path) ----
echo "Test R10g: rm -rf /usr redirect bypass → block"
assert_exit 2 "R10g rm -rf /usr>/dev/null → exit 2" \
    run_hook "rm -rf /usr>/dev/null"

# ---- R10h: rm -f -r ~ → block (split flags for home deletion) ----
echo "Test R10h: rm -f -r ~ (split flags) → block"
assert_exit 2 "R10h rm -f -r ~ → exit 2" \
    run_hook "rm -f -r ~"

# ---- R11a: grep "DROP TABLE" → pass (SQL false positive guard) ----
echo 'Test R11a: grep "DROP TABLE" → pass (SQL FP guard)'
assert_exit 0 'R11a grep "DROP TABLE" file.sql → exit 0' \
    run_hook 'grep "DROP TABLE" file.sql'

# ---- R11b: echo "DROP TABLE" → pass (SQL false positive guard) ----
echo 'Test R11b: echo "DROP TABLE" → pass (SQL FP guard)'
assert_exit 0 'R11b echo "DROP TABLE users" → exit 0' \
    run_hook 'echo "DROP TABLE users"'

# ---- R11c: psql -c "DROP TABLE" → block (real SQL execution) ----
echo 'Test R11c: psql -c "DROP TABLE" → block'
assert_exit 2 'R11c psql -c "DROP TABLE users" → exit 2' \
    run_hook 'psql -c "DROP TABLE users"'

# ---- R12a: printf 'DROP TABLE;' | psql → block (pipeline bypass) ----
echo "Test R12a: printf 'DROP TABLE;' | psql → block (pipeline bypass)"
assert_exit 2 "R12a printf 'DROP TABLE users;' | psql → exit 2" \
    run_hook "printf 'DROP TABLE users;' | psql"

# ---- R12b: echo 'DROP TABLE;' | mysql → block (pipeline bypass) ----
echo "Test R12b: echo 'DROP TABLE;' | mysql → block (pipeline bypass)"
assert_exit 2 "R12b echo 'TRUNCATE TABLE orders;' | mysql → exit 2" \
    run_hook "echo 'TRUNCATE TABLE orders;' | mysql"

# ---- R12c: cat safe_file.sql | psql → pass (no SQL keyword in command) ----
echo "Test R12c: cat safe_file.sql | psql → pass (no SQL keyword)"
assert_exit 0 "R12c cat safe_file.sql | psql → exit 0" \
    run_hook "cat safe_file.sql | psql"

# ---- R13a: rm /* -r (flag-after-path) → block ----
echo "Test R13a: rm /* -r (recursive flag after path) → block"
assert_exit 2 "R13a rm /* -r → exit 2" \
    run_hook "rm /* -r"

# ---- R13a2: rm /usr -rf (flag-after-path on system dir) → block ----
echo "Test R13a2: rm /usr -rf (flag-after-path, system dir) → block"
assert_exit 2 "R13a2 rm /usr -rf → exit 2" \
    run_hook "rm /usr -rf"

# ---- R13b: git -C /repo push --force (git global opts) → block ----
echo "Test R13b: git -C /repo push --force (git global opts) → block"
assert_exit 2 "R13b git -C /repo push --force → exit 2" \
    run_hook "git -C /repo push --force"

# ---- R13b2: git -c color.ui=always push --force → block ----
echo "Test R13b2: git -c color.ui=always push --force → block"
assert_exit 2 "R13b2 git -c color.ui=always push --force → exit 2" \
    run_hook "git -c color.ui=always push --force"

# ---- R13c: printf 'DROP TABLE;' | sudo -u postgres psql → block (wrapped SQL client) ----
echo "Test R13c: printf 'DROP TABLE;' | sudo -u postgres psql → block"
assert_exit 2 "R13c printf 'DROP TABLE users;' | sudo -u postgres psql → exit 2" \
    run_hook "printf 'DROP TABLE users;' | sudo -u postgres psql"

# ---- R13c2: echo 'TRUNCATE TABLE x;' | env PGPASS=x psql → block ----
echo "Test R13c2: echo 'TRUNCATE TABLE;' | env var psql → block"
assert_exit 2 "R13c2 echo 'TRUNCATE TABLE x;' | PGPASS=x psql → exit 2" \
    run_hook "echo 'TRUNCATE TABLE x;' | PGPASS=x psql"

# ---- R13d: git branch -d -f main (split force-delete flags) → block ----
echo "Test R13d: git branch -d -f main (split flags) → block"
assert_exit 2 "R13d git branch -d -f main → exit 2" \
    run_hook "git branch -d -f main"

# ---- R13d2: git branch -d --force main → block ----
echo "Test R13d2: git branch -d --force main → block"
assert_exit 2 "R13d2 git branch -d --force main → exit 2" \
    run_hook "git branch -d --force main"

# ---- R13d3: git branch --delete --force main → block ----
echo "Test R13d3: git branch --delete --force main → block"
assert_exit 2 "R13d3 git branch --delete --force main → exit 2" \
    run_hook "git branch --delete --force main"

# ---- R14a: echo 'TRUNCATE TABLE;' | env PGPASS=x psql → block (env(1) wrapper) ----
echo "Test R14a: echo 'TRUNCATE TABLE;' | env PGPASS=x psql → block (env wrapper)"
assert_exit 2 "R14a echo 'TRUNCATE TABLE x;' | env PGPASS=x psql → exit 2" \
    run_hook "echo 'TRUNCATE TABLE x;' | env PGPASS=x psql"

# ---- R14b: cat safe.sql | env PGPASS=x psql → pass (no SQL keyword) ----
echo "Test R14b: cat safe.sql | env PGPASS=x psql → pass (no SQL keyword)"
assert_exit 0 "R14b cat safe.sql | env PGPASS=x psql → exit 0" \
    run_hook "cat safe.sql | env PGPASS=x psql"

# ---- Bug 1 fixes: git branch -D arg-position bypass ----
# T_BUG1a: git branch -D feature main → block (protected branch not first after flags)
echo "Test T_BUG1a: git branch -D feature main → block (protected not first)"
assert_exit 2 "T_BUG1a git branch -D feature main → exit 2" \
    run_hook "git branch -D feature main"

# T_BUG1b: git branch -D foo bar baz main → block (protected branch last of many)
echo "Test T_BUG1b: git branch -D foo bar baz main → block (multi-prefix)"
assert_exit 2 "T_BUG1b git branch -D foo bar baz main → exit 2" \
    run_hook "git branch -D foo bar baz main"

# T_BUG1c: git branch -D main feature → block (protected first — regression check)
echo "Test T_BUG1c: git branch -D main feature → block (protected first, regression)"
assert_exit 2 "T_BUG1c git branch -D main feature → exit 2" \
    run_hook "git branch -D main feature"

# ---- Bug 2 fixes: rm flag-after-path arg-position bypass ----
# T_BUG2a: rm /tmp /usr -rf → block (system dir not first path)
echo "Test T_BUG2a: rm /tmp /usr -rf → block (system dir not first)"
assert_exit 2 "T_BUG2a rm /tmp /usr -rf → exit 2" \
    run_hook "rm /tmp /usr -rf"

# T_BUG2b: rm build /usr -rf → block (system dir not first path)
echo "Test T_BUG2b: rm build /usr -rf → block (non-path first)"
assert_exit 2 "T_BUG2b rm build /usr -rf → exit 2" \
    run_hook "rm build /usr -rf"

# T_BUG2c: rm /tmp / -rf → block (root not first path, rm_rf_root variant)
echo "Test T_BUG2c: rm /tmp / -rf → block (root not first, rm_rf_root)"
assert_exit 2 "T_BUG2c rm /tmp / -rf → exit 2" \
    run_hook "rm /tmp / -rf"

# T_BUG2d: rm /tmp \$HOME -rf → block (home not first path, rm_rf_home variant)
echo "Test T_BUG2d: rm /tmp \$HOME -rf → block (home not first, rm_rf_home)"
assert_exit 2 "T_BUG2d rm /tmp \$HOME -rf → exit 2" \
    run_hook 'rm /tmp $HOME -rf'

# T_BUG2e: rm -rf /usr → block (flag-first still works — regression check)
echo "Test T_BUG2e: rm -rf /usr → block (flag-first, regression)"
assert_exit 2 "T_BUG2e rm -rf /usr → exit 2" \
    run_hook "rm -rf /usr"

# ---- Summary ----
echo "─────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
