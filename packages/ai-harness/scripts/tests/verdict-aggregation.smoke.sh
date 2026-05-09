#!/usr/bin/env bash
# Smoke test: _record_reviewer_error + _evaluate_stage_completion (plan 01 slice 3)

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

assert_rc() {
  local expected="$1" cmd="$2" label="$3"
  set +e
  eval "$cmd" >/dev/null 2>&1
  local rc=$?
  set -e
  if [ "$rc" = "$expected" ]; then
    PASS=$((PASS+1))
    echo "  ✓ $label"
  else
    FAIL=$((FAIL+1))
    echo "  ✗ $label (rc expected $expected, got $rc)"
  fi
}

state_jq() {
  local sid="$1" path="$2" cwd="$3"
  local sf
  sf=$(state_file "$sid" "$cwd")
  jq -r "$path" "$sf"
}

# Helper: simulate verdict arrival (write into state.last_verdicts)
record_verdict() {
  local sid="$1" cwd="$2" stage="$3" agent="$4" verdict="$5" issues="${6:-0}"
  local entry
  entry=$(jq -nc --arg v "$verdict" --argjson i "$issues" --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" \
    '{verdict: $v, issues: $i, ts: $ts}')
  state_set_json "$sid" ".last_verdicts.$stage[\"$agent\"]" "$entry" "$cwd"
}

SID="agg-test-1"
CWD="/tmp/agg-cwd"
state_init "$SID" "$CWD" "test"

# --- A: _record_reviewer_error increments counter ---
echo "Test A: _record_reviewer_error increments counter"
_record_reviewer_error "$SID" "$CWD" "code-reviewer" 2>/dev/null
count=$(state_jq "$SID" '.verdict_errors["code-reviewer"]' "$CWD")
assert_eq "1" "$count" "A.1 first error → count=1"

_record_reviewer_error "$SID" "$CWD" "code-reviewer" 2>/dev/null
count=$(state_jq "$SID" '.verdict_errors["code-reviewer"]' "$CWD")
assert_eq "2" "$count" "A.2 second error → count=2"

# --- B: 3rd error emits escalation to stderr ---
echo "Test B: 3rd error emits escalation"
err_output=$(_record_reviewer_error "$SID" "$CWD" "code-reviewer" 2>&1)
count=$(state_jq "$SID" '.verdict_errors["code-reviewer"]' "$CWD")
assert_eq "3" "$count" "B.1 third error → count=3"
if echo "$err_output" | grep -q 'reviewer code-reviewer stuck'; then
  PASS=$((PASS+1))
  echo "  ✓ B.2 stuck message in stderr"
else
  FAIL=$((FAIL+1))
  echo "  ✗ B.2 stuck message missing. Got: $err_output"
fi

# --- C: per-agent counter independent ---
echo "Test C: per-agent counter independent"
_record_reviewer_error "$SID" "$CWD" "architect-advisor" 2>/dev/null
arch_count=$(state_jq "$SID" '.verdict_errors["architect-advisor"]' "$CWD")
assert_eq "1" "$arch_count" "C.1 architect-advisor count=1 (independent)"

# --- D: _evaluate_stage_completion review stage with expected set + all APPROVE ---
echo "Test D: review stage with expected set + all APPROVE"
SID2="agg-test-2"
state_init "$SID2" "$CWD" "test"
state_set_json "$SID2" ".review_expected_set" '["code-reviewer","architect-advisor"]' "$CWD"
record_verdict "$SID2" "$CWD" "review" "code-reviewer" "APPROVE"
record_verdict "$SID2" "$CWD" "review" "architect-advisor" "APPROVE"
assert_rc 0 "_evaluate_stage_completion '$SID2' '$CWD' 'review'" "D.1 all APPROVE → completion 0"

# --- E: review with one BLOCK → not complete ---
echo "Test E: one BLOCK fails completion"
SID3="agg-test-3"
state_init "$SID3" "$CWD" "test"
state_set_json "$SID3" ".review_expected_set" '["code-reviewer","architect-advisor"]' "$CWD"
record_verdict "$SID3" "$CWD" "review" "code-reviewer" "APPROVE"
record_verdict "$SID3" "$CWD" "review" "architect-advisor" "BLOCK" 3
assert_rc 1 "_evaluate_stage_completion '$SID3' '$CWD' 'review'" "E.1 one BLOCK → completion 1"

# --- F: review with missing reviewer (expected ⊄ received) ---
echo "Test F: missing reviewer fails completion"
SID4="agg-test-4"
state_init "$SID4" "$CWD" "test"
state_set_json "$SID4" ".review_expected_set" '["code-reviewer","architect-advisor"]' "$CWD"
record_verdict "$SID4" "$CWD" "review" "code-reviewer" "APPROVE"
# architect-advisor not yet received
assert_rc 1 "_evaluate_stage_completion '$SID4' '$CWD' 'review'" "F.1 partial received → completion 1"

# --- G: empty expected_set + fail_open default + first APPROVE → pass ---
echo "Test G: empty expected_set fail_open"
SID5="agg-test-5"
state_init "$SID5" "$CWD" "test"
# expected_set already [] from init
record_verdict "$SID5" "$CWD" "review" "code-reviewer" "APPROVE"
unset SAZO_VERDICT_EMPTY_EXPECTED  # default fail_open
assert_rc 0 "_evaluate_stage_completion '$SID5' '$CWD' 'review'" "G.1 empty + APPROVE + fail_open → 0"

unset_count=$(state_jq "$SID5" '.verdict_unset_expected_set_count' "$CWD")
assert_eq "1" "$unset_count" "G.2 unset metric incremented"

# --- H: empty expected_set + fail_closed → block ---
echo "Test H: empty expected_set fail_closed"
SID6="agg-test-6"
state_init "$SID6" "$CWD" "test"
record_verdict "$SID6" "$CWD" "review" "code-reviewer" "APPROVE"
SAZO_VERDICT_EMPTY_EXPECTED=fail_closed
assert_rc 1 "SAZO_VERDICT_EMPTY_EXPECTED=fail_closed _evaluate_stage_completion '$SID6' '$CWD' 'review'" "H.1 empty + fail_closed → 1"
unset SAZO_VERDICT_EMPTY_EXPECTED

# --- I: plan stage uses fixed expected set [plan-critic, plan-auditor] ---
echo "Test I: plan stage fixed expected set"
SID7="agg-test-7"
state_init "$SID7" "$CWD" "test"
record_verdict "$SID7" "$CWD" "plan" "plan-critic" "APPROVE"
record_verdict "$SID7" "$CWD" "plan" "plan-auditor" "APPROVE"
assert_rc 0 "_evaluate_stage_completion '$SID7' '$CWD' 'plan'" "I.1 both plan reviewers APPROVE → 0"

SID8="agg-test-8"
state_init "$SID8" "$CWD" "test"
record_verdict "$SID8" "$CWD" "plan" "plan-critic" "APPROVE"
# plan-auditor missing
assert_rc 1 "_evaluate_stage_completion '$SID8' '$CWD' 'plan'" "I.2 plan stage missing auditor → 1"

# --- Summary ---
echo "─────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
