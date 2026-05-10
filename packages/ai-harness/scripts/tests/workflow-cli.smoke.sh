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
# 5c. explicit --session for nonexistent session must NOT fall back to global block
# (Codex PR #29 round 2 P2). state file 사라졌어도 audit log에 남은 다른 세션의
# block을 빼앗아 surface하면 안 됨.
run_cli why-blocked --session ghost-session-nonexistent
if [ "$RC" = "0" ] \
    && echo "$OUT" | grep -qi "not blocked"; then
    pass "5c. why-blocked --session <missing> → no global fallback"
else
    fail "5c." "rc=$RC; out=$OUT"
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

# 18. value-taking option without value must not hang (Codex PR #29 round 3 P2)
# `--session` / `--last` / `--days` / `--filter` 인자 없이 호출 시 빠르게 rc=1 + stderr.
# 이전 패턴 (`shift 2`)은 args 1개 남았을 때 실패해도 args 변경 안 해서 while 무한 loop.
# timeout 으로 hang 검출 — 정상 동작은 1초 안에 끝남.
for opt_case in "status --session" "history --last" "audit --filter" "sessions --days" "stats --days"; do
    set -- $opt_case
    sub="$1"; opt="$2"
    OUT_18=$(SAZO_STATE_DIR="$TMP_STATE" timeout 3 "$CLI" "$sub" "$opt" 2>&1)
    rc_18=$?
    if [ "$rc_18" != "124" ] && [ "$rc_18" != "0" ] \
        && echo "$OUT_18" | grep -qi "requires a value"; then
        pass "18.$sub$opt $opt 인자 누락 → rc=$rc_18 + 'requires a value' (no hang)"
    else
        fail "18.$sub$opt" "rc=$rc_18 (124=hung) out=$OUT_18"
    fi
done

# 19. history --last <non-numeric> → rc=1 + 'positive integer' (Codex PR #29 round 4 P2)
# 이전엔 jq --argjson 만 stderr 에러 뱉고 함수가 0 으로 종료해 자동화가 success로 오인.
# 다른 numeric subcommand 와 동일하게 _require_positive_int 적용.
for sub_case in "history --last" "audit --last" "sessions --days" "stats --days"; do
    set -- $sub_case
    sub="$1"; opt="$2"
    OUT_19=$(SAZO_STATE_DIR="$TMP_STATE" "$CLI" "$sub" "$opt" "foo" 2>&1)
    rc_19=$?
    if [ "$rc_19" = "1" ] && echo "$OUT_19" | grep -qi "positive integer"; then
        pass "19.$sub$opt $opt foo → rc=1 + 'positive integer'"
    else
        fail "19.$sub$opt" "rc=$rc_19 out=$OUT_19"
    fi
done

# 20. SAZO_SESSION_ID set + state file missing → exit 2, NOT silent fallback to other session
# (Codex PR #29 round 5 P2 #1)
mock_state_full "sessReal" "abc123"
SAZO_SESSION_ID="ghost-session-$$" run_cli status
if [ "$RC" = "2" ] && ! echo "$OUT" | grep -q "sessReal"; then
    pass "20. SAZO_SESSION_ID stale → exit 2 + no other-session leak"
else
    fail "20." "rc=$RC out=$OUT"
fi
rm -f "$TMP_STATE"/*.json

# 21. stats: audit.log empty + state metric (verdict_unset_expected_set_count) nonzero
# → 의미있는 결과 출력 시 rc=0 이어야 (Codex PR #29 round 5 P2 #2). 이전엔 entries 비어서 rc=2.
mock_state_full "sessV" "v1hash"
# state file 에 verdict_unset_expected_set_count 주입
jq '. + {verdict_unset_expected_set_count: 3}' "$TMP_STATE/sessV--v1hash.json" > "$TMP_STATE/sessV--v1hash.json.new" \
    && mv "$TMP_STATE/sessV--v1hash.json.new" "$TMP_STATE/sessV--v1hash.json"
rm -f "$TMP_STATE/audit.log"  # audit.log 없음
run_cli stats --days 7
if [ "$RC" = "0" ] && echo "$OUT" | grep -qE "verdict_unset_expected_set:[[:space:]]+3"; then
    pass "21. stats: state-derived metric nonzero → rc=0 (not classified as no-data)"
else
    fail "21." "rc=$RC out=$OUT"
fi
rm -f "$TMP_STATE"/*.json

# 22. CLI invoked via symlink resolves SCRIPT_DIR correctly without python3
# (Codex PR #29 round 6 P2 — macOS BSD readlink -f 미지원 + python3 부재 환경)
SYM_DIR=$(mktemp -d)
ln -s "$CLI" "$SYM_DIR/sazo-workflow-link"
# Even if python3 exists, ensure the resolution path doesn't depend on it by
# masking it from PATH. readlink (plain) must work on both macOS BSD and Linux.
OUT_22=$(SAZO_STATE_DIR="$TMP_STATE" PATH="/usr/bin:/bin" "$SYM_DIR/sazo-workflow-link" status 2>&1)
rc_22=$?
# rc_22 = 2 (no session) is fine — what we check is "no script-dir resolution failure".
if ! echo "$OUT_22" | grep -q "cannot find session-state.sh"; then
    pass "22. CLI via symlink resolves SCRIPT_DIR (no python3 dep, BSD-readlink compat)"
else
    fail "22." "rc=$rc_22 out=$OUT_22"
fi
rm -rf "$SYM_DIR"

# 23. _require_positive_int rejects 0 (Codex PR #29 round 7 P2)
# `--last 0` 이전엔 통과 → jq `.[0:]` = 전체 dump. positive 명세 위반.
for sub_case in "history --last" "audit --last" "sessions --days" "stats --days"; do
    set -- $sub_case
    sub="$1"; opt="$2"
    OUT_23=$(SAZO_STATE_DIR="$TMP_STATE" "$CLI" "$sub" "$opt" "0" 2>&1)
    rc_23=$?
    if [ "$rc_23" = "1" ] && echo "$OUT_23" | grep -qi "positive integer"; then
        pass "23.$sub$opt $opt 0 → rc=1 + 'positive integer'"
    else
        fail "23.$sub$opt" "rc=$rc_23 out=$OUT_23"
    fi
done
# leading-zero 변형
OUT_23b=$(SAZO_STATE_DIR="$TMP_STATE" "$CLI" history --last "00" 2>&1)
if [ "$?" = "1" ] && echo "$OUT_23b" | grep -qi "positive integer"; then
    pass "23b. history --last 00 → rc=1 (leading-zero variant rejected)"
else
    fail "23b." "out=$OUT_23b"
fi

# 23c. leading-zero non-octal-safe values (Codex PR #29 round 10 P2)
# `--days 08`/`--days 09`는 valid 정수 regex 통과 → bash arithmetic `$((days * 86400))`
# 에서 invalid octal로 평가 → "value too great for base" 에러 후 no-data 경로로 빠짐.
# 명시적 bad-argument 에러를 내야 자동화가 입력 정규화 의도를 알 수 있음.
for badval in "08" "09" "007"; do
    OUT_23c=$(SAZO_STATE_DIR="$TMP_STATE" "$CLI" sessions --days "$badval" 2>&1)
    rc_23c=$?
    if [ "$rc_23c" = "1" ] && echo "$OUT_23c" | grep -qi "positive integer"; then
        pass "23c. sessions --days $badval → rc=1 (leading-zero non-octal-safe rejected)"
    else
        fail "23c.$badval" "rc=$rc_23c out=$OUT_23c"
    fi
done

# 24. STATE_DIR path containing space (Codex PR #29 round 8 P2)
# `mtime path` row 가 awk space-split 으로 잘리면 sid/path 가 깨짐. tab delimiter 로 해결.
SPACED_PARENT=$(mktemp -d)
SPACED_DIR="$SPACED_PARENT/dir with space"
mkdir -p "$SPACED_DIR"
printf '{"stage":"plan","started_at":"2026-05-09T10:00:00+0900","plan_approved_at":null,"ci_passed_at":null,"history":[]}\n' \
    > "$SPACED_DIR/spaceSession--abchash.json"
OUT_24=$(SAZO_STATE_DIR="$SPACED_DIR" "$CLI" sessions --days 7 2>&1)
rc_24=$?
if [ "$rc_24" = "0" ] \
    && echo "$OUT_24" | grep -q "sid=spaceSession" \
    && echo "$OUT_24" | grep -q "dir with space"; then
    pass "24. STATE_DIR with spaces — sessions parses sid/path correctly (TAB delimiter)"
else
    fail "24." "rc=$rc_24 out=$OUT_24"
fi

OUT_24b=$(SAZO_STATE_DIR="$SPACED_DIR" "$CLI" status 2>&1)
rc_24b=$?
if [ "$rc_24b" = "0" ] && echo "$OUT_24b" | grep -q "Session: spaceSession"; then
    pass "24b. STATE_DIR with spaces — implicit status resolves spaceSession"
else
    fail "24b." "rc=$rc_24b out=$OUT_24b"
fi
rm -rf "$SPACED_PARENT"

# 25. sessions --json 출력 시 path 의 JSON-significant 문자 (`"`, `\`) escape
# (Codex PR #29 round 9 P2). jq 로 parse 해서 valid JSON 검증.
JSON_SPACED_PARENT=$(mktemp -d)
JSON_SPECIAL_DIR="$JSON_SPACED_PARENT/dir\\with\"quote"
mkdir -p "$JSON_SPECIAL_DIR"
printf '{"stage":"plan","started_at":"2026-05-09T10:00:00+0900","plan_approved_at":null,"ci_passed_at":null,"history":[]}\n' \
    > "$JSON_SPECIAL_DIR/jsonSession--abchash.json"
OUT_25=$(SAZO_STATE_DIR="$JSON_SPECIAL_DIR" "$CLI" sessions --days 7 --json 2>&1)
rc_25=$?
# jq 로 parse 가능해야 valid JSON.
if [ "$rc_25" = "0" ] && echo "$OUT_25" | jq -e '.path' >/dev/null 2>&1; then
    pass "25. sessions --json: JSON-significant chars in path properly escaped"
else
    fail "25." "rc=$rc_25 out=$OUT_25"
fi
rm -rf "$JSON_SPACED_PARENT"

# 26. sessions --json 출력 시 path 의 control character 도 안전 처리
# (Gemini PR #29 round 10 P2). awk 직접 JSON 구성 → jq pipeline 으로 변경.
# 디렉토리명에 백스페이스(\b, ASCII 8) 삽입 — JSON spec 상 escape 필요 (\b).
# awk 버전은 control char 를 raw byte 로 emit → jq parse 가능해도 "원본 보존" 안 됨.
# jq -R 버전은 자동 escape (\b) 후 parse 시 원본 byte 복원.
CTRL_PARENT=$(mktemp -d)
CTRL_DIR="$CTRL_PARENT/$(printf 'dir\bwith\bctrl')"
mkdir -p "$CTRL_DIR"
printf '{"stage":"plan","started_at":"2026-05-09T10:00:00+0900","plan_approved_at":null,"ci_passed_at":null,"history":[]}\n' \
    > "$CTRL_DIR/ctrlSession--abchash.json"
OUT_26=$(SAZO_STATE_DIR="$CTRL_DIR" "$CLI" sessions --days 7 --json 2>&1)
rc_26=$?
# parse 가능 + path 가 원본 control char 를 보존해야 통과.
PARSED_PATH_26=$(printf '%s' "$OUT_26" | jq -er '.path' 2>/dev/null)
if [ "$rc_26" = "0" ] \
    && [ -n "$PARSED_PATH_26" ] \
    && [ -f "$PARSED_PATH_26" ]; then
    pass "26. sessions --json: control characters preserved & parseable (jq pipeline)"
else
    fail "26." "rc=$rc_26 parsed_path=$(printf '%s' "$PARSED_PATH_26" | od -c | head -2) out=$OUT_26"
fi
rm -rf "$CTRL_PARENT"

# 26c. audit --json must skip malformed JSON lines (Codex PR #29 round 12 P2)
# 이전엔 `^{` prefix 만으로 필터해서 truncated 라인까지 emit → `jq` 받는 자동화가
# 성공 종료에도 parse 실패. Plan acceptance: 모든 --json 모드는 parseable.
mkdir -p "$TMP_STATE"
rm -f "$TMP_STATE/audit.log"
printf '{"ts":"2026-05-09T10:00:00+0900","event":"stage_block","truncat\n' \
    >> "$TMP_STATE/audit.log"
printf '{"ts":"2026-05-09T11:00:00+0900","event":"stage_block","sid":"sA","stage":"plan"}\n' \
    >> "$TMP_STATE/audit.log"
printf '{"ts":"2026-05-09T12:00:00+0900","event":"stage_block","sid":"sB","stage":"ci"}\n' \
    >> "$TMP_STATE/audit.log"
OUT_26c=$(SAZO_STATE_DIR="$TMP_STATE" "$CLI" audit --last 50 --json 2>&1)
rc_26c=$?
# 출력 라인 수: 정확히 2 (malformed 1 drop), 각 라인 jq parse 가능해야 함.
LINE_COUNT_26c=$(printf '%s\n' "$OUT_26c" | sed '/^$/d' | wc -l | tr -d ' ')
ALL_VALID=1
while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s' "$line" | jq -e . >/dev/null 2>&1 || ALL_VALID=0
done <<EOF_26c
$OUT_26c
EOF_26c
if [ "$rc_26c" = "0" ] && [ "$LINE_COUNT_26c" = "2" ] && [ "$ALL_VALID" = "1" ]; then
    pass "26c. audit --json: malformed JSON lines skipped, only parseable emitted"
else
    fail "26c." "rc=$rc_26c lines=$LINE_COUNT_26c valid=$ALL_VALID out=$OUT_26c"
fi
rm -f "$TMP_STATE/audit.log"

# 26b. stats: malformed JSON line in audit.log must NOT discard valid entries
# (Codex PR #29 round 11 P2). 단일 jq fail → `|| entries=""` 이 valid 라인까지
# 전부 버려서 stage_block count 가 0 으로 보고됨 (no-data 분기까지 빠질 수 있음).
mkdir -p "$TMP_STATE"
rm -f "$TMP_STATE"/*.json
rm -f "$TMP_STATE/audit.log"
# 1) malformed JSON line (truncated)
printf '{"ts":"2026-05-09T10:00:00+0900","event":"stage_block","sid":"sX","stage":"plan","reaso\n' \
    >> "$TMP_STATE/audit.log"
# 2) valid stage_block lines after the bad one
printf '{"ts":"2026-05-09T11:00:00+0900","event":"stage_block","sid":"sA","stage":"plan","status":"blocked","by":"hook","reason":"r1"}\n' \
    >> "$TMP_STATE/audit.log"
printf '{"ts":"2026-05-09T12:00:00+0900","event":"stage_block","sid":"sB","stage":"ci","status":"blocked","by":"hook","reason":"r2"}\n' \
    >> "$TMP_STATE/audit.log"
OUT_26b=$(SAZO_STATE_DIR="$TMP_STATE" "$CLI" stats --days 30 2>&1)
rc_26b=$?
# 정상이라면 total stage_block events = 2 (malformed 라인은 무시).
if [ "$rc_26b" = "0" ] && echo "$OUT_26b" | grep -qE "Total stage_block events:[[:space:]]+2"; then
    pass "26b. stats: malformed audit line skipped, valid entries counted"
else
    fail "26b." "rc=$rc_26b out=$OUT_26b"
fi
rm -f "$TMP_STATE/audit.log"

# 27. stats batched jq aggregation (Gemini PR #29 round 10 P2)
# 다중 state file 의 verdict_unset_expected_set_count 합산 — 이전엔 file별 jq 호출.
# jq 단일 호출로 변경 후에도 합산 결과 동일해야 함.
mkdir -p "$TMP_STATE"
rm -f "$TMP_STATE"/*.json
for sid_n in 1 2 3; do
    jq -n --argjson v "$sid_n" '{verdict_unset_expected_set_count: $v}' \
        > "$TMP_STATE/sessAggr${sid_n}--h${sid_n}.json"
done
# 합계: 1+2+3 = 6
rm -f "$TMP_STATE/audit.log"
OUT_27=$(SAZO_STATE_DIR="$TMP_STATE" "$CLI" stats --days 7 2>&1)
rc_27=$?
if [ "$rc_27" = "0" ] && echo "$OUT_27" | grep -qE "verdict_unset_expected_set:[[:space:]]+6"; then
    pass "27. stats: batched jq aggregation across multiple state files"
else
    fail "27." "rc=$rc_27 out=$OUT_27"
fi
# 0-file edge: state file 없을 때도 0 반환해야 함 (no glob expansion).
rm -f "$TMP_STATE"/*.json
OUT_27b=$(SAZO_STATE_DIR="$TMP_STATE" "$CLI" stats --days 7 2>&1)
rc_27b=$?
# state file/audit 모두 없으면 no-data (rc=2) 가 정상. 단 jq error stderr 로 새지 않아야 함.
if [ "$rc_27b" = "2" ] && ! echo "$OUT_27b" | grep -qi "jq: error"; then
    pass "27b. stats: no state files → no-data, no jq errors"
else
    fail "27b." "rc=$rc_27b out=$OUT_27b"
fi

echo ""
echo "─────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
