#!/usr/bin/env bash
# Smoke test: slash-commands.sh lib (Plan 13 Stage A0b)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SLASH_LIB="$SCRIPT_DIR/../hooks/lib/slash-commands.sh"

# shellcheck source=/dev/null
source "$SLASH_LIB"

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

assert_true() {
    local label="$1"
    shift
    if "$@" 2>/dev/null; then
        PASS=$((PASS+1))
        echo "  ✓ $label"
    else
        FAIL=$((FAIL+1))
        echo "  ✗ $label (expected true)"
    fi
}

assert_false() {
    local label="$1"
    shift
    if "$@" 2>/dev/null; then
        FAIL=$((FAIL+1))
        echo "  ✗ $label (expected false)"
    else
        PASS=$((PASS+1))
        echo "  ✓ $label"
    fi
}

# --- TS1: trim_leading with leading spaces ---
echo "Test TS1: trim_leading with leading spaces"
result=$(trim_leading "  /skip foo")
assert_eq "/skip foo" "$result" "TS1.1 trim_leading '  /skip foo' → '/skip foo'"

# --- TS2: trim_leading with tab ---
echo "Test TS2: trim_leading with leading tab"
result=$(trim_leading "$(printf '\t')/skip")
assert_eq "/skip" "$result" "TS2.1 trim_leading TAB+/skip → '/skip'"

# --- TS3: trim_leading with empty string ---
echo "Test TS3: trim_leading empty string"
result=$(trim_leading "")
assert_eq "" "$result" "TS3.1 trim_leading '' → ''"

# --- TS4: bash version check + trim_leading behavior consistency ---
echo "Test TS4: bash version + trim_leading behavior"
bash_ver=$(bash --version 2>&1 | head -1)
if printf '%s' "$bash_ver" | grep -q '^GNU bash, version 3\.2'; then
    echo "  (bash 3.2 detected — verifying sed path works)"
    result=$(trim_leading "   /approved")
    assert_eq "/approved" "$result" "TS4.1 bash 3.2: trim_leading with multiple spaces"
else
    echo "  (bash version: $bash_ver — trim_leading still uses sed path)"
    result=$(trim_leading "   /approved")
    assert_eq "/approved" "$result" "TS4.1 trim_leading with multiple spaces"
fi

# --- is_known_slash tests ---
echo "Test TS5: is_known_slash"
assert_true "TS5.1 /approved is known" is_known_slash "/approved"
assert_true "TS5.2 /skip is known" is_known_slash "/skip"
assert_false "TS5.3 /unknown is not known" is_known_slash "/unknown"
assert_false "TS5.4 empty string not known" is_known_slash ""
assert_false "TS5.5 plain word not known" is_known_slash "approved"

# --- parse_slash_command tests ---
echo "Test TS6: parse_slash_command"

# /approved standalone OK
result=$(parse_slash_command "/approved")
assert_eq "approved" "$result" "TS6.1 /approved → 'approved'"

# /skip with stage and reason
result=$(parse_slash_command "/skip plan reason here")
assert_eq "skip plan reason here" "$result" "TS6.2 /skip plan reason here → parsed"

# /approved with trailing text → still valid (per existing hook behavior)
result=$(parse_slash_command "/approved please go ahead")
assert_eq "approved please go ahead" "$result" "TS6.3 /approved with extra text → parsed"

# mixed slash → empty (rejected)
result=$(parse_slash_command "/approved /skip plan foo")
assert_eq "" "$result" "TS6.4 mixed slash /approved /skip → rejected (empty)"

# --- trim_leading then parse_slash_command integration ---
echo "Test TS7: trim_leading + parse_slash_command integration"
raw="  /skip research user asked to skip"
trimmed=$(trim_leading "$raw")
result=$(parse_slash_command "$trimmed")
assert_eq "skip research user asked to skip" "$result" "TS7.1 whitespace-trim + parse integration"

# --- Summary ---
echo "─────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
