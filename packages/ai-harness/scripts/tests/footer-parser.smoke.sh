#!/usr/bin/env bash
# Smoke test: parse_verdict_footer (plan 01 slice 1)
# TDD RED → GREEN. Tests envelope marker extraction, multi-envelope, truncated, missing, malformed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../hooks/lib/session-state.sh"

if [ ! -f "$LIB" ]; then
  echo "FAIL: $LIB not found" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$LIB"

PASS=0
FAIL=0

assert_kv() {
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

extract() {
  # parse_verdict_footer output is "STATUS=...\nNONCE=...\nVERDICT=...\nISSUES=..."
  # Extract one key
  local key="$1" output="$2"
  printf '%s\n' "$output" | awk -F= -v k="$key" '$1==k{print $2; exit}'
}

# --- Test 1: multi-envelope (JSONL leak) — only last extracted ---
echo "Test 1: multi-envelope JSONL leak — last envelope only"
input1=$(cat <<'EOF'
some reasoning text
---SAZO_FOOTER_BEGIN---
SAZO_VERDICT_NONCE: aaaa1111aaaa1111aaaa1111aaaa1111
SAZO_VERDICT: BLOCK
SAZO_BLOCKING_ISSUES: 5
---SAZO_FOOTER_END---
more text from transcript leak
---SAZO_FOOTER_BEGIN---
SAZO_VERDICT_NONCE: bbbb2222bbbb2222bbbb2222bbbb2222
SAZO_VERDICT: APPROVE
SAZO_BLOCKING_ISSUES: 0
---SAZO_FOOTER_END---
EOF
)
out1=$(parse_verdict_footer "$input1")
assert_kv "ok" "$(extract STATUS "$out1")" "1.1 status=ok"
assert_kv "bbbb2222bbbb2222bbbb2222bbbb2222" "$(extract NONCE "$out1")" "1.2 last nonce extracted"
assert_kv "APPROVE" "$(extract VERDICT "$out1")" "1.3 last verdict (APPROVE not BLOCK)"
assert_kv "0" "$(extract ISSUES "$out1")" "1.4 last issues=0"

# --- Test 2: truncated (BEGIN, no END) ---
echo "Test 2: truncated envelope (BEGIN without END)"
input2=$(cat <<'EOF'
preamble
---SAZO_FOOTER_BEGIN---
SAZO_VERDICT_NONCE: cccc3333cccc3333cccc3333cccc3333
SAZO_VERDICT: APPROVE
SAZO_BLOCKING_ISSUES: 0
EOF
)
out2=$(parse_verdict_footer "$input2")
assert_kv "truncated" "$(extract STATUS "$out2")" "2.1 status=truncated"

# --- Test 3: missing (no marker at all) ---
echo "Test 3: no envelope markers"
input3="just regular reviewer prose without footer"
out3=$(parse_verdict_footer "$input3")
assert_kv "missing" "$(extract STATUS "$out3")" "3.1 status=missing"

# --- Test 4: single valid envelope ---
echo "Test 4: single valid envelope"
input4=$(cat <<'EOF'
review body here
---SAZO_FOOTER_BEGIN---
SAZO_VERDICT_NONCE: dddd4444dddd4444dddd4444dddd4444
SAZO_VERDICT: NEEDS_REVISION
SAZO_BLOCKING_ISSUES: 2
---SAZO_FOOTER_END---
EOF
)
out4=$(parse_verdict_footer "$input4")
assert_kv "ok" "$(extract STATUS "$out4")" "4.1 status=ok"
assert_kv "dddd4444dddd4444dddd4444dddd4444" "$(extract NONCE "$out4")" "4.2 nonce"
assert_kv "NEEDS_REVISION" "$(extract VERDICT "$out4")" "4.3 verdict"
assert_kv "2" "$(extract ISSUES "$out4")" "4.4 issues"

# --- Test 5: malformed (missing nonce inside envelope) ---
echo "Test 5: envelope present but missing nonce field"
input5=$(cat <<'EOF'
---SAZO_FOOTER_BEGIN---
SAZO_VERDICT: APPROVE
SAZO_BLOCKING_ISSUES: 0
---SAZO_FOOTER_END---
EOF
)
out5=$(parse_verdict_footer "$input5")
assert_kv "truncated" "$(extract STATUS "$out5")" "5.1 status=truncated (missing nonce)"

# --- Test 6: malformed (missing verdict field) ---
echo "Test 6: envelope present but missing verdict field"
input6=$(cat <<'EOF'
---SAZO_FOOTER_BEGIN---
SAZO_VERDICT_NONCE: eeee5555eeee5555eeee5555eeee5555
SAZO_BLOCKING_ISSUES: 1
---SAZO_FOOTER_END---
EOF
)
out6=$(parse_verdict_footer "$input6")
assert_kv "truncated" "$(extract STATUS "$out6")" "6.1 status=truncated (missing verdict)"

# --- Test 7: extra whitespace inside envelope (should still parse) ---
echo "Test 7: extra blank lines inside envelope"
input7=$(cat <<'EOF'
---SAZO_FOOTER_BEGIN---

SAZO_VERDICT_NONCE: ffff6666ffff6666ffff6666ffff6666

SAZO_VERDICT: APPROVE

SAZO_BLOCKING_ISSUES: 0

---SAZO_FOOTER_END---
EOF
)
out7=$(parse_verdict_footer "$input7")
assert_kv "ok" "$(extract STATUS "$out7")" "7.1 status=ok with blank lines"
assert_kv "ffff6666ffff6666ffff6666ffff6666" "$(extract NONCE "$out7")" "7.2 nonce"

# --- Test 8: invalid verdict value ---
echo "Test 8: SAZO_VERDICT with invalid value"
input8=$(cat <<'EOF'
---SAZO_FOOTER_BEGIN---
SAZO_VERDICT_NONCE: 1111aaaa1111aaaa1111aaaa1111aaaa
SAZO_VERDICT: MAYBE
SAZO_BLOCKING_ISSUES: 0
---SAZO_FOOTER_END---
EOF
)
out8=$(parse_verdict_footer "$input8")
# Invalid verdict → treated as missing (regex won't match)
assert_kv "truncated" "$(extract STATUS "$out8")" "8.1 invalid verdict → truncated"

# --- Test 9: invalid nonce format (not 32 hex chars) ---
echo "Test 9: SAZO_VERDICT_NONCE with bad format"
input9=$(cat <<'EOF'
---SAZO_FOOTER_BEGIN---
SAZO_VERDICT_NONCE: not-a-valid-nonce
SAZO_VERDICT: APPROVE
SAZO_BLOCKING_ISSUES: 0
---SAZO_FOOTER_END---
EOF
)
out9=$(parse_verdict_footer "$input9")
assert_kv "truncated" "$(extract STATUS "$out9")" "9.1 invalid nonce → truncated"

# --- Test 10: empty input ---
echo "Test 10: empty input"
out10=$(parse_verdict_footer "")
assert_kv "missing" "$(extract STATUS "$out10")" "10.1 empty input → missing"

# --- Summary ---
echo "─────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
