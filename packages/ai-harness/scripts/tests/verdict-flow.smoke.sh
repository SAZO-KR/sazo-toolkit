#!/usr/bin/env bash
# Smoke test: process_verdict_tracked_post_task end-to-end (plan 01 slice 5)

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

state_jq() {
  local sid="$1" path="$2" cwd="$3"
  local sf; sf=$(state_file "$sid" "$cwd")
  jq -r "$path" "$sf"
}

CWD="/tmp/flow-cwd"

mk_envelope() {
  local nonce="$1" verdict="$2" issues="${3:-0}"
  cat <<EOF
review body here

---SAZO_FOOTER_BEGIN---
SAZO_VERDICT_NONCE: $nonce
SAZO_VERDICT: $verdict
SAZO_BLOCKING_ISSUES: $issues
---SAZO_FOOTER_END---
EOF
}

# --- A: ok footer + valid nonce + APPROVE → record verdict ---
echo "Test A: valid footer + APPROVE → recorded"
SID="flow-1"
state_init "$SID" "$CWD" "test"
state_set_json "$SID" ".review_expected_set" '["code-reviewer","architect-advisor"]' "$CWD"
NONCE_CR=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "$NONCE_CR" "APPROVE")"

verdict=$(state_jq "$SID" '.last_verdicts.review["code-reviewer"].verdict' "$CWD")
assert_eq "APPROVE" "$verdict" "A.1 verdict recorded"

# Stage NOT yet completed (architect-advisor still missing)
last_stage=$(state_jq "$SID" '[.history[] | select(.stage=="review")] | last.status // "none"' "$CWD")
assert_eq "none" "$last_stage" "A.2 review stage not marked yet (waiting architect)"

# Now architect arrives
NONCE_AA=$(verdict_nonce_issue "$SID" "$CWD" "architect-advisor" "review")
process_verdict_tracked_post_task "$SID" "$CWD" "review" "architect-advisor" "$(mk_envelope "$NONCE_AA" "APPROVE")"

last_stage=$(state_jq "$SID" '[.history[] | select(.stage=="review")] | last.status // "none"' "$CWD")
assert_eq "completed" "$last_stage" "A.3 review stage marked completed after both APPROVE"

# --- B: BLOCK from one reviewer → stage NOT marked ---
echo "Test B: one BLOCK keeps stage incomplete"
SID="flow-2"
state_init "$SID" "$CWD" "test"
state_set_json "$SID" ".review_expected_set" '["code-reviewer","architect-advisor"]' "$CWD"
N1=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
N2=$(verdict_nonce_issue "$SID" "$CWD" "architect-advisor" "review")
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "$N1" "APPROVE")"
process_verdict_tracked_post_task "$SID" "$CWD" "review" "architect-advisor" "$(mk_envelope "$N2" "BLOCK" 3)"

stage_passed=$(state_jq "$SID" '[.history[] | select(.stage=="review" and .status=="completed")] | length' "$CWD")
assert_eq "0" "$stage_passed" "B.1 review NOT completed (one BLOCK)"

# --- C: replace-by-agent — first BLOCK then re-call APPROVE ---
echo "Test C: re-call same agent overwrites verdict"
SID="flow-3"
state_init "$SID" "$CWD" "test"
state_set_json "$SID" ".review_expected_set" '["code-reviewer"]' "$CWD"
N1=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "$N1" "BLOCK" 5)"
verdict_first=$(state_jq "$SID" '.last_verdicts.review["code-reviewer"].verdict' "$CWD")
assert_eq "BLOCK" "$verdict_first" "C.1 first BLOCK recorded"

# Re-issue + re-call with APPROVE
N2=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "$N2" "APPROVE")"
verdict_second=$(state_jq "$SID" '.last_verdicts.review["code-reviewer"].verdict' "$CWD")
assert_eq "APPROVE" "$verdict_second" "C.2 second APPROVE replaced BLOCK"

# Stage now marked
stage_passed=$(state_jq "$SID" '[.history[] | select(.stage=="review" and .status=="completed")] | length' "$CWD")
assert_eq "1" "$stage_passed" "C.3 review completed after replacement"

# --- D: missing footer + Phase 1 warn → legacy fallback ---
echo "Test D: missing footer Phase 1 warn → legacy mark"
SID="flow-4"
state_init "$SID" "$CWD" "test"
state_set_json "$SID" ".review_expected_set" '["code-reviewer"]' "$CWD"
unset SAZO_VERDICT_FOOTER_ENFORCE  # default warn
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "no footer here just prose"

stage_passed=$(state_jq "$SID" '[.history[] | select(.stage=="review" and .status=="completed")] | length' "$CWD")
assert_eq "1" "$stage_passed" "D.1 Phase 1: no footer → legacy stage_mark"

missing_count=$(state_jq "$SID" '.verdict_missing_count["code-reviewer"]' "$CWD")
assert_eq "1" "$missing_count" "D.2 verdict_missing_count incremented"

# --- E: missing footer + Phase 2 block → no stage_mark ---
echo "Test E: missing footer Phase 2 block → no mark"
SID="flow-5"
state_init "$SID" "$CWD" "test"
state_set_json "$SID" ".review_expected_set" '["code-reviewer"]' "$CWD"
SAZO_VERDICT_FOOTER_ENFORCE=block process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "no footer prose"

stage_passed=$(state_jq "$SID" '[.history[] | select(.stage=="review" and .status=="completed")] | length' "$CWD")
assert_eq "0" "$stage_passed" "E.1 Phase 2: no footer → no stage_mark"

missing_count=$(state_jq "$SID" '.verdict_missing_count["code-reviewer"]' "$CWD")
assert_eq "1" "$missing_count" "E.2 verdict_missing_count incremented"

# --- F: truncated envelope → always block ---
echo "Test F: truncated envelope blocks regardless of phase"
SID="flow-6"
state_init "$SID" "$CWD" "test"
state_set_json "$SID" ".review_expected_set" '["code-reviewer"]' "$CWD"
N=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
truncated="prose
---SAZO_FOOTER_BEGIN---
SAZO_VERDICT_NONCE: $N
SAZO_VERDICT: APPROVE
SAZO_BLOCKING_ISSUES: 0
"
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$truncated"
stage_passed=$(state_jq "$SID" '[.history[] | select(.stage=="review" and .status=="completed")] | length' "$CWD")
assert_eq "0" "$stage_passed" "F.1 truncated → no stage_mark even Phase 1"

# --- G: invalid nonce → reject ---
echo "Test G: invalid (unknown) nonce → reject"
SID="flow-7"
state_init "$SID" "$CWD" "test"
state_set_json "$SID" ".review_expected_set" '["code-reviewer"]' "$CWD"
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "00000000000000000000000000000000" "APPROVE")"

verdict_recorded=$(state_jq "$SID" '.last_verdicts.review["code-reviewer"] // null' "$CWD")
assert_eq "null" "$verdict_recorded" "G.1 invalid nonce → verdict NOT recorded"

# --- H: agent mismatch (nonce issued for code-reviewer, consumed by architect-advisor) ---
echo "Test H: nonce-agent binding mismatch"
SID="flow-8"
state_init "$SID" "$CWD" "test"
state_set_json "$SID" ".review_expected_set" '["architect-advisor"]' "$CWD"
N=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
# architect-advisor uses code-reviewer's nonce → reject
process_verdict_tracked_post_task "$SID" "$CWD" "review" "architect-advisor" "$(mk_envelope "$N" "APPROVE")"

verdict_recorded=$(state_jq "$SID" '.last_verdicts.review["architect-advisor"] // null' "$CWD")
assert_eq "null" "$verdict_recorded" "H.1 agent mismatch → verdict rejected"

# --- I: plan stage flow ---
echo "Test I: plan stage with critic + auditor"
SID="flow-9"
state_init "$SID" "$CWD" "test"
N_CRIT=$(verdict_nonce_issue "$SID" "$CWD" "plan-critic" "plan")
N_AUD=$(verdict_nonce_issue "$SID" "$CWD" "plan-auditor" "plan")
process_verdict_tracked_post_task "$SID" "$CWD" "plan" "plan-critic" "$(mk_envelope "$N_CRIT" "APPROVE")"
process_verdict_tracked_post_task "$SID" "$CWD" "plan" "plan-auditor" "$(mk_envelope "$N_AUD" "APPROVE")"

plan_passed=$(state_jq "$SID" '[.history[] | select(.stage=="plan" and .status=="completed")] | length' "$CWD")
assert_eq "1" "$plan_passed" "I.1 plan completed when critic + auditor both APPROVE"

# --- Summary ---
echo "─────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
