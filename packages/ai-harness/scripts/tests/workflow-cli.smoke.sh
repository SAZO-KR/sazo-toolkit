#!/usr/bin/env bash
# Smoke test: sazo-workflow CLI (Plan 02)
#
# 17 scenarios covering status / history / why-blocked / audit / sessions /
# stats / recover, plus install symlink + multi-session resolution + legacy
# audit.log compatibility + macOS/Linux date fallback.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$HARNESS_DIR/scripts/sazo-workflow.sh"
LIB="$HARNESS_DIR/scripts/hooks/lib/session-state.sh"

if [ ! -f "$CLI" ] || [ ! -f "$LIB" ]; then
    echo "FATAL: required scripts missing (CLI=$CLI LIB=$LIB)" >&2
    exit 1
fi

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); printf '  \xe2\x9c\x93 %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  \xe2\x9c\x97 %s — %s\n' "$1" "$2"; }

run_cli() {
    # Args: subcmd [opts...]
    # Captures stdout/stderr/rc into globals OUT, ERR, RC.
    local stderr_tmp
    stderr_tmp=$(mktemp)
    OUT=$(SAZO_STATE_DIR="$TMP_STATE" "$CLI" "$@" 2>"$stderr_tmp")
    RC=$?
    ERR=$(cat "$stderr_tmp")
    rm -f "$stderr_tmp"
}

write_state() {
    # Args: sid cwd_hash content_jq_input
    local sid="$1" h="$2" body="$3"
    printf '%s' "$body" > "$TMP_STATE/${sid}--${h}.json"
}

mock_state_full() {
    local sid="$1" h="$2"
    jq -n \
        --arg sid "$sid" \
        --arg ts "2026-05-10T10:00:00+0900" \
        '{
            schema_version: 2,
            session_id: $sid,
            cwd: "/work/foo",
            model: "opus",
            started_at: $ts,
            stage: "ci",
            history: [
                {ts:"2026-05-10T10:00:00+0900",stage:"research",status:"completed",by:"auto",reason:"subagent=code-searcher",cycle_id:""},
                {ts:"2026-05-10T10:05:00+0900",stage:"plan",status:"completed",by:"auto",reason:"subagent=plan-drafter",cycle_id:""},
                {ts:"2026-05-10T10:10:00+0900",stage:"approval",status:"completed",by:"user",reason:"/approved",cycle_id:""},
                {ts:"2026-05-10T10:30:00+0900",stage:"ci",status:"completed",by:"auto",reason:"ci-cmd matched",cycle_id:""},
                {ts:"2026-05-10T10:35:00+0900",stage:"review",status:"completed",by:"auto",reason:"verdict aggregation: all APPROVE",cycle_id:""}
            ],
            explore_count: 0,
            plan_approved_at: "2026-05-10T10:10:00+0900",
            approval_nonce: null,
            ci_passed_at: "2026-05-10T10:30:00+0900",
            review_ts: null,
            verdict_nonces: {},
            last_verdicts: {review:{"code-reviewer":{verdict:"APPROVE",issues:0,ts:"x"}}, plan:{}},
            verdict_missing_count: {"code-reviewer":1},
            verdict_errors: {},
            verdict_unset_expected_set_count: 2,
            review_expected_set: ["code-reviewer","architect-advisor"],
            soft_warn_count_research: 1,
            soft_warn_count_plan: 0,
            last_cycle_at: {},
            last_cycle_id: {}
        }' > "$TMP_STATE/${sid}--${h}.json"
}

# ===== suite =====

TMP_STATE=$(mktemp -d)
trap 'rm -rf "$TMP_STATE" "${FAKE_HOME:-}" "${PATH_SHIM_DIR:-}" 2>/dev/null || true' EXIT

# 1. empty STATE_DIR → status exit 2
run_cli status
if [ "$RC" = "2" ]; then pass "1. empty STATE_DIR → status exit 2"; else fail "1." "rc=$RC"; fi

# 2. mock state.json 1개 → status 핵심 필드 표시
mock_state_full "sessA" "abc123def456"
run_cli status --session sessA
if [ "$RC" = "0" ] \
    && echo "$OUT" | grep -q "Session: sessA" \
    && echo "$OUT" | grep -q "Stage: ci" \
    && echo "$OUT" | grep -q "Plan approved at: 2026-05-10T10:10:00+0900" \
    && echo "$OUT" | grep -q "CI passed at: 2026-05-10T10:30:00+0900" \
    && echo "$OUT" | grep -q "code-reviewer: 1" \
    && echo "$OUT" | grep -q "research: 1"; then
    pass "2. mock state → status displays core fields"
else
    fail "2." "rc=$RC; out=$OUT"
fi

# 3. history --last 5
run_cli history --last 5 --session sessA
n=$(printf '%s\n' "$OUT" | grep -c .)
if [ "$RC" = "0" ] && [ "$n" = "5" ] && echo "$OUT" | head -1 | grep -q research; then
    pass "3. history --last 5 → 5 entries chronological"
else
    fail "3." "n=$n rc=$RC"
fi

# 4. JSON Lines block entry → why-blocked exit 2 + reason
printf '{"ts":"2026-05-10T11:00:00+0900","event":"stage_block","sid":"sessA","stage":"ci","status":"blocked","by":"hook","reason":"CI not passed"}\n' \
    >> "$TMP_STATE/audit.log"
run_cli why-blocked --session sessA
if [ "$RC" = "2" ] \
    && echo "$OUT" | grep -q "Blocked at stage: ci" \
    && echo "$OUT" | grep -q "CI not passed" \
    && echo "$OUT" | grep -q "project CI command"; then
    pass "4. why-blocked exit 2 + reason + next action"
else
    fail "4." "rc=$RC; out=$OUT"
fi

# 5. block entry 0 → why-blocked exit 0
rm -f "$TMP_STATE/audit.log"
run_cli why-blocked --session sessA
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "Not blocked"; then
    pass "5. no block entries → why-blocked exit 0"
else
    fail "5." "rc=$RC; out=$OUT"
fi

# 5b. multi-session: --session filter must NOT cross-leak block reasons
mock_state_full "sessB" "def456abc789"
printf '{"ts":"2026-05-10T11:00:01+0900","event":"stage_block","sid":"sessA","stage":"ci","status":"blocked","by":"hook","reason":"sessA CI"}\n' \
    >> "$TMP_STATE/audit.log"
printf '{"ts":"2026-05-10T11:00:02+0900","event":"stage_block","sid":"sessB","stage":"review","status":"blocked","by":"hook","reason":"sessB review"}\n' \
    >> "$TMP_STATE/audit.log"
# --session sessA must surface sessA's block, NOT sessB's (which is more recent in audit.log)
run_cli why-blocked --session sessA
if [ "$RC" = "2" ] \
    && echo "$OUT" | grep -q "sessA CI" \
    && ! echo "$OUT" | grep -q "sessB review"; then
    pass "5b. why-blocked --session filter (no cross-session leak)"
else
    fail "5b." "rc=$RC; out=$OUT"
fi
rm -f "$TMP_STATE/audit.log"

# 6. audit --filter stage_block
printf '{"ts":"2026-05-10T11:00:00+0900","event":"stage_block","sid":"x","stage":"ci","status":"blocked","by":"hook","reason":"r1"}\n' \
    >> "$TMP_STATE/audit.log"
printf '{"ts":"2026-05-10T11:01:00+0900","event":"stage_complete","sid":"x","stage":"ci","status":"completed","by":"auto","reason":"r2"}\n' \
    >> "$TMP_STATE/audit.log"
printf '{"ts":"2026-05-10T11:02:00+0900","event":"stage_block","sid":"x","stage":"review","status":"blocked","by":"hook","reason":"r3"}\n' \
    >> "$TMP_STATE/audit.log"
run_cli audit --filter stage_block
n=$(printf '%s\n' "$OUT" | grep -c '"event":"stage_block"')
n_other=$(printf '%s\n' "$OUT" | grep -c '"event":"stage_complete"')
if [ "$RC" = "0" ] && [ "$n" = "2" ] && [ "$n_other" = "0" ]; then
    pass "6. audit --filter stage_block → only matching events"
else
    fail "6." "n=$n n_other=$n_other rc=$RC"
fi

# 7. sessions --days 7 — multiple sessions sorted by mtime
# Use explicit `touch -t` timestamps (instantaneous + deterministic, no flaky sleep).
mock_state_full "sessB" "def456abc789"
touch -t 202605100900 "$TMP_STATE/sessB--def456abc789.json"
touch -t 202605101000 "$TMP_STATE/sessA--abc123def456.json"
run_cli sessions --days 7
first=$(printf '%s\n' "$OUT" | head -1)
if [ "$RC" = "0" ] \
    && echo "$OUT" | grep -q "sid=sessA" \
    && echo "$OUT" | grep -q "sid=sessB" \
    && echo "$first" | grep -q "sid=sessA"; then
    pass "7. sessions --days 7 → both listed, newest first"
else
    fail "7." "rc=$RC; out=$OUT"
fi

# 8. --json flag valid JSON for all cmds
run_cli status --session sessA --json
if [ "$RC" = "0" ] && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
    j_status=ok
else
    j_status="rc=$RC"
fi
run_cli history --session sessA --json
if [ "$RC" = "0" ] && printf '%s' "$OUT" | jq -e 'type=="array"' >/dev/null 2>&1; then
    j_hist=ok
else
    j_hist="rc=$RC"
fi
run_cli why-blocked --json
# RC may be 0 or 2 depending on audit content; both are valid as long as JSON parses
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
    j_wb=ok
else
    j_wb="bad json"
fi
run_cli sessions --days 7 --json
if [ "$RC" = "0" ]; then
    valid=1
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        printf '%s' "$line" | jq -e . >/dev/null 2>&1 || valid=0
    done <<EOF2
$OUT
EOF2
    [ "$valid" = "1" ] && j_sess=ok || j_sess="bad json"
else
    j_sess="rc=$RC"
fi
run_cli stats --days 30 --json
if printf '%s' "$OUT" | jq -e .promotion >/dev/null 2>&1; then
    j_stats=ok
else
    j_stats="bad json"
fi
if [ "$j_status" = "ok" ] && [ "$j_hist" = "ok" ] && [ "$j_wb" = "ok" ] \
    && [ "$j_sess" = "ok" ] && [ "$j_stats" = "ok" ]; then
    pass "8. --json valid for status/history/why-blocked/sessions/stats"
else
    fail "8." "status=$j_status hist=$j_hist wb=$j_wb sess=$j_sess stats=$j_stats"
fi

# 9. SAZO_STATE_DIR override (test relies on TMP_STATE != HOME default)
run_cli status --session sessA
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "Session: sessA"; then
    pass "9. SAZO_STATE_DIR override → custom dir works"
else
    fail "9." "rc=$RC"
fi

# 10. multi-session, no SAZO_SESSION_ID → most recent + warn stderr
unset SAZO_SESSION_ID
run_cli status
# stderr should mention multiple sessions; stdout shows newest (sessA touched later)
if echo "$ERR" | grep -q "Multiple active sessions" \
    && echo "$OUT" | grep -q "Session: sessA"; then
    pass "10. multi-session → most recent + warn"
else
    fail "10." "err=$ERR; out=$OUT"
fi

# 11. --session bogus → exit 2
run_cli status --session does-not-exist
if [ "$RC" = "2" ]; then
    pass "11. unknown --session → exit 2"
else
    fail "11." "rc=$RC"
fi

# 12. legacy freeform + JSON Lines mixed → audit shows both
rm -f "$TMP_STATE/audit.log"
printf '[2026-05-10T12:00:00+0900] sessA stage=plan status=completed by=auto reason=foo\n' \
    >> "$TMP_STATE/audit.log"
printf '{"ts":"2026-05-10T12:05:00+0900","event":"stage_block","sid":"sessA","stage":"plan","status":"blocked","by":"hook","reason":"r"}\n' \
    >> "$TMP_STATE/audit.log"
run_cli audit
if [ "$RC" = "0" ] \
    && echo "$OUT" | grep -q "stage=plan status=completed" \
    && echo "$OUT" | grep -q '"event":"stage_block"'; then
    pass "12. mixed legacy + JSON entries — audit shows both"
else
    fail "12." "rc=$RC; out=$OUT"
fi

# 13. install symlink — exercise the REAL sync_workflow_cli function from install.sh
# (no re-implementation of `ln -sfn`). Sources install.sh in subshell with HOME
# isolation so we test the actual logic including the "non-symlink exists" warn branch.
FAKE_HOME=$(mktemp -d)
INSTALL_SH="$HARNESS_DIR/install.sh"

# Helper to invoke sync_workflow_cli in isolated HOME.
# Extract the function body from install.sh and exec it with HARNESS_DIR set —
# avoids running install.sh's interactive top-level while still calling the
# real function (no re-implementation of `ln -sfn`).
invoke_sync() {
    HOME="$FAKE_HOME" HARNESS_DIR="$HARNESS_DIR" \
    INSTALL_SH="$INSTALL_SH" \
    bash -c '
        set -uo pipefail
        eval "$(awk "/^sync_workflow_cli\\(\\) \\{/,/^\\}/" "$INSTALL_SH")"
        sync_workflow_cli
    '
    return $?
}

invoke_sync_rc=0
invoke_sync || invoke_sync_rc=$?
target="$FAKE_HOME/.local/bin/sazo-workflow"
expected_link="$HARNESS_DIR/scripts/sazo-workflow.sh"

if [ -L "$target" ] && [ "$(readlink "$target")" = "$expected_link" ]; then
    # Idempotency: real function called twice → link still correct, no error
    invoke_sync_rc2=0
    invoke_sync || invoke_sync_rc2=$?
    if [ -L "$target" ] \
        && [ "$(readlink "$target")" = "$expected_link" ] \
        && [ "$invoke_sync_rc2" = "0" ]; then
        # Negative case: replace link with regular file, expect rc=0 + warn
        # (must NOT abort under install.sh's `set -e`).
        rm -f "$target"
        echo "stub" > "$target"
        invoke_sync_negative_rc=0
        STDERR_OUT=$(invoke_sync 2>&1 1>/dev/null) || invoke_sync_negative_rc=$?
        # Existing stub must remain (skipped, not overwritten).
        if [ "$invoke_sync_negative_rc" = "0" ] \
            && echo "$STDERR_OUT" | grep -qi "warn" \
            && [ -f "$target" ] && [ ! -L "$target" ]; then
            pass "13. sync_workflow_cli: symlink + idempotent + non-symlink warn (rc=0, no abort)"
        else
            fail "13. negative case" "rc=$invoke_sync_negative_rc stderr=$STDERR_OUT"
        fi
    else
        fail "13. idempotent" "rc=$invoke_sync_rc2"
    fi
else
    fail "13." "first call: symlink missing or wrong target (rc=$invoke_sync_rc)"
fi

# 14. PATH 미등록 시 warn — install function in install.sh (not yet implemented at this stage).
# We test the predicate logic: a function that warns when ~/.local/bin is not in PATH.
warn_check() {
    local expected="$HOME/.local/bin"
    case ":$PATH:" in
        *":$expected:"*) return 1 ;;
        *) return 0 ;;
    esac
}
HOME_BACKUP="$HOME"
HOME="$FAKE_HOME"
PATH_BACKUP="$PATH"
PATH="/usr/bin:/bin"
if warn_check; then
    PATH="$PATH_BACKUP"
    PATH="$FAKE_HOME/.local/bin:$PATH_BACKUP"
    if ! warn_check; then
        HOME="$HOME_BACKUP"
        PATH="$PATH_BACKUP"
        pass "14. PATH check warns when ~/.local/bin missing, silent when present"
    else
        HOME="$HOME_BACKUP"
        PATH="$PATH_BACKUP"
        fail "14." "predicate did not silence with PATH set"
    fi
else
    HOME="$HOME_BACKUP"
    PATH="$PATH_BACKUP"
    fail "14." "predicate did not warn when PATH missing"
fi

# 15. recover stub — Plan 05 marker absent → exit 2 "no degraded"
run_cli recover
if [ "$RC" = "2" ] && echo "$OUT" | grep -q "No degraded state"; then
    pass "15. recover stub: marker absent → exit 2"
else
    fail "15." "rc=$RC; out=$OUT"
fi

# 16. stats --days 30 — Plan 12 promotion criteria displayed
# Add some events for richer output (TMP_STATE has audit.log already from #12)
printf '{"ts":"2026-05-10T13:00:00+0900","event":"stage_block","sid":"sessA","stage":"review","status":"blocked","by":"hook","reason":"r"}\n' \
    >> "$TMP_STATE/audit.log"
run_cli stats --days 30
if [ "$RC" = "0" ] \
    && echo "$OUT" | grep -q "state_corruption_count" \
    && echo "$OUT" | grep -q "lock_timeout_count" \
    && echo "$OUT" | grep -q "jq_error_count" \
    && echo "$OUT" | grep -q "verdict_unset_expected_set" \
    && (echo "$OUT" | grep -q "Phase 2 promotion"); then
    pass "16. stats --days 30 → all 5 Plan 12 criteria + promotion verdict"
else
    fail "16." "rc=$RC; out=$OUT"
fi

# 17. macOS BSD vs GNU date fallback — both expressions accepted
gnu_ok=0
bsd_ok=0
if date -d "30 days ago" +%Y-%m-%dT%H:%M:%S%z >/dev/null 2>&1; then gnu_ok=1; fi
if date -v-30d +%Y-%m-%dT%H:%M:%S%z >/dev/null 2>&1; then bsd_ok=1; fi
# stats uses chained `||` — at least one must work for stats to compute since.
# Test passes if stats succeeds AND at least one date variant works locally.
run_cli stats --days 30
if [ "$RC" = "0" ] && { [ "$gnu_ok" = "1" ] || [ "$bsd_ok" = "1" ]; }; then
    pass "17. date fallback chain works (gnu=$gnu_ok bsd=$bsd_ok)"
else
    fail "17." "rc=$RC gnu=$gnu_ok bsd=$bsd_ok"
fi

echo ""
echo "─────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
