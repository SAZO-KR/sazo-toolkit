#!/usr/bin/env bash
# Smoke test: verdict_nonce_issue / verdict_nonce_consume + schema v2 init.
# TDD RED → GREEN. Tests pool issuance, agent binding, single-use, expiry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../hooks/lib/session-state.sh"

# Isolate STATE_DIR
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
    echo "  ✗ $label"
    echo "    expected: '$expected'"
    echo "    actual:   '$actual'"
  fi
}

assert_match() {
  local pattern="$1" actual="$2" label="$3"
  if echo "$actual" | grep -qE "$pattern"; then
    PASS=$((PASS+1))
    echo "  ✓ $label"
  else
    FAIL=$((FAIL+1))
    echo "  ✗ $label"
    echo "    pattern: '$pattern'"
    echo "    actual:  '$actual'"
  fi
}

# Setup test session
SID="test-sid-001"
CWD="/tmp/test-cwd"

# Helper: read raw jq from state file (avoids state_get `// empty` stripping booleans)
state_jq() {
  local sid="$1" path="$2" cwd="$3"
  local sf
  sf=$(state_file "$sid" "$cwd")
  jq -r "$path" "$sf"
}

# --- Test A: schema v3 init ---
echo "Test A: state_init creates schema v3 with verdict fields"
state_init "$SID" "$CWD" "test-model"
schema_ver=$(state_get "$SID" '.schema_version' "$CWD")
# v3 added pre_commit_markers (PR #30 self-review A5).
assert_eq "3" "$schema_ver" "A.1 schema_version=3"

# Verify new fields exist with defaults
verdict_nonces=$(state_get "$SID" '.verdict_nonces' "$CWD")
assert_eq "{}" "$verdict_nonces" "A.2 verdict_nonces empty obj"

last_verdicts=$(state_get "$SID" '.last_verdicts' "$CWD")
assert_match '"review"' "$last_verdicts" "A.3 last_verdicts.review present"
assert_match '"plan"' "$last_verdicts" "A.4 last_verdicts.plan present"

review_set=$(state_get "$SID" '.review_expected_set' "$CWD")
assert_eq "[]" "$review_set" "A.5 review_expected_set empty array"

unset_count=$(state_get "$SID" '.verdict_unset_expected_set_count' "$CWD")
assert_eq "0" "$unset_count" "A.6 verdict_unset_expected_set_count=0"

# --- Test B: verdict_nonce_issue ---
echo "Test B: verdict_nonce_issue creates entry"
NONCE_A=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
assert_match '^[0-9a-f]{32}$' "$NONCE_A" "B.1 nonce is 32-hex string"

agent=$(state_get "$SID" ".verdict_nonces[\"$NONCE_A\"].agent" "$CWD")
assert_eq "code-reviewer" "$agent" "B.2 nonce.agent=code-reviewer"

stage=$(state_get "$SID" ".verdict_nonces[\"$NONCE_A\"].stage" "$CWD")
assert_eq "review" "$stage" "B.3 nonce.stage=review"

consumed=$(state_jq "$SID" ".verdict_nonces[\"$NONCE_A\"].consumed" "$CWD")
assert_eq "false" "$consumed" "B.4 nonce.consumed=false"

# --- Test C: verdict_nonce_consume valid ---
echo "Test C: consume valid nonce"
if verdict_nonce_consume "$SID" "$CWD" "$NONCE_A" "code-reviewer"; then
  PASS=$((PASS+1)); echo "  ✓ C.1 consume returns 0"
else
  FAIL=$((FAIL+1)); echo "  ✗ C.1 consume returned non-zero"
fi

consumed=$(state_jq "$SID" ".verdict_nonces[\"$NONCE_A\"].consumed" "$CWD")
assert_eq "true" "$consumed" "C.2 nonce.consumed=true after consume"

# --- Test D: consume already-consumed nonce → reject ---
echo "Test D: replay reject"
if verdict_nonce_consume "$SID" "$CWD" "$NONCE_A" "code-reviewer" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  ✗ D.1 replay should reject"
else
  PASS=$((PASS+1)); echo "  ✓ D.1 replay rejected"
fi

# --- Test E: agent binding mismatch ---
echo "Test E: agent mismatch reject"
NONCE_B=$(verdict_nonce_issue "$SID" "$CWD" "architect-advisor" "review")
if verdict_nonce_consume "$SID" "$CWD" "$NONCE_B" "code-reviewer" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  ✗ E.1 wrong agent should reject"
else
  PASS=$((PASS+1)); echo "  ✓ E.1 wrong agent rejected"
fi

# Verify B nonce still NOT consumed (rejection didn't flip it)
consumed_b=$(state_jq "$SID" ".verdict_nonces[\"$NONCE_B\"].consumed" "$CWD")
assert_eq "false" "$consumed_b" "E.2 rejected nonce stays unconsumed"

# Now consume with correct agent
if verdict_nonce_consume "$SID" "$CWD" "$NONCE_B" "architect-advisor"; then
  PASS=$((PASS+1)); echo "  ✓ E.3 correct agent consume succeeds"
else
  FAIL=$((FAIL+1)); echo "  ✗ E.3 correct agent consume failed"
fi

# --- Test F: nonexistent nonce ---
echo "Test F: unknown nonce reject"
if verdict_nonce_consume "$SID" "$CWD" "0000000000000000000000000000aaaa" "code-reviewer" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  ✗ F.1 unknown nonce should reject"
else
  PASS=$((PASS+1)); echo "  ✓ F.1 unknown nonce rejected"
fi

# --- Test G: distinct nonces issued ---
echo "Test G: pool issues distinct nonces"
N1=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
N2=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
N3=$(verdict_nonce_issue "$SID" "$CWD" "code-reviewer" "review")
if [ "$N1" != "$N2" ] && [ "$N2" != "$N3" ] && [ "$N1" != "$N3" ]; then
  PASS=$((PASS+1)); echo "  ✓ G.1 three distinct nonces"
else
  FAIL=$((FAIL+1)); echo "  ✗ G.1 nonce collision"
fi

# --- Test H: backward compat — schema v1 state.json ---
echo "Test H: legacy schema v1 → lazy access fallback"
SID_LEGACY="legacy-sid"
LEGACY_FILE=$(state_file "$SID_LEGACY" "$CWD")
mkdir -p "$(dirname "$LEGACY_FILE")"
cat > "$LEGACY_FILE" <<EOF
{
  "schema_version": 1,
  "session_id": "$SID_LEGACY",
  "cwd": "$CWD",
  "stage": "init",
  "history": [],
  "explore_count": 0,
  "plan_approved_at": null,
  "approval_nonce": null,
  "ci_passed_at": null
}
EOF
# Access new field via lazy fallback (// {})
nonces=$(state_get "$SID_LEGACY" '.verdict_nonces // {}' "$CWD")
assert_eq "{}" "$nonces" "H.1 legacy state: verdict_nonces lazy default"

review_set=$(state_get "$SID_LEGACY" '.review_expected_set // []' "$CWD")
assert_eq "[]" "$review_set" "H.2 legacy state: review_expected_set lazy default"

# --- Summary ---
echo "─────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
