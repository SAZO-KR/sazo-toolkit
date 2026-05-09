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

# Verify stage_is_passed (synthetic APPROVE coexists with cycle gate)
if stage_is_passed "$SID" "review" "$CWD"; then
  PASS=$((PASS+1)); echo "  ✓ D.3 stage_is_passed true via synthetic phase1_fallback"
else
  FAIL=$((FAIL+1)); echo "  ✗ D.3 stage_is_passed should be true"
fi

# --- D2: Phase 1 fallback REJECTED when aggregation cycle active ---
echo "Test D2: Phase 1 fallback rejected during active aggregation cycle"
SID="flow-D2"
state_init "$SID" "$CWD" "test"
verdict_cycle_init "$SID" "$CWD" "review" '["code-reviewer","architect-advisor"]'

# code-reviewer with footer (real APPROVE)
N1=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "$N1" "APPROVE")"

# architect-advisor WITHOUT footer (Phase 1 warn fallback)
unset SAZO_VERDICT_FOOTER_ENFORCE
process_verdict_tracked_post_task "$SID" "$CWD" "review" "architect-advisor" "no footer prose"

# Cycle active → fallback should NOT write synthetic APPROVE.
# Stage stays incomplete (architect-advisor never properly responded).
recorded=$(state_jq "$SID" '.last_verdicts.review["architect-advisor"] // null' "$CWD")
assert_eq "null" "$recorded" "D2.1 cycle active: synthetic APPROVE NOT written"

if stage_is_passed "$SID" "review" "$CWD"; then
  FAIL=$((FAIL+1)); echo "  ✗ D2.2 stage should NOT pass (architect-advisor missing)"
else
  PASS=$((PASS+1)); echo "  ✓ D2.2 stage stays incomplete — fallback cycle-scoped"
fi

# verdict_missing_count still incremented (warn signal preserved)
miss_count=$(state_jq "$SID" '.verdict_missing_count["architect-advisor"]' "$CWD")
assert_eq "1" "$miss_count" "D2.3 verdict_missing_count incremented (warn signal)"

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

# --- M: verdict_cycle_init clears stale verdicts ---
echo "Test M: verdict_cycle_init resets stale verdicts (cycle isolation)"
SID="flow-M"
state_init "$SID" "$CWD" "test"

# Round 1: both APPROVE → stage passed
verdict_cycle_init "$SID" "$CWD" "review" '["code-reviewer","architect-advisor"]'
N1=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
N2=$(verdict_nonce_issue "$SID" "$CWD" "architect-advisor" "review")
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "$N1" "APPROVE")"
process_verdict_tracked_post_task "$SID" "$CWD" "review" "architect-advisor" "$(mk_envelope "$N2" "APPROVE")"

if stage_is_passed "$SID" "review" "$CWD"; then
  PASS=$((PASS+1)); echo "  ✓ M.1 round 1: stage passed"
else
  FAIL=$((FAIL+1)); echo "  ✗ M.1 round 1 should pass"
fi

# Round 2: code change → re-init cycle. Stale verdicts must be cleared.
verdict_cycle_init "$SID" "$CWD" "review" '["code-reviewer","architect-advisor"]'

# After init, last_verdicts.review should be empty
last_v_count=$(state_jq "$SID" '.last_verdicts.review | length' "$CWD")
assert_eq "0" "$last_v_count" "M.2 cycle_init clears last_verdicts.review"

# Only code-reviewer arrives in round 2 (architect-advisor still pending)
N3=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "$N3" "APPROVE")"

# Stage should NOT be passed yet — architect-advisor missing
# (without verdict_cycle_init, the stale architect-advisor APPROVE
# would combine with new code-reviewer APPROVE and pass prematurely)
if stage_is_passed "$SID" "review" "$CWD"; then
  FAIL=$((FAIL+1)); echo "  ✗ M.3 stage should NOT pass (architect-advisor pending after re-init)"
else
  PASS=$((PASS+1)); echo "  ✓ M.3 stale verdicts cleared — gate awaits fresh architect-advisor"
fi

# Now architect-advisor responds
N4=$(verdict_nonce_issue "$SID" "$CWD" "architect-advisor" "review")
process_verdict_tracked_post_task "$SID" "$CWD" "review" "architect-advisor" "$(mk_envelope "$N4" "APPROVE")"

if stage_is_passed "$SID" "review" "$CWD"; then
  PASS=$((PASS+1)); echo "  ✓ M.4 stage passes after fresh APPROVE pair"
else
  FAIL=$((FAIL+1)); echo "  ✗ M.4 stage should pass with fresh pair"
fi

# --- K: stage_is_passed invalidation — APPROVE → BLOCK downgrade ---
echo "Test K: verdict downgrade invalidates passed stage"
SID="flow-K"
state_init "$SID" "$CWD" "test"
state_set_json "$SID" ".review_expected_set" '["code-reviewer","architect-advisor"]' "$CWD"
N1=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
N2=$(verdict_nonce_issue "$SID" "$CWD" "architect-advisor" "review")
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "$N1" "APPROVE")"
process_verdict_tracked_post_task "$SID" "$CWD" "review" "architect-advisor" "$(mk_envelope "$N2" "APPROVE")"

# Stage should be passed
if stage_is_passed "$SID" "review" "$CWD"; then
  PASS=$((PASS+1)); echo "  ✓ K.1 stage passed after both APPROVE"
else
  FAIL=$((FAIL+1)); echo "  ✗ K.1 stage should be passed"
fi

# Re-issue + downgrade code-reviewer to BLOCK
N3=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "$N3" "BLOCK" 5)"

# Stage should now be NOT passed (despite history "completed")
if stage_is_passed "$SID" "review" "$CWD"; then
  FAIL=$((FAIL+1)); echo "  ✗ K.2 stage should be invalidated after BLOCK downgrade"
else
  PASS=$((PASS+1)); echo "  ✓ K.2 stage invalidated by BLOCK downgrade"
fi

# Re-approve and verify stage passes again
N4=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "$N4" "APPROVE")"
if stage_is_passed "$SID" "review" "$CWD"; then
  PASS=$((PASS+1)); echo "  ✓ K.3 stage re-passed after BLOCK → APPROVE"
else
  FAIL=$((FAIL+1)); echo "  ✗ K.3 stage should pass again"
fi

# --- L: legacy fallback — history-only when last_verdicts empty ---
echo "Test L: legacy phase 1 fallback (no last_verdicts entries)"
SID="flow-L"
state_init "$SID" "$CWD" "test"
# Manually mark stage completed (simulating Phase 1 missing footer fallback)
stage_mark "$SID" "review" "completed" "auto" "Phase 1 fallback" "$CWD"

# No last_verdicts yet — stage_is_passed should return true (vacuous truth)
if stage_is_passed "$SID" "review" "$CWD"; then
  PASS=$((PASS+1)); echo "  ✓ L.1 legacy fallback: history entry alone passes"
else
  FAIL=$((FAIL+1)); echo "  ✗ L.1 legacy fallback should pass"
fi

# --- Q: same-second cycle restart rejects via cycle_id ---
echo "Test Q: cycle_id rejects same-second stale nonce (timestamp precision bypass)"
SID="flow-Q"
state_init "$SID" "$CWD" "test"

# Cycle 1: issue + cycle 2 init within same second (no sleep)
verdict_cycle_init "$SID" "$CWD" "review" '["code-reviewer"]'
N_OLD=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")

verdict_cycle_init "$SID" "$CWD" "review" '["code-reviewer"]'

# Late nonce arrival from cycle 1 — must be rejected via cycle_id mismatch
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "$N_OLD" "APPROVE")"

verdict_recorded=$(state_jq "$SID" '.last_verdicts.review["code-reviewer"] // null' "$CWD")
assert_eq "null" "$verdict_recorded" "Q.1 same-second stale-cycle nonce rejected via cycle_id"

# --- P: stale-cycle nonce rejected after cycle_init ---
echo "Test P: nonce issued in prior cycle rejected after cycle_init"
SID="flow-P"
state_init "$SID" "$CWD" "test"

# Cycle 1: issue nonce but DON'T consume yet (simulating in-flight Task)
verdict_cycle_init "$SID" "$CWD" "review" '["code-reviewer","architect-advisor"]'
N_OLD=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")

# Sleep so cycle 2 has newer cycle_at
sleep 1

# Cycle 2: cycle_init fires (e.g., user reset for fresh review)
verdict_cycle_init "$SID" "$CWD" "review" '["code-reviewer","architect-advisor"]'

# Late response from cycle 1 arrives — should be rejected
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "$N_OLD" "APPROVE")"

verdict_recorded=$(state_jq "$SID" '.last_verdicts.review["code-reviewer"] // null' "$CWD")
assert_eq "null" "$verdict_recorded" "P.1 stale-cycle nonce rejected — verdict NOT recorded in fresh cycle"

# Fresh nonce in cycle 2 should still work
N_FRESH=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "$N_FRESH" "APPROVE")"
fresh_verdict=$(state_jq "$SID" '.last_verdicts.review["code-reviewer"].verdict // "none"' "$CWD")
assert_eq "APPROVE" "$fresh_verdict" "P.2 fresh-cycle nonce accepted"

# --- O: cycle_init invalidates prior cycle's stale completion ---
echo "Test O: cycle_init prevents stale completion from passing fresh cycle"
SID="flow-O"
state_init "$SID" "$CWD" "test"

# Round 1: complete cycle
verdict_cycle_init "$SID" "$CWD" "review" '["code-reviewer","architect-advisor"]'
N1=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
N2=$(verdict_nonce_issue "$SID" "$CWD" "architect-advisor" "review")
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "$N1" "APPROVE")"
process_verdict_tracked_post_task "$SID" "$CWD" "review" "architect-advisor" "$(mk_envelope "$N2" "APPROVE")"

if stage_is_passed "$SID" "review" "$CWD"; then
  PASS=$((PASS+1)); echo "  ✓ O.1 round 1: stage passed"
else
  FAIL=$((FAIL+1)); echo "  ✗ O.1 round 1 should pass"
fi

# Sleep to ensure timestamp difference (BSD/GNU date second precision)
sleep 1

# Round 2: cycle_init only — no fresh verdicts yet
verdict_cycle_init "$SID" "$CWD" "review" '["code-reviewer","architect-advisor"]'

# Stage should NOT pass — even though history has "completed" from round 1,
# cycle_at is now newer than that entry → fresh cycle pending
if stage_is_passed "$SID" "review" "$CWD"; then
  FAIL=$((FAIL+1)); echo "  ✗ O.2 stage should NOT pass (fresh cycle pending)"
else
  PASS=$((PASS+1)); echo "  ✓ O.2 fresh cycle blocks stale completion"
fi

# --- N: user /skip overrides BLOCK verdict ---
echo "Test N: user-skip overrides blocking verdicts"
SID="flow-N"
state_init "$SID" "$CWD" "test"
verdict_cycle_init "$SID" "$CWD" "review" '["code-reviewer","architect-advisor"]'

# Both reviewers respond, one BLOCK
N1=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
N2=$(verdict_nonce_issue "$SID" "$CWD" "architect-advisor" "review")
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "$N1" "BLOCK" 3)"
process_verdict_tracked_post_task "$SID" "$CWD" "review" "architect-advisor" "$(mk_envelope "$N2" "APPROVE")"

# Stage NOT passed yet (BLOCK present)
if stage_is_passed "$SID" "review" "$CWD"; then
  FAIL=$((FAIL+1)); echo "  ✗ N.1 stage should NOT pass with BLOCK"
else
  PASS=$((PASS+1)); echo "  ✓ N.1 stage NOT passed (BLOCK present)"
fi

# Sleep to ensure timestamp progression (date precision = 1 second)
# In real workflow: user types /skip after a delay so this is realistic.
sleep 1

# User explicitly /skip review (simulated)
stage_mark "$SID" "review" "skipped" "user" "user override after BLOCK" "$CWD"

# Stage now passes via user override
if stage_is_passed "$SID" "review" "$CWD"; then
  PASS=$((PASS+1)); echo "  ✓ N.2 user skip overrides BLOCK"
else
  FAIL=$((FAIL+1)); echo "  ✗ N.2 user skip should pass"
fi

# Auto skip should NOT override (only user)
SID="flow-N2"
state_init "$SID" "$CWD" "test"
verdict_cycle_init "$SID" "$CWD" "review" '["code-reviewer"]'
N=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
process_verdict_tracked_post_task "$SID" "$CWD" "review" "code-reviewer" "$(mk_envelope "$N" "BLOCK" 1)"
stage_mark "$SID" "review" "skipped" "auto" "auto skip" "$CWD"

if stage_is_passed "$SID" "review" "$CWD"; then
  FAIL=$((FAIL+1)); echo "  ✗ N.3 auto skip should NOT override BLOCK"
else
  PASS=$((PASS+1)); echo "  ✓ N.3 auto skip does NOT override BLOCK"
fi

# --- J: unknown agent rejected by allowlist (defense-in-depth) ---
echo "Test J: unknown agent name → allowlist reject"
SID="flow-10"
state_init "$SID" "$CWD" "test"
# Inject an unknown agent — process_verdict_tracked_post_task should
# silently audit + return without touching state.
process_verdict_tracked_post_task "$SID" "$CWD" "review" "evil-agent\$(id)" "any text"

# Verify no last_verdicts entry created
verdict_recorded=$(state_jq "$SID" '.last_verdicts.review // {} | length' "$CWD")
assert_eq "0" "$verdict_recorded" "J.1 unknown agent → no verdict stored"

# --- Summary ---
echo "─────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
