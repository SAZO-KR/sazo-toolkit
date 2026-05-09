#!/usr/bin/env bash
# Smoke test: _maybe_truncate_state (plan 01 slice 4)
# Cap state.json to 1MB. Preserve last 50 history + ci/approval completed.

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

assert_le() {
  local upper="$1" actual="$2" label="$3"
  if [ "$actual" -le "$upper" ]; then
    PASS=$((PASS+1))
    echo "  ✓ $label ($actual ≤ $upper)"
  else
    FAIL=$((FAIL+1))
    echo "  ✗ $label ($actual > $upper)"
  fi
}

state_jq() {
  local sid="$1" path="$2" cwd="$3"
  local sf; sf=$(state_file "$sid" "$cwd")
  jq -r "$path" "$sf"
}

SID="trunc-test-1"
CWD="/tmp/trunc-cwd"
state_init "$SID" "$CWD" "test"

# --- A: small state — no truncation ---
echo "Test A: state under 1MB → no truncation"
SF=$(state_file "$SID" "$CWD")
sz_before=$(wc -c <"$SF")
_maybe_truncate_state "$SID" "$CWD"
sz_after=$(wc -c <"$SF")
assert_eq "$sz_before" "$sz_after" "A.1 small state unchanged"

# --- B: synthetic 1.2MB state → truncate ---
echo "Test B: state over 1MB → truncate, history reduced"
# Build a large state.json directly to avoid arg-list-too-long
# Compose history: 5 ci + 300 noise (1MB+) + 5 approval
big_state="$SF.big"
jq -nc '
  [range(5) | {
    stage: "ci",
    status: "completed",
    by: "user",
    reason: "ci pass",
    ts: ("2026-05-09T01:00:0" + (. | tostring) + "Z")
  }]
  +
  [range(300) | {
    stage: "research",
    status: "completed",
    by: "auto",
    reason: ("noise " * 1000 + (. | tostring)),
    ts: ("2026-05-09T00:" + (if . < 10 then "0" + (. | tostring) else (. | tostring) end) + ":00Z")
  }]
  +
  [range(5) | {
    stage: "approval",
    status: "completed",
    by: "user",
    reason: "approved",
    ts: ("2026-05-09T02:00:0" + (. | tostring) + "Z")
  }]
' > "$SF.history"

# Read original state, replace .history field via jq using --slurpfile
jq --slurpfile h "$SF.history" '.history = $h[0]' "$SF" > "$SF.new"
mv "$SF.new" "$SF"
rm -f "$SF.history"

sz_before=$(wc -c <"$SF")
echo "  state size before: $sz_before bytes"

_maybe_truncate_state "$SID" "$CWD"

sz_after=$(wc -c <"$SF")
echo "  state size after:  $sz_after bytes"

# Hard precondition: padding MUST exceed 1MB to exercise truncation path
if [ "$sz_before" -le 1048576 ]; then
  echo "  ✗ B.0 PRECONDITION: padding insufficient ($sz_before <= 1MB) — increase noise multiplier"
  FAIL=$((FAIL+1))
else
  PASS=$((PASS+1))
  echo "  ✓ B.0 precondition: state exceeds 1MB ($sz_before bytes)"
  assert_le 1500000 "$sz_after" "B.1 truncated below 1.5MB (with safety margin)"
fi

# Critical: ci entries preserved
ci_count=$(state_jq "$SID" '[.history[] | select(.stage=="ci" and .status=="completed")] | length' "$CWD")
assert_eq "5" "$ci_count" "B.2 all 5 ci completed entries preserved"

# Critical: approval entries preserved
approval_count=$(state_jq "$SID" '[.history[] | select(.stage=="approval" and .status=="completed")] | length' "$CWD")
assert_eq "5" "$approval_count" "B.3 all 5 approval completed entries preserved"

# History sorted by ts (after dedup)
ts_sorted=$(state_jq "$SID" '.history | sort_by(.ts) == .' "$CWD")
assert_eq "true" "$ts_sorted" "B.4 history sorted by ts"

# --- C: user-skipped ci entries preserved ---
echo "Test C: user-skipped ci entries preserved (stage_is_passed dependency)"
SID="trunc-test-2"
state_init "$SID" "$CWD" "test"
SF=$(state_file "$SID" "$CWD")

# 5 ci skipped(by=user) + 300 noise + 5 approval skipped(by=user)
jq -nc '
  [range(3) | {
    stage: "ci",
    status: "skipped",
    by: "user",
    reason: "ci skip authorized",
    ts: ("2026-05-09T01:00:0" + (. | tostring) + "Z")
  }]
  +
  [range(300) | {
    stage: "research",
    status: "completed",
    by: "auto",
    reason: ("noise " * 1000 + (. | tostring)),
    ts: ("2026-05-09T00:" + (if . < 10 then "0" + (. | tostring) else (. | tostring) end) + ":00Z")
  }]
  +
  [range(2) | {
    stage: "approval",
    status: "skipped",
    by: "user",
    reason: "approval bypass",
    ts: ("2026-05-09T02:00:0" + (. | tostring) + "Z")
  }]
' > "$SF.history"
jq --slurpfile h "$SF.history" '.history = $h[0]' "$SF" > "$SF.new"
mv "$SF.new" "$SF"
rm -f "$SF.history"

_maybe_truncate_state "$SID" "$CWD"

ci_skip=$(state_jq "$SID" '[.history[] | select(.stage=="ci" and .status=="skipped" and .by=="user")] | length' "$CWD")
assert_eq "3" "$ci_skip" "C.1 user-skipped ci entries preserved"

approval_skip=$(state_jq "$SID" '[.history[] | select(.stage=="approval" and .status=="skipped" and .by=="user")] | length' "$CWD")
assert_eq "2" "$approval_skip" "C.2 user-skipped approval entries preserved"

# --- D: auto-skipped entries NOT preserved (only user-skipped + completed) ---
echo "Test D: auto-skipped entries NOT preserved (only user-skipped/completed survive)"
SID="trunc-test-3"
state_init "$SID" "$CWD" "test"
SF=$(state_file "$SID" "$CWD")

# 5 ci skipped(by=auto) + 300 noise — auto-skip should NOT be preserved
# (only user-authorized skip counts toward stage_is_passed)
jq -nc '
  [range(5) | {
    stage: "ci",
    status: "skipped",
    by: "auto",
    reason: "auto-skip",
    ts: ("2026-05-09T01:00:0" + (. | tostring) + "Z")
  }]
  +
  [range(300) | {
    stage: "research",
    status: "completed",
    by: "auto",
    reason: ("noise " * 1000 + (. | tostring)),
    ts: ("2026-05-09T00:" + (if . < 10 then "0" + (. | tostring) else (. | tostring) end) + ":00Z")
  }]
' > "$SF.history"
jq --slurpfile h "$SF.history" '.history = $h[0]' "$SF" > "$SF.new"
mv "$SF.new" "$SF"
rm -f "$SF.history"

sz_before=$(wc -c <"$SF")
_maybe_truncate_state "$SID" "$CWD"

# auto-skipped ci entries that fall outside last-50 window are dropped
total_history=$(state_jq "$SID" '.history | length' "$CWD")
# Should be ~50 (only the last-50 window, since auto-skip doesn't qualify for preservation)
if [ "$total_history" -le 60 ]; then
  PASS=$((PASS+1))
  echo "  ✓ D.1 auto-skip entries dropped beyond last-50 window (total=$total_history)"
else
  FAIL=$((FAIL+1))
  echo "  ✗ D.1 too many entries kept (total=$total_history); auto-skip should not be preserved"
fi

# --- E: review/plan user-skipped + completed entries preserved ---
echo "Test E: review/plan completed and user-skipped entries preserved"
SID="trunc-test-4"
state_init "$SID" "$CWD" "test"
SF=$(state_file "$SID" "$CWD")

jq -nc '
  [{
    stage: "review", status: "completed", by: "auto",
    reason: "verdict aggregation: all APPROVE",
    ts: "2026-05-09T01:00:00Z"
  }] +
  [{
    stage: "review", status: "skipped", by: "user",
    reason: "docs only PR",
    ts: "2026-05-09T01:00:01Z"
  }] +
  [{
    stage: "plan", status: "completed", by: "auto",
    reason: "verdict aggregation: all APPROVE",
    ts: "2026-05-09T01:00:02Z"
  }] +
  [range(300) | {
    stage: "research",
    status: "completed",
    by: "auto",
    reason: ("noise " * 1000 + (. | tostring)),
    ts: ("2026-05-09T00:" + (if . < 10 then "0" + (. | tostring) else (. | tostring) end) + ":00Z")
  }]
' > "$SF.history"
jq --slurpfile h "$SF.history" '.history = $h[0]' "$SF" > "$SF.new"
mv "$SF.new" "$SF"
rm -f "$SF.history"

_maybe_truncate_state "$SID" "$CWD"

review_completed=$(state_jq "$SID" '[.history[] | select(.stage=="review" and .status=="completed")] | length' "$CWD")
assert_eq "1" "$review_completed" "E.1 review completed entry preserved"

review_user_skip=$(state_jq "$SID" '[.history[] | select(.stage=="review" and .status=="skipped" and .by=="user")] | length' "$CWD")
assert_eq "1" "$review_user_skip" "E.2 review user-skip entry preserved"

plan_completed=$(state_jq "$SID" '[.history[] | select(.stage=="plan" and .status=="completed")] | length' "$CWD")
assert_eq "1" "$plan_completed" "E.3 plan completed entry preserved"

# --- Summary ---
echo "─────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
